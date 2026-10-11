#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; Engine.ahk - the data-driven workflow for one "steps" category (PLAN 5.3). Pure logic: no GUI, no files, no clock.
;
;   eng := WorkflowEngine(categoryMap)               ; a category Map from the config (kind "steps")
;   answers := Map()                                  ; stepId -> {option: "optionId", fields: Map(fieldId -> text)}
;   eng.VisibleSteps(answers)   -> [step Map, ...]    in config order; `when` is evaluated against VISIBLE steps only
;   eng.Stop(answers)           -> {Stopped, StepId, Message, Fragment, KeepSteps}
;   eng.StepState(id, answers)  -> "visible" | "hidden" | "locked"      (locked = after a stop)
;   eng.Validate(answers)       -> {Ok, Missing: [{stepId, fieldId, label}], Warnings}
;   eng.Flags(answers)          -> [message, ...] for the flags whose `when` is true (they never block)
;   eng.Fragments(answers)      -> {Fragments: [raw template text...], Values: Map, Stopped, Warnings}
;                                  The Composer fills the placeholders; Values = every field of the active steps
;                                  (field id -> text, "" when empty) + the chosen option's label under the STEP id.
;   eng.Warnings(answers)       -> [text...] about unknown step / option / field ids in the answers (ignored, never thrown)
;
; Rules
;   - A step is "visible" when it has no `when`, or its `when` is true. A condition {step, in} is false when that
;     step is hidden (or comes later in the list), {all} / {any} combine. Nothing else is evaluated: no scripting.
;   - A stop: the first visible choice/yesno step whose chosen option carries `stop`. Steps after it are LOCKED:
;     shown but disabled, not validated, no fragments. The note then holds only the fragments of the stop's
;     `keepSteps` (in step order, if they are visible) followed by the stop `fragment`.
;   - Answer retention: answers for hidden and locked steps are never deleted by the engine. They are only left out
;     of Validate / Fragments / Flags, so switching PWO -> TC -> PWO (or No -> Yes) brings the typed text back.
;   - A choice/yesno step contributes its chosen option's fragment, then the step's own `fragment`. A text/group
;     step contributes its `fragment` when any of its fields has text (or it has no fields).
;   - Every method tolerates junk: unknown ids in the answers are ignored and listed by Warnings(); nothing throws.

class WorkflowEngine {
    __New(category) {
        this.Category := category
        this.Steps := []
        this.ById := Map()
        this.Index := Map()
        this.FlagDefs := []
        if (category is Map && category.Has("steps") && category["steps"] is Array)
            for s in category["steps"]
                if (s is Map && s.Has("id") && s["id"] is String && !this.ById.Has(s["id"])) {
                    this.Steps.Push(s)
                    this.ById[s["id"]] := s
                    this.Index[s["id"]] := this.Steps.Length
                }
        if (category is Map && category.Has("flags") && category["flags"] is Array)
            for f in category["flags"]
                if (f is Map && f.Has("when") && f.Has("message"))
                    this.FlagDefs.Push(f)
    }

    ; --- answers accessors (an answer is {option, fields: Map}; a Map with the same keys is accepted too) -------
    static ChosenId(entry) {
        if !IsObject(entry)
            return ""
        try {
            if (entry is Map)
                return entry.Has("option") ? String(entry["option"]) : ""
            return entry.HasProp("option") ? String(entry.option) : ""
        }
        return ""
    }

    static FieldsOf(entry) {
        if !IsObject(entry)
            return Map()
        try {
            f := (entry is Map) ? (entry.Has("fields") ? entry["fields"] : "") : (entry.HasProp("fields") ? entry.fields : "")
            if (f is Map)
                return f
        }
        return Map()
    }

    static Entry(answers, stepId) => (answers is Map && answers.Has(stepId)) ? answers[stepId] : ""

    static FieldValue(entry, fieldId) {
        f := WorkflowEngine.FieldsOf(entry)
        return f.Has(fieldId) ? String(f[fieldId]) : ""
    }

    static Truthy(v) => (v = 1 || v = "1" || v = "true")

    static StepType(s) => s.Has("type") ? String(s["type"]) : ""

    static IsChoice(s) => (WorkflowEngine.StepType(s) = "choice" || WorkflowEngine.StepType(s) = "yesno")

    ; The option Map of a choice/yesno step, or "".
    OptionOf(s, optionId) {
        if (optionId = "" || !s.Has("options") || !(s["options"] is Array))
            return ""
        for o in s["options"]
            if (o is Map && o.Has("id") && o["id"] == optionId)
                return o
        return ""
    }

    ; The chosen option Map of a step ("" when nothing valid is chosen).
    ChosenOption(s, answers) => this.OptionOf(s, WorkflowEngine.ChosenId(WorkflowEngine.Entry(answers, s["id"])))

    FieldsList(s) {
        out := []
        if (s.Has("fields") && s["fields"] is Array)
            for f in s["fields"]
                if (f is Map && f.Has("id"))
                    out.Push(f)
        return out
    }

    ; --- conditions -----------------------------------------------------------------------------------
    ; `set`: Map of step ids that count as present. A step that is not in it evaluates to false.
    Cond(c, answers, set) {
        if !(c is Map)
            return false
        if c.Has("all") {
            if !(c["all"] is Array) || c["all"].Length = 0
                return false
            for x in c["all"]
                if !this.Cond(x, answers, set)
                    return false
            return true
        }
        if c.Has("any") {
            if !(c["any"] is Array)
                return false
            for x in c["any"]
                if this.Cond(x, answers, set)
                    return true
            return false
        }
        if (c.Has("step") && c.Has("in") && c["in"] is Array) {
            id := c["step"]
            if !(id is String) || !set.Has(id)
                return false
            chosen := WorkflowEngine.ChosenId(WorkflowEngine.Entry(answers, id))
            if (chosen = "")
                return false
            for v in c["in"]
                if (v is String && v == chosen)
                    return true
        }
        return false
    }

    ; --- visibility, stop, locking -----------------------------------------------------------------------
    ; Core pass: {Visible: [steps], VisSet: Map, Stop: {...}, StopIdx: index in Steps or 0, Active: [steps], ActSet: Map}
    ; Active = visible and not locked (everything up to and including the stop step).
    Analyse(answers) {
        vis := [], visSet := Map()
        for s in this.Steps
            if (!s.Has("when") || this.Cond(s["when"], answers, visSet)) {
                vis.Push(s)
                visSet[s["id"]] := true
            }
        stop := {Stopped: false, StepId: "", Message: "", Fragment: "", KeepSteps: []}
        stopIdx := 0
        for s in vis {
            if !WorkflowEngine.IsChoice(s)
                continue
            opt := this.ChosenOption(s, answers)
            if (IsObject(opt) && opt.Has("stop") && opt["stop"] is Map) {
                st := opt["stop"]
                stop.Stopped := true
                stop.StepId := s["id"]
                stop.Message := st.Has("message") ? String(st["message"]) : ""
                stop.Fragment := st.Has("fragment") ? String(st["fragment"]) : ""
                if (st.Has("keepSteps") && st["keepSteps"] is Array)
                    for k in st["keepSteps"]
                        stop.KeepSteps.Push(String(k))
                stopIdx := this.Index[s["id"]]
                break
            }
        }
        active := [], actSet := Map()
        for s in vis
            if (!stop.Stopped || this.Index[s["id"]] <= stopIdx) {
                active.Push(s)
                actSet[s["id"]] := true
            }
        return {Visible: vis, VisSet: visSet, Stop: stop, StopIdx: stopIdx, Active: active, ActSet: actSet}
    }

    VisibleSteps(answers) => this.Analyse(answers).Visible

    Stop(answers) => this.Analyse(answers).Stop

    StepState(stepId, answers) {
        if !this.ById.Has(stepId)
            return "hidden"
        a := this.Analyse(answers)
        if !a.VisSet.Has(stepId)
            return "hidden"
        return a.ActSet.Has(stepId) ? "visible" : "locked"
    }

    ; Is this field required right now? (`required`, or `requiredWhen` true). Needs the analysis of the same answers.
    FieldRequired(f, answers, a) {
        if (f.Has("required") && WorkflowEngine.Truthy(f["required"]))
            return true
        return f.Has("requiredWhen") && this.Cond(f["requiredWhen"], answers, a.VisSet)
    }

    ; --- validation --------------------------------------------------------------------------------------
    Validate(answers) {
        a := this.Analyse(answers)
        missing := []
        for s in a.Active {
            entry := WorkflowEngine.Entry(answers, s["id"])
            req := s.Has("required") && WorkflowEngine.Truthy(s["required"])
            flds := this.FieldsList(s)
            if WorkflowEngine.IsChoice(s) {
                if (req && !IsObject(this.ChosenOption(s, answers)))
                    missing.Push({stepId: s["id"], fieldId: "", label: this.Label(s)})
            } else if req {
                hasText := false
                for f in flds
                    if (Util.Trim(WorkflowEngine.FieldValue(entry, f["id"])) != "")
                        hasText := true
                if (!hasText)
                    missing.Push({stepId: s["id"], fieldId: "", label: this.Label(s)})
            }
            for f in flds
                if (this.FieldRequired(f, answers, a) && Util.Trim(WorkflowEngine.FieldValue(entry, f["id"])) = "")
                    missing.Push({stepId: s["id"], fieldId: f["id"], label: f.Has("label") ? String(f["label"]) : f["id"]})
        }
        return {Ok: missing.Length = 0, Missing: missing, Warnings: this.Warnings(answers)}
    }

    Label(s) => s.Has("label") ? String(s["label"]) : s["id"]

    ; --- flags --------------------------------------------------------------------------------------------
    Flags(answers) {
        a := this.Analyse(answers)
        out := []
        for f in this.FlagDefs
            if this.Cond(f["when"], answers, a.ActSet)
                out.Push(String(f["message"]))
        return out
    }

    ; --- fragments ----------------------------------------------------------------------------------------
    Fragments(answers) {
        a := this.Analyse(answers)
        frags := []
        values := Map()
        for s in a.Active {
            entry := WorkflowEngine.Entry(answers, s["id"])
            if WorkflowEngine.IsChoice(s) {
                opt := this.ChosenOption(s, answers)
                values[s["id"]] := IsObject(opt) && opt.Has("label") ? String(opt["label"]) : ""
            }
            for f in this.FieldsList(s)
                values[f["id"]] := WorkflowEngine.FieldValue(entry, f["id"])
        }
        if a.Stop.Stopped {
            keep := Map()
            for k in a.Stop.KeepSteps
                keep[k] := true
            for s in a.Active
                if (keep.Has(s["id"]) && s["id"] != a.Stop.StepId)
                    this.StepFragments(s, answers, frags)
            if (Util.Trim(a.Stop.Fragment) != "")
                frags.Push(a.Stop.Fragment)
        } else
            for s in a.Active
                this.StepFragments(s, answers, frags)
        return {Fragments: frags, Values: values, Stopped: a.Stop.Stopped, Warnings: this.Warnings(answers)}
    }

    StepFragments(s, answers, out) {
        entry := WorkflowEngine.Entry(answers, s["id"])
        sf := s.Has("fragment") ? String(s["fragment"]) : ""
        if WorkflowEngine.IsChoice(s) {
            opt := this.ChosenOption(s, answers)
            if !IsObject(opt)
                return
            of := opt.Has("fragment") ? String(opt["fragment"]) : ""
            if (Util.Trim(of) != "")
                out.Push(of)
            if (Util.Trim(sf) != "")
                out.Push(sf)
            return
        }
        if (Util.Trim(sf) = "")
            return
        flds := this.FieldsList(s)
        if (flds.Length > 0) {
            hasText := false
            for f in flds
                if (Util.Trim(WorkflowEngine.FieldValue(entry, f["id"])) != "")
                    hasText := true
            if !hasText
                return
        }
        out.Push(sf)
    }

    ; --- junk in the answers --------------------------------------------------------------------------------
    ; Ids the config does not know (a changed config, a damaged History file). They are ignored everywhere.
    Warnings(answers) {
        out := []
        if !(answers is Map)
            return out
        for id, entry in answers {
            if !this.ById.Has(id) {
                out.Push('Unknown step "' id '" in the answers (ignored).')
                continue
            }
            s := this.ById[id]
            chosen := WorkflowEngine.ChosenId(entry)
            if (chosen != "" && !IsObject(this.OptionOf(s, chosen)))
                out.Push('Unknown option "' chosen '" for step "' id '" (ignored).')
            known := Map()
            for f in this.FieldsList(s)
                known[f["id"]] := true
            for fid, v in WorkflowEngine.FieldsOf(entry)
                if !known.Has(fid)
                    out.Push('Unknown field "' fid '" for step "' id '" (ignored).')
        }
        return out
    }
}
