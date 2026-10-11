#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\Util.ahk
; Log.ahk - rotating diagnostic log with personal-data redaction.
;
; Usage (instance, owned by App):
;   log := Log({Path: "...", Level: "info"})
;   log.RegisterSensitive("Jordan Smith")
;   log.Info("ctx", {techName: "Jordan Smith", count: 3})   ; techName -> [redacted]
;
; IPv4 addresses are deliberately NOT masked (needed for ping diagnostics).

class Log {
    static LEVELS := Map("debug", 1, "info", 2, "warn", 3, "error", 4)
    static SENSITIVE_KEYS := ["techname", "techid", "address", "jobnumber", "workorder", "supervisorname", "notes"]
    static MASK := "[redacted]"

    ; opts: Path, Level, MaxBytes, Keep
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.Path := o.HasOwnProp("Path") && o.Path != "" ? o.Path : Util.UserDataDir() "\logs\nfsnotes.log"
        this.MaxBytes := o.HasOwnProp("MaxBytes") ? o.MaxBytes : 1048576
        this.Keep := o.HasOwnProp("Keep") ? o.Keep : 5
        this.LastError := ""
        this._sensitive := []
        this.SetLevel(o.HasOwnProp("Level") ? o.Level : "info")
    }

    SetLevel(name) {
        name := StrLower(Trim(String(name)))
        this.LevelName := Log.LEVELS.Has(name) ? name : "info"
        this._level := Log.LEVELS[this.LevelName]
    }

    ; Register a value that must never appear in the log (names, addresses, job numbers, IDs).
    RegisterSensitive(value) {
        v := Util.Trim(value)
        if (StrLen(v) < 2)
            return
        for x in this._sensitive
            if (x = v)
                return
        ; keep longest first so "Jordan Smith" is masked before "Jordan"
        pos := this._sensitive.Length + 1
        for i, x in this._sensitive
            if (StrLen(v) > StrLen(x)) {
                pos := i
                break
            }
        this._sensitive.InsertAt(pos, v)
    }

    ClearSensitive() => this._sensitive := []

    ; Mask all registered sensitive values (case-insensitive) in text.
    Redact(text) {
        text := String(text)
        for v in this._sensitive
            text := StrReplace(text, v, Log.MASK)
        return text
    }

    static IsSensitiveKey(key) {
        k := StrLower(String(key))
        for s in Log.SENSITIVE_KEYS
            if (s = k)
                return true
        return false
    }

    ; Render a data object/Map as "k=v k=v" with sensitive keys masked.
    FormatData(data) {
        if !IsObject(data)
            return this.Redact(data)
        parts := []
        if (data is Map) {
            for k, v in data
                parts.Push(this._Pair(k, v))
        } else if (data is Array) {
            for v in data
                parts.Push(this.Redact(this._Str(v)))
        } else {
            for k, v in data.OwnProps()
                parts.Push(this._Pair(k, v))
        }
        out := ""
        for p in parts
            out .= (out = "" ? "" : " ") p
        return out
    }

    _Pair(k, v) => k "=" (Log.IsSensitiveKey(k) ? Log.MASK : this.Redact(this._Str(v)))

    _Str(v) => IsObject(v) ? "<object>" : String(v)

    Debug(msg, data := unset) => this.Write("debug", msg, data?)
    Info(msg, data := unset) => this.Write("info", msg, data?)
    Warn(msg, data := unset) => this.Write("warn", msg, data?)
    Error(msg, data := unset) => this.Write("error", msg, data?)

    ; Never throws: a logging failure must not break the app. See LastError.
    Write(level, msg, data := unset) {
        lv := Log.LEVELS.Has(level) ? Log.LEVELS[level] : 2
        if (lv < this._level)
            return false
        line := Util.IsoNow(true) " " SubStr(StrUpper(level) "     ", 1, 5) " " this.Redact(this._Str(msg))
        if IsSet(data) {
            extra := this.FormatData(data)
            if (extra != "")
                line .= " | " extra
        }
        line := StrReplace(StrReplace(line, "`r", " "), "`n", " ")
        try {
            Util.EnsureDir(Util.ParentDir(this.Path))
            this._RotateIfNeeded()
            FileAppend(line "`n", this.Path, "UTF-8-RAW")
            return true
        } catch as e {
            this.LastError := e.Message
            return false
        }
    }

    _RotateIfNeeded() {
        if !FileExist(this.Path) || FileGetSize(this.Path) < this.MaxBytes
            return
        oldest := this.Path "." this.Keep
        if FileExist(oldest)
            FileDelete(oldest)
        i := this.Keep - 1
        while (i >= 1) {
            src := this.Path "." i
            if FileExist(src)
                FileMove(src, this.Path "." (i + 1), 1)
            i--
        }
        FileMove(this.Path, this.Path ".1", 1)
    }
}
