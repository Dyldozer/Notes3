#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\..\Context\CallContext.ahk
#Include %A_LineFile%\..\..\Workflow\Engine.ahk
#Include %A_LineFile%\..\..\Workflow\Items.ahk
#Include %A_LineFile%\..\..\Net\StaticModel.ahk
; CallSession.ahk - the call in progress. Pure logic: no GUI.
; Which categories the agent used (first-use order, no duplicates), per-category workflow ANSWERS (steps
; categories: stepId -> {option, fields: Map}), the note fragments and field VALUES derived from them (the
; WorkflowEngine output; items/static categories and the dev panel put fragments in directly), the context
; snapshot taken when the call began, the notes-box text (NoteText), the last generated note (GeneratedText)
; and whether the agent edited the box (AgentEdited).
;
; Answers for steps that are hidden or locked are KEPT here (the engine only leaves them out of the note and the
; validation), so switching PWO -> TC -> PWO brings the typed text back.
;
; Items categories (Equipment, Billing) keep a list of ENTRIES {action, item, qty, outcome, details} (plain objects
; of strings). Every change to the list runs the category's ItemsModel and REPLACES that category's fragments and
; values; the caller marks the category used (App.AddEntry).
;
; Static categories keep one STATE object (StaticModel: the IP utility boxes, the include switch, the ping choice). Every
; change runs the category's StaticModel and REPLACES that category's fragments and values; the caller marks the category
; used (App.StaticSet).
;
; Snapshot() -> plain Map/Array tree (JSON-able) for History; Restore(snap) loads it back and marks every
; context value "history" (never live). Snapshot categories.<id> = {fragments, values, answers?, entries?, static?}:
; `answers`, `entries` and `static` are only present when there is something, and snapshots without them (made before
; M5 / M6 / M7) still restore.

class CallSession {
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.Logger := o.HasOwnProp("Logger") ? o.Logger : ""
        this.Used := []
        this.Answers := Map()         ; categoryId -> engine answers: Map stepId -> {option, fields: Map}
        this.Vals := Map()            ; categoryId -> Map of placeholder values ({fieldId}, {stepId}) for the Composer
        this.Entries := Map()         ; categoryId -> Array of items entries {action, item, qty, outcome, details}
        this.StaticSt := Map()          ; categoryId -> static state object (StaticModel)
        this.Frags := Map()           ; categoryId -> Array of fragment texts
        this.Context := CallContext()  ; snapshot at the start of the call
        this.NoteText := ""           ; what the notes box holds now
        this.GeneratedText := ""      ; what the composer last put in the box
        this.AgentEdited := false
        this._subs := []
    }

    ; Mark a category as used. True when it was newly added.
    UseCategory(id) {
        id := Util.Trim(id)
        if (id = "")
            return false
        for x in this.Used
            if (x = id)
                return false
        this.Used.Push(id)
        if !this.Answers.Has(id)
            this.Answers[id] := Map()
        this._Notify()
        return true
    }

    IsUsed(id) {
        for x in this.Used
            if (x = id)
                return true
        return false
    }

    ; A copy, in first-use order.
    UsedCategories() {
        out := []
        for x in this.Used
            out.Push(x)
        return out
    }

    ; --- fragments and values ----------------------------------------------------
    Values => this.Vals

    ; The placeholder values of one category (created on first access).
    ValuesFor(id) {
        if !this.Vals.Has(id)
            this.Vals[id] := Map()
        return this.Vals[id]
    }

    ; The workflow answers of one category: stepId -> {option, fields: Map} (created on first access).
    AnswersFor(id) {
        if !this.Answers.Has(id)
            this.Answers[id] := Map()
        return this.Answers[id]
    }

    ; --- workflow answers ------------------------------------------------------------------------------
    ; Choose / Type change the answers, then (when an engine is given) replace the category's fragments and values
    ; with the engine output and tell the subscribers once. Returns false when nothing changed.
    Choose(catId, stepId, optionId, engine := "") {
        m := this.AnswersFor(catId)
        cur := WorkflowEngine.ChosenId(WorkflowEngine.Entry(m, stepId))
        optionId := String(optionId)
        if (cur == optionId)
            return false
        if !m.Has(stepId)
            m[stepId] := {option: "", fields: Map()}
        m[stepId].option := optionId
        this._AnswersChanged(catId, engine)
        return true
    }

    Type(catId, stepId, fieldId, text, engine := "") {
        m := this.AnswersFor(catId)
        text := String(text)
        old := WorkflowEngine.FieldValue(WorkflowEngine.Entry(m, stepId), fieldId)
        if (old == text)
            return false
        if !m.Has(stepId) {
            if (text = "")
                return false
            m[stepId] := {option: "", fields: Map()}
        }
        m[stepId].fields[fieldId] := text
        this._AnswersChanged(catId, engine)
        return true
    }

    ; Re-run the engine for a category (after Restore, or when the config changed) and replace its fragments/values.
    ApplyEngine(catId, engine) {
        r := engine.Fragments(this.AnswersFor(catId))
        if (r.Fragments.Length > 0)
            this.Frags[catId] := r.Fragments
        else
            CallSession.Drop(this.Frags, catId)
        this.Vals[catId] := r.Values
        return r
    }

    _AnswersChanged(catId, engine) {
        if IsObject(engine)
            this.ApplyEngine(catId, engine)
        this._Notify()
    }

    ; --- items entries -----------------------------------------------------------------------------------------
    ; The live entry list of one category (created on first access). Callers must not change it directly.
    EntriesFor(catId) {
        if !this.Entries.Has(catId)
            this.Entries[catId] := []
        return this.Entries[catId]
    }

    ; True when the category has any entry.
    HasEntries(catId) => this.Entries.Has(catId) && this.Entries[catId].Length > 0

    ; Add an entry to the end of the list. With a model the entry is validated and a duplicate (same printed sentence)
    ; is refused. Returns {Ok, Error, Index, Missing}; nothing changes when Ok is false.
    AddEntry(catId, entry, model := "") {
        e := IsObject(model) ? model.Clean(entry) : ItemsModel.Norm(entry)
        bad := this._CheckEntry(catId, e, model, 0)
        if (bad != "")
            return bad
        list := this.EntriesFor(catId)
        list.Push(e)
        this._EntriesChanged(catId, model)
        return {Ok: true, Error: "", Index: list.Length, Missing: []}
    }

    ; Replace the entry at a 1-based index (same checks as AddEntry; the entry itself is not its own duplicate).
    UpdateEntry(catId, index, entry, model := "") {
        list := this.EntriesFor(catId)
        if !(index is Integer) || index < 1 || index > list.Length
            return {Ok: false, Error: "That entry is no longer in the list.", Index: 0, Missing: []}
        e := IsObject(model) ? model.Clean(entry) : ItemsModel.Norm(entry)
        bad := this._CheckEntry(catId, e, model, index)
        if (bad != "")
            return bad
        if (list[index].action == e.action && list[index].item == e.item && list[index].qty == e.qty
                && list[index].outcome == e.outcome && list[index].details == e.details)
            return {Ok: true, Error: "", Index: index, Missing: []}           ; nothing changed
        list[index] := e
        this._EntriesChanged(catId, model)
        return {Ok: true, Error: "", Index: index, Missing: []}
    }

    RemoveEntry(catId, index, model := "") {
        list := this.EntriesFor(catId)
        if !(index is Integer) || index < 1 || index > list.Length
            return false
        list.RemoveAt(index)
        this._EntriesChanged(catId, model)
        return true
    }

    ; Move the entry at `from` to position `to` (both 1-based). False when either is out of range or they are equal.
    MoveEntry(catId, from, to, model := "") {
        list := this.EntriesFor(catId)
        if !(from is Integer) || !(to is Integer) || from < 1 || to < 1 || from > list.Length || to > list.Length || from = to
            return false
        e := list.RemoveAt(from)
        list.InsertAt(to, e)
        this._EntriesChanged(catId, model)
        return true
    }

    _CheckEntry(catId, e, model, skipIndex) {
        if !IsObject(model)
            return ""
        v := model.Validate(e)
        if !v.Ok
            return {Ok: false, Error: "Missing or invalid: " ItemsModel.MissingText(v) ".", Index: 0, Missing: v.Missing}
        if (model.FindDuplicate(this.EntriesFor(catId), e, skipIndex) > 0)
            return {Ok: false, Error: ItemsModel.DupMessage(), Index: 0, Missing: [], Duplicate: true}
        return ""
    }

    ; Replace the category's fragments and values with the model output for its entries (also used after a History
    ; load or a config change). Returns the model result.
    ApplyEntries(catId, model) {
        r := model.Fragments(this.EntriesFor(catId))
        if (r.Fragments.Length > 0)
            this.Frags[catId] := r.Fragments
        else
            CallSession.Drop(this.Frags, catId)
        if (r.Values.Count > 0)
            this.Vals[catId] := r.Values
        else
            CallSession.Drop(this.Vals, catId)
        return r
    }

    _EntriesChanged(catId, model) {
        if IsObject(model)
            this.ApplyEntries(catId, model)
        this._Notify()
    }

    ; --- static state ------------------------------------------------------------------------------------------
    ; The state of a static category (a fresh default when nothing was entered). Callers must not change it directly.
    StaticFor(catId) => this.StaticSt.Has(catId) ? this.StaticSt[catId] : StaticModel.NewState()

    HasStatic(catId) => this.StaticSt.Has(catId) && !StaticModel.IsDefault(this.StaticSt[catId])

    ; True when any static category holds typed input or choices (these are not "content" for the note or History, but
    ; Clear All must still empty them).
    HasStaticInput() {
        for id, st in this.StaticSt
            if !StaticModel.IsDefault(st)
                return true
        return false
    }

    ; Store a new state. With a model the category's fragments and values are replaced with the model output.
    SetStatic(catId, state, model := "") {
        this.StaticSt[catId] := state
        if IsObject(model)
            this.ApplyStatic(catId, model)
        this._Notify()
    }

    ; Replace the category's fragments and values with the model output for its state (also after a config change).
    ApplyStatic(catId, model) {
        r := model.Fragments(this.StaticFor(catId))
        if (r.Fragments.Length > 0)
            this.Frags[catId] := r.Fragments
        else
            CallSession.Drop(this.Frags, catId)
        if (r.Values.Count > 0)
            this.Vals[catId] := r.Values
        else
            CallSession.Drop(this.Vals, catId)
        return r
    }

    ; "Reset this category": forget its answers, entries, fragments and values. It stays used (stats keep it).
    ResetCategory(catId) {
        this.Answers[catId] := Map()
        CallSession.Drop(this.Entries, catId)
        CallSession.Drop(this.StaticSt, catId)
        CallSession.Drop(this.Frags, catId)
        CallSession.Drop(this.Vals, catId)
        this._Notify()
    }

    ; Map.Delete throws for a key that is not there.
    static Drop(m, key) {
        if m.Has(key)
            m.Delete(key)
    }

    ; True when the category has any answer.
    HasAnswers(catId) => this.Answers.Has(catId) && this.Answers[catId].Count > 0

    ; Add a note fragment to a category (does not mark the category used: the caller does, via App.UseCategory).
    AddFragment(catId, text) {
        catId := Util.Trim(catId)
        if (catId = "" || Util.Trim(text) = "")
            return false
        if !this.Frags.Has(catId)
            this.Frags[catId] := []
        this.Frags[catId].Push(String(text))
        this._Notify()
        return true
    }

    ; Remove the fragment at a 1-based index.
    RemoveFragment(catId, index) {
        if !this.Frags.Has(catId) || !(index is Integer) || index < 1 || index > this.Frags[catId].Length
            return false
        this.Frags[catId].RemoveAt(index)
        if (this.Frags[catId].Length = 0)
            this.Frags.Delete(catId)
        this._Notify()
        return true
    }

    ; A copy of the category's fragments, in the order added.
    Fragments(catId) {
        out := []
        if this.Frags.Has(catId)
            for x in this.Frags[catId]
                out.Push(x)
        return out
    }

    ; Set an answer value a fragment placeholder can use (e.g. supervisorName).
    SetValue(catId, name, value) {
        this.ValuesFor(catId)[name] := String(value)
        this._Notify()
        return true
    }

    ; True when the agent entered anything for this call: a used category, any fragment or value, or
    ; non-blank note text. The context alone is not content.
    HasContent() => this.HasStructured() || Util.Trim(this.NoteText) != ""

    ; A used category, a fragment or an answer value (everything except the note text itself).
    HasStructured() {
        if (this.Used.Length > 0)
            return true
        for id, m in this.Answers
            if (m is Map && m.Count > 0)
                return true
        for id, m in this.Vals
            if (m is Map && m.Count > 0)
                return true
        for id, a in this.Entries
            if (a.Length > 0)
                return true
        for id, a in this.Frags
            if (a.Length > 0)
                return true
        return false
    }

    ; Forget categories, answers, fragments and note state. The context snapshot stays (Clear All is the same call).
    Reset() {
        this._Clear()
        this._Notify()
        return this
    }

    ; A new call: reset and take a snapshot of the context.
    BeginCall(ctx) {
        this._Clear()
        this.Context := ctx.Clone()
        this._Notify()
        return this
    }

    _Clear() {
        this.Used := []
        this.Answers := Map()
        this.Vals := Map()
        this.Entries := Map()
        this.StaticSt := Map()
        this.Frags := Map()
        this.NoteText := ""
        this.GeneratedText := ""
        this.AgentEdited := false
    }

    ; --- history snapshot ----------------------------------------------------------
    ; Plain Map/Array tree: {context: {id: {value, status}}, categoriesUsed: [], categories: {id: {fragments: [],
    ; values: {}, answers?: {stepId: {option, fields: {}}}, entries?: [{action, item, qty, outcome, details}]}},
    ; noteText, generatedText, agentEdited (0/1)}.
    ; Categories without fragments, values, answers or entries are left out; `answers` / `entries` when empty.
    Snapshot() {
        ctx := Map()
        for id, f in this.Context.Fields
            ctx[id] := Map("value", f.Value, "status", f.Status)
        used := []
        for x in this.Used
            used.Push(x)
        cats := Map()
        for id, a in this.Frags
            cats[id] := Map("fragments", this.Fragments(id), "values", Map())
        for id, m in this.Vals {
            if !(m is Map) || m.Count = 0
                continue
            if !cats.Has(id)
                cats[id] := Map("fragments", [], "values", Map())
            for k, v in m
                cats[id]["values"][k] := String(v)
        }
        for id, m in this.Answers {
            tree := CallSession.AnswersToTree(m)
            if (tree.Count = 0)
                continue
            if !cats.Has(id)
                cats[id] := Map("fragments", [], "values", Map())
            cats[id]["answers"] := tree
        }
        for id, list in this.Entries {
            if (list.Length = 0)
                continue
            if !cats.Has(id)
                cats[id] := Map("fragments", [], "values", Map())
            arr := []
            for e in list
                arr.Push(ItemsModel.ToMap(e))
            cats[id]["entries"] := arr
        }
        for id, st in this.StaticSt {
            if StaticModel.IsDefault(st)
                continue
            if !cats.Has(id)
                cats[id] := Map("fragments", [], "values", Map())
            cats[id]["static"] := StaticModel.ToMap(st)
        }
        return Map("context", ctx, "categoriesUsed", used, "categories", cats,
            "noteText", this.NoteText, "generatedText", this.GeneratedText, "agentEdited", this.AgentEdited ? 1 : 0)
    }

    ; answers (stepId -> {option, fields}) -> plain Map tree; steps with nothing in them and junk entries are left out.
    static AnswersToTree(m) {
        tree := Map()
        if !(m is Map)
            return tree
        for stepId, e in m {
            if !IsObject(e)
                continue
            opt := WorkflowEngine.ChosenId(e)
            fl := WorkflowEngine.FieldsOf(e)
            if (opt = "" && fl.Count = 0)
                continue
            fm := Map()
            for k, v in fl
                fm[k] := String(v)
            tree[stepId] := Map("option", opt, "fields", fm)
        }
        return tree
    }

    ; the reverse (a damaged or hand-edited tree gives whatever is usable)
    static AnswersFromTree(tree) {
        m := Map()
        if !(tree is Map)
            return m
        for stepId, e in tree {
            if !(e is Map)
                continue
            fm := Map()
            if (e.Has("fields") && e["fields"] is Map)
                for k, v in e["fields"]
                    fm[k] := String(v)
            opt := e.Has("option") ? String(e["option"]) : ""
            if (opt = "" && fm.Count = 0)
                continue
            m[stepId] := {option: opt, fields: fm}
        }
        return m
    }

    ; Load a snapshot back. Every context value becomes "history" (fields that had no value stay empty /
    ; unavailable). Returns false (and changes nothing) when the snapshot is not usable.
    Restore(snap) {
        if !(snap is Map) || !snap.Has("context") || !(snap["context"] is Map)
            return false
        ctx := CallContext()
        for id, f in snap["context"] {
            if !(f is Map) || !f.Has("value")
                continue
            v := String(f["value"])
            st := f.Has("status") ? f["status"] : "empty"
            if (v != "")
                ctx.Set(id, v, "history", "history")
            else
                ctx.Set(id, "", st = "unavailable" ? "unavailable" : "empty", "history")
        }
        used := []
        if snap.Has("categoriesUsed") && (snap["categoriesUsed"] is Array)
            for x in snap["categoriesUsed"]
                used.Push(String(x))
        frags := Map(), vals := Map(), answers := Map(), entries := Map(), statics := Map()
        if snap.Has("categories") && (snap["categories"] is Map)
            for id, c in snap["categories"] {
                if !(c is Map)
                    continue
                if c.Has("fragments") && (c["fragments"] is Array) && c["fragments"].Length > 0 {
                    a := []
                    for x in c["fragments"]
                        a.Push(String(x))
                    frags[id] := a
                }
                if c.Has("values") && (c["values"] is Map) && c["values"].Count > 0 {
                    m := Map()
                    for k, v in c["values"]
                        m[k] := String(v)
                    vals[id] := m
                }
                if c.Has("answers") && (c["answers"] is Map) {
                    am := CallSession.AnswersFromTree(c["answers"])
                    if (am.Count > 0)
                        answers[id] := am
                }
                if c.Has("entries") && (c["entries"] is Array) {
                    list := []
                    for x in c["entries"]
                        if (x is Map)
                            list.Push(ItemsModel.Norm(x))
                    if (list.Length > 0)
                        entries[id] := list
                }
                if c.Has("static") && (c["static"] is Map) {
                    st := StaticModel.FromMap(c["static"])
                    if IsObject(st) && !StaticModel.IsDefault(st)
                        statics[id] := st
                }
            }
        this.Context := ctx
        this.Used := used
        this.Frags := frags
        this.Vals := vals
        this.Answers := answers
        this.Entries := entries
        this.StaticSt := statics
        this.NoteText := snap.Has("noteText") ? String(snap["noteText"]) : ""
        this.GeneratedText := snap.Has("generatedText") ? String(snap["generatedText"]) : ""
        this.AgentEdited := snap.Has("agentEdited") && snap["agentEdited"] ? true : false
        this._Notify()
        return true
    }

    OnChanged(fn) {
        this._subs.Push(fn)
        return this
    }

    _Notify() {
        copy := []
        for fn in this._subs
            copy.Push(fn)
        for fn in copy {
            try fn(this)
            catch as e {
                if IsObject(this.Logger)
                    try this.Logger.Warn("session subscriber failed", {error: e.Message})
            }
        }
    }
}
