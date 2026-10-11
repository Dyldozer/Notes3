#Requires AutoHotkey v2.0
; TestEngine.ahk - WorkflowEngine (PLAN 5.3, M5): visibility, stop/lock, validation, flags, fragments, retention,
; junk tolerance, and the exhaustive Not Done branch test (4 reasons x 3 order types x TC yes/no x 4 contacts x 4 outcomes).

class TestEngine {
    static Name := "Engine"

    static Run() {
        for name in ["Skeleton", "NoAnswers", "Exhaustive", "Missing", "PwoRequired", "TcRequired", "StopLocks", "Retention",
                "Flags", "HiddenConditions", "Junk", "RequiredWhen", "RequiredSteps", "FragmentRules", "ValuesMap",
                "StopVariants", "Pure", "CloseJob", "BadCategory"]
            T.Case(name, ObjBindMethod(TestEngine, name))
    }

    ; --- fixtures -----------------------------------------------------------------------------
    static Cfg() => Defaults.Config()

    static NotDone() => WorkflowEngine(Defaults.Config()["categories"][1])

    ; answers: put each step with its option and fields. Usage: A("reason", "r1", "orderType", "pwo", ...)
    static A(pairs*) {
        m := Map()
        i := 1
        while (i < pairs.Length) {
            m[pairs[i]] := {option: pairs[i + 1], fields: Map()}
            i += 2
        }
        return m
    }

    static Put(ans, step, opt := "", fields := "") {
        f := Map()
        if IsObject(fields)
            for k, v in fields
                f[k] := v
        ans[step] := {option: opt, fields: f}
        return ans
    }

    ; a complete Not Done answer set
    static Full(reason, order, tc, contact, outcome) {
        ans := Map()
        TestEngine.Put(ans, "reason", reason)
        TestEngine.Put(ans, "orderType", order)
        if (order = "pwo")
            TestEngine.Put(ans, "supervisorPwo", "", Map("supervisorName", "Pat Lee", "rescheduleReason", "Moved"))
        if (order = "tc")
            TestEngine.Put(ans, "supervisorTc", tc, Map("supervisorNameTc", tc = "yes" ? "Sam Ray" : ""))
        TestEngine.Put(ans, "contact", contact, Map("contactDetails", ""))
        TestEngine.Put(ans, "outcome", outcome)
        return ans
    }

    static Ids(steps) {
        s := ""
        for x in steps
            s .= (s = "" ? "" : ",") x["id"]
        return s
    }

    static Join(arr, sep := "|") {
        s := ""
        for x in arr
            s .= (s = "" ? "" : sep) x
        return s
    }

    static MissingIds(r) {
        s := ""
        for m in r.Missing
            s .= (s = "" ? "" : ",") m.stepId (m.fieldId != "" ? "." m.fieldId : "")
        return s
    }

    ; The note's Notes: text for a category's engine output, through the real session + Composer.
    static NoteOf(eng, ans, cfg := "") {
        if !IsObject(cfg)
            cfg := Defaults.Config()
        ses := CallSession()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        c.Set("techId", "T12345", "mock")
        c.Set("jobNumber", "88412", "mock")
        ses.BeginCall(c)
        ses.UseCategory("notDone")
        for k, v in ans
            ses.AnswersFor("notDone")[k] := v
        ses.ApplyEngine("notDone", eng)
        res := Composer.Compose(ses.Context, ses, cfg)
        return SubStr(res.Text, InStr(res.Text, "Notes:") + 7)
    }

    ; --- tests -----------------------------------------------------------------------------------
    static Skeleton() {
        eng := TestEngine.NotDone()
        T.Eq(TestEngine.Ids(eng.Steps), "reason,orderType,supervisorPwo,supervisorTc,contact,outcome", "steps indexed in order")
        T.Eq(eng.FlagDefs.Length, 1, "one flag definition")
        T.True(eng.ById.Has("supervisorTc"), "ById")
    }

    static NoAnswers() {
        eng := TestEngine.NotDone()
        ans := Map()
        T.Eq(TestEngine.Ids(eng.VisibleSteps(ans)), "reason,orderType,contact,outcome", "before an order type is chosen no supervisor step shows")
        T.False(eng.Stop(ans).Stopped, "no stop")
        T.Eq(eng.StepState("reason", ans), "visible", "reason visible")
        T.Eq(eng.StepState("supervisorPwo", ans), "hidden", "PWO supervisor hidden")
        T.Eq(eng.StepState("supervisorTc", ans), "hidden", "TC supervisor hidden")
        T.Eq(eng.StepState("nope", ans), "hidden", "unknown step: hidden, no throw")
        r := eng.Validate(ans)
        T.False(r.Ok, "empty answers are invalid")
        T.Eq(TestEngine.MissingIds(r), "reason,orderType,contact,outcome", "the four required choices are missing")
        T.Eq(r.Missing[1].label, "Reason (placeholder)", "missing item carries the step label")
        T.Eq(r.Missing[1].fieldId, "", "a step-level item has no field id")
        T.Eq(eng.Fragments(ans).Fragments.Length, 0, "no fragments")
        T.Eq(eng.Flags(ans).Length, 0, "no flags")
    }

    ; Every combination, checked against an independent description of the expected result.
    static Exhaustive() {
        cfg := Defaults.Config()
        eng := WorkflowEngine(cfg["categories"][1])
        order := Map("pwo", "PWO", "tc", "TC", "sro", "SRO")
        combos := 0
        bad := 0
        for ri in [1, 2, 3, 4]
            for ot in ["pwo", "tc", "sro"]
                for tcv in (ot = "tc" ? ["yes", "no"] : [""])
                    for ci in [1, 2, 3, 4]
                        for oi in [1, 2, 3, 4] {
                            combos += 1
                            ans := TestEngine.Full("r" ri, ot, tcv, "c" ci, "o" oi)
                            stopped := (ot = "tc" && tcv = "no")
                            ; expected, written out by hand
                            vis := "reason,orderType," (ot = "pwo" ? "supervisorPwo," : ot = "tc" ? "supervisorTc," : "") "contact,outcome"
                            lock := stopped ? "contact:locked,outcome:locked" : "contact:visible,outcome:visible"
                            frags := ["Reason " ri " placeholder note.", "Order type " order[ot] " placeholder note."]
                            if stopped
                                frags.Push("Tech has not contacted supervisor; advised tech to contact supervisor before calling back.")
                            else {
                                if (ot = "pwo")
                                    frags.Push("Supervisor {supervisorName} placeholder note. Reschedule reason {rescheduleReason} placeholder note.")
                                if (ot = "tc")
                                    frags.Push("Tech spoke with supervisor {supervisorNameTc} placeholder note.")
                                frags.Push("Contact " ci " placeholder note. {contactDetails}", "Outcome " oi " placeholder note.")
                            }
                            note := "Reason " ri " placeholder note. Order type " order[ot] " placeholder note."
                            if stopped
                                note .= " Tech has not contacted supervisor; advised tech to contact supervisor before calling back."
                            else {
                                if (ot = "pwo")
                                    note .= " Supervisor Pat Lee placeholder note. Reschedule reason Moved placeholder note."
                                if (ot = "tc")
                                    note .= " Tech spoke with supervisor Sam Ray placeholder note."
                                note .= " Contact " ci " placeholder note. Outcome " oi " placeholder note."
                            }
                            expect := vis "#" lock "#valid#" (stopped ? "stopped:supervisorTc" : "go") "#" TestEngine.Join(frags) "#" note
                            ; actual, from the engine
                            st := eng.Stop(ans)
                            fr := eng.Fragments(ans)
                            v := eng.Validate(ans)
                            actual := TestEngine.Ids(eng.VisibleSteps(ans)) "#"
                                . "contact:" eng.StepState("contact", ans) ",outcome:" eng.StepState("outcome", ans) "#"
                                . (v.Ok ? "valid" : "INVALID " TestEngine.MissingIds(v)) "#"
                                . (st.Stopped ? "stopped:" st.StepId : "go") "#" TestEngine.Join(fr.Fragments) "#"
                                . TestEngine.NoteOf(eng, ans, cfg)
                            if !(actual == expect) {
                                bad += 1
                                T.Record(false, "branch r" ri "/" ot "/" tcv "/c" ci "/o" oi, "expected [" expect "] got [" actual "]")
                            }
                            ; hidden supervisor step state, the other order types' steps
                            if (ot != "pwo" && eng.StepState("supervisorPwo", ans) != "hidden") {
                                bad += 1
                                T.Record(false, "supervisorPwo hidden for " ot)
                            }
                            if (ot != "tc" && eng.StepState("supervisorTc", ans) != "hidden") {
                                bad += 1
                                T.Record(false, "supervisorTc hidden for " ot)
                            }
                        }
        T.Eq(combos, 4 * (1 + 2 + 1) * 4 * 4, "all 256 combinations were walked")
        T.Eq(bad, 0, "every combination: visibility, lock state, validity, stop, exact fragments and exact note line")
    }

    ; Every single required answer, removed one at a time, over all orders.
    static Missing() {
        eng := TestEngine.NotDone()
        for ot in ["pwo", "tc", "sro"] {
            ans := TestEngine.Full("r1", ot, ot = "tc" ? "yes" : "", "c1", "o1")
            T.True(eng.Validate(ans).Ok, ot ": complete answers are valid")
            for step in ["reason", "orderType", "contact", "outcome"] {
                a2 := TestEngine.Full("r1", ot, ot = "tc" ? "yes" : "", "c1", "o1")
                a2.Delete(step)
                r := eng.Validate(a2)
                T.False(r.Ok, ot ": missing " step " is invalid")
                if (step != "orderType")
                    T.Eq(TestEngine.MissingIds(r), step, ot ": only " step " is listed")
            }
        }
        ans := TestEngine.Full("r1", "pwo", "", "c1", "o1")
        ans["orderType"].option := "zzz"
        T.False(eng.Validate(ans).Ok, "an option id that does not exist counts as not chosen")
        ans := TestEngine.Full("r1", "pwo", "", "c1", "o1")
        ans["reason"].option := ""
        T.False(eng.Validate(ans).Ok, "an empty option id counts as not chosen")
    }

    static PwoRequired() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r1", "pwo", "", "c1", "o1")
        TestEngine.Put(ans, "supervisorPwo")
        r := eng.Validate(ans)
        T.Eq(TestEngine.MissingIds(r), "supervisorPwo.supervisorName,supervisorPwo.rescheduleReason", "PWO without name and reschedule reason lists both")
        T.Eq(r.Missing[1].label, "Supervisor name", "field label")
        T.Eq(r.Missing[2].label, "Reason for reschedule", "second field label")
        T.Eq(r.Missing[1].stepId, "supervisorPwo", "step id on a field item")
        TestEngine.Put(ans, "supervisorPwo", "", Map("supervisorName", "Pat"))
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "supervisorPwo.rescheduleReason", "only the reschedule reason missing")
        TestEngine.Put(ans, "supervisorPwo", "", Map("supervisorName", "   ", "rescheduleReason", "Moved"))
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "supervisorPwo.supervisorName", "a blank name is missing")
        TestEngine.Put(ans, "supervisorPwo", "", Map("supervisorName", "Pat", "rescheduleReason", "a`nb"))
        T.True(eng.Validate(ans).Ok, "multi-line reschedule reason is fine")
        ans.Delete("supervisorPwo")
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "supervisorPwo.supervisorName,supervisorPwo.rescheduleReason", "no entry at all is the same")
        T.False(eng.Fragments(ans).Fragments.Length = 0, "the other steps still produce fragments")
        fr := eng.Fragments(ans).Fragments
        T.Eq(fr.Length, 4, "no PWO supervisor fragment while both fields are empty (reason, order type, contact, outcome)")
    }

    static TcRequired() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r1", "tc", "yes", "c1", "o1")
        TestEngine.Put(ans, "supervisorTc", "yes", Map("supervisorNameTc", ""))
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "supervisorTc.supervisorNameTc", "TC yes without a name is invalid")
        TestEngine.Put(ans, "supervisorTc", "yes", Map("supervisorNameTc", "Sam"))
        T.True(eng.Validate(ans).Ok, "TC yes with a name is valid")
        TestEngine.Put(ans, "supervisorTc", "", Map("supervisorNameTc", "Sam"))
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "supervisorTc", "the question itself is required")
        TestEngine.Put(ans, "supervisorTc", "no", Map())
        T.True(eng.Validate(ans).Ok, "TC no needs no name")
        T.Eq(eng.Validate(ans).Missing.Length, 0, "nothing missing")
    }

    static StopLocks() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r2", "tc", "no", "c3", "o4")
        st := eng.Stop(ans)
        T.True(st.Stopped, "No stops")
        T.Eq(st.StepId, "supervisorTc", "stop step")
        T.Eq(st.Message, "The tech must contact their supervisor before calling back.", "stop message")
        T.Eq(st.KeepSteps.Length, 2, "keepSteps")
        T.Eq(st.KeepSteps[1] "," st.KeepSteps[2], "reason,orderType", "keepSteps content")
        T.Eq(eng.StepState("supervisorTc", ans), "visible", "the stop step itself stays usable")
        T.Eq(eng.StepState("contact", ans), "locked", "contact locked")
        T.Eq(eng.StepState("outcome", ans), "locked", "outcome locked")
        T.Eq(eng.StepState("reason", ans), "visible", "earlier steps stay visible")
        T.Eq(TestEngine.Ids(eng.VisibleSteps(ans)), "reason,orderType,supervisorTc,contact,outcome", "locked steps are still listed (shown disabled)")
        ; locked steps are not validated, even when they are empty
        a2 := TestEngine.Full("r2", "tc", "no", "", "")
        a2.Delete("contact")
        a2.Delete("outcome")
        T.True(eng.Validate(a2).Ok, "empty locked steps do not make the call invalid")
        ; ... but an earlier missing answer still does
        a2.Delete("reason")
        T.Eq(TestEngine.MissingIds(eng.Validate(a2)), "reason", "an unanswered step before the stop is still required")
        fr := eng.Fragments(ans)
        T.Eq(TestEngine.Join(fr.Fragments), "Reason 2 placeholder note.|Order type TC placeholder note.|Tech has not contacted supervisor; advised tech to contact supervisor before calling back.", "only keepSteps fragments + the stop fragment")
        T.True(fr.Stopped, "Fragments reports the stop")
        T.False(fr.Values.Has("contact"), "no values from locked steps")
        T.False(fr.Values.Has("contactDetails"), "no field values from locked steps")
        ; a pending stop is not triggered by the other option
        T.False(eng.Stop(TestEngine.Full("r2", "tc", "yes", "c3", "o4")).Stopped, "Yes does not stop")
        ; the stop does not apply when its step is hidden (answer kept from a PWO/TC switch)
        a3 := TestEngine.Full("r2", "pwo", "", "c3", "o4")
        TestEngine.Put(a3, "supervisorTc", "no")
        T.False(eng.Stop(a3).Stopped, "a retained No on a hidden step stops nothing")
        T.Eq(eng.StepState("contact", a3), "visible", "so later steps stay open")
        T.Eq(eng.Fragments(a3).Fragments.Length, 5, "and the PWO note is complete")
    }

    static Retention() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r3", "pwo", "", "c2", "o2")
        before := ConfigJson.Canon(CallSession.AnswersToTree(ans))
        ; PWO -> TC -> PWO
        ans["orderType"].option := "tc"
        TestEngine.Put(ans, "supervisorTc", "yes", Map("supervisorNameTc", "Sam"))
        T.Eq(eng.StepState("supervisorPwo", ans), "hidden", "PWO supervisor hidden while TC")
        r := eng.Validate(ans)
        T.True(r.Ok, "TC with its own answers is valid; the hidden PWO answers are not required or checked")
        fr := eng.Fragments(ans)
        T.NotContains(TestEngine.Join(fr.Fragments), "{supervisorName}", "the hidden PWO supervisor fragment is not offered")
        T.False(fr.Values.Has("supervisorName"), "nor in the values")
        T.True(ans.Has("supervisorPwo"), "the engine does not delete hidden answers")
        ans["orderType"].option := "pwo"
        T.Eq(eng.StepState("supervisorPwo", ans), "visible", "PWO again")
        T.Contains(TestEngine.Join(eng.Fragments(ans).Fragments), "Supervisor {supervisorName} placeholder note.", "the PWO supervisor fragment is back")
        T.Eq(eng.Fragments(ans).Values["supervisorName"], "Pat Lee", "and in the values")
        T.True(eng.Validate(ans).Ok, "valid again")
        after := ConfigJson.Canon(CallSession.AnswersToTree(ans))
        T.True(InStr(after, "supervisorNameTc") > 0, "the TC answers are still there too")
        ; stop / unstop
        a2 := TestEngine.Full("r1", "tc", "yes", "c4", "o3")
        TestEngine.Put(a2, "contact", "c4", Map("contactDetails", "left a note"))
        a2["supervisorTc"].option := "no"
        T.NotContains(TestEngine.Join(eng.Fragments(a2).Fragments), "{contactDetails}", "stopped: contact fragment not offered")
        T.Eq(WorkflowEngine.FieldValue(a2["contact"], "contactDetails"), "left a note", "contact details still in the answers")
        a2["supervisorTc"].option := "yes"
        T.Contains(TestEngine.Join(eng.Fragments(a2).Fragments), "Contact 4 placeholder note. {contactDetails}", "unstopped: contact fragment is back")
        T.Eq(eng.Fragments(a2).Values["contactDetails"], "left a note", "and its value")
        ; calling the engine many times never changes the answers
        c1 := ConfigJson.Canon(CallSession.AnswersToTree(a2))
        loop 3 {
            eng.Validate(a2), eng.Fragments(a2), eng.Flags(a2), eng.Stop(a2), eng.VisibleSteps(a2)
        }
        T.Eq(ConfigJson.Canon(CallSession.AnswersToTree(a2)), c1, "engine calls leave the answers untouched")
        T.Eq(before, ConfigJson.Canon(CallSession.AnswersToTree(TestEngine.Full("r3", "pwo", "", "c2", "o2"))), "(fixture is deterministic)")
    }

    static Flags() {
        eng := TestEngine.NotDone()
        msg := "Placeholder flag: Reason 4 with SRO may need review."
        ans := TestEngine.Full("r4", "sro", "", "c1", "o1")
        f := eng.Flags(ans)
        T.Eq(f.Length, 1, "Reason 4 + SRO raises the flag")
        T.Eq(f[1], msg, "flag message")
        T.True(eng.Validate(ans).Ok, "a flag never blocks")
        T.Eq(eng.Fragments(ans).Fragments.Length, 4, "nor changes the note")
        T.Eq(eng.Flags(TestEngine.Full("r4", "pwo", "", "c1", "o1")).Length, 0, "Reason 4 + PWO: no flag")
        T.Eq(eng.Flags(TestEngine.Full("r3", "sro", "", "c1", "o1")).Length, 0, "Reason 3 + SRO: no flag")
        T.Eq(eng.Flags(Map()).Length, 0, "no answers: no flag")
        T.Eq(eng.Flags(TestEngine.A("reason", "r4")).Length, 0, "half of the condition: no flag")
        ; flags look only at steps that count: a locked step's answer raises nothing
        cfg := TestEngine.Cfg()
        cat := cfg["categories"][1]
        cat["flags"] := [Map("id", "f1", "message", "after the stop", "when", Map("step", "outcome", "in", ["o1"])),
            Map("id", "f2", "message", "any of", "when", Map("any", [Map("step", "reason", "in", ["r1"]), Map("step", "reason", "in", ["r2"])]))]
        e2 := WorkflowEngine(cat)
        a2 := TestEngine.Full("r2", "tc", "yes", "c1", "o1")
        T.Eq(TestEngine.Join(e2.Flags(a2)), "after the stop|any of", "both flags before the stop")
        a2["supervisorTc"].option := "no"
        T.Eq(TestEngine.Join(e2.Flags(a2)), "any of", "the flag on a locked step is off")
        T.Eq(WorkflowEngine(Map("steps", [Map("id", "a", "type", "text")])).Flags(Map()).Length, 0, "a category without flags")
    }

    ; "A condition referring to a step that is hidden evaluates as false."
    static HiddenConditions() {
        cat := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "a", "label", "A", "type", "choice", "options", [Map("id", "x", "label", "X"), Map("id", "z", "label", "Z")]),
            Map("id", "b", "label", "B", "type", "choice", "when", Map("step", "a", "in", ["x"]),
                "options", [Map("id", "y", "label", "Y"), Map("id", "w", "label", "W")]),
            Map("id", "c", "label", "C", "type", "text", "when", Map("step", "b", "in", ["y"]),
                "fields", [Map("id", "ctext", "label", "C text", "required", true)], "fragment", "C is {ctext}"),
            Map("id", "d", "label", "D", "type", "text", "when", Map("any", [Map("step", "b", "in", ["y"]), Map("step", "a", "in", ["z"])]),
                "fields", [Map("id", "dtext", "label", "D text")], "fragment", "D is {dtext}")],
            "flags", [Map("id", "fl", "message", "b is y", "when", Map("step", "b", "in", ["y"]))])
        eng := WorkflowEngine(cat)
        ans := Map()
        TestEngine.Put(ans, "a", "z")
        TestEngine.Put(ans, "b", "y")                       ; answered, but b is hidden (a is not x)
        TestEngine.Put(ans, "c", "", Map("ctext", ""))
        T.Eq(TestEngine.Ids(eng.VisibleSteps(ans)), "a,d", "b is hidden, so c (which needs b = y) is hidden too, d shows through its other branch")
        T.Eq(eng.Flags(ans).Length, 0, "a flag on a hidden step is false")
        T.True(eng.Validate(ans).Ok, "c's required field is not required while c is hidden")
        T.Eq(eng.Fragments(ans).Fragments.Length, 0, "hidden steps give no fragments")
        a2 := Map()
        TestEngine.Put(a2, "a", "x")
        TestEngine.Put(a2, "b", "y")
        T.Eq(TestEngine.Ids(eng.VisibleSteps(a2)), "a,b,c,d", "a = x shows b; b = y shows c and d")
        T.Eq(TestEngine.MissingIds(eng.Validate(a2)), "c.ctext", "c's required field now counts")
        T.Eq(eng.Flags(a2).Length, 1, "the flag is true when its step shows")
        ; a condition may not look ahead: a step that comes later is not visible yet
        cat2 := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "p", "label", "P", "type", "text", "when", Map("step", "q", "in", ["m"]), "fields", [Map("id", "pt", "label", "PT")]),
            Map("id", "q", "label", "Q", "type", "choice", "options", [Map("id", "m", "label", "M")])])
        T.Eq(TestEngine.Ids(WorkflowEngine(cat2).VisibleSteps(TestEngine.A("q", "m"))), "q", "a forward reference is false")
    }

    static Junk() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r1", "pwo", "", "c1", "o1")
        ans["ghostStep"] := {option: "x", fields: Map()}
        ans["reason"].fields["ghostField"] := "text"
        ans["outcome"].option := "o99"
        r := eng.Validate(ans)
        T.False(r.Ok, "an unknown option leaves the step unanswered")
        T.Eq(TestEngine.MissingIds(r), "outcome", "and that is all that is reported as missing")
        T.Eq(r.Warnings.Length, 3, "unknown step, field and option are reported as warnings")
        w := TestEngine.Join(eng.Warnings(ans), "~")
        T.Contains(w, 'Unknown step "ghostStep"', "warning: unknown step")
        T.Contains(w, 'Unknown field "ghostField" for step "reason"', "warning: unknown field")
        T.Contains(w, 'Unknown option "o99" for step "outcome"', "warning: unknown option")
        fr := eng.Fragments(ans)
        T.Eq(fr.Warnings.Length, 3, "Fragments reports them too")
        T.NotContains(TestEngine.Join(fr.Fragments), "ghost", "unknown ids never reach the note")
        T.False(fr.Values.Has("ghostField"), "nor the values")
        T.Eq(eng.StepState("ghostStep", ans), "hidden", "unknown step: hidden")
        ; odd shapes in the answers must not throw
        T.Eq(eng.Validate("not a map").Missing.Length, 4, "answers that are not a Map count as empty")
        T.Eq(eng.Fragments(0).Fragments.Length, 0, "a number as answers")
        junk := Map("reason", "r1", "orderType", 5, "contact", Map("option", "c1", "fields", "x"), "outcome", {})
        T.Eq(eng.Validate(junk).Missing.Length, 3, "strings / numbers / empty objects as entries: unanswered (reason is a bare string)")
        mapForm := Map("reason", Map("option", "r1", "fields", Map()), "orderType", Map("option", "sro"))
        T.Eq(TestEngine.Ids(eng.VisibleSteps(mapForm)), "reason,orderType,contact,outcome", "a Map entry works like an object")
        T.Eq(eng.Fragments(mapForm).Fragments.Length, 2, "and gives its fragments")
        T.Eq(eng.Warnings(Map()).Length, 0, "no warnings for no answers")
    }

    static RequiredWhen() {
        cat := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "kind", "label", "Kind", "type", "choice", "required", true,
                "options", [Map("id", "k1", "label", "K1"), Map("id", "k2", "label", "K2"), Map("id", "k3", "label", "K3")]),
            Map("id", "info", "label", "Info", "type", "group", "fields", [
                Map("id", "alpha", "label", "Alpha", "requiredWhen", Map("step", "kind", "in", ["k1", "k2"])),
                Map("id", "beta", "label", "Beta", "requiredWhen", Map("all", [Map("step", "kind", "in", ["k2"]), Map("step", "kind", "in", ["k2", "k3"])])),
                Map("id", "gamma", "label", "Gamma", "required", true, "requiredWhen", Map("step", "kind", "in", ["k3"]))])])
        eng := WorkflowEngine(cat)
        ans := TestEngine.A("kind", "k1")
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "info.alpha,info.gamma", "k1: alpha (requiredWhen) and gamma (required) are needed")
        ans := TestEngine.A("kind", "k2")
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "info.alpha,info.beta,info.gamma", "k2: alpha and beta too")
        ans := TestEngine.A("kind", "k3")
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "info.gamma", "k3: only gamma")
        TestEngine.Put(ans, "info", "", Map("gamma", "g"))
        T.True(eng.Validate(ans).Ok, "filled")
        ans := Map()
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "kind,info.gamma", "nothing chosen: only plain required items")
        ; FieldRequired drives the UI star
        a := eng.Analyse(TestEngine.A("kind", "k2"))
        flds := eng.FieldsList(eng.ById["info"])
        T.True(eng.FieldRequired(flds[2], TestEngine.A("kind", "k2"), a), "beta is required for k2")
        T.False(eng.FieldRequired(flds[2], TestEngine.A("kind", "k1"), eng.Analyse(TestEngine.A("kind", "k1"))), "beta is not required for k1")
    }

    static RequiredSteps() {
        cat := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "g1", "label", "Group one", "type", "group", "required", true,
                "fields", [Map("id", "f1", "label", "F1"), Map("id", "f2", "label", "F2")]),
            Map("id", "t1", "label", "Text one", "type", "text", "fields", [Map("id", "tf", "label", "TF")]),
            Map("id", "c1", "label", "Choice", "type", "choice", "options", [Map("id", "o", "label", "O")]),
            Map("id", "y1", "label", "YN", "type", "yesno", "required", true,
                "options", [Map("id", "yes", "label", "Yes"), Map("id", "no", "label", "No")])])
        eng := WorkflowEngine(cat)
        T.Eq(TestEngine.MissingIds(eng.Validate(Map())), "g1,y1", "required group / yes-no must be answered; optional ones need nothing")
        ans := Map()
        TestEngine.Put(ans, "g1", "", Map("f2", "x"))
        TestEngine.Put(ans, "y1", "no")
        T.True(eng.Validate(ans).Ok, "a required group needs only one field to have text")
        TestEngine.Put(ans, "g1", "", Map("f1", "  "))
        T.Eq(TestEngine.MissingIds(eng.Validate(ans)), "g1", "blank text does not count")
        T.Eq(eng.Validate(ans).Missing[1].label, "Group one", "label of the step")
    }

    static FragmentRules() {
        cat := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "c", "label", "C", "type", "choice", "fragment", "after {c} step",
                "options", [Map("id", "a", "label", "Alpha", "fragment", "option a"), Map("id", "b", "label", "Beta", "fragment", ""),
                    Map("id", "d", "label", "Delta")]),
            Map("id", "t", "label", "T", "type", "text", "fields", [Map("id", "tx", "label", "Tx")], "fragment", "text {tx}"),
            Map("id", "g", "label", "G", "type", "group", "fragment", "fixed group text",
                "fields", [Map("id", "g1", "label", "G1"), Map("id", "g2", "label", "G2")]),
            Map("id", "n", "label", "N", "type", "text", "fragment", "no fields at all")])
        eng := WorkflowEngine(cat)
        J := (a) => TestEngine.Join(eng.Fragments(a).Fragments)
        T.Eq(J(Map()), "no fields at all", "nothing chosen or typed: only a fieldless text step speaks")
        T.Eq(J(TestEngine.A("c", "a")), "option a|after {c} step|no fields at all", "option fragment first, then the step fragment")
        T.Eq(J(TestEngine.A("c", "b")), "after {c} step|no fields at all", "an empty option fragment is skipped, the step fragment stays")
        T.Eq(J(TestEngine.A("c", "d")), "after {c} step|no fields at all", "an option without a fragment key")
        T.Eq(J(TestEngine.A("c", "zzz")), "no fields at all", "an unknown option gives nothing for that step")
        ans := Map()
        TestEngine.Put(ans, "t", "", Map("tx", "  "))
        T.Eq(J(ans), "no fields at all", "blank text: no fragment")
        TestEngine.Put(ans, "t", "", Map("tx", "hello"))
        T.Eq(J(ans), "text {tx}|no fields at all", "text typed: the fragment (the composer fills {tx})")
        TestEngine.Put(ans, "g", "", Map("g2", "z"))
        T.Eq(J(ans), "text {tx}|fixed group text|no fields at all", "a group speaks once any field has text, in step order")
    }

    static ValuesMap() {
        eng := TestEngine.NotDone()
        ans := TestEngine.Full("r2", "pwo", "", "c1", "o3")
        TestEngine.Put(ans, "contact", "c1", Map("contactDetails", "left a note"))
        v := eng.Fragments(ans).Values
        T.Eq(v["reason"], "Reason 2 (placeholder)", "chosen option label under the step id")
        T.Eq(v["orderType"], "PWO", "order type label")
        T.Eq(v["supervisorName"], "Pat Lee", "field values by field id")
        T.Eq(v["contactDetails"], "left a note", "contact details")
        T.Eq(v["outcome"], "Outcome 3 (placeholder)", "outcome label")
        T.False(v.Has("supervisorNameTc"), "fields of hidden steps are not in the values")
        T.False(v.Has("supervisorTc"), "nor hidden steps")
        v2 := eng.Fragments(Map()).Values
        T.True(v2.Has("reason") && v2["reason"] = "", "an unanswered visible choice has an empty label (so {reason} never warns)")
        T.True(v2.Has("contactDetails") && v2["contactDetails"] = "", "an empty field is an empty value")
    }

    ; Stop corner cases on a made-up category.
    static StopVariants() {
        cat := Map("id", "x", "kind", "steps", "steps", [
            Map("id", "s1", "label", "S1", "type", "choice", "options", [
                Map("id", "go", "label", "Go", "fragment", "s1 go"),
                Map("id", "halt", "label", "Halt", "fragment", "s1 halt", "stop", Map("message", "Stop at the first step", "fragment", "halted first"))]),
            Map("id", "s2", "label", "S2", "type", "choice", "when", Map("step", "s1", "in", ["go"]), "options", [
                Map("id", "ok", "label", "OK", "fragment", "s2 ok"),
                Map("id", "no", "label", "No", "fragment", "s2 no", "stop", Map("message", "Stop two", "fragment", "halted two", "keepSteps", ["s1", "gone"]))]),
            Map("id", "s3", "label", "S3", "type", "text", "fields", [Map("id", "s3t", "label", "S3T", "required", true)], "fragment", "s3 {s3t}")])
        eng := WorkflowEngine(cat)
        a := TestEngine.A("s1", "halt")
        TestEngine.Put(a, "s3", "", Map("s3t", "typed"))
        st := eng.Stop(a)
        T.True(st.Stopped && st.StepId = "s1", "a stop on the first step")
        T.Eq(st.KeepSteps.Length, 0, "no keepSteps: nothing kept")
        T.Eq(TestEngine.Join(eng.Fragments(a).Fragments), "halted first", "the note is the stop fragment alone")
        T.True(eng.Validate(a).Ok, "everything after is locked, so the call is valid")
        T.Eq(eng.StepState("s3", a), "locked", "s3 locked")
        T.Eq(eng.StepState("s2", a), "hidden", "s2 is hidden (its condition is false), not locked")
        b := TestEngine.A("s1", "go", "s2", "no")
        T.Eq(eng.Stop(b).StepId, "s2", "a stop on the second step")
        T.Eq(TestEngine.Join(eng.Fragments(b).Fragments), "s1 go|halted two", "keepSteps: unknown ids are ignored, kept steps in step order, the stop option's own fragment is replaced")
        T.Eq(eng.StepState("s3", b), "locked", "s3 locked after the second stop")
        c := TestEngine.A("s1", "go", "s2", "ok")
        T.False(eng.Stop(c).Stopped, "the non-stop option does not stop")
        T.Eq(TestEngine.Join(eng.Fragments(c).Fragments), "s1 go|s2 ok", "normal run")
        T.Eq(TestEngine.MissingIds(eng.Validate(c)), "s3.s3t", "s3's required field counts when not locked")
        ; a stop option without message / keepSteps keys still stops and does not throw
        cat2 := Map("id", "x", "kind", "steps", "steps", [Map("id", "q", "label", "Q", "type", "yesno", "options",
            [Map("id", "yes", "label", "Y"), Map("id", "no", "label", "N", "stop", Map())]),
            Map("id", "r", "label", "R", "type", "text", "fields", [Map("id", "rt", "label", "RT")], "fragment", "r {rt}")])
        e2 := WorkflowEngine(cat2)
        s2 := e2.Stop(TestEngine.A("q", "no"))
        T.True(s2.Stopped && s2.Message = "" && s2.KeepSteps.Length = 0, "a bare stop")
        T.Eq(e2.Fragments(TestEngine.A("q", "no")).Fragments.Length, 0, "and an empty note part")
    }

    static Pure() {
        ; the engine reads the config only: a deep copy of the config is unchanged by every call
        cfg := Defaults.Config()
        before := ConfigJson.Canon(cfg)
        eng := WorkflowEngine(cfg["categories"][1])
        ans := TestEngine.Full("r4", "tc", "no", "c2", "o2")
        eng.Validate(ans), eng.Fragments(ans), eng.Flags(ans), eng.Stop(ans), eng.StepState("contact", ans)
        T.Eq(ConfigJson.Canon(cfg), before, "the config tree is not modified")
    }

    static CloseJob() {
        eng := WorkflowEngine(Defaults.Config()["categories"][5])
        T.Eq(TestEngine.Ids(eng.VisibleSteps(Map())), "closeChoice,closeFollowUp,closeText", "three steps")
        r := eng.Validate(Map())
        T.Eq(TestEngine.MissingIds(r), "closeChoice", "only the required choice is missing")
        ans := TestEngine.A("closeChoice", "k2")
        T.True(eng.Validate(ans).Ok, "the optional steps may stay empty")
        T.Eq(TestEngine.Join(eng.Fragments(ans).Fragments), "Close option 2 placeholder note.", "just the choice")
        TestEngine.Put(ans, "closeFollowUp", "yes")
        TestEngine.Put(ans, "closeText", "", Map("closeNote", "typed here"))
        T.Eq(TestEngine.Join(eng.Fragments(ans).Fragments), "Close option 2 placeholder note.|Close question yes placeholder note.|Close note {closeNote} placeholder note.", "choice, yes/no, text")
        TestEngine.Put(ans, "closeFollowUp", "no")
        T.Eq(eng.Fragments(ans).Fragments.Length, 2, "No has an empty fragment")
        T.Eq(eng.Fragments(ans).Values["closeFollowUp"], "No", "the label is still a value")
    }

    static BadCategory() {
        for bad in ["junk", Map(), Map("steps", "x"), Map("steps", [5, "a", Map("label", "no id")]), 0] {
            e := WorkflowEngine(bad)
            T.Eq(e.Steps.Length, 0, "bad category has no steps: " Type(bad))
            T.True(e.Validate(Map()).Ok, "validate on nothing: " Type(bad))
            T.Eq(e.Fragments(Map()).Fragments.Length, 0, "fragments on nothing: " Type(bad))
            T.False(e.Stop(Map()).Stopped, "no stop: " Type(bad))
        }
        e := WorkflowEngine(Map("steps", [Map("id", "a", "type", "text"), Map("id", "a", "type", "text")]))
        T.Eq(e.Steps.Length, 1, "a duplicate step id is skipped")
        e := WorkflowEngine(Map("steps", [Map("id", "a", "type", "choice")]))
        T.Eq(e.Validate(Map()).Ok ? 1 : 0, 1, "a choice step without options and without required is fine")
        T.Eq(e.Fragments(TestEngine.A("a", "x")).Fragments.Length, 0, "and gives nothing")
    }
}
