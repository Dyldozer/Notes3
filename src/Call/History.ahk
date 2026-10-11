#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\..\Config\ConfigJson.ahk
#Include %A_LineFile%\..\..\Notes\Composer.ahk
; History.ahk - saved calls (PLAN 2 "Clearing notes -> History", PLAN 3.10). Pure logic: no GUI.
; Paths and the clock are injected.
;
;   h := History({Dir: Util.UserDataDir(), Logger: lg, Now: () => Util.NowStamp(), RetentionDays: 14})
;   id := h.Save(session.Snapshot(), "newCall")         ; "" when refused (empty snapshot) or the write failed
;   h.Days()                                            ; ["2026-10-10", ...] newest first, within retention
;   h.List("2026-10-10", "jordan", labels)              ; newest first, with display fields
;   h.Get(id)                                           ; the entry Map {id, savedAt, reason, restoredFrom, snapshot}
;   h.Prune()                                           ; delete day files older than RetentionDays
;
; File <Dir>\history\YYYY-MM-DD.json = {agent, date, entries: [{id, savedAt, reason, restoredFrom, snapshot}]}.
; The snapshot is whatever CallSession.Snapshot() produced; nothing else about the call is stored.
; The log gets counts, ids and reasons only: never a name, job, address or note text.
; A corrupt day file is renamed YYYY-MM-DD.bad-<stamp>.json and treated as empty.

class History {
    static REASONS := ["newCall", "clearAll", "beforeRestore"]
    static PREVIEW_LEN := 80

    ; opts: Dir (user data dir; files go in Dir\history), Logger, Now, RetentionDays, Agent
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        g := (n, d) => o.HasOwnProp(n) ? o.%n% : d
        this.HistDir := RTrim(g("Dir", Util.UserDataDir()), "\") "\history"
        this.Logger := g("Logger", "")
        this.Now := g("Now", () => Util.NowStamp())
        this.RetentionDays := g("RetentionDays", 14)
        this.Agent := g("Agent", A_UserName)
        this.LastError := ""
        this._counter := 0
        this._subs := []
    }

    FileFor(date) => this.HistDir "\" date ".json"

    OnChanged(fn) {
        this._subs.Push(fn)
        return this
    }

    ; True when a snapshot holds nothing the agent entered (context alone is not content).
    static IsEmpty(snap) {
        if !(snap is Map)
            return true
        if snap.Has("categoriesUsed") && (snap["categoriesUsed"] is Array) && snap["categoriesUsed"].Length > 0
            return false
        if snap.Has("categories") && (snap["categories"] is Map)
            for id, c in snap["categories"] {
                if !(c is Map)
                    continue
                if c.Has("fragments") && (c["fragments"] is Array) && c["fragments"].Length > 0
                    return false
                if c.Has("values") && (c["values"] is Map) && c["values"].Count > 0
                    return false
                if c.Has("answers") && (c["answers"] is Map) && c["answers"].Count > 0
                    return false
                if c.Has("entries") && (c["entries"] is Array) && c["entries"].Length > 0
                    return false
                if c.Has("static") && (c["static"] is Map) && c["static"].Count > 0
                    return false
            }
        return !snap.Has("noteText") || Util.Trim(snap["noteText"]) = ""
    }

    ; --- saving --------------------------------------------------------------------
    Save(snapshot, reason, restoredFrom := "") {
        this.LastError := ""
        if History.IsEmpty(snapshot) {
            this._Log("debug", "history save skipped", {why: "empty"})
            return ""
        }
        if !History._InList(History.REASONS, reason) {
            this.LastError := "unknown history reason"
            this._Log("warn", "history save refused", {why: "reason"})
            return ""
        }
        try {
            now := this.Now.Call()
            if (StrLen(now) = 14)
                now .= "000"
            date := Util.DateOfStamp(now)
            entries := this._ReadDay(date)
            id := this._NewId(now, entries)
            entries.Push(Map("id", id, "savedAt", Util.IsoOfStamp(now), "reason", reason,
                "restoredFrom", restoredFrom, "snapshot", Util.Clone(snapshot)))
            this._WriteDay(date, entries)
        } catch as e {
            this.LastError := e.Message
            this._Log("warn", "history save failed", {error: e.Message})
            return ""
        }
        this._Log("info", "history saved", {id: id, reason: reason, entriesToday: entries.Length})
        this._Notify()
        return id
    }

    _NewId(now, entries) {
        loop {
            this._counter += 1
            id := SubStr(now, 1, 17) "-" Format("{:03}", this._counter)
            dup := false
            for e in entries
                if (e["id"] = id)
                    dup := true
            if !dup
                return id
        }
    }

    _WriteDay(date, entries) {
        doc := Map("agent", this.Agent, "date", date, "entries", entries)
        Util.AtomicWrite(this.FileFor(date), ConfigJson.Stringify(doc))
    }

    ; --- reading -------------------------------------------------------------------
    ; Dates (newest first) that have a history file and are still within retention.
    Days() {
        cutoff := this._Cutoff()
        s := ""
        loop files this.HistDir "\*.json" {
            if RegExMatch(A_LoopFileName, "^(\d{4}-\d\d-\d\d)\.json$", &m) && StrCompare(m[1], cutoff) >= 0
                s .= m[1] "`n"
        }
        s := Sort(RTrim(s, "`n"), "R")
        return s = "" ? [] : StrSplit(s, "`n")
    }

    ; labels: Map id -> label (or any object with Has/[]), used for category names. query: every word must
    ; match the tech name, job number, work order or a category label (case-insensitive).
    List(date, query := "", labels := "") {
        out := []
        entries := this._ReadDay(date)
        words := []
        for w in StrSplit(Util.Squeeze(query), " ")
            if (w != "")
                words.Push(w)
        i := entries.Length
        while (i >= 1) {
            item := History._Item(entries[i], labels)
            i -= 1
            hay := item.TechName "`n" item.Job "`n" item.WorkOrder "`n" item.Categories
            ok := true
            for w in words
                if !InStr(hay, w)               ; InStr is case-insensitive by default
                    ok := false
            if ok
                out.Push(item)
        }
        return out
    }

    ; The full entry (a copy), or "" when it is not found.
    Get(id) {
        if !RegExMatch(String(id), "^(\d{4})(\d\d)(\d\d)\d{9}-\d+$", &m)
            return ""
        for e in this._ReadDay(m[1] "-" m[2] "-" m[3])
            if (e["id"] = id)
                return Util.Clone(e)
        return ""
    }

    static _Item(e, labels) {
        snap := e["snapshot"]
        field := (id) => (snap["context"] is Map && snap["context"].Has(id) && snap["context"][id] is Map
            && snap["context"][id].Has("value")) ? String(snap["context"][id]["value"]) : ""
        ids := []
        if snap.Has("categoriesUsed") && (snap["categoriesUsed"] is Array)
            for x in snap["categoriesUsed"]
                ids.Push(String(x))
        if snap.Has("categories") && (snap["categories"] is Map)
            for cid, c in snap["categories"]
                if !History._InList(ids, cid)
                    ids.Push(cid)
        labs := ""
        for cid in ids {
            lab := (labels is Map && labels.Has(cid)) ? labels[cid] : cid
            labs .= (labs = "" ? "" : ", ") lab
        }
        note := snap.Has("noteText") ? String(snap["noteText"]) : ""
        flat := Util.Squeeze(note)
        prev := StrLen(flat) > History.PREVIEW_LEN ? SubStr(flat, 1, History.PREVIEW_LEN) Chr(0x2026) : flat
        return {Id: e["id"], SavedAt: e["savedAt"], Time: SubStr(e["savedAt"], 12, 5), Reason: e["reason"],
            Tech: Composer.FirstName(field("techName")), TechName: field("techName"), Job: field("jobNumber"),
            WorkOrder: field("workOrder"), Categories: labs, CategoryIds: ids, Preview: prev, Note: note}
    }

    ; Entries of one day. A missing file is empty; a corrupt one is quarantined and treated as empty.
    _ReadDay(date) {
        path := this.FileFor(date)
        if !FileExist(path)
            return []
        try {
            data := ConfigJson.Parse(FileRead(path, "UTF-8"))
            ents := History._ParseEntries(data)
            if IsObject(ents)
                return ents
        }
        this._Quarantine(path, date)
        return []
    }

    static _ParseEntries(data) {
        if !(data is Map) || !data.Has("entries") || !(data["entries"] is Array)
            return ""
        for e in data["entries"] {
            if !(e is Map) || !e.Has("id") || !e.Has("savedAt") || !e.Has("reason") || !e.Has("snapshot")
                || !(e["snapshot"] is Map) || IsObject(e["id"]) || IsObject(e["savedAt"]) || StrLen(String(e["savedAt"])) < 16
                return ""
            e["id"] := String(e["id"]), e["savedAt"] := String(e["savedAt"]), e["reason"] := String(e["reason"])
            if !e.Has("restoredFrom")
                e["restoredFrom"] := ""
        }
        return data["entries"]
    }

    _Quarantine(path, date) {
        stamp := FormatTime(SubStr(this.Now.Call(), 1, 14), "yyyyMMdd-HHmmss")
        bad := this.HistDir "\" date ".bad-" stamp ".json"
        try {
            FileMove(path, bad, 1)
            this._Log("warn", "history file was corrupt; renamed and starting empty", {date: date})
        } catch as e {
            this._Log("warn", "history file was corrupt and could not be renamed", {date: date, error: e.Message})
        }
    }

    ; --- retention -----------------------------------------------------------------
    ; The oldest date kept (a file dated RetentionDays ago is kept, the day before is removed).
    _Cutoff() => Util.DateOfStamp(DateAdd(SubStr(this.Now.Call(), 1, 14), -this.RetentionDays, "Days"))

    ; Delete history files (and quarantined copies) older than RetentionDays. Returns the number deleted.
    Prune() {
        n := 0
        try {
            cutoff := this._Cutoff()
            loop files this.HistDir "\*.json" {
                if !RegExMatch(A_LoopFileName, "^(\d{4}-\d\d-\d\d)", &m)
                    continue
                if (StrCompare(m[1], cutoff) < 0) {            ; dates compare as text (< needs numbers)
                    FileDelete(A_LoopFileFullPath)
                    n += 1
                }
            }
        } catch as e
            this._Log("warn", "history prune failed", {error: e.Message})
        if (n > 0)
            this._Log("info", "old history files removed", {count: n})
        return n
    }

    ; --- misc ----------------------------------------------------------------------
    static _InList(list, v) {
        for x in list
            if (x = v)
                return true
        return false
    }

    _Notify() {
        copy := []
        for fn in this._subs
            copy.Push(fn)
        for fn in copy {
            try fn(this)
            catch as e
                this._Log("warn", "history subscriber failed", {error: e.Message})
        }
    }

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }
}
