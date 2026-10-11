#Requires AutoHotkey v2.0
; TestLib.ahk - tiny assertion library. Headless: no GUI.

class T {
    static Lines := []
    static Pass := 0
    static Fail := 0
    static Suite := ""

    static Record(ok, name, detail := "") {
        label := (T.Suite != "" ? T.Suite ": " : "") name
        if ok {
            T.Pass += 1
            T.Lines.Push("PASS " label)
        } else {
            T.Fail += 1
            T.Lines.Push("FAIL " label (detail != "" ? " -- " detail : ""))
        }
        return ok
    }

    static Eq(actual, expected, name) {
        a := IsObject(actual) ? "<object>" : String(actual)
        e := IsObject(expected) ? "<object>" : String(expected)
        return T.Record(a == e, name, "expected [" e "] got [" a "]")
    }

    static True(cond, name) => T.Record(!!cond, name, "condition was false")

    static False(cond, name) => T.Record(!cond, name, "condition was true")

    static Contains(haystack, needle, name) =>
        T.Record(InStr(haystack, needle, true) > 0, name, "[" needle "] not found in [" SubStr(haystack, 1, 200) "]")

    static NotContains(haystack, needle, name) =>
        T.Record(!InStr(haystack, needle, true), name, "[" needle "] unexpectedly found")

    static Throws(fn, name) {
        try fn()
        catch
            return T.Record(true, name)
        return T.Record(false, name, "no exception thrown")
    }

    ; Run a test body; an unexpected exception becomes a FAIL line instead of aborting the run.
    static Case(name, fn) {
        try fn()
        catch as e
            T.Record(false, name, "exception: " e.Message " (line " e.Line ")")
    }

    static Summary() => "TOTAL " (T.Pass + T.Fail) " PASS " T.Pass " FAIL " T.Fail

    static Report() {
        out := ""
        for l in T.Lines
            out .= l "`n"
        return out T.Summary() "`n"
    }
}
