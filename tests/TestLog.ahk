#Requires AutoHotkey v2.0

class TestLog {
    static Name := "Log"

    static Run() {
        base := A_Temp "\NFSNotesTest_Log_" A_TickCount
        T.Case("redact", () => TestLog.Redaction(base))
        T.Case("levels", () => TestLog.Levels(base))
        T.Case("rotation", () => TestLog.Rotation(base))
        T.Case("default path", () => TestLog.DefaultPath())
        try DirDelete(base, true)
    }

    static Read(path) => FileExist(path) ? FileRead(path, "UTF-8") : ""

    static Redaction(base) {
        p := base "\r\test.log"
        lg := Log({Path: p, Level: "debug"})
        lg.RegisterSensitive("Jordan Smith")
        lg.RegisterSensitive("Jordan")
        lg.RegisterSensitive("123 Example St")
        lg.RegisterSensitive("88412")
        lg.RegisterSensitive("")
        T.Eq(lg.Redact("hello Jordan Smith at 123 example st job 88412"), "hello [redacted] at [redacted] job [redacted]", "registered values masked (case-insensitive)")
        T.Eq(lg.Redact("Jordan Smith"), "[redacted]", "longest value wins over its first-name part")
        T.Eq(lg.Redact("only Jordan"), "only [redacted]", "shorter registered value masked")
        T.Eq(lg.Redact("ping 192.168.1.10 ok"), "ping 192.168.1.10 ok", "IPv4 kept")

        lg.Info("msg with Jordan Smith")
        lg.Info("ctx", {techName: "Someone Else", techId: "T999", address: "9 Nowhere Rd", jobNumber: "J1", workOrder: "W1", supervisorName: "Boss Person", notes: "free text", ip: "10.0.0.1", count: 3})
        lg.Warn("map", Map("TechName", "Casey Jones", "other", "88412 here"))
        lg.Info("plain string data", "Jordan stuff")
        txt := TestLog.Read(p)
        for bad in ["Jordan", "Someone Else", "T999", "9 Nowhere", "Boss Person", "free text", "Casey", "88412", "123 Example"]
            T.NotContains(txt, bad, "log never contains '" bad "'")
        T.Contains(txt, "ip=10.0.0.1", "IP field kept in structured data")
        T.Contains(txt, "count=3", "non-sensitive field kept")
        T.Contains(txt, "techName=[redacted]", "sensitive key masked")
        T.Contains(txt, "TechName=[redacted]", "sensitive key masked for Map, case-insensitive")
        T.Contains(txt, "INFO  msg with [redacted]", "message redacted, level padded")
        T.True(RegExMatch(txt, "m)^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3} INFO "), "line starts with ISO timestamp")
    }

    static Levels(base) {
        p := base "\l\test.log"
        lg := Log({Path: p, Level: "warn"})
        lg.Debug("dbg"), lg.Info("inf"), lg.Warn("wrn"), lg.Error("err")
        txt := TestLog.Read(p)
        T.NotContains(txt, "dbg", "debug filtered at warn")
        T.NotContains(txt, "inf", "info filtered at warn")
        T.Contains(txt, "wrn", "warn written")
        T.Contains(txt, "err", "error written")
        lg.SetLevel("debug")
        lg.Debug("dbg2")
        T.Contains(TestLog.Read(p), "dbg2", "debug written after SetLevel(debug)")
        lg.SetLevel("bogus")
        T.Eq(lg.LevelName, "info", "unknown level falls back to info")
    }

    static Rotation(base) {
        p := base "\rot\test.log"
        lg := Log({Path: p, Level: "info", MaxBytes: 500, Keep: 3})
        loop 60
            lg.Info("line number " A_Index " padding padding padding padding")
        T.True(FileExist(p), "active log exists")
        T.True(FileExist(p ".1"), ".1 exists")
        T.True(FileExist(p ".2"), ".2 exists")
        T.True(FileExist(p ".3"), ".3 exists")
        T.False(FileExist(p ".4"), "no more than Keep rotated files")
        T.True(FileGetSize(p) < 500 + 200, "active log stays near the limit")
        T.Contains(TestLog.Read(p), "line number 60", "newest line is in the active log")
    }

    static DefaultPath() {
        lg := Log()
        T.Eq(lg.Path, A_MyDocuments "\NotesForNFS\logs\nfsnotes.log", "default path under Documents\NotesForNFS")
    }
}
