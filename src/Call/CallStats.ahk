#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\..\Config\ConfigJson.ahk
; CallStats.ahk - local per-day call counts (PLAN 2 "What counts a call", "Uncategorized calls").
; Pure logic: no GUI. Paths and the clock are injected.
;
;   st := CallStats({Dir: Util.UserDataDir(), Logger: lg, Now: () => Util.NowStamp(), DebounceMs: 3000})
;   st.Load()                     ; today's file, prune files older than 90 days
;   st.NewCallEvent(jobNumber)    ; provider new-call event -> true when it opened a record (counted)
;   st.UseCategory("notDone")     ; credit the current record -> true when newly credited
;   st.Today()                    ; {Date, Total, Uncategorized, ById}
;   st.Summary(config["categories"])  ; {Items:[{id,label,count}...], Total}
;
; Attribution rule (decided by Opus):
;   - A new-call event that passes the debounce opens a call record: total +1.
;   - Categories used afterwards are credited to the CURRENT record, each at most once per record.
;     Per-category count = records that used it. Uncategorized = records with no categories.
;   - Clear All does not open a record. Category use before the first counted event has no record and
;     is not counted.
;   - Debounce: ignore an event within DebounceMs of the last COUNTED event, or one whose non-empty job
;     number equals the current record's job number (kept in memory only; empty job = time rule only).
;   - A record belongs to the local date of its event; a category used after midnight is credited to the
;     record's own day (its file is rewritten). Today() always counts the current date.
;   - After an app restart there is NO current record until the next counted event (the open record is
;     not persisted; the job number is never written to disk).
;
; File <Dir>\stats\YYYY-MM-DD.json = {agent, date, calls:[{at, categories:[ids]}]}: no names, IDs,
; addresses or job/work-order numbers. Written atomically on every change. Corrupt -> renamed
; YYYY-MM-DD.bad-<stamp>.json, start empty, warning logged.

class CallStats {
    static UNCATEGORIZED := "uncategorized"

    ; opts: Dir (user data dir; files go in Dir\stats), Logger, Now, DebounceMs, Agent, RetentionDays
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        g := (n, d) => o.HasOwnProp(n) ? o.%n% : d
        this.StatsDir := RTrim(g("Dir", Util.UserDataDir()), "\") "\stats"
        this.Logger := g("Logger", "")
        this.Now := g("Now", () => Util.NowStamp())
        this.DebounceMs := g("DebounceMs", 3000)
        this.Agent := g("Agent", A_UserName)
        this.RetentionDays := g("RetentionDays", 90)
        this.LastError := ""
        this._days := Map()          ; "YYYY-MM-DD" -> Array of records {at, categories[]}
        this._cur := ""              ; {date, rec} of the current record
        this._curJob := ""           ; memory only
        this._lastMs := ""           ; ms stamp of the last counted event
        this._subs := []
    }

    FileFor(date) => this.StatsDir "\" date ".json"

    ; Load today's file (surfaces a corrupt file early) and prune old files.
    Load() {
        this._Day(Util.DateOfStamp(this.Now.Call()))
        this.Prune()
        return this
    }

    ; --- events ------------------------------------------------------------------
    ; True when the event opened a new record (it counts); false when ignored by the debounce.
    ; "debounce" / "same job" when an event now would be ignored, else "". Changes nothing, so the caller can
    ; check before doing work (saving History) that must only happen for a counted event.
    IgnoreReason(job := "") {
        ms := Util.StampMs(this.Now.Call())
        job := Util.Trim(job)
        if (this._lastMs != "") {
            d := ms - this._lastMs
            if (d >= 0 && d < this.DebounceMs)         ; a clock that moved backwards is not "within"
                return "debounce"
        }
        if (job != "" && this._cur != "" && this._curJob != "" && job = this._curJob)
            return "same job"
        return ""
    }

    NewCallEvent(job := "") {
        now := this.Now.Call()
        ms := Util.StampMs(now)
        job := Util.Trim(job)
        why := this.IgnoreReason(job)
        if (why != "") {
            this._Log("debug", "new-call ignored", {why: why})
            return false
        }
        date := Util.DateOfStamp(now)
        calls := this._Day(date)
        rec := {at: Util.IsoOfStamp(now), categories: []}
        calls.Push(rec)
        this._cur := {date: date, rec: rec}
        this._curJob := job
        this._lastMs := ms
        this._Save(date)
        this._Log("debug", "call counted", {total: calls.Length, date: date})
        this._Notify()
        return true
    }

    ; Credit a category to the current record. False when there is no record or it was already credited.
    UseCategory(id) {
        id := Util.Trim(id)
        if (id = "" || this._cur = "")
            return false
        for x in this._cur.rec.categories
            if (x = id)
                return false
        this._cur.rec.categories.Push(id)
        this._Save(this._cur.date)
        this._Notify()
        return true
    }

    HasCurrentRecord => this._cur != ""

    ; --- reading -----------------------------------------------------------------
    ; Counts for the current local date.
    Today() {
        date := Util.DateOfStamp(this.Now.Call())
        return this.Count(date)
    }

    Count(date) {
        calls := this._Day(date)
        r := {Date: date, Total: calls.Length, Uncategorized: 0, ById: Map()}
        for rec in calls {
            if (rec.categories.Length = 0)
                r.Uncategorized += 1
            for id in rec.categories
                r.ById[id] := (r.ById.Has(id) ? r.ById[id] : 0) + 1
        }
        return r
    }

    ; Ordered items: enabled categories in config order, then categories found in records that the config
    ; does not know (label = id), then Uncategorized. Disabled categories are omitted from the list (their
    ; records still count in Total).
    Summary(categories) {
        t := this.Today()
        items := []
        known := Map()
        if (categories is Array)
            for c in categories {
                if !(c is Map) || !c.Has("id")
                    continue
                known[StrLower(c["id"])] := true
                if (c.Has("enabled") && !c["enabled"])
                    continue
                items.Push({id: c["id"], label: c.Has("label") ? c["label"] : c["id"],
                    count: t.ById.Has(c["id"]) ? t.ById[c["id"]] : 0})
            }
        extra := []
        for id, n in t.ById
            if !known.Has(StrLower(id))
                extra.Push(id)
        extra := CallStats._SortedIds(extra)
        for id in extra
            items.Push({id: id, label: id, count: t.ById[id]})
        items.Push({id: CallStats.UNCATEGORIZED, label: "Uncategorized", count: t.Uncategorized})
        return {Items: items, Total: t.Total}
    }

    static _SortedIds(arr) {
        s := ""
        for x in arr
            s .= x "`n"
        s := Sort(RTrim(s, "`n"))
        return s = "" ? [] : StrSplit(s, "`n")
    }

    OnChanged(fn) {
        this._subs.Push(fn)
        return this
    }

    ; --- persistence -------------------------------------------------------------
    _Day(date) {
        if this._days.Has(date)
            return this._days[date]
        calls := this._ReadDay(date)
        this._days[date] := calls
        return calls
    }

    ; Returns an Array of records; a corrupt file is quarantined and an empty list returned.
    _ReadDay(date) {
        path := this.FileFor(date)
        if !FileExist(path)
            return []
        try {
            data := ConfigJson.Parse(FileRead(path, "UTF-8"))
            calls := CallStats._ParseCalls(data)
            if IsObject(calls)
                return calls
        }
        this._Quarantine(path, date)
        return []
    }

    static _ParseCalls(data) {
        if !(data is Map) || !data.Has("calls") || !(data["calls"] is Array)
            return ""
        out := []
        for c in data["calls"] {
            if !(c is Map) || !c.Has("at") || IsObject(c["at"]) || !c.Has("categories") || !(c["categories"] is Array)
                return ""
            cats := []
            for id in c["categories"] {
                if IsObject(id) || id = ""
                    return ""
                cats.Push(String(id))
            }
            out.Push({at: String(c["at"]), categories: cats})
        }
        return out
    }

    _Quarantine(path, date) {
        stamp := FormatTime(SubStr(this.Now.Call(), 1, 14), "yyyyMMdd-HHmmss")
        bad := this.StatsDir "\" date ".bad-" stamp ".json"
        try {
            FileMove(path, bad, 1)
            this._Log("warn", "stats file was corrupt; renamed and starting empty", {date: date})
        } catch as e {
            this._Log("warn", "stats file was corrupt and could not be renamed", {date: date, error: e.Message})
        }
    }

    _Save(date) {
        try {
            calls := []
            for rec in this._days[date] {
                cats := []
                for id in rec.categories
                    cats.Push(id)
                calls.Push(Map("at", rec.at, "categories", cats))
            }
            doc := Map("agent", this.Agent, "date", date, "calls", calls)
            Util.AtomicWrite(this.FileFor(date), ConfigJson.Stringify(doc))
            this.LastError := ""
            return true
        } catch as e {
            this.LastError := e.Message
            this._Log("warn", "stats save failed", {date: date, error: e.Message})
            return false
        }
    }

    ; Delete stats files (and quarantined copies) older than RetentionDays. Returns the number deleted.
    Prune() {
        n := 0
        try {
            cutoff := Util.DateOfStamp(DateAdd(SubStr(this.Now.Call(), 1, 14), -this.RetentionDays, "Days"))
            loop files this.StatsDir "\*.json" {
                if !RegExMatch(A_LoopFileName, "^(\d{4}-\d\d-\d\d)", &m)
                    continue
                if (StrCompare(m[1], cutoff) < 0) {            ; dates compare as text (< needs numbers)
                    FileDelete(A_LoopFileFullPath)
                    n += 1
                }
            }
        } catch as e
            this._Log("warn", "stats prune failed", {error: e.Message})
        if (n > 0)
            this._Log("info", "old stats files removed", {count: n})
        return n
    }

    ; --- misc --------------------------------------------------------------------
    _Notify() {
        copy := []
        for fn in this._subs
            copy.Push(fn)
        for fn in copy {
            try fn(this)
            catch as e
                this._Log("warn", "stats subscriber failed", {error: e.Message})
        }
    }

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }
}
