#Requires AutoHotkey v2.0

class TestHistory {
    static Name := "History"

    static Run() {
        for name in ["SaveListGet", "EmptyRefused", "Order", "Days", "Search", "Unique", "Prune", "PruneCustom", "Corrupt",
                "FileContent", "NoContentInLog", "Reasons", "SaveFails", "Notify", "Labels"]
            T.Case(name, ObjBindMethod(TestHistory, name))
    }

    ; --- fixtures ---------------------------------------------------------------------
    static NewDir() {
        d := A_Temp "\NFSHistTest_" A_TickCount "_" Random(1000, 9999)
        DirCreate(d)
        return d
    }

    static Clock(stamp := "20261010120000000") {
        c := {Stamp: stamp}
        c.Now := () => c.Stamp
        c.Add := (self, sec) => (c.Stamp := FormatTime(DateAdd(SubStr(c.Stamp, 1, 14), sec, "Seconds"), "yyyyMMddHHmmss") SubStr(c.Stamp, 15))
        return c
    }

    static Make(opts := "") {
        d := TestHistory.NewDir()
        clk := TestHistory.Clock()
        o := {Dir: d, Now: clk.Now, Agent: "tester"}
        if IsObject(opts)
            for k, v in opts.OwnProps()
                o.%k% := v
        return {Dir: d, Clk: clk, H: History(o)}
    }

    static Snap(tech := "Jordan Smith", job := "88412", wo := "55-2231", cats := "", note := "Tech name: Jordan`r`nNotes: hello there") {
        s := CallSession()
        c := CallContext()
        c.Set("techName", tech, "mock")
        c.Set("techId", "T12345", "mock")
        c.Set("jobNumber", job, "mock")
        c.Set("workOrder", wo, "mock")
        c.Set("address", "123 Example St", "mock")
        s.BeginCall(c)
        for id in (IsObject(cats) ? cats : ["notDone"]) {
            s.UseCategory(id)
            s.AddFragment(id, "frag for " id)
        }
        s.NoteText := note
        s.GeneratedText := note
        return s.Snapshot()
    }

    static Done(m) {
        try DirDelete(m.Dir, true)
    }

    ; --- tests --------------------------------------------------------------------------
    static SaveListGet() {
        m := TestHistory.Make()
        h := m.H
        snap := TestHistory.Snap("jordan SMITH", "88412", "55-2231", ["notDone", "billing"],
            "Line one`r`nLine two " "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        id := h.Save(snap, "newCall")
        T.True(id != "", "save returns an id")
        T.True(FileExist(m.Dir "\history\2026-10-10.json") != "", "day file created")
        T.False(FileExist(m.Dir "\history\2026-10-10.json.tmp") != "", "no temp file left")
        labels := Map("notDone", "Not Done", "billing", "Billing")
        list := h.List("2026-10-10", "", labels)
        T.Eq(list.Length, 1, "one entry listed")
        it := list[1]
        T.Eq(it.Id, id, "item id")
        T.Eq(it.Time, "12:00", "time HH:mm")
        T.Eq(it.Tech, "Jordan", "tech first name (first-name rule)")
        T.Eq(it.Job, "88412", "job")
        T.Eq(it.Categories, "Not Done, Billing", "category labels")
        T.Eq(it.Reason, "newCall", "reason")
        T.False(InStr(it.Preview, "`n") || InStr(it.Preview, "`r"), "newlines removed from preview")
        T.True(StrLen(it.Preview) <= 81, "preview is cut at about 80 characters")
        T.True(SubStr(it.Preview, 1, 8) = "Line one", "preview starts with the note")
        e := h.Get(id)
        T.True(IsObject(e), "Get finds the entry")
        T.Eq(ConfigJson.Canon(e["snapshot"]), ConfigJson.Canon(snap), "snapshot comes back exactly")
        T.Eq(e["reason"], "newCall", "reason stored")
        T.Eq(e["restoredFrom"], "", "restoredFrom empty by default")
        T.Eq(e["savedAt"], "2026-10-10T12:00:00", "savedAt ISO")
        T.Eq(h.Get("20261010120000000-999"), "", "unknown id")
        T.Eq(h.Get("garbage"), "", "malformed id")
        T.Eq(h.List("2026-10-09").Length, 0, "other day empty")
        ; unknown label falls back to the id
        T.Eq(h.List("2026-10-10")[1].Categories, "notDone, billing", "no label map: ids shown")
        TestHistory.Done(m)
    }

    static EmptyRefused() {
        m := TestHistory.Make()
        h := m.H
        empty := CallSession().Snapshot()
        T.Eq(h.Save(empty, "newCall"), "", "empty snapshot refused")
        T.False(DirExist(m.Dir "\history") != "", "nothing written for an empty snapshot")
        ctxOnly := TestHistory.Snap()
        ctxOnly["categoriesUsed"] := []
        ctxOnly["categories"] := Map()
        ctxOnly["noteText"] := "   "
        T.Eq(h.Save(ctxOnly, "clearAll"), "", "context alone is not content")
        T.Eq(h.Save("junk", "clearAll"), "", "non-snapshot refused")
        note := TestHistory.Snap()
        note["categoriesUsed"] := []
        note["categories"] := Map()
        T.True(h.Save(note, "clearAll") != "", "note text alone is content")
        TestHistory.Done(m)
    }

    static Order() {
        m := TestHistory.Make()
        h := m.H
        ids := []
        for n in ["First", "Second", "Third"] {
            ids.Push(h.Save(TestHistory.Snap(n " Tech"), "newCall"))
            m.Clk.Add(60)
        }
        l := h.List("2026-10-10")
        T.Eq(l.Length, 3, "three entries")
        T.True(l[1].Tech = "Third" && l[2].Tech = "Second" && l[3].Tech = "First", "newest first")
        T.True(l[1].Time = "12:02" && l[3].Time = "12:00", "times follow the clock")
        TestHistory.Done(m)
    }

    static Days() {
        m := TestHistory.Make()
        h := m.H
        h.Save(TestHistory.Snap("A"), "newCall")
        m.Clk.Add(86400)
        h.Save(TestHistory.Snap("B"), "newCall")
        m.Clk.Add(86400 * 2)
        h.Save(TestHistory.Snap("C"), "newCall")
        d := h.Days()
        T.Eq(d.Length, 3, "three days")
        T.True(d[1] = "2026-10-13" && d[2] = "2026-10-11" && d[3] = "2026-10-10", "newest first")
        T.Eq(h.List("2026-10-11")[1].Tech, "B", "each day has its own entries")
        T.Eq(h.List("2026-10-13").Length, 1, "one entry on the last day")
        TestHistory.Done(m)
    }

    static Search() {
        m := TestHistory.Make()
        h := m.H
        h.Save(TestHistory.Snap("Jordan Smith", "88412", "55-2231", ["notDone"]), "newCall")
        h.Save(TestHistory.Snap("Casey Rivera", "88390", "77-1000", ["equipment", "billing"]), "newCall")
        h.Save(TestHistory.Snap("Morgan LEE", "99999", "55-2260", ["static"]), "clearAll")
        labels := Map("notDone", "Not Done", "equipment", "Equipment", "billing", "Billing", "static", "Static")
        q := (s) => h.List("2026-10-10", s, labels)
        T.Eq(q("").Length, 3, "no query: all")
        T.Eq(q("   ").Length, 3, "blank query: all")
        T.Eq(q("jordan").Length, 1, "tech first name, case-insensitive")
        T.Eq(q("SMITH").Length, 1, "tech last name")
        T.Eq(q("morgan lee").Length, 1, "two words match the same field")
        T.Eq(q("88390").Length, 1, "job number")
        T.Eq(q("55-22").Length, 2, "work order fragment matches two")
        T.Eq(q("billing").Length, 1, "category label")
        T.Eq(q("not done").Length, 1, "a multi-word label matches (each word must be found)")
        T.Eq(q("equipment billing").Length, 1, "all words must match")
        T.Eq(q("jordan billing").Length, 0, "words from different entries don't combine")
        T.Eq(q("zzz").Length, 0, "no match")
        T.Eq(q("jordan")[1].Tech, "Jordan", "result has display fields")
        TestHistory.Done(m)
    }

    static Unique() {
        m := TestHistory.Make()
        h := m.H
        seen := Map()
        loop 6
            seen[h.Save(TestHistory.Snap("X" A_Index), "newCall")] := true
        T.Eq(seen.Count, 6, "ids are unique even when the clock does not move")
        h2 := History({Dir: m.Dir, Now: m.Clk.Now})
        id2 := h2.Save(TestHistory.Snap("Y"), "newCall")
        T.False(seen.Has(id2), "a second instance (restart) on the same millisecond doesn't reuse an id")
        T.Eq(h.List("2026-10-10").Length, 7, "all entries kept in the same day file")
        TestHistory.Done(m)
    }

    static Prune() {
        m := TestHistory.Make({RetentionDays: 14})
        h := m.H
        ; files for 20, 15, 14 and 1 days ago and today (dated relative to the fake clock, 2026-10-10)
        DirCreate(m.Dir "\history")
        for date in ["2026-09-20", "2026-09-25", "2026-09-26", "2026-10-09", "2026-10-10"]
            FileAppend('{"agent":"a","date":"' date '","entries":[]}', m.Dir "\history\" date ".json", "UTF-8-RAW")
        FileAppend("x", m.Dir "\history\2026-09-01.bad-20260901-101010.json", "UTF-8-RAW")
        T.Eq(h.Days().Length, 3, "Days() already hides the days beyond retention (09-26 kept, 09-25 not)")
        n := h.Prune()
        T.Eq(n, 3, "15 and 20 days old and the old quarantined copy are deleted")
        T.False(FileExist(m.Dir "\history\2026-09-25.json") != "", "15 days old: gone")
        T.True(FileExist(m.Dir "\history\2026-09-26.json") != "", "exactly 14 days old: kept")
        T.True(FileExist(m.Dir "\history\2026-10-10.json") != "", "today kept")
        T.Eq(h.Prune(), 0, "second prune deletes nothing")
        TestHistory.Done(m)
    }

    static PruneCustom() {
        m := TestHistory.Make({RetentionDays: 3})
        h := m.H
        DirCreate(m.Dir "\history")
        for date in ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-10"]
            FileAppend('{"agent":"a","date":"' date '","entries":[]}', m.Dir "\history\" date ".json", "UTF-8-RAW")
        T.Eq(h.Prune(), 2, "retention 3: 10-05 and 10-06 deleted (10-07 is 3 days old)")
        d := h.Days()
        T.True(d.Length = 2 && d[1] = "2026-10-10" && d[2] = "2026-10-07", "remaining days")
        h.RetentionDays := 1
        T.Eq(h.Days().Length, 1, "changing RetentionDays applies at once")
        TestHistory.Done(m)
    }

    static Corrupt() {
        m := TestHistory.Make()
        h := m.H
        DirCreate(m.Dir "\history")
        path := m.Dir "\history\2026-10-10.json"
        for junk in ["not json at all", '{"agent":"a"}', '{"entries":[{"id":"x"}]}', '[]', ""] {
            FileOpen(path, "w", "UTF-8-RAW").Write(junk)
            T.Eq(h.List("2026-10-10").Length, 0, "corrupt file reads as empty: [" SubStr(junk, 1, 12) "]")
            T.False(FileExist(path) != "", "corrupt file was moved away")
        }
        bad := 0
        loop files m.Dir "\history\2026-10-10.bad-*.json"
            bad += 1
        T.True(bad >= 1, "quarantined as .bad-<stamp>.json")
        T.True(h.Save(TestHistory.Snap(), "newCall") != "", "saving after a corrupt file works")
        T.Eq(h.List("2026-10-10").Length, 1, "fresh file has the new entry")
        TestHistory.Done(m)
    }

    static FileContent() {
        m := TestHistory.Make()
        h := m.H
        h.Save(TestHistory.Snap(), "newCall")
        h.Save(TestHistory.Snap("Casey Rivera"), "beforeRestore", "20261010120000000-001")
        doc := ConfigJson.Parse(FileRead(m.Dir "\history\2026-10-10.json", "UTF-8"))
        T.Eq(TestHistory.Keys(doc), "agent,date,entries", "file keys")
        T.Eq(doc["agent"], "tester", "agent stored")
        T.Eq(doc["date"], "2026-10-10", "date stored")
        e := doc["entries"][2]
        T.Eq(TestHistory.Keys(e), "id,reason,restoredFrom,savedAt,snapshot", "entry keys")
        T.Eq(e["restoredFrom"], "20261010120000000-001", "restoredFrom stored")
        T.Eq(e["reason"], "beforeRestore", "reason stored")
        T.Eq(TestHistory.Keys(e["snapshot"]), "agentEdited,categories,categoriesUsed,context,generatedText,noteText", "snapshot keys only")
        for id, f in e["snapshot"]["context"]
            T.Eq(TestHistory.Keys(f), "status,value", "context field keys: " id)
        TestHistory.Done(m)
    }

    static Keys(m) {
        s := ""
        for k, v in m
            s .= (s = "" ? "" : ",") k
        return s
    }

    static NoContentInLog() {
        d := TestHistory.NewDir()
        lg := Log({Path: d "\t.log", Level: "debug"})
        m := TestHistory.Make({Logger: lg})
        h := m.H
        h.Save(TestHistory.Snap("Jordan Smith", "88412", "55-2231", ["notDone"], "SECRET NOTE TEXT"), "newCall")
        h.List("2026-10-10", "jordan", Map())
        FileOpen(m.Dir "\history\2026-10-10.json", "w", "UTF-8-RAW").Write("garbage")
        h.List("2026-10-10")
        h.RetentionDays := 1
        text := FileRead(d "\t.log", "UTF-8")
        T.True(StrLen(text) > 0, "something was logged")
        for needle in ["Jordan", "Smith", "88412", "55-2231", "T12345", "123 Example", "SECRET", "frag for"]
            T.NotContains(text, needle, "log has no call content: " needle)
        T.Contains(text, "history saved", "save is logged (id and reason only)")
        T.Contains(text, "history file was corrupt", "corrupt file is logged")
        TestHistory.Done(m)
        try DirDelete(d, true)
    }

    static Reasons() {
        m := TestHistory.Make()
        h := m.H
        for r in ["newCall", "clearAll", "beforeRestore"]
            T.True(h.Save(TestHistory.Snap(), r) != "", "reason accepted: " r)
        T.Eq(h.Save(TestHistory.Snap(), "bogus"), "", "unknown reason refused")
        T.True(h.LastError != "", "refusal sets LastError")
        T.Eq(h.List("2026-10-10").Length, 3, "refused save wrote nothing")
        TestHistory.Done(m)
    }

    static SaveFails() {
        m := TestHistory.Make()
        blocker := m.Dir "\blocker"
        FileAppend("x", blocker, "UTF-8-RAW")
        h := History({Dir: blocker, Now: m.Clk.Now})      ; history folder would have to live under a file
        id := h.Save(TestHistory.Snap(), "newCall")
        T.Eq(id, "", "save fails when the folder can't be created")
        T.True(h.LastError != "", "LastError explains")
        TestHistory.Done(m)
    }

    static Notify() {
        m := TestHistory.Make()
        h := m.H
        n := [0]
        h.OnChanged((x) => n[1] += 1)
        h.Save(TestHistory.Snap(), "newCall")
        T.Eq(n[1], 1, "subscriber told after a save")
        h.Save(CallSession().Snapshot(), "newCall")
        T.Eq(n[1], 1, "not told when nothing was saved")
        TestHistory.Done(m)
    }

    static Labels() {
        T.True(History.IsEmpty(CallSession().Snapshot()), "IsEmpty on a fresh snapshot")
        s := CallSession()
        s.UseCategory("billing")
        T.False(History.IsEmpty(s.Snapshot()), "a used category is content")
        s := CallSession()
        s.SetValue("notDone", "x", "1")
        T.False(History.IsEmpty(s.Snapshot()), "a value is content")
        s := CallSession()
        s.AddFragment("notDone", "frag")
        T.False(History.IsEmpty(s.Snapshot()), "a fragment is content")
    }
}
