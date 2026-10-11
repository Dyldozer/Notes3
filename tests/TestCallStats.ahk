#Requires AutoHotkey v2.0

; A hand-set clock: tests move time by assigning Stamp (YYYYMMDDHH24MISS + 3 ms digits). No sleeping.
class TestClock {
    __New(stamp := "20261010120000000") {
        this.Stamp := stamp
    }
    Fn() => (*) => this.Stamp
}

class TestCallStats {
    static Name := "CallStats"
    static Root := ""
    static N := 0

    static Run() {
        TestCallStats.Root := A_Temp "\NFSNotesTest_Stats_" A_TickCount
        for name in ["Attribution", "Categories", "Debounce", "Jobs", "ClearAll", "BeforeFirst", "Persistence",
                "Midnight", "Corrupt", "SummaryOrder", "NoPersonalData", "Prune", "Subscribers", "SaveFailure", "ZeroDebounce"]
            T.Case(name, ObjBindMethod(TestCallStats, name))
        try DirDelete(TestCallStats.Root, true)
    }

    static Dir() {
        TestCallStats.N += 1
        return TestCallStats.Root "\d" TestCallStats.N
    }

    static Make(clk, dir := "", debounce := 3000) {
        if (dir = "")
            dir := TestCallStats.Dir()
        return CallStats({Dir: dir, Now: clk.Fn(), DebounceMs: debounce, Agent: "tester"})
    }

    static Boom(*) {
        throw Error("boom")
    }

    static Cats() => [Map("id", "notDone", "label", "Not Done", "enabled", true),
        Map("id", "equipment", "label", "Equipment", "enabled", true),
        Map("id", "billing", "label", "Billing", "enabled", true),
        Map("id", "static", "label", "Static", "enabled", false),
        Map("id", "closeJob", "label", "Close Job", "enabled", true)]

    static Attribution() {
        clk := TestClock()
        s := TestCallStats.Make(clk)
        T.True(s.NewCallEvent("100"), "first event counts")
        td := s.Today()
        T.Eq(td.Total, 1, "total 1")
        T.Eq(td.Uncategorized, 1, "a record with no category is Uncategorized")
        T.Eq(td.ById.Count, 0, "no category counts")
        T.Eq(s.Summary(TestCallStats.Cats()).Total, 1, "summary total")
    }

    static Categories() {
        clk := TestClock()
        s := TestCallStats.Make(clk)
        s.NewCallEvent("100")
        T.True(s.UseCategory("notDone"), "first category credited")
        T.True(s.UseCategory("billing"), "second category credited")
        T.False(s.UseCategory("notDone"), "same category twice in one call is not credited again")
        td := s.Today()
        T.Eq(td.Total, 1, "two categories, still one call")
        T.Eq(td.ById["notDone"], 1, "notDone +1")
        T.Eq(td.ById["billing"], 1, "billing +1")
        T.Eq(td.Uncategorized, 0, "not uncategorized")
        clk.Stamp := "20261010120010000"
        s.NewCallEvent("101")
        s.UseCategory("notDone")
        td := s.Today()
        T.Eq(td.Total, 2, "second call")
        T.Eq(td.ById["notDone"], 2, "notDone counts records that used it")
        T.Eq(td.ById["billing"], 1, "billing unchanged")
        T.False(s.UseCategory(""), "blank category refused")
    }

    static Debounce() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk)
        T.True(s.NewCallEvent("100"), "burst: first counted")
        n := 0
        for ms in ["200", "400", "600", "800"] {
            clk.Stamp := "20261010120000" ms
            if s.NewCallEvent("100")
                n += 1
        }
        T.Eq(n, 0, "burst of five in one second counts once")
        T.Eq(s.Today().Total, 1, "total is 1")
        ; different jobs inside the window are still ignored by the time rule
        clk.Stamp := "20261010120002999"
        T.False(s.NewCallEvent("999"), "2.999 s after: ignored even with a new job")
        clk.Stamp := "20261010120003000"
        T.True(s.NewCallEvent("101"), "exactly at the window and a new job: counted")
        T.Eq(s.Today().Total, 2, "total 2")
        ; the window runs from the last COUNTED event, ignored ones do not extend it
        clk.Stamp := "20261010120005000"
        T.False(s.NewCallEvent("102"), "2 s after the counted event: ignored")
        clk.Stamp := "20261010120006001"
        T.True(s.NewCallEvent("102"), "3.001 s after the counted event (ignored ones do not extend it): counted")
        T.Eq(s.Today().Total, 3, "total 3")
    }

    static Jobs() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk)
        s.NewCallEvent("88412")
        clk.Stamp := "20261010120100000"
        T.False(s.NewCallEvent("88412"), "same job after the window: ignored")
        T.False(s.NewCallEvent(" 88412 "), "same job with spaces: ignored")
        T.Eq(s.Today().Total, 1, "still 1")
        T.True(s.NewCallEvent("88413"), "new job after the window: counted")
        clk.Stamp := "20261010120200000"
        T.True(s.NewCallEvent(""), "empty job uses the time rule only: counted after the window")
        clk.Stamp := "20261010120300000"
        T.True(s.NewCallEvent(""), "empty again after the window: counted (not equal to anything)")
        clk.Stamp := "20261010120300500"
        T.False(s.NewCallEvent(""), "empty job inside the window: ignored")
        clk.Stamp := "20261010120400000"
        T.True(s.NewCallEvent("88413"), "an old job after an empty-job record: counted")
        T.Eq(s.Today().Total, 5, "five records")
    }

    static ClearAll() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk)
        ses := CallSession()
        s.NewCallEvent("1")
        ses.UseCategory("billing"), s.UseCategory("billing")
        ses.Reset()                                   ; Clear All: resets the session, never touches stats
        T.Eq(s.Today().Total, 1, "Clear All does not count a call")
        T.True(s.UseCategory("notDone"), "later use credits the current record")
        T.True(s.UseCategory("equipment"), "and another")
        td := s.Today()
        T.Eq(td.Total, 1, "still one call")
        T.Eq(td.ById["billing"], 1, "category used before the clear stays credited")
        T.Eq(td.ById["notDone"], 1, "category used after the clear is credited to the same record")
        T.Eq(td.Uncategorized, 0, "not uncategorized")
    }

    static BeforeFirst() {
        clk := TestClock()
        dir := TestCallStats.Dir()
        s := TestCallStats.Make(clk, dir)
        T.False(s.HasCurrentRecord, "no record at the start")
        T.False(s.UseCategory("billing"), "use before the first event is not counted")
        T.Eq(s.Today().Total, 0, "total 0")
        T.Eq(s.Today().ById.Count, 0, "no category counts")
        T.False(FileExist(s.FileFor("2026-10-10")), "nothing written")
        s.NewCallEvent("1")
        T.Eq(s.Today().ById.Count, 0, "the earlier use did not leak into the first record")
        T.Eq(s.Today().Uncategorized, 1, "first record is uncategorized")
    }

    static Persistence() {
        clk := TestClock("20261010120000000")
        dir := TestCallStats.Dir()
        s := TestCallStats.Make(clk, dir)
        s.NewCallEvent("1")
        s.UseCategory("notDone"), s.UseCategory("billing")
        clk.Stamp := "20261010120100000"
        s.NewCallEvent("2")
        clk.Stamp := "20261010120200000"
        s.NewCallEvent("3")
        s.UseCategory("billing")
        T.False(FileExist(s.FileFor("2026-10-10") ".tmp"), "no .tmp left behind")
        s2 := TestCallStats.Make(clk, dir).Load()
        td := s2.Today()
        T.Eq(td.Total, 3, "reloaded total")
        T.Eq(td.Uncategorized, 1, "reloaded uncategorized")
        T.Eq(td.ById["notDone"], 1, "reloaded notDone")
        T.Eq(td.ById["billing"], 2, "reloaded billing")
        ; no current record after a restart: category use is not counted until the next event
        T.False(s2.HasCurrentRecord, "no current record after a restart")
        T.False(s2.UseCategory("equipment"), "use after a restart, before an event, is not counted")
        T.Eq(s2.Today().Total, 3, "total unchanged")
        T.True(s2.NewCallEvent("4"), "first event after the restart counts (no debounce history)")
        T.Eq(s2.Today().Total, 4, "total 4")
        s3 := TestCallStats.Make(clk, dir).Load()
        T.Eq(s3.Today().Total, 4, "persisted again")
        doc := ConfigJson.Parse(FileRead(s3.FileFor("2026-10-10"), "UTF-8"))
        T.Eq(doc["agent"], "tester", "agent stored")
        T.Eq(doc["date"], "2026-10-10", "date stored")
        T.Eq(doc["calls"].Length, 4, "four calls stored")
        T.Eq(doc["calls"][1]["at"], "2026-10-10T12:00:00", "ISO time stored")
        T.Eq(doc["calls"][1]["categories"].Length, 2, "categories stored")
        T.Eq(doc["calls"][2]["categories"].Length, 0, "empty category list stored")
    }

    static Midnight() {
        clk := TestClock("20261010235959000")
        dir := TestCallStats.Dir()
        s := TestCallStats.Make(clk, dir)
        T.True(s.NewCallEvent("1"), "event at 23:59:59 counts")
        T.Eq(s.Today().Total, 1, "today has it")
        clk.Stamp := "20261011000001000"
        T.Eq(s.Today().Total, 0, "after midnight with no events, today shows 0")
        T.Eq(s.Today().Date, "2026-10-11", "today is the new date")
        T.True(s.UseCategory("billing"), "category used after midnight is credited to the open record")
        T.Eq(s.Count("2026-10-10").ById["billing"], 1, "...in the record's own day")
        T.Eq(s.Today().Total, 0, "...and does not touch the new day")
        clk.Stamp := "20261011000005000"
        T.True(s.NewCallEvent("2"), "event at 00:00:05 counts")
        T.Eq(s.Today().Total, 1, "new day has 1")
        T.Eq(s.Count("2026-10-10").Total, 1, "old day still 1")
        T.True(FileExist(s.FileFor("2026-10-10")) != "", "old day file exists")
        T.True(FileExist(s.FileFor("2026-10-11")) != "", "new day file exists")
        s2 := TestCallStats.Make(clk, dir).Load()
        T.Eq(s2.Today().Total, 1, "restart after midnight loads the new day")
        T.Eq(s2.Count("2026-10-10").Total, 1, "old day loads from its file")
    }

    static Corrupt() {
        clk := TestClock("20261010120000000")
        lg := Log({Path: TestCallStats.Root "\corrupt.log", Level: "debug"})
        for text in ["this is { not json", '{"agent":"x","date":"2026-10-10"}', '{"calls":[{"at":"x"}]}', ""] {
            dir := TestCallStats.Dir()
            DirCreate(dir "\stats")
            FileAppend(text, dir "\stats\2026-10-10.json", "UTF-8-RAW")
            s := CallStats({Dir: dir, Now: clk.Fn(), Logger: lg, Agent: "tester"})
            s.Load()
            T.Eq(s.Today().Total, 0, "corrupt file starts empty: " SubStr(text, 1, 12))
            n := 0
            loop files dir "\stats\2026-10-10.bad-*.json"
                n += 1
            T.Eq(n, 1, "corrupt file renamed to .bad-: " SubStr(text, 1, 12))
            T.False(FileExist(dir "\stats\2026-10-10.json"), "original name is free")
            T.True(s.NewCallEvent("1"), "counting works after the quarantine")
            T.Eq(CallStats({Dir: dir, Now: clk.Fn()}).Load().Today().Total, 1, "new file is valid")
        }
        T.Contains(FileRead(lg.Path), "corrupt", "a warning was logged")
    }

    static SummaryOrder() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk)
        s.NewCallEvent("1")
        s.UseCategory("billing"), s.UseCategory("zzOld"), s.UseCategory("static")
        clk.Stamp := "20261010120100000"
        s.NewCallEvent("2")
        s.UseCategory("notDone")
        clk.Stamp := "20261010120200000"
        s.NewCallEvent("3")
        clk.Stamp := "20261010120300000"
        s.NewCallEvent("4")
        s.UseCategory("aaOld")
        r := s.Summary(TestCallStats.Cats())
        ids := ""
        for it in r.Items
            ids .= (ids = "" ? "" : ",") it.id
        T.Eq(ids, "notDone,equipment,billing,closeJob,aaOld,zzOld,uncategorized", "config order, disabled omitted, unknown appended, then Uncategorized")
        T.Eq(r.Total, 4, "total counts every record")
        byId := Map()
        for it in r.Items
            byId[it.id] := it
        T.Eq(byId["notDone"].label, "Not Done", "configured label")
        T.Eq(byId["notDone"].count, 1, "notDone count")
        T.Eq(byId["equipment"].count, 0, "equipment count")
        T.Eq(byId["billing"].count, 1, "billing count")
        T.Eq(byId["zzOld"].label, "zzOld", "unknown id used as the label")
        T.Eq(byId["zzOld"].count, 1, "unknown id count")
        T.Eq(byId["uncategorized"].label, "Uncategorized", "uncategorized label")
        T.Eq(byId["uncategorized"].count, 1, "one record without categories")
        T.False(byId.Has("static"), "disabled category not listed")
    }

    static NoPersonalData() {
        clk := TestClock("20261010120000000")
        dir := TestCallStats.Dir()
        s := TestCallStats.Make(clk, dir)
        s.NewCallEvent("88412")
        s.UseCategory("notDone")
        text := FileRead(s.FileFor("2026-10-10"), "UTF-8")
        for v in ["Jordan", "Smith", "T12345", "88412", "55-2231", "Example", "Mockville"]
            T.NotContains(text, v, "stats file has no " v)
        T.Contains(text, "notDone", "category ids are stored")
    }

    static Prune() {
        clk := TestClock("20261010120000000")
        dir := TestCallStats.Dir()
        DirCreate(dir "\stats")
        mk := (name) => FileAppend('{"agent":"x","date":"d","calls":[]}', dir "\stats\" name, "UTF-8-RAW")
        ; 2026-10-10 minus 90 days = 2026-07-12
        for d in ["2026-07-11", "2026-01-01", "2026-07-12", "2026-07-13", "2026-10-09"]
            mk(d ".json")
        mk("2026-05-01.bad-20260501-101010.json")
        s := TestCallStats.Make(clk, dir)
        n := s.Load().Prune()
        T.Eq(n, 0, "second prune finds nothing")
        T.False(FileExist(dir "\stats\2026-07-11.json"), "91 days old: removed")
        T.False(FileExist(dir "\stats\2026-01-01.json"), "old: removed")
        T.False(FileExist(dir "\stats\2026-05-01.bad-20260501-101010.json"), "old quarantined file: removed")
        T.True(FileExist(dir "\stats\2026-07-12.json") != "", "exactly 90 days old: kept")
        T.True(FileExist(dir "\stats\2026-07-13.json") != "", "89 days old: kept")
        T.True(FileExist(dir "\stats\2026-10-09.json") != "", "yesterday: kept")
        ; Load itself prunes
        dir2 := TestCallStats.Dir()
        DirCreate(dir2 "\stats")
        FileAppend('{"agent":"x","date":"d","calls":[]}', dir2 "\stats\2026-01-01.json", "UTF-8-RAW")
        TestCallStats.Make(clk, dir2).Load()
        T.False(FileExist(dir2 "\stats\2026-01-01.json"), "Load prunes")
    }

    static Subscribers() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk)
        n := [0]
        s.OnChanged((x) => n[1] += 1)
        s.OnChanged(ObjBindMethod(TestCallStats, "Boom"))
        s.OnChanged((x) => n[1] += 10)
        s.NewCallEvent("1")
        T.Eq(n[1], 11, "all healthy subscribers ran")
        s.UseCategory("billing")
        T.Eq(n[1], 22, "category use notifies")
        s.UseCategory("billing")
        T.Eq(n[1], 22, "repeat does not notify")
        s.NewCallEvent("1")
        T.Eq(n[1], 22, "ignored event does not notify")
    }

    static SaveFailure() {
        clk := TestClock("20261010120000000")
        base := TestCallStats.Dir()
        DirCreate(base)
        FileAppend("x", base "\blocker", "UTF-8-RAW")       ; a file where the stats folder should be
        s := CallStats({Dir: base "\blocker", Now: clk.Fn(), Agent: "tester"})
        T.True(s.NewCallEvent("1"), "event still counts when saving fails")
        T.True(s.LastError != "", "error recorded")
        T.Eq(s.Today().Total, 1, "kept in memory")
    }

    static ZeroDebounce() {
        clk := TestClock("20261010120000000")
        s := TestCallStats.Make(clk, , 0)
        T.True(s.NewCallEvent("1"), "first")
        T.True(s.NewCallEvent(""), "same instant, empty job, debounce 0: counted")
        T.True(s.NewCallEvent("2"), "a new job counts")
        T.Eq(s.Today().Total, 3, "three records")
        T.False(s.NewCallEvent("2"), "same job as current record is still ignored")
    }
}
