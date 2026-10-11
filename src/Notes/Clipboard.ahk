#Requires AutoHotkey v2.0
; Clipboard.ahk - copy text with read-back verification and one retry (PLAN 5.4 "Copy Notes").
; Pure logic apart from the clipboard itself, which tests replace through the injectable Set/Get functions:
;
;   NoteClipboard.Copy(text)                                     ; real clipboard
;   NoteClipboard.Copy(text, {Set: (s) => ..., Get: () => ...})  ; injected (tests)
;
; Returns {Ok, Error}. Line endings are normalised to CRLF. The text is never logged here.

class NoteClipboard {
    static ERROR_TEXT := "Clipboard is in use by another app " Chr(0x2014) " try again."

    static Copy(text, hooks := "") {
        text := NoteClipboard.Crlf(text)
        setFn := IsObject(hooks) && hooks.HasOwnProp("Set") ? hooks.Set : (s) => NoteClipboard._RealSet(s)
        getFn := IsObject(hooks) && hooks.HasOwnProp("Get") ? hooks.Get : () => NoteClipboard._RealGet()
        loop 2 {
            try {
                if (setFn(text) !== false) {
                    back := getFn()
                    if (back == text)
                        return {Ok: true, Error: ""}
                }
            }
            Sleep(IsObject(hooks) && hooks.HasOwnProp("Set") ? 0 : 60)
        }
        return {Ok: false, Error: NoteClipboard.ERROR_TEXT}
    }

    static Crlf(s) => StrReplace(StrReplace(StrReplace(String(s), "`r`n", "`n"), "`r", "`n"), "`n", "`r`n")

    ; Real clipboard: set, then wait up to 1 s for it to be ready (an empty string never raises ClipWait).
    static _RealSet(text) {
        A_Clipboard := text
        if (text = "")
            return true
        return ClipWait(1) ? true : false
    }

    static _RealGet() => A_Clipboard
}
