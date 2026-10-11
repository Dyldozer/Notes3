#Requires AutoHotkey v2.0

class TestCallSession {
    static Name := "CallSession"

    static Run() {
        for name in ["Categories", "Content", "Reset", "BeginCall", "Subscribers", "Fragments", "HasContent",
                "SnapshotShape", "RoundTrip", "RestoreStatuses", "RestoreBad", "ResetClearsNote", "StaticState"]
            T.Case(name, ObjBindMethod(TestCallSession, name))
    }

    ; M7: the static state lives in the session, goes into the snapshot as categories.<id>.static and comes back; a snapshot
    ; made before M7 still restores.
    static StaticState() {
        m := StaticModel(Defaults.Config()["categories"][4])
        s := CallSession()
        s.BeginCall(CallContext())
        st := m.Apply(m.Apply(StaticModel.NewState(), {ipText: "1.1.1.1/30"}), {pingOutcome: "reply"})
        s.SetStatic("static", st, m)
        s.UseCategory("static")
        snap := s.Snapshot()
        T.True(snap["categories"]["static"].Has("static"), "snapshot carries categories.static.static")
        T.Eq(snap["categories"]["static"]["static"]["ipInput"], "1.1.1.1", "with the typed IP")
        c := CallSession()
        T.True(c.Restore(ConfigJson.Parse(ConfigJson.Stringify(snap))), "restores through JSON")
        T.Eq(c.StaticFor("static").gateway, "1.1.1.2", "the state is back with its gateway")
        T.Eq(c.Fragments("static").Length, 1, "and the fragment")
        old := CallSession()
        old.UseCategory("billing")
        old.AddFragment("billing", "old")
        o := old.Snapshot()
        T.False(o["categories"]["billing"].Has("static"), "a snapshot without static state")
        c2 := TestCallSession.WithStatic(m)
        T.True(c2.Restore(o), "restores")
        T.False(c2.HasStaticInput(), "and leaves the static state empty")
    }

    static WithStatic(m) {
        s := CallSession()
        s.SetStatic("static", m.Apply(StaticModel.NewState(), {ipText: "9.9.9.9/29"}), m)
        return s
    }

    static Boom(*) {
        throw Error("boom")
    }

    static Categories() {
        s := CallSession()
        T.Eq(s.UsedCategories().Length, 0, "starts empty")
        T.True(s.UseCategory("billing"), "first use is new")
        T.True(s.UseCategory("notDone"), "second category is new")
        T.False(s.UseCategory("billing"), "repeat is not new")
        T.True(s.UseCategory("static"), "third category is new")
        u := s.UsedCategories()
        T.Eq(u.Length, 3, "no duplicates")
        T.True(u[1] = "billing" && u[2] = "notDone" && u[3] = "static", "first-use order")
        u.Push("junk")
        T.Eq(s.UsedCategories().Length, 3, "returned list is a copy")
        T.True(s.IsUsed("notDone"), "IsUsed true")
        T.False(s.IsUsed("equipment"), "IsUsed false")
        T.False(s.UseCategory(""), "blank id refused")
        T.True(s.Answers.Has("billing"), "answers placeholder created per category")
        T.True(s.AnswersFor("equipment") is Map, "AnswersFor creates a map")
    }

    static Content() {
        s := CallSession()
        T.False(s.HasContent(), "empty session has no content")
        s.UseCategory("billing")
        T.True(s.HasContent(), "category use is content")
        s.Reset()
        T.False(s.HasContent(), "empty after reset")
        s.AnswersFor("billing")["x"] := "1"
        T.True(s.HasContent(), "an answer is content")
    }

    static Reset() {
        s := CallSession()
        ctx := CallContext()
        ctx.Set("jobNumber", "5", "mock")
        s.BeginCall(ctx)
        s.UseCategory("billing")
        s.Reset()
        T.Eq(s.UsedCategories().Length, 0, "categories cleared")
        T.Eq(s.Answers.Count, 0, "answers cleared")
        T.Eq(s.Context.Value("jobNumber"), "5", "Clear All keeps the same call's context")
    }

    static BeginCall() {
        s := CallSession()
        ctx := CallContext()
        ctx.Set("jobNumber", "88412", "mock")
        s.UseCategory("billing")
        s.BeginCall(ctx)
        T.Eq(s.UsedCategories().Length, 0, "new call clears categories")
        T.Eq(s.Context.Value("jobNumber"), "88412", "context snapshot taken")
        ctx.Set("jobNumber", "changed", "mock")
        T.Eq(s.Context.Value("jobNumber"), "88412", "snapshot is independent of the source")
    }

    static Fixture() {
        s := CallSession()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        c.Set("techId", "T12345", "live")
        c.Set("jobNumber", "88412", "manual")
        c.Set("workOrder", "55-2231", "stale")
        c.Set("address", "123 Example St", "mock")
        s.BeginCall(c)
        s.UseCategory("billing")
        s.UseCategory("notDone")
        s.AddFragment("notDone", "first {tech.firstName}")
        s.AddFragment("notDone", "second`nline")
        s.AddFragment("billing", "bill it")
        s.SetValue("notDone", "supervisorName", "Pat Lee")
        s.NoteText := "Edited`r`nnote text " Chr(0x2014) " with `"quotes`" and \ slash"
        s.GeneratedText := "Generated text"
        s.AgentEdited := true
        return s
    }

    static Fragments() {
        s := CallSession()
        n := [0]
        s.OnChanged((x) => n[1] += 1)
        T.True(s.AddFragment("notDone", "one"), "add")
        T.True(s.AddFragment("notDone", "two"), "add second")
        T.False(s.AddFragment("notDone", "   "), "blank fragment refused")
        T.False(s.AddFragment("", "x"), "blank category refused")
        T.Eq(s.Fragments("notDone").Length, 2, "two fragments")
        T.Eq(s.Fragments("billing").Length, 0, "unknown category: empty list")
        f := s.Fragments("notDone")
        f.Push("junk")
        T.Eq(s.Fragments("notDone").Length, 2, "returned list is a copy")
        T.Eq(n[1], 2, "subscribers told per change")
        T.False(s.RemoveFragment("notDone", 3), "index out of range")
        T.False(s.RemoveFragment("billing", 1), "unknown category")
        T.True(s.RemoveFragment("notDone", 1), "remove first")
        T.Eq(s.Fragments("notDone")[1], "two", "second is now first")
        s.RemoveFragment("notDone", 1)
        T.False(s.HasContent(), "removing the last fragment leaves nothing")
        s.SetValue("notDone", "supervisorName", "Pat")
        T.Eq(s.ValuesFor("notDone")["supervisorName"], "Pat", "values per category")
        T.Eq(s.Values["notDone"]["supervisorName"], "Pat", "Values map")
    }

    static HasContent() {
        s := CallSession()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        s.BeginCall(c)
        T.False(s.HasContent(), "context alone is not content")
        s.NoteText := "   `r`n "
        T.False(s.HasContent(), "blank note text is not content")
        s.NoteText := "typed"
        T.True(s.HasContent(), "note text is content")
        s.NoteText := ""
        s.AddFragment("notDone", "x")
        T.True(s.HasContent(), "a fragment is content")
        s.Reset()
        s.SetValue("billing", "k", "v")
        T.True(s.HasContent(), "a value is content")
        s.Reset()
        s.UseCategory("static")
        T.True(s.HasContent(), "a used category is content")
        T.True(s.HasStructured(), "used category is structured content")
        s.Reset()
        s.NoteText := "typed"
        T.False(s.HasStructured(), "note text alone is not structured content")
    }

    static SnapshotShape() {
        snap := TestCallSession.Fixture().Snapshot()
        T.Eq(TestCallSession.Keys(snap), "agentEdited,categories,categoriesUsed,context,generatedText,noteText", "top-level keys")
        T.Eq(TestCallSession.Keys(snap["context"]["techName"]), "status,value", "context field keys")
        T.Eq(snap["context"]["techName"]["value"], "Jordan Smith", "context value")
        T.Eq(snap["context"]["jobNumber"]["status"], "manual", "context status as it was")
        T.Eq(snap["categoriesUsed"][1] "," snap["categoriesUsed"][2], "billing,notDone", "used categories in first-use order")
        T.Eq(TestCallSession.Keys(snap["categories"]), "billing,notDone", "categories with content")
        T.Eq(TestCallSession.Keys(snap["categories"]["notDone"]), "fragments,values", "category keys")
        T.Eq(snap["categories"]["notDone"]["fragments"].Length, 2, "fragments")
        T.Eq(snap["categories"]["notDone"]["values"]["supervisorName"], "Pat Lee", "values")
        T.Eq(snap["agentEdited"], 1, "agentEdited as 1")
        ; plain data only: it survives JSON and is independent of the session
        T.Eq(ConfigJson.Canon(ConfigJson.Parse(ConfigJson.Stringify(snap))), ConfigJson.Canon(snap), "JSON round trip")
        s := TestCallSession.Fixture()
        snap2 := s.Snapshot()
        s.AddFragment("notDone", "later")
        snap2["context"]["techName"]["value"] := "changed"
        T.Eq(snap2["categories"]["notDone"]["fragments"].Length, 2, "snapshot is a copy")
        T.Eq(s.Context.Value("techName"), "Jordan Smith", "changing the snapshot doesn't touch the session")
    }

    static Keys(m) {
        s := ""
        for k, v in m
            s .= (s = "" ? "" : ",") k
        return s
    }

    static RoundTrip() {
        a := TestCallSession.Fixture()
        snap := a.Snapshot()
        b := CallSession()
        T.True(b.Restore(snap), "restore ok")
        s2 := b.Snapshot()
        for k in ["categories", "categoriesUsed", "noteText", "generatedText", "agentEdited"]
            T.Eq(ConfigJson.Canon(s2[k]), ConfigJson.Canon(snap[k]), "restore then snapshot: same " k)
        for id, f in snap["context"]
            T.Eq(s2["context"][id]["value"], f["value"], "context value unchanged: " id)
        c2 := CallSession()
        c2.Restore(s2)
        T.Eq(ConfigJson.Canon(c2.Snapshot()), ConfigJson.Canon(s2), "a restored call snapshots and restores to the identical tree")
        T.Eq(b.NoteText, a.NoteText, "edited note text restored exactly")
        T.Eq(b.GeneratedText, "Generated text", "generated text restored")
        T.True(b.AgentEdited, "agentEdited restored")
        T.Eq(b.UsedCategories().Length, 2, "used categories restored")
        T.Eq(b.Fragments("notDone")[2], "second`nline", "fragments restored exactly")
        T.Eq(b.ValuesFor("notDone")["supervisorName"], "Pat Lee", "values restored")
        ; through a file-style JSON round trip too
        c := CallSession()
        c.Restore(ConfigJson.Parse(ConfigJson.Stringify(snap)))
        T.Eq(c.NoteText, a.NoteText, "note text survives JSON")
        T.True(c.AgentEdited, "agentEdited survives JSON")
        T.Eq(c.Fragments("billing")[1], "bill it", "fragments survive JSON")
        a.AgentEdited := false
        d := CallSession()
        d.Restore(a.Snapshot())
        T.False(d.AgentEdited, "agentEdited false restored as false")
    }

    static RestoreStatuses() {
        b := CallSession()
        b.Restore(TestCallSession.Fixture().Snapshot())
        for id in ["techName", "techId", "jobNumber", "workOrder", "address"]
            T.Eq(b.Context.Status(id), "history", "restored status is history: " id)
        T.Eq(b.Context.Value("jobNumber"), "88412", "values kept")
        T.False(b.Context.Get("techId").Editable, "history values are not editable")
        ; fields that had no value keep that fact (history never carries an empty value)
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        c.Set("address", "", "unavailable")
        c.Set("workOrder", "", "empty")
        s := CallSession()
        s.BeginCall(c)
        s.UseCategory("notDone")
        r := CallSession()
        r.Restore(s.Snapshot())
        T.Eq(r.Context.Status("techName"), "history", "valued field becomes history")
        T.Eq(r.Context.Status("address"), "unavailable", "unavailable stays unavailable")
        T.Eq(r.Context.Status("workOrder"), "empty", "empty stays empty")
    }

    static RestoreBad() {
        s := TestCallSession.Fixture()
        T.False(s.Restore("junk"), "non-map refused")
        T.False(s.Restore(Map("x", 1)), "map without context refused")
        T.Eq(s.Fragments("notDone").Length, 2, "session untouched after a refused restore")
        T.True(s.Restore(Map("context", Map())), "minimal snapshot accepted")
        T.False(s.HasContent(), "minimal snapshot is empty")
    }

    static ResetClearsNote() {
        s := TestCallSession.Fixture()
        s.Reset()
        T.Eq(s.NoteText, "", "reset clears note text")
        T.Eq(s.GeneratedText, "", "reset clears generated text")
        T.False(s.AgentEdited, "reset clears agentEdited")
        T.Eq(s.Fragments("notDone").Length, 0, "reset clears fragments")
        T.Eq(s.Context.Value("techName"), "Jordan Smith", "reset keeps context")
        s := TestCallSession.Fixture()
        s.BeginCall(CallContext())
        T.False(s.HasContent(), "new call clears everything")
    }

    static Subscribers() {
        s := CallSession()
        n := [0]
        s.OnChanged((x) => n[1] += 1)
        s.OnChanged(ObjBindMethod(TestCallSession, "Boom"))
        s.OnChanged((x) => n[1] += 10)
        s.UseCategory("billing")
        T.Eq(n[1], 11, "all healthy subscribers ran despite a throwing one")
        s.UseCategory("billing")
        T.Eq(n[1], 11, "no event for a repeat use")
        s.Reset()
        T.Eq(n[1], 22, "reset notifies")
    }
}
