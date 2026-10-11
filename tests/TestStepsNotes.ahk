#Requires AutoHotkey v2.0
; TestStepsNotes.ahk - the engine inside CallSession (answers -> fragments/values -> note), snapshots with answers,
; old snapshots, History, and the Composer output for Not Done + Close Job. Headless.

; App.ahk (included by the test runner for its workflow methods) names the window class, which headless tests do not have.
class MainWindow {
}

class TestStepsNotes {
    static Name := "StepsNotes"

    static Run() {
        for name in ["ChooseType", "Replaces", "NotifyOnce", "Retention", "ComposeExact", "ComposeStop", "ConfigOrder",
                "ResetCategory", "SnapshotShape", "RoundTrip", "OldSnapshot", "DamagedAnswers", "HistoryContent", "HistoryFile",
                "AppSteps", "NoSteps"]
            T.Case(name, ObjBindMethod(TestStepsNotes, name))
    }

    static Cfg() => Defaults.Config()

    static Eng(id := "notDone") {
        for c in Defaults.Config()["categories"]
            if (c["id"] = id)
                return WorkflowEngine(c)
    }

    ; a session with a started call and the engine for Not Done
    static Make() {
        s := CallSession()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        c.Set("techId", "T12345", "mock")
        c.Set("jobNumber", "88412", "mock")
        c.Set("workOrder", "55-2231", "mock")
        c.Set("address", "123 Example St", "mock")
        s.BeginCall(c)
        return s
    }

    ; answer the whole of Not Done for a PWO call
    static FillPwo(s, eng) {
        s.UseCategory("notDone")
        s.Choose("notDone", "reason", "r2", eng)
        s.Choose("notDone", "orderType", "pwo", eng)
        s.Type("notDone", "supervisorPwo", "supervisorName", "Pat Lee", eng)
        s.Type("notDone", "supervisorPwo", "rescheduleReason", "Moved", eng)
        s.Choose("notDone", "contact", "c1", eng)
        s.Choose("notDone", "outcome", "o3", eng)
    }

    static Note(s, cfg := "") {
        if !IsObject(cfg)
            cfg := Defaults.Config()
        return Composer.Compose(s.Context, s, cfg).Text
    }

    static NotesPart(text) => SubStr(text, InStr(text, "Notes:") + 7)

    static ChooseType() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        T.False(s.HasAnswers("notDone"), "no answers yet")
        T.True(s.Choose("notDone", "reason", "r1", eng), "first choice changes")
        T.False(s.Choose("notDone", "reason", "r1", eng), "the same choice again is not a change")
        T.True(s.HasAnswers("notDone"), "answers exist")
        T.Eq(WorkflowEngine.ChosenId(s.AnswersFor("notDone")["reason"]), "r1", "stored as {option, fields}")
        T.True(s.AnswersFor("notDone")["reason"].fields is Map, "fields is a Map")
        T.False(s.Type("notDone", "contact", "contactDetails", "", eng), "typing nothing into a new step creates nothing")
        T.False(s.AnswersFor("notDone").Has("contact"), "no empty entry")
        T.True(s.Type("notDone", "contact", "contactDetails", "x", eng), "typing creates the entry")
        T.Eq(s.AnswersFor("notDone")["contact"].option, "", "with no option chosen")
        T.False(s.Type("notDone", "contact", "contactDetails", "x", eng), "same text: no change")
        T.True(s.Type("notDone", "contact", "contactDetails", "", eng), "clearing text is a change")
        T.Eq(WorkflowEngine.FieldValue(s.AnswersFor("notDone")["contact"], "contactDetails"), "", "and stores the empty text")
        T.Eq(s.Fragments("notDone").Length, 1, "the engine output replaced the fragments (reason only)")
        T.Eq(s.Fragments("notDone")[1], "Reason 1 placeholder note.", "the reason fragment")
        T.Eq(s.ValuesFor("notDone")["reason"], "Reason 1 (placeholder)", "values come from the engine")
    }

    static Replaces() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        T.Eq(s.Fragments("notDone").Length, 5, "reason, order type, supervisor, contact, outcome")
        s.AddFragment("notDone", "stray fragment")
        T.Eq(s.Fragments("notDone").Length, 6, "(a stray fragment added directly)")
        s.Choose("notDone", "outcome", "o4", eng)
        T.Eq(s.Fragments("notDone").Length, 5, "the next answer REPLACES the fragments, it does not append")
        T.Eq(s.Fragments("notDone")[5], "Outcome 4 placeholder note.", "outcome changed")
        s.Choose("notDone", "orderType", "sro", eng)
        T.Eq(s.Fragments("notDone").Length, 4, "SRO: the supervisor fragment is gone")
        T.False(s.ValuesFor("notDone").Has("supervisorName"), "and its values")
        T.Eq(s.ValuesFor("notDone")["orderType"], "SRO", "the new order type label")
        ; an untouched category stays as it was
        s.AddFragment("billing", "billing sample")
        s.Choose("notDone", "outcome", "o1", eng)
        T.Eq(s.Fragments("billing").Length, 1, "other categories are not touched")
    }

    static NotifyOnce() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        n := [0]
        s.OnChanged((x) => n[1] += 1)
        s.Choose("notDone", "reason", "r1", eng)
        T.Eq(n[1], 1, "one notification per change (answers + fragments together)")
        s.Choose("notDone", "reason", "r1", eng)
        T.Eq(n[1], 1, "none for no change")
        s.Type("notDone", "supervisorPwo", "supervisorName", "A", eng)
        T.Eq(n[1], 2, "typing notifies once")
        s.ResetCategory("notDone")
        T.Eq(n[1], 3, "reset notifies once")
        s.Choose("notDone", "reason", "r1")
        T.Eq(n[1], 4, "without an engine the answers change and subscribers hear, fragments untouched")
        T.Eq(s.Fragments("notDone").Length, 0, "no engine, no fragments")
    }

    static Retention() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        s.Choose("notDone", "orderType", "tc", eng)
        T.True(s.AnswersFor("notDone").Has("supervisorPwo"), "PWO answers kept in the session while TC")
        T.Eq(WorkflowEngine.FieldValue(s.AnswersFor("notDone")["supervisorPwo"], "supervisorName"), "Pat Lee", "with their text")
        T.NotContains(TestStepsNotes.Note(s), "Pat Lee", "but not in the note")
        s.Choose("notDone", "supervisorTc", "no", eng)
        T.NotContains(TestStepsNotes.Note(s), "Contact 1", "stopped: contact not in the note")
        s.Choose("notDone", "supervisorTc", "yes", eng)
        s.Type("notDone", "supervisorTc", "supervisorNameTc", "Sam Ray", eng)
        T.Contains(TestStepsNotes.Note(s), "Contact 1 placeholder note.", "unstopped: contact back")
        s.Choose("notDone", "orderType", "pwo", eng)
        T.Contains(TestStepsNotes.Note(s), "Supervisor Pat Lee placeholder note.", "PWO again: the old text is back in the note")
        T.Eq(WorkflowEngine.FieldValue(s.AnswersFor("notDone")["supervisorTc"], "supervisorNameTc"), "Sam Ray", "and the TC text is still kept")
    }

    static ComposeExact() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        T.Eq(TestStepsNotes.Note(s), "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes:", "(an empty call composes to the bare template)")
        TestStepsNotes.FillPwo(s, eng)
        exact := "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes: Reason 2 placeholder note. Order type PWO placeholder note."
            . " Supervisor Pat Lee placeholder note. Reschedule reason Moved placeholder note. Contact 1 placeholder note. Outcome 3 placeholder note."
        T.Eq(TestStepsNotes.Note(s), exact, "the exact PWO note")
        s.Type("notDone", "contact", "contactDetails", "left a message", eng)
        T.Contains(TestStepsNotes.Note(s), "Contact 1 placeholder note. left a message. Outcome", "details after the contact fragment (only the first character of a fragment is capitalised)")
        s.Type("notDone", "supervisorPwo", "rescheduleReason", "line one`nline two`r`n  and three", eng)
        T.Contains(TestStepsNotes.Note(s), "Reschedule reason line one line two and three placeholder note.", "multi-line text is squeezed to one line")
        ; a value that looks like a placeholder is inserted literally
        s.Type("notDone", "supervisorPwo", "supervisorName", "{tech.id}", eng)
        T.Contains(TestStepsNotes.Note(s), "Supervisor {tech.id} placeholder note.", "typed text is never expanded")
        ; the {<stepId>} placeholder is the chosen label
        cfg := Defaults.Config()
        cfg["categories"][1]["steps"][2]["fragment"] := "Order is {orderType} for {reason}."
        e2 := WorkflowEngine(cfg["categories"][1])
        s2 := TestStepsNotes.Make()
        s2.UseCategory("notDone")
        s2.Choose("notDone", "reason", "r3", e2)
        s2.Choose("notDone", "orderType", "sro", e2)
        T.Contains(TestStepsNotes.Note(s2, cfg), "Order type SRO placeholder note. Order is SRO for Reason 3 (placeholder).", "{stepId} placeholders and the step fragment after the option fragment")
        r := Composer.Compose(s2.Context, s2, cfg)
        T.Eq(r.Warnings.Length, 0, "no composer warnings")
        r := Composer.Compose(s.Context, s, Defaults.Config())
        T.Eq(r.Warnings.Length, 0, "no composer warnings for the real PWO call")
    }

    static ComposeStop() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        s.Choose("notDone", "orderType", "tc", eng)
        s.Choose("notDone", "supervisorTc", "yes", eng)
        s.Type("notDone", "supervisorTc", "supervisorNameTc", "Sam Ray", eng)
        T.Contains(TestStepsNotes.Note(s), "Tech spoke with supervisor Sam Ray placeholder note.", "TC yes")
        s.Choose("notDone", "supervisorTc", "no", eng)
        T.Eq(TestStepsNotes.NotesPart(TestStepsNotes.Note(s)), "Reason 2 placeholder note. Order type TC placeholder note. Tech has not contacted supervisor; advised tech to contact supervisor before calling back.",
            "TC No: reason, order type and the stop note - nothing else, though contact and outcome were answered")
        T.True(s.AnswersFor("notDone").Has("contact") && s.AnswersFor("notDone").Has("outcome"), "the locked answers are still stored")
    }

    static ConfigOrder() {
        s := TestStepsNotes.Make()
        ndE := TestStepsNotes.Eng("notDone"), cjE := TestStepsNotes.Eng("closeJob")
        s.UseCategory("closeJob")                                  ; used first ...
        s.Choose("closeJob", "closeChoice", "k1", cjE)
        s.UseCategory("notDone")
        s.Choose("notDone", "reason", "r1", ndE)
        s.AddFragment("billing", "billing note")
        s.UseCategory("billing")
        n := TestStepsNotes.NotesPart(TestStepsNotes.Note(s))
        T.Eq(n, "Reason 1 placeholder note.`r`nBilling note.`r`nClose option 1 placeholder note.", "... but the note follows config order: Not Done, Billing, Close Job")
    }

    static ResetCategory() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        s.AddFragment("billing", "keep me")
        s.ResetCategory("notDone")
        T.False(s.HasAnswers("notDone"), "answers cleared")
        T.Eq(s.Fragments("notDone").Length, 0, "fragments cleared")
        T.Eq(s.ValuesFor("notDone").Count, 0, "values cleared")
        T.True(s.IsUsed("notDone"), "the category stays used")
        T.Eq(s.Fragments("billing").Length, 1, "other categories untouched")
        T.True(s.HasContent(), "a used category is still content")
        snap := s.Snapshot()
        T.False(snap["categories"].Has("notDone"), "nothing of it in the snapshot")
        T.Contains(ConfigJson.Canon(snap["categoriesUsed"]), "notDone", "but it is listed as used")
        ; answering again works
        s.Choose("notDone", "reason", "r4", eng)
        T.Eq(s.Fragments("notDone")[1], "Reason 4 placeholder note.", "fresh start")
    }

    static SnapshotShape() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        s.Choose("notDone", "orderType", "tc", eng)                 ; the PWO answers are now hidden but kept
        snap := s.Snapshot()
        cat := snap["categories"]["notDone"]
        T.Eq(TestStepsNotes.Keys(cat), "answers,fragments,values", "category keys")
        a := cat["answers"]
        T.Eq(TestStepsNotes.Keys(a), "contact,orderType,outcome,reason,supervisorPwo", "an entry per answered step, hidden ones included")
        T.Eq(TestStepsNotes.Keys(a["reason"]), "fields,option", "entry keys")
        T.Eq(a["reason"]["option"], "r2", "option id")
        T.Eq(a["supervisorPwo"]["fields"]["supervisorName"], "Pat Lee", "hidden answer text kept")
        T.Eq(a["supervisorPwo"]["option"], "", "group has no option")
        T.True(a["reason"]["fields"] is Map, "fields is a Map even when empty")
        T.Eq(ConfigJson.Canon(ConfigJson.Parse(ConfigJson.Stringify(snap))), ConfigJson.Canon(snap), "JSON round trip of the whole snapshot")
        ; a category with only answers (no fragments / values) still appears
        s2 := TestStepsNotes.Make()
        s2.AnswersFor("notDone")["reason"] := {option: "r1", fields: Map()}
        T.Eq(TestStepsNotes.Keys(s2.Snapshot()["categories"]["notDone"]), "answers,fragments,values", "answers alone make a category entry")
        ; no answers: no answers key
        s3 := TestStepsNotes.Make()
        s3.AddFragment("billing", "x")
        T.Eq(TestStepsNotes.Keys(s3.Snapshot()["categories"]["billing"]), "fragments,values", "no answers key without answers")
        ; entries with nothing in them are left out
        s4 := TestStepsNotes.Make()
        s4.AnswersFor("notDone")["contact"] := {option: "", fields: Map()}
        T.False(s4.Snapshot()["categories"].Has("notDone"), "an empty entry is not content")
    }

    static Keys(m) {
        s := ""
        for k, v in m
            s .= (s = "" ? "" : ",") k
        return s
    }

    static RoundTrip() {
        eng := TestStepsNotes.Eng()
        a := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(a, eng)
        a.Type("notDone", "contact", "contactDetails", "text with `"quotes`", \ and " Chr(0x2014), eng)
        a.Choose("notDone", "orderType", "tc", eng)
        a.Choose("notDone", "supervisorTc", "no", eng)
        cj := TestStepsNotes.Eng("closeJob")
        a.Choose("closeJob", "closeChoice", "k3", cj)
        a.NoteText := "edited"
        snap := a.Snapshot()
        b := CallSession()
        T.True(b.Restore(snap), "restore ok")
        T.Eq(ConfigJson.Canon(b.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "snapshot -> restore -> snapshot: same categories (answers, fragments, values)")
        T.True(b.AnswersFor("notDone")["reason"].fields is Map, "restored answers are objects with a Map")
        T.Eq(WorkflowEngine.ChosenId(b.AnswersFor("notDone")["supervisorTc"]), "no", "restored option")
        T.Eq(WorkflowEngine.FieldValue(b.AnswersFor("notDone")["contact"], "contactDetails"), "text with `"quotes`", \ and " Chr(0x2014), "restored text exactly")
        T.Eq(WorkflowEngine.FieldValue(b.AnswersFor("notDone")["supervisorPwo"], "supervisorName"), "Pat Lee", "hidden answers restored")
        ; the restored answers drive the engine to the same output as the stored fragments
        r := eng.Fragments(b.AnswersFor("notDone"))
        T.Eq(ConfigJson.Canon(r.Fragments), ConfigJson.Canon(b.Fragments("notDone")), "engine output on the restored answers = restored fragments")
        T.Eq(ConfigJson.Canon(r.Values), ConfigJson.Canon(b.ValuesFor("notDone")), "... and values")
        ; through JSON (what History does)
        c := CallSession()
        c.Restore(ConfigJson.Parse(ConfigJson.Stringify(snap)))
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "same through a JSON file")
        T.Eq(WorkflowEngine.FieldValue(c.AnswersFor("notDone")["contact"], "contactDetails"), "text with `"quotes`", \ and " Chr(0x2014), "text survives JSON")
        ; editing a restored call works like a live one
        c.Choose("notDone", "supervisorTc", "yes", eng)
        T.Contains(TestStepsNotes.Note(c), "Contact 1 placeholder note.", "unstopping a restored call brings contact back")
        ; restoring twice replaces, not merges
        c.Restore(ConfigJson.Parse(ConfigJson.Stringify(snap)))
        T.Eq(WorkflowEngine.ChosenId(c.AnswersFor("notDone")["supervisorTc"]), "no", "restore replaces the answers")
        ; Reset / BeginCall forget answers
        c.Reset()
        T.False(c.HasAnswers("notDone"), "reset clears answers")
        T.Eq(c.Answers.Count, 0, "answers map cleared")
    }

    static OldSnapshot() {
        ; a snapshot made before M5: values and fragments, no answers
        old := Map("context", Map("techName", Map("value", "Jordan Smith", "status", "mock")),
            "categoriesUsed", ["notDone"],
            "categories", Map("notDone", Map("fragments", ["old fragment"], "values", Map("supervisorName", "Pat"))),
            "noteText", "old note", "generatedText", "old note", "agentEdited", 0)
        s := CallSession()
        T.True(s.Restore(old), "an old snapshot restores")
        T.Eq(s.Fragments("notDone")[1], "old fragment", "fragments")
        T.Eq(s.ValuesFor("notDone")["supervisorName"], "Pat", "values")
        T.False(s.HasAnswers("notDone"), "no answers")
        T.Eq(s.NoteText, "old note", "note text")
        T.Eq(TestStepsNotes.Keys(s.Snapshot()["categories"]["notDone"]), "fragments,values", "and it snapshots back without an answers key")
        T.Eq(ConfigJson.Canon(s.Snapshot()["categories"]), ConfigJson.Canon(old["categories"]), "identical to what was loaded")
        ; the old snapshot's values still feed the Composer
        s.Context.Set("techName", "Jordan Smith", "history")
        old2 := Map("context", Map(), "categoriesUsed", ["notDone"], "categories", Map("notDone", Map("fragments", ["Spoke with {supervisorName}"], "values", Map("supervisorName", "Pat"))))
        s2 := CallSession()
        s2.Restore(old2)
        T.Contains(TestStepsNotes.Note(s2), "Spoke with Pat.", "old values are used by the composer")
    }

    static DamagedAnswers() {
        snap := Map("context", Map(), "categoriesUsed", ["notDone"], "categories", Map("notDone", Map("fragments", [], "values", Map(),
            "answers", Map("reason", "r1", "orderType", Map("option", "pwo", "fields", "x"), "contact", Map("fields", Map("contactDetails", 5)),
            "blank", Map("option", "", "fields", Map()), "outcome", Map("option", "o2")))))
        s := CallSession()
        T.True(s.Restore(snap), "damaged answers do not stop the restore")
        a := s.AnswersFor("notDone")
        T.False(a.Has("reason"), "a string entry is dropped")
        T.Eq(WorkflowEngine.ChosenId(a["orderType"]), "pwo", "a good option with junk fields survives")
        T.Eq(WorkflowEngine.FieldValue(a["contact"], "contactDetails"), "5", "numbers become text")
        T.False(a.Has("blank"), "empty entries are dropped")
        T.Eq(WorkflowEngine.ChosenId(a["outcome"]), "o2", "entry without fields")
        s2 := CallSession()
        T.True(s2.Restore(Map("context", Map(), "categories", Map("notDone", Map("answers", "junk")))), "answers that are not a Map are ignored")
        T.False(s2.HasAnswers("notDone"), "nothing restored")
        ; unknown ids in restored answers are warnings from the engine, never errors
        s3 := CallSession()
        s3.Restore(Map("context", Map(), "categories", Map("notDone", Map("answers", Map("gone", Map("option", "x", "fields", Map()))))))
        eng := TestStepsNotes.Eng()
        T.Eq(eng.Warnings(s3.AnswersFor("notDone")).Length, 1, "engine warns about the unknown step")
        T.Eq(eng.Fragments(s3.AnswersFor("notDone")).Fragments.Length, 0, "and ignores it")
    }

    static HistoryContent() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        T.True(History.IsEmpty(s.Snapshot()), "empty call")
        s.AnswersFor("notDone")["reason"] := {option: "r1", fields: Map()}
        T.False(History.IsEmpty(s.Snapshot()), "answers alone are content")
        s2 := TestStepsNotes.Make()
        s2.Choose("notDone", "reason", "r1", eng)
        T.False(History.IsEmpty(s2.Snapshot()), "a chosen option is content")
        T.True(s2.HasContent() && s2.HasStructured(), "HasContent / HasStructured")
        s3 := TestStepsNotes.Make()
        s3.AnswersFor("notDone")["x"] := "junk string"
        T.True(History.IsEmpty(s3.Snapshot()), "a junk answer entry is not content in a snapshot")
    }

    static HistoryFile() {
        eng := TestStepsNotes.Eng()
        s := TestStepsNotes.Make()
        TestStepsNotes.FillPwo(s, eng)
        s.Choose("notDone", "orderType", "tc", eng)
        s.Choose("notDone", "supervisorTc", "no", eng)
        d := A_Temp "\NFSStepsTest_" A_TickCount "_" Random(1000, 9999)
        DirCreate(d)
        h := History({Dir: d, Agent: "tester", Now: () => "20261010120000000"})
        id := h.Save(s.Snapshot(), "clearAll")
        T.True(id != "", "saved")
        text := FileRead(h.FileFor("2026-10-10"), "UTF-8")
        T.Contains(text, '"answers"', "the file holds the answers")
        T.Contains(text, '"supervisorName": "Pat Lee"', "including the hidden ones")
        e := h.Get(id)
        c := CallSession()
        T.True(c.Restore(e["snapshot"]), "restored from the file")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(s.Snapshot()["categories"]), "the answers come back exactly")
        T.Eq(WorkflowEngine.ChosenId(c.AnswersFor("notDone")["supervisorTc"]), "no", "stop state restored")
        T.Eq(eng.Stop(c.AnswersFor("notDone")).Stopped ? 1 : 0, 1, "the engine sees the stop again")
        try DirDelete(d, true)
    }

    ; App-level wiring without a window: SetOption / SetField / MissingRequired / ResetCategory.
    static AppSteps() {
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSStepsLog_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        T.True(app.IsStepsCategory("notDone") && app.IsStepsCategory("closeJob"), "Not Done and Close Job are steps categories")
        T.False(app.IsStepsCategory("billing") || app.IsStepsCategory("static") || app.IsStepsCategory("nope"), "others are not")
        T.True(app.EngineFor("notDone") == app.EngineFor("notDone"), "engines are cached")
        T.Eq(app.EngineFor("billing"), "", "no engine for items categories")
        T.False(app.AddSampleFragment("notDone"), "sample fragments are refused for steps categories")
        T.Eq(app.Session.Fragments("notDone").Length, 0, "and nothing was added")
        T.False(app.AddSampleFragment("billing"), "nor for items categories (M6)")
        T.False(app.AddSampleFragment("static"), "nor for static categories (M7: no category takes dev sample fragments)")
        T.Eq(app.MissingRequired().Length, 0, "nothing answered: nothing to ask about")
        T.True(app.SetOption("notDone", "reason", "r1"), "first answer")
        T.True(app.Session.IsUsed("notDone"), "marks the category used")
        T.Eq(app.Stats.Used["notDone"], 1, "and credits it once")
        app.SetOption("notDone", "orderType", "pwo")
        T.Eq(app.Stats.Used["notDone"], 1, "only the first answer uses the category")
        m := app.MissingRequired()
        T.Eq(m.Length, 1, "one category is incomplete")
        T.Eq(m[1].Id "|" m[1].Label, "notDone|Not Done", "id and label")
        T.Eq(m[1].Labels.Length, 4, "supervisor name, reschedule reason, contact and outcome are missing")
        app.SetField("notDone", "supervisorPwo", "supervisorName", "Pat")
        app.SetField("notDone", "supervisorPwo", "rescheduleReason", "Moved")
        app.SetOption("notDone", "contact", "c2")
        app.SetOption("notDone", "outcome", "o2")
        T.Eq(app.MissingRequired().Length, 0, "complete")
        T.Eq(app.Session.Fragments("notDone").Length, 5, "five fragments")
        ; Close Job: used with answers but incomplete
        app.SetOption("closeJob", "closeFollowUp", "yes")
        m := app.MissingRequired()
        T.Eq(m.Length "|" m[1].Id, "1|closeJob", "a second category, listed alone")
        T.Eq(m[1].Labels[1], "Close choice (placeholder)", "label of the missing step")
        app.ResetCategory("closeJob")
        T.Eq(app.MissingRequired().Length, 0, "after Reset it has no answers: nothing to ask about")
        T.True(app.Session.IsUsed("closeJob"), "but it stays used")
        ; locked steps never count
        app.SetOption("notDone", "orderType", "tc")
        app.SetOption("notDone", "supervisorTc", "no")
        T.Eq(app.MissingRequired().Length, 0, "a stopped Not Done is complete")
        ; a category the config no longer has
        app.Session.Choose("gone", "s", "o")
        app.Session.UseCategory("gone")
        T.Eq(app.MissingRequired().Length, 0, "unknown categories are skipped")
        try FileDelete(app.Logger.Path)
    }

    static FakeStats() {
        o := {Used: Map()}
        o.UseCategory := (self, id) => (self.Used[id] := self.Used.Has(id) ? self.Used[id] + 1 : 1, true)
        return o
    }

    ; An app whose config has no steps category: nothing breaks.
    static NoSteps() {
        cfg := Defaults.Config()
        cfg["categories"].RemoveAt(5)                              ; no Close Job
        app := NFSApp()
        app.Config := {Config: cfg}
        T.False(app.IsStepsCategory("closeJob"), "removed category is not a steps category")
        T.Eq(app.EngineFor("closeJob"), "", "no engine")
        T.False(app.SetOption("closeJob", "x", "y"), "answering an unknown category does nothing")
    }
}
