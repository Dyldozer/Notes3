#Requires AutoHotkey v2.0
; App.ahk - composition root. Reads the ini, builds services, wires the main window.
; The entry script owns the single NFSApp instance; nothing else holds global state.

class NFSApp {
    static VERSION := "0.9.0 (M9)"
    static CONFIG_POLL_MS := 300000      ; slow poll: only sets "pending", never applies mid-call

    __New(iniPath := "") {
        this.IniPath := iniPath != "" ? iniPath : A_ScriptDir "\nfsnotes.ini"
        this.SharedPath := ""
        this.LogLevel := "info"
        this.DevMode := false
        this.SelfTest := false
        this.Logger := ""
        this.Config := ""           ; ConfigStore (shared/cache/defaults)
        this.Settings := ""         ; per-user Settings
        this.SettingsDir := ""      ; folder of settings.json (a temp folder in --selftest)
        this.Provider := ""         ; ContextProvider (MockProvider until the AppBar milestone)
        this.Ctx := ""              ; the working CallContext shown on the card (provider values + manual entries)
        this.Session := ""          ; CallSession
        this.Stats := ""            ; CallStats
        this.History := ""          ; History (saved calls)
        this.StatsRoot := ""        ; folder that holds stats\ and history\ (a temp folder in --selftest)
        this.Restoring := false     ; true while a History entry is being loaded into the session
        this.HistoryLoaded := false ; the working context came from History: provider updates don't overwrite it
        this.RestoredFrom := ""     ; id of the History entry the current call was loaded from
        this._restoredCanon := ""   ; the loaded call as first shown, to skip re-saving it unchanged
        this.Win := ""
        this._pendingLogged := 0
        this._engines := Map()      ; catId -> WorkflowEngine (see EngineFor)
        this._models := Map()       ; catId -> ItemsModel (see ModelFor)
        this._statics := Map()      ; catId -> StaticModel (see StaticModelFor)
        this.Pinger := ""           ; Pinger (async ICMP, M8); one run at a time
        this._ping := ""            ; {Cat, TargetId, Expect}: what the current run belongs to (see StartPing)
        this._engCfg := ""
    }

    LoadIni() {
        ; Admin config lives next to the program in the shared OneDrive folder; the ini can override it.
        this.SharedPath := Util.Trim(IniRead(this.IniPath, "Config", "SharedPath", ""))
        if (this.SharedPath = "")
            this.SharedPath := A_ScriptDir "\config"
        this.LogLevel := IniRead(this.IniPath, "Log", "Level", "info")
        this.DevMode := IniRead(this.IniPath, "Dev", "Enabled", "0") = "1"
    }

    Run() {
        this.LoadIni()
        for a in A_Args
            if (a = "--selftest")
                this.SelfTest := true
        this.Logger := Log({Level: this.LogLevel})
        this.Logger.Info("NFS Notes starting", {ahk: A_AhkVersion, dev: this.DevMode,
            sharedPathOverride: IniRead(this.IniPath, "Config", "SharedPath", "") != "", logLevel: this.LogLevel})
        try {
            ; Config (shared -> cache -> defaults) and per-user settings.
            dataDir := Util.UserDataDir()
            ; --selftest uses a throw-away settings folder: the real settings.json is never read or written by it
            this.SettingsDir := this.SelfTest ? A_Temp "\NFSNotesSelfTest_settings_" A_TickCount : dataDir
            this.Settings := Settings({Dir: this.SettingsDir, Logger: this.Logger}).Load()
            this.Config := ConfigStore({SharedDir: this.SharedPath, CacheDir: dataDir, Logger: this.Logger}).Load()
            this.Logger.Info("config ready", {source: this.Config.Source, revision: this.Config.Revision,
                warnings: this.Config.Warnings.Length, sharedConfigured: this.Config.SharedConfigured ? 1 : 0,
                settingsWarnings: this.Settings.Warnings.Length})
            this.BuildCallServices(dataDir)
            OnExit(ObjBindMethod(this, "OnAppExit"))
            this.Win := MainWindow(this)
            this.Win.Build()
            this.Win.Show()
            this.Provider.Start()
            if !this.SelfTest
                SetTimer(ObjBindMethod(this, "PollConfig"), NFSApp.CONFIG_POLL_MS)
        } catch as e {
            this.Logger.Error("startup failed", {error: e.Message, line: e.Line, file: e.File, what: e.What})
            throw e
        }
    }

    ; Context provider, call session, local stats and History. --selftest keeps stats and history in a temp
    ; folder so the real Documents\NotesForNFS\stats and \history are never written by a test run.
    BuildCallServices(dataDir) {
        this.StatsRoot := this.SelfTest ? A_Temp "\NFSNotesSelfTest_" A_TickCount : dataDir
        this.Stats := CallStats({Dir: this.StatsRoot, Logger: this.Logger, DebounceMs: this.DebounceMs()}).Load()
        this.History := History({Dir: this.StatsRoot, Logger: this.Logger, RetentionDays: this.RetentionDays()})
        this.History.Prune()
        this.Session := CallSession({Logger: this.Logger})
        this.Pinger := Pinger({Logger: this.Logger})
        this.Provider := MockProvider({Logger: this.Logger})
        this.Ctx := this.Provider.GetContext()
        this.RegisterSensitive(this.Ctx)
        this.Session.Context := this.Ctx.Clone()
        this.Provider.OnContextChanged(ObjBindMethod(this, "HandleContextChanged"))
        this.Provider.OnNewCall(ObjBindMethod(this, "HandleNewCall"))
        today := this.Stats.Today()
        this.Logger.Info("call services ready", {provider: this.Provider.Kind, callsToday: today.Total,
            debounceMs: this.Stats.DebounceMs})
    }

    DebounceMs() {
        try return this.Config.Config["callTracking"]["newCallDebounceMs"]
        return 3000
    }

    RetentionDays() {
        try return this.Config.Config["history"]["retentionDays"]
        return 14
    }

    ; category id -> label, for the History list.
    HistoryLabels() {
        m := Map()
        try for c in this.Config.Config["categories"]
            m[c["id"]] := c["label"]
        return m
    }

    ; --- provider events ---------------------------------------------------------
    ; Values changed: merge them into the working context (manual entries survive while the provider
    ; still has nothing for that field) and redraw the card.
    HandleContextChanged(ctx) {
        this.RegisterSensitive(ctx)
        if this.HistoryLoaded                   ; a call loaded from History keeps its own context until the next call
            return
        this.Ctx.MergeProvider(ctx)
        if IsObject(this.Win)
            this.Win.RenderCard()
    }

    ; The counted call boundary. Returns true when the event counted (and so reset the session).
    HandleNewCall(ctx) {
        this.RegisterSensitive(ctx)
        job := ctx.Value("jobNumber")
        if (this.Stats.IgnoreReason(job) != "") {
            this.Stats.NewCallEvent(job)            ; ignored: only logs the reason
            return false
        }
        ; Nothing is cleared before it is saved. If History can't be written the call is kept, the event is
        ; not counted, and the agent is told (Clear All retries the save).
        if !this.SaveCurrentCall("newCall") {
            this.Logger.Warn("new call not applied: History save failed", {error: this.History.LastError})
            if IsObject(this.Win)
                this.Win.OnSaveFailed()
            return false
        }
        if !this.Stats.NewCallEvent(job)
            return false
        this.ResetPing()                        ; a running ping belongs to the previous call
        this.Ctx := ctx.Clone()                 ; the agent's manual entries belong to the previous call
        this.HistoryLoaded := false
        this.RestoredFrom := ""
        this.Session.BeginCall(this.Ctx)
        this.ApplyConfigBetweenCalls()
        this.Logger.Info("new call", {callsToday: this.Stats.Today().Total})
        if IsObject(this.Win)
            this.Win.OnCallCounted()
        return true
    }

    ; Every context value (and the tech's first name, which notes use alone) is masked in the log,
    ; whichever provider produced it.
    RegisterSensitive(ctx) {
        for id, f in ctx.Fields {
            if (f.Value = "")
                continue
            this.Logger.RegisterSensitive(f.Value)
            if (id = "techName")
                this.Logger.RegisterSensitive(StrSplit(Util.Squeeze(f.Value), " ")[1])
        }
    }

    ; Category used by the agent: remember it in the session and credit the current call record.
    UseCategory(id) {
        isNew := this.Session.UseCategory(id)
        credited := this.Stats.UseCategory(id)
        this.Logger.Debug("category used", {category: id, newInSession: isNew ? 1 : 0, credited: credited ? 1 : 0})
        return credited
    }

    ; --- History -------------------------------------------------------------------
    ; Save the current call to History if anything was entered. True when saved or when there was nothing to
    ; save; false when the write failed (the caller must then NOT clear anything).
    SaveCurrentCall(reason) {
        if IsObject(this.Win)
            this.Win.SyncNote()
        if !this.Session.HasContent()
            return true
        snap := this.Session.Snapshot()
        ; A call loaded from History and left unchanged is already saved: don't store a duplicate.
        if (this.RestoredFrom != "" && this._restoredCanon != "" && ConfigJson.Canon(snap) == this._restoredCanon) {
            this.Logger.Debug("history save skipped: loaded call unchanged", {reason: reason, id: this.RestoredFrom})
            return true
        }
        return this.History.Save(snap, reason, this.RestoredFrom) != ""
    }

    ; Clear All: save, then reset. Returns false (call kept) when the save failed. Never counts a call.
    ClearCall() {
        if !this.SaveCurrentCall("clearAll") {
            this.Logger.Warn("clear all not applied: History save failed", {error: this.History.LastError})
            return false
        }
        this.RestoredFrom := ""
        this.ResetPing()
        this.Session.Reset()
        return true
    }

    ; Load a saved call back into the session. If the current call has content it is saved first (reason
    ; beforeRestore) after the window confirms; confirmed := true skips the question (selftest).
    ; Returns {Ok, Error, Cancelled}. Never counts a call and never credits a stats category.
    LoadFromHistory(id, confirmed := false) {
        entry := this.History.Get(id)
        if !IsObject(entry)
            return {Ok: false, Error: "That saved call could not be found.", Cancelled: false}
        if IsObject(this.Win)
            this.Win.SyncNote()
        if this.Session.HasContent() {
            if (!confirmed && IsObject(this.Win) && !this.Win.ConfirmReplace())
                return {Ok: false, Error: "", Cancelled: true}
            if !this.SaveCurrentCall("beforeRestore") {
                this.Logger.Warn("load from history not applied: saving the current call failed", {error: this.History.LastError})
                return {Ok: false, Error: "The current call could not be saved to History, so nothing was replaced.", Cancelled: false}
            }
        }
        this.ResetPing()
        this.Restoring := true
        try ok := this.Session.Restore(entry["snapshot"])
        catch
            ok := false
        this.Restoring := false
        if !ok
            return {Ok: false, Error: "That saved call is damaged and could not be loaded.", Cancelled: false}
        this.RegisterSensitive(this.Session.Context)
        this.Ctx := this.Session.Context.Clone()
        this.HistoryLoaded := true
        this.RestoredFrom := id
        this.Logger.Info("history loaded", {id: id, categories: this.Session.UsedCategories().Length})
        if IsObject(this.Win) {
            this.Win.OnHistoryLoaded()
            this.Win.SyncNote()
        }
        this._restoredCanon := ConfigJson.Canon(this.Session.Snapshot())
        return {Ok: true, Error: "", Cancelled: false}
    }

    ; Dev sample fragments are gone: every category now builds its note lines from its own page (steps -> workflow
    ; engine, items -> items model, static -> static model). Kept so an old caller gets false, never a fragment.
    AddSampleFragment(catId, duplicate := false) {
        return false
    }

    ; --- workflow (steps categories) ---------------------------------------------------------------------
    ; The category Map from the config ("" when unknown).
    CategoryFor(catId) {
        try for c in this.Config.Config["categories"]
            if (c["id"] == catId)
                return c
        return ""
    }

    IsStepsCategory(catId) {
        c := this.CategoryFor(catId)
        return (c is Map) && c.Has("kind") && c["kind"] = "steps"
    }

    ; The WorkflowEngine of a steps category ("" for any other). Cached per config object, so a config applied
    ; between calls gets fresh engines.
    EngineFor(catId) {
        this._SyncCaches()
        if this._engines.Has(catId)
            return this._engines[catId]
        c := this.CategoryFor(catId)
        if !(c is Map) || !c.Has("kind") || c["kind"] != "steps"
            return ""
        eng := WorkflowEngine(c)
        this._engines[catId] := eng
        return eng
    }

    ; Engines and models are cached per config object: a config applied between calls gets fresh ones.
    _SyncCaches() {
        cfg := ""
        try cfg := this.Config.Config
        if (!IsObject(this._engCfg) || cfg != this._engCfg) {
            this._engines := Map()
            this._models := Map()
            this._statics := Map()
            this._engCfg := cfg
        }
    }

    ; --- items categories (Equipment, Billing, ...) ----------------------------------------------------------------
    IsItemsCategory(catId) {
        c := this.CategoryFor(catId)
        return (c is Map) && c.Has("kind") && c["kind"] = "items"
    }

    ; The ItemsModel of an items category ("" for any other), with the note template's sentence case / end punctuation.
    ModelFor(catId) {
        this._SyncCaches()
        if this._models.Has(catId)
            return this._models[catId]
        c := this.CategoryFor(catId)
        if !(c is Map) || !c.Has("kind") || c["kind"] != "items"
            return ""
        m := ItemsModel(c)
        try {
            t := this.Config.Config["noteTemplate"]
            m.SentenceCase := t["sentenceCase"] ? true : false
            m.EndPunct := t["endPunctuation"]
        }
        this._models[catId] := m
        return m
    }

    ; Add an entry to an items category. The first entry marks the category used (stats + rail dot). The category's
    ; fragments and values are replaced and the note is regenerated by the session subscribers (M4 edit-lock rules apply).
    ; Returns {Ok, Error, Index, Missing}; a refused entry (missing part, duplicate) changes nothing, not even "used".
    AddEntry(catId, entry) {
        m := this.ModelFor(catId)
        if !IsObject(m)
            return {Ok: false, Error: "This category cannot hold entries.", Index: 0, Missing: []}
        r := this.Session.AddEntry(catId, entry, m)
        if r.Ok && !this.Session.IsUsed(catId)
            this.UseCategory(catId)
        this.Logger.Debug("entry", {category: catId, kind: "add", ok: r.Ok ? 1 : 0, entries: this.Session.EntriesFor(catId).Length})
        return r
    }

    UpdateEntry(catId, index, entry) {
        m := this.ModelFor(catId)
        if !IsObject(m)
            return {Ok: false, Error: "This category cannot hold entries.", Index: 0, Missing: []}
        r := this.Session.UpdateEntry(catId, index, entry, m)
        this.Logger.Debug("entry", {category: catId, kind: "update", ok: r.Ok ? 1 : 0, entries: this.Session.EntriesFor(catId).Length})
        return r
    }

    RemoveEntry(catId, index) {
        m := this.ModelFor(catId)
        if !IsObject(m)
            return false
        ok := this.Session.RemoveEntry(catId, index, m)
        this.Logger.Debug("entry", {category: catId, kind: "remove", ok: ok ? 1 : 0, entries: this.Session.EntriesFor(catId).Length})
        return ok
    }

    MoveEntry(catId, from, to) {
        m := this.ModelFor(catId)
        return IsObject(m) && this.Session.MoveEntry(catId, from, to, m)
    }

    ; Re-run the items model for a category from its current entries (after a config change).
    RefreshEntries(catId) {
        m := this.ModelFor(catId)
        if IsObject(m)
            this.Session.ApplyEntries(catId, m)
    }

    ; --- static categories (the Static page) ---------------------------------------------------------------------------
    IsStaticCategory(catId) {
        c := this.CategoryFor(catId)
        return (c is Map) && c.Has("kind") && c["kind"] = "static"
    }

    ; The StaticModel of a static category ("" for any other), with the note template's sentence case / end punctuation.
    ; Cached per config object like the other models.
    StaticModelFor(catId) {
        this._SyncCaches()
        if this._statics.Has(catId)
            return this._statics[catId]
        c := this.CategoryFor(catId)
        if !(c is Map) || !c.Has("kind") || c["kind"] != "static"
            return ""
        m := StaticModel(c)
        try {
            t := this.Config.Config["noteTemplate"]
            m.SentenceCase := t["sentenceCase"] ? true : false
            m.EndPunct := t["endPunctuation"]
        }
        this._statics[catId] := m
        return m
    }

    ; Change the static state (patch: see StaticModel.Apply). The category's fragments and values are replaced and the
    ; note is regenerated by the session subscribers (M4 edit-lock rules apply). The category becomes "used" the first
    ; time the agent adds something to the note (a confirmed ping outcome); typing an IP and calculating
    ; does not. Returns true when the state changed.
    StaticSet(catId, patch) {
        m := this.StaticModelFor(catId)
        if !IsObject(m)
            return false
        old := this.Session.StaticFor(catId)
        nxt := m.Apply(old, patch)
        if StaticModel.Same(old, nxt)
            return false
        this.Session.SetStatic(catId, nxt, m)
        if (IsObject(this._ping) && this._ping.Cat = catId && IsObject(this.Pinger) && this.Pinger.Running
            && (nxt.pingTarget != this._ping.TargetId || (this._ping.Expect != "" && StaticModel.PingAddress(nxt) != this._ping.Expect)))
            this.CancelPing("target or address changed")
        if (StaticModel.AddsToNote(nxt) && !this.Session.IsUsed(catId))
            this.UseCategory(catId)
        this.Logger.Debug("static", {category: catId, ready: nxt.ready ? 1 : 0,
            outcome: nxt.pingOutcome != "" ? 1 : 0, confirmed: nxt.pingConfirmed ? 1 : 0})
        return true
    }

    ; The seam for M8's pinger: prefill the ping outcome from a real result. Not confirmed, so it stays out of the note
    ; (and does not mark the category used) until the agent confirms it on the Static page.
    StaticPrefillPing(catId, outcomeId, target := "") {
        m := this.StaticModelFor(catId)
        if !IsObject(m) || !m.OutcomeById.Has(outcomeId)
            return false
        patch := {pingOutcome: outcomeId, pingConfirmed: false}
        if (target != "")
            patch.pingTarget := target
        return this.StaticSet(catId, patch)
    }

    ; --- ping (M8) --------------------------------------------------------------------------------------------------
    ; Start a ping run for the Static page. mode: "count" | "untilSuccess". The address is the gateway or IP the page shows
    ; (StaticModel.PingAddress): it has already been through Ipv4.Parse and the usable-range check, and Pinger.Start checks it
    ; again. A new run clears an unconfirmed (prefilled) outcome from the previous run and cancels the previous run.
    ; opts (selftest only): Addr (ping this address instead; no tie to the page's address), AllowLoopback, Timeout, Attempts,
    ; Interval, CapMs. Returns {Ok, Error, Run}.
    StartPing(catId, mode, opts := "") {
        o := IsObject(opts) ? opts : {}
        m := this.StaticModelFor(catId)
        if !IsObject(m) || !IsObject(this.Pinger)
            return {Ok: false, Error: "Pinging is not available.", Run: ""}
        s := this.Session.StaticFor(catId)
        override := o.HasOwnProp("Addr")
        addr := override ? o.Addr : StaticModel.PingAddress(s)
        if (addr = "")
            return {Ok: false, Error: s.pingTarget = "ip" ? "Enter a valid IP first." : "No valid gateway yet.", Run: ""}
        if (s.pingOutcome != "" && !s.pingConfirmed)
            this.StaticSet(catId, {pingOutcome: ""})
        cfg := Map()
        try for k, v in this.Config.Config["ping"]
            cfg[k] := v
        for pair in [["Timeout", "timeoutMs"], ["Attempts", "attempts"], ["Interval", "intervalMs"]]
            if o.HasOwnProp(pair[1])
                cfg[pair[2]] := o.%pair[1]%
        po := {Owner: catId, OnUpdate: ObjBindMethod(this, "PingUpdated"), OnDone: ObjBindMethod(this, "PingDone")}
        if o.HasOwnProp("CapMs")
            po.CapMs := o.CapMs
        if (o.HasOwnProp("AllowLoopback") && o.AllowLoopback)
            po.AllowLoopback := true
        this._ping := {Cat: catId, TargetId: s.pingTarget, Expect: override ? "" : addr}
        r := this.Pinger.Start(mode, addr, cfg, po)
        if !r.Ok
            this._ping := ""
        return r
    }

    ; Stop scheduling attempts and show "Cancelled" now. Returns true when a run was cancelled.
    CancelPing(why := "") {
        if !IsObject(this.Pinger) || !this.Pinger.Cancel()
            return false
        this.Logger.Debug("ping cancelled by the app", {reason: why})
        return true
    }

    ; New call, Clear All, History load: cancel and forget the run and its console.
    ResetPing() {
        if IsObject(this.Pinger)
            this.Pinger.Reset()
        this._ping := ""
    }

    PingUpdated(run) {
        if IsObject(this.Win)
            this.Win.OnPingUpdate()
    }

    ; A run finished by itself (cancelled runs and errors do not prefill anything): prefill the outcome through the M7 seam,
    ; unconfirmed. If the page moved on in the meantime (other target / address) the result is not used.
    PingDone(res) {
        pi := this._ping
        if (IsObject(pi) && !res.Cancelled && res.Status != "error") {
            s := this.Session.StaticFor(pi.Cat)
            if (s.pingTarget = pi.TargetId && (pi.Expect = "" || StaticModel.PingAddress(s) = pi.Expect))
                this.StaticPrefillPing(pi.Cat, res.AnyReply ? "reply" : "noReply", pi.TargetId)
        }
        if IsObject(this.Win)
            this.Win.OnPingUpdate()
    }

    ; Window closed / app exit: cancel and let an in-flight request finish before the process ends.
    OnAppExit(reason := "", code := 0) {
        if IsObject(this.Pinger)
            this.Pinger.Shutdown()
        return 0
    }

    ; Re-run the static model for a category from its state (after a config change).
    RefreshStatic(catId) {
        m := this.StaticModelFor(catId)
        if IsObject(m)
            this.Session.ApplyStatic(catId, m)
    }

    ; The agent chose an option. The first answer marks the category used (stats + rail dot); the category's
    ; fragments and values are then replaced with the engine output and the note is regenerated by the session
    ; subscribers (the M4 edit-lock rules still apply). Returns true when the answer changed.
    SetOption(catId, stepId, optionId) {
        eng := this.EngineFor(catId)
        if !IsObject(eng)
            return false
        if (optionId != "" && !this.Session.IsUsed(catId))
            this.UseCategory(catId)
        changed := this.Session.Choose(catId, stepId, optionId, eng)
        this.Logger.Debug("answer", {category: catId, step: stepId, kind: "option", changed: changed ? 1 : 0})
        return changed
    }

    SetField(catId, stepId, fieldId, text) {
        eng := this.EngineFor(catId)
        if !IsObject(eng)
            return false
        if (Util.Trim(text) != "" && !this.Session.IsUsed(catId))
            this.UseCategory(catId)
        changed := this.Session.Type(catId, stepId, fieldId, text, eng)
        this.Logger.Debug("answer", {category: catId, step: stepId, kind: "field", changed: changed ? 1 : 0})
        return changed
    }

    ; Re-run the engine for a category from its current answers (after a History load or a config change).
    RefreshAnswers(catId) {
        eng := this.EngineFor(catId)
        if IsObject(eng)
            this.Session.ApplyEngine(catId, eng)
    }

    ; "Reset this category": answers, fragments and values go; the category stays used (stats keep it).
    ResetCategory(catId) {
        if (IsObject(this._ping) && this._ping.Cat = catId)
            this.ResetPing()
        this.Session.ResetCategory(catId)
        this.Logger.Info("category reset", {category: catId})
    }

    ; Used steps categories that have answers and fail validation, in config order:
    ; [{Id, Label, Missing: [{stepId, fieldId, label}], Labels: [text]}]. Nothing else blocks anything; the
    ; caller only asks the agent before copying.
    MissingRequired() {
        out := []
        try for c in this.Config.Config["categories"] {
            id := c["id"]
            if (c["kind"] != "steps" || !this.Session.IsUsed(id) || !this.Session.HasAnswers(id))
                continue
            eng := this.EngineFor(id)
            if !IsObject(eng)
                continue
            r := eng.Validate(this.Session.AnswersFor(id))
            if r.Ok
                continue
            labels := []
            for m in r.Missing
                labels.Push(m.label)
            out.Push({Id: id, Label: c["label"], Missing: r.Missing, Labels: labels})
        }
        return out
    }

    ; --- config between calls ----------------------------------------------------
    ; Called on each counted call: pick up a newer shared config (cheap: the share is a local OneDrive
    ; copy) and refresh whatever depends on config. Never called mid-call.
    ApplyConfigBetweenCalls() {
        old := this.Config.Revision
        applied := false
        try {
            this.Config.CheckForUpdate()
            applied := this.Config.ApplyPending()
        } catch as e
            this.Logger.Warn("config update check failed", {error: e.Message})
        if !applied
            return false
        this.Stats.DebounceMs := this.DebounceMs()
        this.History.RetentionDays := this.RetentionDays()
        this.Logger.Info("config revision changed", {from: old, to: this.Config.Revision})
        if IsObject(this.Win)
            this.Win.OnConfigChanged()
        return true
    }

    ; Slow timer: only notices that a newer config exists (sets Pending); applying waits for a call boundary.
    PollConfig() {
        try {
            if this.Config.CheckForUpdate() && IsObject(this.Config.Pending) {
                rev := this.Config.Pending["revision"]
                if (rev != this._pendingLogged) {
                    this._pendingLogged := rev
                    this.Logger.Info("config update pending", {revision: rev})
                }
            }
        } catch as e
            this.Logger.Warn("config poll failed", {error: e.Message})
    }
}
