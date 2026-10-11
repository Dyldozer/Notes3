#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\Gui visual Library\lib\AxJson.ahk
; ConfigJson.ahk - JSON read/write for config and settings files.
; Wraps AxJson (pure parser, no GUI code). AxJson reads null as "" and true/false as 1/0 and can
; only write 1/0, so known boolean keys are post-processed into true/false to keep files readable.
; The reader accepts 1/0 and true/false for those keys.

class ConfigJson {
    static BOOL_KEYS := ["enabled", "system", "required", "sentenceCase", "alwaysOnTop", "historyOpen",
        "qty", "details", "multiline", "outcomeRequired"]

    static Parse(text) => AxJson.Parse(text)

    ; Pretty text, Map keys in sorted order (AxJson), booleans written as true/false.
    static Stringify(v) {
        s := AxJson.Stringify(v, "  ")
        keys := ""
        for k in ConfigJson.BOOL_KEYS
            keys .= (keys = "" ? "" : "|") k
        s := RegExReplace(s, "m)^(\s*`"(?:" keys ")`": )1(,?)$", "${1}true$2")
        s := RegExReplace(s, "m)^(\s*`"(?:" keys ")`": )0(,?)$", "${1}false$2")
        return s
    }

    ; Canonical compact form used to compare two trees structurally.
    static Canon(v) => AxJson.Stringify(v, "")
}
