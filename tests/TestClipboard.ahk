#Requires AutoHotkey v2.0

class TestClipboard {
    static Name := "Clipboard"

    static Run() {
        for name in ["Ok", "RetryOnce", "FailsTwice", "SetFails", "Crlf", "Real"]
            T.Case(name, ObjBindMethod(TestClipboard, name))
    }

    ; fake clipboard: Mode "good" stores what is set; "badOnce" loses the first set; "bad" never keeps it
    static Fake(mode) {
        f := {Store: "", Sets: 0, Gets: 0}
        f.Set := (s) => (f.Sets += 1, f.Store := (mode = "bad" || (mode = "badOnce" && f.Sets = 1)) ? "other" : s)
        f.Get := () => (f.Gets += 1, f.Store)
        return f
    }

    static Ok() {
        f := TestClipboard.Fake("good")
        r := NoteClipboard.Copy("hello", f)
        T.True(r.Ok, "copy ok")
        T.Eq(r.Error, "", "no error")
        T.Eq(f.Store, "hello", "text stored")
        T.Eq(f.Sets, 1, "one set when it works first time")
    }

    static RetryOnce() {
        f := TestClipboard.Fake("badOnce")
        r := NoteClipboard.Copy("hello", f)
        T.True(r.Ok, "second attempt succeeds")
        T.Eq(f.Sets, 2, "exactly one retry")
        T.Eq(f.Store, "hello", "text stored after retry")
    }

    static FailsTwice() {
        f := TestClipboard.Fake("bad")
        r := NoteClipboard.Copy("hello", f)
        T.False(r.Ok, "fails after two attempts")
        T.Eq(f.Sets, 2, "no more than two attempts")
        T.Eq(r.Error, "Clipboard is in use by another app " Chr(0x2014) " try again.", "actionable error text")
    }

    static SetFails() {
        n := [0]
        hooks := {Set: (s) => (n[1] += 1, false), Get: () => "hello"}
        r := NoteClipboard.Copy("hello", hooks)
        T.False(r.Ok, "a set that reports failure is a failure")
        T.Eq(n[1], 2, "retried once")
        thrower := {Set: ObjBindMethod(TestClipboard, "Throws"), Get: () => ""}
        r := NoteClipboard.Copy("x", thrower)
        T.False(r.Ok, "an exception from the clipboard is a failure, not a crash")
    }

    static Throws(*) {
        throw OSError("busy")
    }

    static Crlf() {
        f := TestClipboard.Fake("good")
        NoteClipboard.Copy("a`nb`r`nc`rd", f)
        T.Eq(f.Store, "a`r`nb`r`nc`r`nd", "line endings normalised to CRLF before copying")
        T.Eq(NoteClipboard.Crlf("x`ny"), "x`r`ny", "Crlf helper")
    }

    ; One test against the real clipboard; it saves and restores the user's clipboard.
    static Real() {
        saved := ClipboardAll()
        try {
            r := NoteClipboard.Copy("nfs-notes clipboard test`nline two")
            T.True(r.Ok, "real clipboard copy ok")
            T.Eq(A_Clipboard, "nfs-notes clipboard test`r`nline two", "real clipboard holds the CRLF text")
        } finally
            A_Clipboard := saved
    }
}
