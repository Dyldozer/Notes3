#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\ConfigJson.ahk
#Include %A_LineFile%\..\Defaults.ahk
#Include %A_LineFile%\..\Schema.ahk
; ConfigStore.ahk - load shared -> migrate -> validate -> cache; fallbacks; locked, atomic, backed-up save.
; Pure logic: no GUI. All paths are injected so tests can use temp directories.
;
;   store := ConfigStore({SharedDir: A_ScriptDir "\config", CacheDir: Util.UserDataDir(), Logger: lg, User: "me"})
;   store.Load()      ; .Config .Source("shared"|"cache"|"defaults") .Revision .Warnings[] .SharedConfigured
;   store.Save(cfg)   ; admin path -> {Ok, Error, Revision}

class ConfigStore {
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.SharedDir := RTrim(Util.Trim(ConfigStore._Opt(o, "SharedDir", "")), "\")
        this.CacheDir := RTrim(Util.Trim(ConfigStore._Opt(o, "CacheDir", Util.UserDataDir())), "\")
        this.Logger := ConfigStore._Opt(o, "Logger", "")
        this.User := ConfigStore._Opt(o, "User", A_UserName)
        this.Machine := ConfigStore._Opt(o, "Machine", A_ComputerName)
        this.LockStaleMin := ConfigStore._Opt(o, "LockStaleMin", 30)
        this.BackupKeep := ConfigStore._Opt(o, "BackupKeep", 20)
        this.FailAt := ""            ; test hook: "afterTmp" | "afterBackup" makes Save throw at that point
        this.Config := Defaults.Config()
        this.Source := "defaults"
        this.Revision := 0
        this.Warnings := []
        this.Pending := ""
        this.SharedConfigured := this.SharedDir != ""
    }

    static _Name(path) {
        SplitPath(path, &n)
        return n
    }

    static _Opt(o, name, def) => HasProp(o, name) ? o.%name% : def

    SharedFile => this.SharedDir "\config.json"
    CacheFile => this.CacheDir "\config.cache.json"
    LockFile => this.SharedDir "\config.lock"
    BackupDir => this.SharedDir "\backups"

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }

    ; --------------------------------------------------------------- reading
    ; Read, parse, migrate and validate one config file. Returns {Ok, Cfg, Error, Migrated}.
    ; Error is a short user-facing phrase.
    ReadFile(path) {
        r := {Ok: false, Cfg: "", Error: "", Migrated: false}
        try {
            if !FileExist(path) {
                r.Error := "file not found"
                return r
            }
            text := FileRead(path, "UTF-8")
        } catch as e {
            r.Error := "could not be read"
            this._Log("warn", "config read failed", {file: ConfigStore._Name(path), error: e.Message})
            return r
        }
        try cfg := ConfigJson.Parse(text)
        catch as e {
            r.Error := "is not valid JSON"
            this._Log("warn", "config parse failed", {file: ConfigStore._Name(path), error: e.Message})
            return r
        }
        m := Schema.Migrate(cfg)
        if (m.Error != "") {
            r.Error := RegExReplace(m.Error, "^config ", "")
            return r
        }
        v := Schema.Validate(m.Cfg)
        if !v.Ok {
            r.Error := "is invalid: " Schema.Summary(v, 3)
            this._Log("warn", "config invalid", {file: ConfigStore._Name(path), errors: v.Errors.Length})
            return r
        }
        r.Ok := true, r.Cfg := m.Cfg, r.Migrated := m.Changed
        return r
    }

    _Use(cfg, source) {
        this.Config := cfg
        this.Source := source
        this.Revision := cfg["revision"]
    }

    _WriteCache(cfg) {
        Util.AtomicWrite(this.CacheFile, ConfigJson.Stringify(cfg))
    }

    ; Order: shared (if configured) -> cache -> built-in defaults.
    Load() {
        this.Warnings := []
        this.Pending := ""
        this.SharedConfigured := this.SharedDir != ""
        if this.SharedConfigured {
            if !DirExist(this.SharedDir) {
                this.Warnings.Push("Shared config folder is not reachable")
                this._Log("warn", "shared config folder not reachable")
            } else {
                r := this.ReadFile(this.SharedFile)
                if r.Ok {
                    this._Use(r.Cfg, "shared")
                    try this._WriteCache(r.Cfg)
                    catch as e {
                        this.Warnings.Push("Could not update the local cache copy")
                        this._Log("warn", "cache write failed", {error: e.Message})
                    }
                    this._Log("info", "config loaded", {source: "shared", revision: this.Revision, migrated: r.Migrated ? 1 : 0})
                    return this
                }
                this.Warnings.Push("Shared config " r.Error)
            }
        }
        c := this.ReadFile(this.CacheFile)
        if c.Ok {
            this._Use(c.Cfg, "cache")
            if this.SharedConfigured
                this.Warnings.Push("Using the local cached copy (r" this.Revision ")")
            this._Log("info", "config loaded", {source: "cache", revision: this.Revision, warnings: this.Warnings.Length})
            return this
        }
        this._Use(Defaults.Config(), "defaults")
        if this.SharedConfigured
            this.Warnings.Push("No valid local cache (" c.Error "); using built-in defaults")
        else if (c.Error != "file not found")
            this._Log("warn", "local cache unusable, using defaults", {reason: c.Error})
        this._Log("info", "config loaded", {source: "defaults", revision: 0, warnings: this.Warnings.Length})
        return this
    }

    ; Short text for the title-bar chip, e.g. "config: shared r12", "config: cache r12 (warn)".
    ChipText() {
        warn := this.Warnings.Length ? " " Chr(0x26A0) : ""
        if !this.SharedConfigured
            return "config: local" (this.Source = "cache" ? " r" this.Revision : "")
        return "config: " this.Source (this.Source = "defaults" ? "" : " r" this.Revision) warn
    }

    ; Tooltip text for the chip.
    ChipTip() {
        if !this.Warnings.Length
            return !this.SharedConfigured ? "No shared config folder is set; using this PC's local copy"
                : "Config loaded from the shared folder"
        out := ""
        for w in this.Warnings
            out .= (out = "" ? "" : "; ") w
        return out
    }

    ; True (and .Pending set) when the shared config is newer/different from what is loaded.
    CheckForUpdate() {
        if !this.SharedConfigured || !DirExist(this.SharedDir)
            return false
        r := this.ReadFile(this.SharedFile)
        if !r.Ok
            return false
        if (r.Cfg["revision"] = this.Revision && this.Source = "shared")
            return false
        this.Pending := r.Cfg
        return true
    }

    ; Swap the pending config in (the app calls this between calls, never mid-call).
    ApplyPending() {
        if !IsObject(this.Pending)
            return false
        cfg := this.Pending
        this.Pending := ""
        this._Use(cfg, "shared")
        this.Warnings := []
        try this._WriteCache(cfg)
        this._Log("info", "config update applied", {revision: this.Revision})
        return true
    }

    RestoreDefaults() => Defaults.Config()

    ; --------------------------------------------------------------- saving
    ; Admin path. Never touches the original unless every step before the final replace succeeded.
    Save(cfg) {
        res := {Ok: false, Error: "", Revision: 0}
        if !this.SharedConfigured {
            res.Error := "No shared config folder is set."
            return res
        }
        if !DirExist(this.SharedDir) {
            res.Error := "The shared config folder is not reachable."
            return res
        }
        if !(cfg is Map) {
            res.Error := "Config must be an object."
            return res
        }
        locked := false
        tmp := this.SharedFile ".tmp"
        try {
            lockErr := this._AcquireLock()
            if (lockErr != "") {
                res.Error := lockErr
                return res
            }
            locked := true
            cur := this._PeekShared()
            if (cur.Exists && cur.Rev >= 0 && cur.Rev != this.Revision) {
                res.Error := "Config was changed by " cur.By " at " cur.At " (r" cur.Rev "; you have r" this.Revision "). Reload first."
                return res
            }
            nxt := Util.Clone(cfg)
            nxt["revision"] := this.Revision + 1
            nxt["updatedAt"] := Util.IsoNow()
            nxt["updatedBy"] := this.User
            v := Schema.Validate(nxt)
            if !v.Ok {
                res.Error := "Config is not valid: " Schema.Summary(v, 3)
                return res
            }
            text := ConfigJson.Stringify(nxt)
            f := FileOpen(tmp, "w", "UTF-8-RAW")
            if !IsObject(f)
                throw OSError("Could not write " tmp)
            f.Write(text)
            f.Close()
            this._Inject("afterTmp")
            back := ConfigJson.Parse(FileRead(tmp, "UTF-8"))
            if (ConfigJson.Canon(back) != ConfigJson.Canon(nxt))
                throw Error("Verification of the temporary file failed")
            if FileExist(this.SharedFile)
                this._Backup()
            this._Inject("afterBackup")
            FileMove(tmp, this.SharedFile, 1)
            try this._WriteCache(nxt)
            catch as e
                this._Log("warn", "cache refresh after save failed", {error: e.Message})
            this.Config := nxt
            this.Source := "shared"
            this.Revision := nxt["revision"]
            res.Ok := true, res.Revision := nxt["revision"]
            this._Log("info", "config saved", {revision: res.Revision})
        } catch as e {
            res.Ok := false
            res.Error := "Save failed, the existing config was not changed (" e.Message ")"
            try FileDelete(tmp)
            this._Log("error", "config save failed", {error: e.Message})
        } finally {
            if locked
                this._ReleaseLock()
        }
        return res
    }

    _Inject(point) {
        if (this.FailAt = point)
            throw Error("injected failure " point)
    }

    ; Revision / author / time of the file on the share. Rev -1 = exists but unreadable.
    _PeekShared() {
        p := {Exists: FileExist(this.SharedFile) != "", Rev: -1, By: "unknown", At: "unknown"}
        if !p.Exists
            return p
        try {
            m := ConfigJson.Parse(FileRead(this.SharedFile, "UTF-8"))
            if (m is Map) {
                if m.Has("revision") && (m["revision"] is Integer)
                    p.Rev := m["revision"]
                if m.Has("updatedBy")
                    p.By := m["updatedBy"]
                if m.Has("updatedAt")
                    p.At := m["updatedAt"]
            }
        } catch {
            this._Log("warn", "existing shared config unreadable during save; it will be backed up and replaced")
        }
        return p
    }

    _Backup() {
        Util.EnsureDir(this.BackupDir)
        stamp := Util.Stamp()
        ; Same-second saves get _02, _03 ... One past the highest existing index, so a name freed by
        ; pruning is never reused (that would sort a new backup before older ones).
        top := 0
        Loop Files this.BackupDir "\config-" stamp "*.json", "F"
            top := Max(top, RegExMatch(A_LoopFileName, "_(\d+)\.json$", &m) ? Integer(m[1]) : 1)
        path := this.BackupDir "\config-" stamp (top = 0 ? "" : "_" Format("{:02}", top + 1)) ".json"
        FileCopy(this.SharedFile, path, 0)
        this._Prune()
    }

    ; Keep the newest BackupKeep files. Names sort chronologically ("." < "_" for same-second copies).
    _Prune() {
        names := []
        Loop Files this.BackupDir "\config-*.json", "F"
            names.Push(A_LoopFileName)
        i := 2
        while (i <= names.Length) {                  ; insertion sort, ordinal
            x := names[i], j := i - 1
            while (j >= 1 && StrCompare(names[j], x, true) > 0) {
                names[j + 1] := names[j]
                j -= 1
            }
            names[j + 1] := x
            i += 1
        }
        excess := names.Length - this.BackupKeep
        loop Max(0, excess)
            try FileDelete(this.BackupDir "\" names[A_Index])
    }

    ; --------------------------------------------------------------- lock
    ; Returns "" when acquired, else a message naming the holder.
    ; The lock file is created with CREATE_NEW, so two saves racing for a free lock can't both win.
    _AcquireLock() {
        lp := this.LockFile
        text := ConfigJson.Stringify(Map("user", this.User, "machine", this.Machine, "time", Util.IsoNow()))
        if ConfigStore._CreateNew(lp, text)
            return ""
        info := ""
        try info := ConfigJson.Parse(FileRead(lp, "UTF-8"))
        if (info is Map) && info.Has("user") {
            if this._IsOurs(info) {
                Util.AtomicWrite(lp, text)            ; re-entrant: refresh our own lock
                return ""
            }
            t := info.Has("time") ? info["time"] : ""
            if ConfigStore.MinutesSince(t) < this.LockStaleMin   ; invalid time = stale
                return "Config is locked by " info["user"] (info.Has("machine") ? " on " info["machine"] : "")
                    . " since " t ". Try again later."
            this._Log("warn", "taking over a stale config lock", {ageMin: ConfigStore.MinutesSince(t)})
        } else
            this._Log("warn", "config lock file unreadable; taking over")
        try FileDelete(lp)
        if ConfigStore._CreateNew(lp, text)
            return ""
        return "Could not take the config lock (another save started at the same moment). Try again."
    }

    _IsOurs(info) => info.Has("user") && info["user"] = this.User
        && (!info.Has("machine") || info["machine"] = this.Machine)

    _ReleaseLock() {
        try {
            info := ConfigJson.Parse(FileRead(this.LockFile, "UTF-8"))
            if (info is Map) && this._IsOurs(info)
                FileDelete(this.LockFile)
        }
    }

    ; Create path only if it does not exist (Win32 CREATE_NEW) and write text. False if it exists.
    static _CreateNew(path, text) {
        h := DllCall("CreateFileW", "str", path, "uint", 0x40000000, "uint", 0, "ptr", 0
            , "uint", 1, "uint", 0x80, "ptr", 0, "ptr")          ; GENERIC_WRITE, no sharing, CREATE_NEW
        if (h = -1)
            return false
        buf := Buffer(StrPut(text, "UTF-8") - 1)
        StrPut(text, buf, "UTF-8")
        DllCall("WriteFile", "ptr", h, "ptr", buf, "uint", buf.Size, "uint*", 0, "ptr", 0)
        DllCall("CloseHandle", "ptr", h)
        return true
    }

    ; Minutes since an ISO local time; 999999 when the text is not a valid time.
    static MinutesSince(iso) {
        if !RegExMatch(String(iso), "^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)", &m)
            return 999999
        try return DateDiff(A_Now, m[1] m[2] m[3] m[4] m[5] m[6], "Minutes")
        return 999999
    }
}
