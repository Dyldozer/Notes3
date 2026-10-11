#Requires AutoHotkey v2.0

class TestConfigStore {
    static Name := "ConfigStore"
    static Root := ""
    static N := 0

    static Run() {
        TestConfigStore.Root := A_Temp "\NFSNotesTest_Store_" A_TickCount
        for name in ["Loading", "Fallbacks", "Unreachable", "Updates", "SaveBasics", "Backups", "Interrupted",
                     "Locks", "Conflict", "SaveEdge"]
            T.Case(name, ObjBindMethod(TestConfigStore, name))
        try DirDelete(TestConfigStore.Root, true)
    }

    ; --- helpers ---------------------------------------------------------------
    ; Fresh {shared, cache} pair of directories (shared is created, cache is not until needed).
    static Dirs() {
        TestConfigStore.N += 1
        d := TestConfigStore.Root "\t" TestConfigStore.N
        DirCreate(d "\shared")
        return {shared: d "\shared", cache: d "\cache"}
    }

    static Cfg(rev := 1, by := "admin") {
        c := Defaults.Config()
        c["revision"] := rev
        c["updatedBy"] := by
        return c
    }

    static Put(path, cfg) => Util.AtomicWrite(path, ConfigJson.Stringify(cfg))

    static Store(d, user := "alice") => ConfigStore({SharedDir: d.shared, CacheDir: d.cache, User: user, Machine: "PC-A"})

    static Raw(path) => FileRead(path, "UTF-8-RAW")

    static Count(pattern) {
        n := 0
        Loop Files pattern, "F"
            n += 1
        return n
    }

    static WarnText(s) {
        out := ""
        for w in s.Warnings
            out .= w "|"
        return out
    }

    ; --- loading ---------------------------------------------------------------
    static Loading() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(12))
        s := TestConfigStore.Store(d).Load()
        T.Eq(s.Source, "shared", "shared OK: source")
        T.Eq(s.Revision, 12, "shared OK: revision")
        T.Eq(s.Warnings.Length, 0, "shared OK: no warnings")
        T.True(s.SharedConfigured, "shared OK: SharedConfigured")
        T.True(FileExist(d.cache "\config.cache.json"), "shared OK: cache written")
        T.Eq(ConfigJson.Parse(FileRead(d.cache "\config.cache.json", "UTF-8"))["revision"], 12, "cache holds the shared revision")
        T.False(FileExist(d.cache "\config.cache.json.tmp"), "no .tmp left in cache dir")
        T.Eq(s.ChipText(), "config: shared r12", "chip text for shared")

        ; legacy v0 file on the share is migrated on load
        d := TestConfigStore.Dirs()
        legacy := Map("historyDays", 21)
        FileAppend(ConfigJson.Stringify(legacy), d.shared "\config.json", "UTF-8-RAW")
        s := TestConfigStore.Store(d).Load()
        T.Eq(s.Source, "shared", "v0 shared file loads (migrated)")
        T.Eq(s.Config["history"]["retentionDays"], 21, "v0 value carried over")
        T.Eq(ConfigJson.Parse(FileRead(d.cache "\config.cache.json", "UTF-8"))["schemaVersion"], 1, "cache holds migrated v1")

        ; no shared path
        d := TestConfigStore.Dirs()
        s := ConfigStore({CacheDir: d.cache}).Load()
        T.Eq(s.Source, "defaults", "no shared path, no cache: defaults")
        T.Eq(s.Warnings.Length, 0, "no shared path: no warning")
        T.False(s.SharedConfigured, "no shared path: SharedConfigured false")
        T.Eq(s.ChipText(), "config: local", "chip text local")
        TestConfigStore.Put(d.cache "\config.cache.json", TestConfigStore.Cfg(7))
        s := ConfigStore({CacheDir: d.cache}).Load()
        T.Eq(s.Source, "cache", "no shared path, valid cache used")
        T.Eq(s.Warnings.Length, 0, "no shared path with cache: still no warning")
        T.Eq(s.ChipText(), "config: local r7", "chip text local with revision")
        ; corrupt cache and no shared path: defaults, silently
        FileDelete(d.cache "\config.cache.json")
        FileAppend("{broken", d.cache "\config.cache.json", "UTF-8-RAW")
        s := ConfigStore({CacheDir: d.cache}).Load()
        T.True(s.Source = "defaults" && s.Warnings.Length = 0, "corrupt cache, no shared path: defaults, no warning")
    }

    ; Shared file bad in various ways -> the cache (r5) is used, with a warning.
    static Fallbacks() {
        cases := Map()
        cases["missing file"] := (d) => 0
        cases["malformed JSON"] := (d) => FileAppend('{"schemaVersion": 1, ', d.shared "\config.json", "UTF-8-RAW")
        cases["empty file"] := (d) => FileAppend("", d.shared "\config.json", "UTF-8-RAW")
        cases["invalid config"] := (d) => TestConfigStore.Put(d.shared "\config.json", TestConfigStore.BadCfg())
        cases["too new"] := (d) => TestConfigStore.Put(d.shared "\config.json", TestConfigStore.NewerCfg())
        for name, setup in cases {
            d := TestConfigStore.Dirs()
            TestConfigStore.Put(d.cache "\config.cache.json", TestConfigStore.Cfg(5))
            setup(d)
            s := TestConfigStore.Store(d).Load()
            T.Eq(s.Source, "cache", name ": falls back to cache")
            T.Eq(s.Revision, 5, name ": cache revision")
            T.True(s.Warnings.Length >= 1, name ": has a warning")
            T.Contains(s.ChipText(), Chr(0x26A0), name ": chip shows the warning mark")
            T.Eq(s.ChipText(), "config: cache r5 " Chr(0x26A0), name ": chip text")
        }
        ; the warning text is specific
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.NewerCfg())
        s := TestConfigStore.Store(d).Load()
        T.Contains(TestConfigStore.WarnText(s), "newer version", "too-new warning says why")
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.BadCfg())
        s := TestConfigStore.Store(d).Load()
        T.Contains(TestConfigStore.WarnText(s), "categories", "invalid warning names the path")

        ; shared bad AND cache bad/missing -> defaults with warning
        d := TestConfigStore.Dirs()
        s := TestConfigStore.Store(d).Load()
        T.Eq(s.Source, "defaults", "no shared file, no cache: defaults")
        T.True(s.Warnings.Length >= 1, "defaults fallback has a warning")
        T.Eq(s.Revision, 0, "defaults revision 0")
        T.Eq(s.ChipText(), "config: defaults " Chr(0x26A0), "defaults chip")
        d := TestConfigStore.Dirs()
        DirCreate(d.cache)
        FileAppend("not json", d.cache "\config.cache.json", "UTF-8-RAW")
        s := TestConfigStore.Store(d).Load()
        T.True(s.Source = "defaults" && s.Warnings.Length >= 2, "corrupt cache + missing shared: defaults, warnings")
        ; the defaults object is a fresh copy each time
        s.Config["ping"]["attempts"] := 9
        T.Eq(Defaults.Config()["ping"]["attempts"], 4, "mutating loaded defaults does not leak")
    }

    static BadCfg() {
        c := TestConfigStore.Cfg(9)
        c["categories"].RemoveAt(1)
        return c
    }

    static NewerCfg() {
        c := TestConfigStore.Cfg(9)
        c["schemaVersion"] := 2
        return c
    }

    static Unreachable() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.cache "\config.cache.json", TestConfigStore.Cfg(5))
        gone := TestConfigStore.Root "\does\not\exist"
        s := ConfigStore({SharedDir: gone, CacheDir: d.cache}).Load()
        T.Eq(s.Source, "cache", "nonexistent shared dir: cache")
        T.True(s.Warnings.Length >= 1 && InStr(TestConfigStore.WarnText(s), "not reachable"), "nonexistent shared dir: warning")
        r := ConfigStore({SharedDir: gone, CacheDir: d.cache}).Save(Defaults.Config())
        T.False(r.Ok, "save to an unreachable folder fails cleanly")
        ; UNC host that does not exist; timed so a slow lookup shows up in the notes
        t0 := A_TickCount
        s := ConfigStore({SharedDir: "\\nonexistent-host-xyz\share", CacheDir: d.cache}).Load()
        ms := A_TickCount - t0
        T.Eq(s.Source, "cache", "bad UNC path: cache (took " ms " ms)")
        T.True(ms < 8000, "bad UNC path does not hang (" ms " ms)")
    }

    static Updates() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(1))
        s := TestConfigStore.Store(d).Load()
        T.False(s.CheckForUpdate(), "no update when revisions match")
        c := TestConfigStore.Cfg(2)
        c["ping"]["attempts"] := 6
        TestConfigStore.Put(d.shared "\config.json", c)
        T.True(s.CheckForUpdate(), "update found when revision differs")
        T.Eq(s.Revision, 1, "loaded config unchanged until applied")
        T.True(s.ApplyPending(), "ApplyPending")
        T.Eq(s.Revision, 2, "revision after apply")
        T.Eq(s.Config["ping"]["attempts"], 6, "new content after apply")
        T.Eq(ConfigJson.Parse(FileRead(d.cache "\config.cache.json", "UTF-8"))["revision"], 2, "cache refreshed on apply")
        T.False(s.ApplyPending(), "nothing pending now")
        ; invalid shared file is not offered as an update
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.BadCfg())
        T.False(s.CheckForUpdate(), "invalid shared file is not an update")
        ; recovery: loaded from cache, shared comes back with the same revision -> still offered
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.cache "\config.cache.json", TestConfigStore.Cfg(3))
        s := TestConfigStore.Store(d).Load()
        T.Eq(s.Source, "cache", "(loaded from cache)")
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
        T.True(s.CheckForUpdate(), "shared back online with same revision is offered")
        s.ApplyPending()
        T.True(s.Source = "shared" && s.Warnings.Length = 0, "applying clears the warning")
    }

    ; --- saving ------------------------------------------------------------------
    static SaveBasics() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
        s := TestConfigStore.Store(d, "alice").Load()
        cfg := Util.Clone(s.Config)
        cfg["categories"][1]["label"] := "Not Done (edited)"
        r := s.Save(cfg)
        T.True(r.Ok, "save succeeds " r.Error)
        T.Eq(r.Revision, 4, "revision bumped")
        T.Eq(s.Revision, 4, "store revision follows")
        disk := ConfigJson.Parse(FileRead(d.shared "\config.json", "UTF-8"))
        T.Eq(disk["revision"], 4, "file revision")
        T.Eq(disk["updatedBy"], "alice", "updatedBy set")
        T.Eq(disk["categories"][1]["label"], "Not Done (edited)", "content saved")
        T.True(RegExMatch(disk["updatedAt"], "^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$"), "updatedAt set")
        T.Eq(TestConfigStore.Count(d.shared "\backups\config-*.json"), 1, "one backup written")
        T.Eq(ConfigJson.Parse(FileRead(d.cache "\config.cache.json", "UTF-8"))["revision"], 4, "cache refreshed")
        T.False(FileExist(d.shared "\config.lock"), "lock released")
        T.False(FileExist(d.shared "\config.json.tmp"), "no .tmp left")
        T.Contains(FileRead(d.shared "\config.json", "UTF-8-RAW"), '"enabled": true', "booleans written as true/false")
        ; the backup is the PREVIOUS file (r3)
        Loop Files d.shared "\backups\config-*.json"
            T.Eq(ConfigJson.Parse(FileRead(A_LoopFileFullPath, "UTF-8"))["revision"], 3, "backup holds the previous revision")
        ; a second store sees the saved file
        s2 := TestConfigStore.Store(d, "bob").Load()
        T.True(s2.Source = "shared" && s2.Revision = 4, "fresh store loads the saved config")
    }

    static Backups() {
        d := TestConfigStore.Dirs()
        s := TestConfigStore.Store(d).Load()       ; no shared file yet: defaults, r0
        n := 0
        loop 25 {
            r := s.Save(s.Config)
            if r.Ok
                n += 1
        }
        T.Eq(n, 25, "25 saves succeed")
        T.Eq(s.Revision, 25, "revision after 25 saves")
        T.Eq(TestConfigStore.Count(d.shared "\backups\config-*.json"), 20, "exactly 20 backups kept")
        T.Eq(ConfigJson.Parse(FileRead(d.shared "\config.json", "UTF-8"))["revision"], 25, "file at r25")
        ; the kept backups are the newest 19..24 -> oldest kept is r5 (backups hold revisions 1..24; first save wrote no backup)
        lowest := 999
        Loop Files d.shared "\backups\config-*.json" {
            rev := ConfigJson.Parse(FileRead(A_LoopFileFullPath, "UTF-8"))["revision"]
            lowest := Min(lowest, rev)
        }
        T.Eq(lowest, 5, "oldest backups were pruned (lowest kept revision)")
    }

    static Interrupted() {
        for point in ["afterTmp", "afterBackup"] {
            d := TestConfigStore.Dirs()
            TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
            before := TestConfigStore.Raw(d.shared "\config.json")
            s := TestConfigStore.Store(d).Load()
            s.FailAt := point
            cfg := Util.Clone(s.Config)
            cfg["categories"][1]["label"] := "SHOULD NOT BE SAVED"
            r := s.Save(cfg)
            T.False(r.Ok, point ": save reports failure")
            T.Contains(r.Error, "not changed", point ": message says the original is unchanged")
            T.True(TestConfigStore.Raw(d.shared "\config.json") == before, point ": original byte-identical")
            T.False(FileExist(d.shared "\config.lock"), point ": no lock left")
            T.False(FileExist(d.shared "\config.json.tmp"), point ": no .tmp left")
            T.Eq(s.Revision, 3, point ": store revision unchanged")
            ; after clearing the hook the same store can save normally
            s.FailAt := ""
            T.True(s.Save(cfg).Ok, point ": later save works")
        }
    }

    static Locks() {
        ; fresh lock by someone else -> refused, holder named
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
        before := TestConfigStore.Raw(d.shared "\config.json")
        s := TestConfigStore.Store(d, "alice").Load()
        lock := Map("user", "dana", "machine", "PC-DANA", "time", Util.IsoNow())
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        r := s.Save(s.Config)
        T.False(r.Ok, "fresh foreign lock: refused")
        T.Contains(r.Error, "dana", "fresh foreign lock: holder named")
        T.True(FileExist(d.shared "\config.lock") != "", "foreign lock left in place")
        T.True(TestConfigStore.Raw(d.shared "\config.json") == before, "file untouched when locked")
        ; stale foreign lock -> taken over
        old := FormatTime(DateAdd(A_Now, -2, "Hours"), "yyyy-MM-dd'T'HH:mm:ss")
        lock := Map("user", "dana", "machine", "PC-DANA", "time", old)
        FileDelete(d.shared "\config.lock")
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        r := s.Save(s.Config)
        T.True(r.Ok, "stale foreign lock: taken over " r.Error)
        T.False(FileExist(d.shared "\config.lock"), "lock released after takeover")
        ; just under / over the limit
        lock["time"] := FormatTime(DateAdd(A_Now, -29, "Minutes"), "yyyy-MM-dd'T'HH:mm:ss")
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        T.False(s.Save(s.Config).Ok, "29 minute old lock still holds")
        lock["time"] := FormatTime(DateAdd(A_Now, -31, "Minutes"), "yyyy-MM-dd'T'HH:mm:ss")
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        T.True(s.Save(s.Config).Ok, "31 minute old lock is stale")
        ; same user on another PC -> a different holder, refused
        lock := Map("user", "alice", "machine", "PC-OTHER", "time", Util.IsoNow())
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        r := s.Save(s.Config)
        T.False(r.Ok, "same user on another PC: refused")
        T.Contains(r.Error, "PC-OTHER", "same user on another PC: machine named")
        T.True(FileExist(d.shared "\config.lock") != "", "other PC's lock left in place")
        FileDelete(d.shared "\config.lock")
        ; same user, same PC -> re-entrant
        lock := Map("user", "alice", "machine", s.Machine, "time", Util.IsoNow())
        Util.AtomicWrite(d.shared "\config.lock", ConfigJson.Stringify(lock))
        T.True(s.Save(s.Config).Ok, "own fresh lock is re-entrant")
        T.False(FileExist(d.shared "\config.lock"), "lock released after re-entrant save")
        ; CREATE_NEW: a second create on an existing lock fails, the first holder's content survives
        lp := d.shared "\race.lock"
        T.True(ConfigStore._CreateNew(lp, "first"), "create-new on a free lock succeeds")
        T.False(ConfigStore._CreateNew(lp, "second"), "create-new on a taken lock fails")
        T.Eq(FileRead(lp, "UTF-8"), "first", "taken lock keeps the first holder")
        FileDelete(lp)
        ; unreadable lock -> taken over
        FileAppend("garbage", d.shared "\config.lock", "UTF-8-RAW")
        T.True(s.Save(s.Config).Ok, "corrupt lock file is taken over")
        ; a lock that is not ours when we finish is not deleted by release
        T.False(FileExist(d.shared "\config.lock"), "no lock after corrupt-lock save")
    }

    static Conflict() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
        a := TestConfigStore.Store(d, "alice").Load()
        b := TestConfigStore.Store(d, "bob").Load()
        cb := Util.Clone(b.Config)
        cb["categories"][1]["label"] := "Bob's edit"
        T.True(b.Save(cb).Ok, "first admin saves")
        before := TestConfigStore.Raw(d.shared "\config.json")
        r := a.Save(a.Config)
        T.False(r.Ok, "stale revision: refused")
        T.Contains(r.Error, "bob", "conflict names who changed it")
        T.Contains(r.Error, "Reload", "conflict tells the admin to reload")
        T.True(TestConfigStore.Raw(d.shared "\config.json") == before, "file untouched on conflict")
        T.False(FileExist(d.shared "\config.lock"), "no lock left after conflict")
        a.Load()
        T.Eq(a.Revision, 4, "reload picks up the new revision")
        T.True(a.Save(a.Config).Ok, "save after reload works")
        T.Eq(a.Revision, 5, "revision 5")
    }

    static SaveEdge() {
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(3))
        s := TestConfigStore.Store(d).Load()
        before := TestConfigStore.Raw(d.shared "\config.json")
        bad := Util.Clone(s.Config)
        bad["categories"].RemoveAt(1)
        r := s.Save(bad)
        T.False(r.Ok, "invalid config refused")
        T.Contains(r.Error, "notDone", "refusal names the problem")
        T.True(TestConfigStore.Raw(d.shared "\config.json") == before, "file untouched on invalid save")
        T.False(FileExist(d.shared "\config.lock"), "no lock left after invalid save")
        T.False(ConfigStore({CacheDir: d.cache}).Save(Defaults.Config()).Ok, "save without a shared dir fails")
        T.False(s.Save("nope").Ok, "non-object refused")
        ; RestoreDefaults returns the built-ins and saving them works
        rd := s.RestoreDefaults()
        T.Eq(ConfigJson.Canon(rd), ConfigJson.Canon(Defaults.Config()), "RestoreDefaults equals Defaults")
        T.True(s.Save(rd).Ok, "restored defaults can be saved")
        ; corrupt shared file: loads as defaults (via cache/none), save backs it up and replaces it
        d := TestConfigStore.Dirs()
        FileAppend("garbage{", d.shared "\config.json", "UTF-8-RAW")
        s := TestConfigStore.Store(d).Load()
        T.Eq(s.Source, "defaults", "(corrupt shared, no cache: defaults)")
        T.True(s.Save(s.Config).Ok, "repair save over a corrupt file works")
        found := false
        Loop Files d.shared "\backups\config-*.json"
            found := TestConfigStore.Raw(A_LoopFileFullPath) == "garbage{"
        T.True(found, "corrupt file was kept as a backup")
        ; same-second backups do not collide
        d := TestConfigStore.Dirs()
        TestConfigStore.Put(d.shared "\config.json", TestConfigStore.Cfg(1))
        s := TestConfigStore.Store(d).Load()
        loop 3
            s.Save(s.Config)
        T.Eq(TestConfigStore.Count(d.shared "\backups\config-*.json"), 3, "3 quick saves give 3 distinct backups")
    }
}
