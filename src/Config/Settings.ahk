#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\ConfigJson.ahk
; Settings.ahk - per-user preferences in <Dir>\settings.json (default Documents\NotesForNFS).
; Pure logic: no GUI. Invalid values are rejected by Set() (returns false) and repaired on Load().
;
;   s := Settings({Dir: Util.UserDataDir(), Logger: lg})
;   s.Load(), s.Get("mode"), s.Set("fontSize", 14), s.Save()
;
; Appearance keys (M9): preset ("" = the config's default look), mode ("" = the look's own mode, or light / dark /
; system), accent ("" = the look's colour, or #RRGGBB), fontFamily ("" = the look's font, or one of FONTS), fontSize.
; Older files only had theme: light|dark; Load() maps it to mode (and the next Save writes mode, not theme).

class Settings {
    static KEYS := ["preset", "mode", "accent", "fontFamily", "fontSize", "window", "alwaysOnTop", "historyOpen", "lastPage"]
    static APPEARANCE_KEYS := ["preset", "mode", "accent", "fontFamily", "fontSize"]
    static MODES := ["light", "dark", "system"]
    ; Fonts the Settings page may offer (the first is the default; "" in the file means the same as the look's own).
    static FONTS := ["Segoe UI", "Calibri", "Arial", "Tahoma", "Verdana"]
    static SIZE_MIN := 9
    static SIZE_MAX := 20
    static SIZE_DEFAULT := 12

    static Defaults() {
        d := Map()
        d["preset"] := ""                       ; "" = the config's default look
        d["mode"] := ""                         ; "" = the look's own mode
        d["accent"] := ""                       ; "" = use the look's colour
        d["fontFamily"] := ""                   ; "" = the look's font (Segoe UI)
        d["fontSize"] := Settings.SIZE_DEFAULT
        d["window"] := Map("x", "", "y", "", "w", "", "h", "")     ; "" = unset
        d["alwaysOnTop"] := 0
        d["historyOpen"] := 0
        d["lastPage"] := ""
        return d
    }

    ; The five appearance values at their defaults (Restore defaults on the Settings page).
    static AppearanceDefaults() {
        d := Settings.Defaults()
        m := Map()
        for k in Settings.APPEARANCE_KEYS
            m[k] := d[k]
        return m
    }

    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.Dir := RTrim(HasProp(o, "Dir") && o.Dir != "" ? o.Dir : Util.UserDataDir(), "\")
        this.Logger := HasProp(o, "Logger") ? o.Logger : ""
        this.Values := Settings.Defaults()
        this.Warnings := []
        this.BadFile := ""                       ; path the corrupt file was renamed to, if any
    }

    Path => this.Dir "\settings.json"

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }

    ; Returns a normalised value, or throws ValueError when invalid.
    static Normalize(key, v) {
        switch key {
        case "preset":
            if (v is String && RegExMatch(v, "^(?:[A-Za-z][A-Za-z0-9_-]{0,63})?$"))
                return v
        case "mode":
            if (v is String && (v = "" || Settings.InList(Settings.MODES, v)))
                return StrLower(v)
        case "accent":
            if (v is String && (v = "" || (StrLen(v) = 7 && RegExMatch(v, "^#[0-9A-Fa-f]{6}$"))))
                return StrUpper(v)
        case "fontFamily":
            if (v is String) {
                if (v = "")
                    return ""
                for fam in Settings.FONTS
                    if (StrCompare(fam, v) = 0)
                        return fam
            }
        case "fontSize":
            if (v is Integer && v >= Settings.SIZE_MIN && v <= Settings.SIZE_MAX)
                return v
        case "alwaysOnTop", "historyOpen":
            if (v is Integer && (v = 0 || v = 1))
                return v
        case "lastPage":
            if (v is String && RegExMatch(v, "^[A-Za-z0-9_]{0,40}$"))
                return v
        case "window":
            if (v is Map) {
                out := Map("x", "", "y", "", "w", "", "h", "")
                for k, x in v {
                    if !out.Has(k)
                        throw ValueError("window." k " is not a window field")
                    if (x is String && x = "")
                        continue
                    lo := (k = "x" || k = "y") ? -32000 : 100
                    if !(x is Integer) || x < lo || x > 32000
                        throw ValueError("window." k " must be a whole number or empty")
                    out[k] := x
                }
                return out
            }
        default:
            throw ValueError("unknown setting " key)
        }
        throw ValueError("invalid value for " key)
    }

    static InList(list, v) {
        for x in list
            if (StrCompare(x, v) = 0)
                return true
        return false
    }

    Get(key) {
        if !this.Values.Has(key)
            throw ValueError("unknown setting " key)
        return Util.Clone(this.Values[key])
    }

    ; Returns true when stored; false (value rejected) otherwise. Does not write the file.
    Set(key, value) {
        try nv := Settings.Normalize(key, value)
        catch as e {
            this._Log("warn", "setting rejected", {key: key, reason: e.Message})
            return false
        }
        this.Values[key] := nv
        return true
    }

    SetMany(map) {
        ok := true
        for k, v in map
            ok := this.Set(k, v) && ok
        return ok
    }

    Load() {
        this.Values := Settings.Defaults()
        this.Warnings := []
        this.BadFile := ""
        if !FileExist(this.Path)
            return this
        try {
            m := ConfigJson.Parse(FileRead(this.Path, "UTF-8"))
            if !(m is Map)
                throw Error("not an object")
        } catch as e {
            this._Quarantine(e.Message)
            return this
        }
        if (!m.Has("mode") && m.Has("theme")) {           ; settings from before M9: theme light|dark became mode
            try this.Values["mode"] := Settings.Normalize("mode", m["theme"] is String && m["theme"] != "" ? m["theme"] : "light")
            catch {
                this.Warnings.Push("Setting 'theme' was invalid and was reset")
                this._Log("warn", "setting repaired on load", {key: "theme", reason: "not light or dark"})
            }
        }
        for k in Settings.KEYS {
            if !m.Has(k)
                continue
            try this.Values[k] := Settings.Normalize(k, m[k])
            catch as e {
                this.Warnings.Push("Setting '" k "' was invalid and was reset")
                this._Log("warn", "setting repaired on load", {key: k, reason: e.Message})
            }
        }
        return this
    }

    _Quarantine(reason) {
        stamp := Util.Stamp()
        bad := this.Dir "\settings.bad-" stamp ".json"
        n := 1
        while FileExist(bad) {
            n += 1
            bad := this.Dir "\settings.bad-" stamp "_" n ".json"
        }
        try {
            FileMove(this.Path, bad)
            this.BadFile := bad
        } catch as e
            this._Log("error", "could not move corrupt settings file", {error: e.Message})
        this.Warnings.Push("Settings file was unreadable; defaults were used" (this.BadFile != "" ? " (old file kept)" : ""))
        this._Log("warn", "settings file corrupt; using defaults", {reason: reason})
    }

    Save() {
        try {
            Util.AtomicWrite(this.Path, ConfigJson.Stringify(this.Values))
            return true
        } catch as e {
            this._Log("error", "settings save failed", {error: e.Message})
            return false
        }
    }
}
