#Requires AutoHotkey v2.0
; MainWindow.ahk - the shell (PLAN section 6).
;
; Layout (AxGui):
;   title bar   : app name, MOCK DATA badge (provider Kind mock), config chip, [Dev], theme toggle, pin
;   Header band : Technician card (rendered from the provider's CallContext, one status tag per field)
;                 + "Calls today" tile (CallStats total, hover popover from CallStats.Summary)
;   rail + page : Not Done / Equipment / Billing / Static / Close Job / Settings (dot = category used);
;                 every "steps" category page (Not Done, Close Job) is a StepsView
;   Footer band : the ONE persistent notes panel (textarea + History / Clear All / Copy Notes)
;
; g.Footer(html) pins raw HTML under the page area (outside the page container), so the notes panel
; survives page switches with no per-page copy.

class MainWindow {
    ; Put markup with the library's <ax-*> tags into a mount point. The tags are expanded as TEXT first
    ; (AxTags.ExpandHtml) and written in one go: replacing elements one by one in the live page
    ; (AxTags.ExpandIn -> el.outerHTML) intermittently threw 0x80020101 when a page was rebuilt from an
    ; event such as a History load. The live walk is kept only as the fallback ExpandHtml asks for ("").
    static SetTagHtml(el, html) {
        x := AxTags.ExpandHtml(html, true)
        if (x != "") {
            el.innerHTML := x
            return
        }
        el.innerHTML := html
        AxTags.ExpandIn(el)
    }

    ; page id, title, icon, category id ("" = not a call category)
    static PAGES := [
        ["notdone",  "Not Done",  "E711", "notDone"],
        ["equipment", "Equipment", "E772", "equipment"],
        ["billing",  "Billing",   "E8C7", "billing"],
        ["static",   "Static",    "E774", "static"],
        ["closejob", "Close Job", "E73E", "closeJob"],
        ["settings", "Settings",  "E713", ""]
    ]
    ; card layout: context field id, short label
    static FIELDS := [["techName", "Name"], ["techId", "ID"], ["jobNumber", "Job"], ["workOrder", "WO"], ["address", "Addr"]]
    static TAGS := Map("live", "Live", "mock", "Mock", "manual", "Manual", "unavailable", "Unavailable",
        "stale", "Stale", "empty", "Empty", "history", "From history")

    __New(app) {
        this.App := app
        this.G := ""
        this.LogoShown := false
        this.Look := ""                    ; the resolved look in force (Theme.Resolve result)
        this.SV := ""                      ; SettingsView (the Settings page)
        this.PrevPage := ""
        this.AutoAsk := ""                 ; selftest: fn(kind, text) -> answer, in place of the appearance questions
        this.LastAsked := {Kind: "", Text: ""}
        this.RunHook := ""                 ; selftest: fn(command) in place of Run()
        this.LastRun := ""
        this.FontNames := ""               ; selftest: registered font names in place of the registry
        this.SystemModeHook := ""          ; selftest: "light" | "dark" in place of the Windows setting
        this._warned := Map()
        this.Ready := false
        this.Req := {x: "", y: "", w: 820, h: 680}
        this.Off := {x: 0, y: 0, w: 0, h: 0}
        this.Persist := true               ; --selftest is safe too: its Settings live in a temp folder (App.SettingsDir)
        this.Dev := ""                     ; DevPanel (dev mode only)
        this.TileDate := ""
        this.Hist := HistoryPanel(this, app)
        this.ClipHooks := ""               ; injected Set/Get for NoteClipboard (selftest only)
        this._evFn := ""
        this._noteChkFn := ObjBindMethod(this, "NoteTouched")
        this.LastWarnings := []            ; composer warnings from the last compose (shown in dev mode only)
        this.Steps := Map()                ; category id -> StepsView (steps categories only)
        this.Items := Map()                ; category id -> ItemsView (items categories only)
        this.Statics := Map()              ; category id -> StaticView (static categories only)
        this.LastDraftText := ""
        this.AutoConfirm := ""             ; selftest: fn(text) -> bool in place of the "missing required" question
        this.LastMissingText := ""
        this._stepsFn := ObjBindMethod(this, "RenderStepsNow")
    }

    ; Structural CSS only (layout, sizes in rem so the Text size setting scales them). Every colour comes from
    ; Theme.Css, generated from the resolved accent and mode.
    Css() => "
    (
    .nfs-top { display: -ms-flexbox; display: flex; padding: 10px 14px 4px 14px; box-sizing: border-box; width: 100%; }
    .nfs-ctx { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; overflow: hidden; padding: 10px 14px; margin-right: 12px;
        border-radius: 6px; }
    .nfs-ctx-t, .nfs-tile-l { font-size: .786rem; text-transform: uppercase; letter-spacing: .6px; margin-bottom: 4px; }
    .nfs-kv { display: -ms-flexbox; display: flex; -ms-flex-wrap: wrap; flex-wrap: wrap; }
    .nfs-kv div { margin-right: 22px; margin-bottom: 2px; white-space: nowrap; }
    .nfs-kv b { font-weight: normal; margin-right: 6px; }
    .nfs-dot { display: inline-block; width: 8px; height: 8px; border-radius: 4px; margin-left: 8px; vertical-align: middle; }
    .nfs-tag { display: inline-block; font-size: .643rem; font-weight: 700; letter-spacing: .4px; text-transform: uppercase;
        padding: 0 4px; margin-left: 5px; border-radius: 3px; vertical-align: middle; line-height: 14px; }
    .nfs-s-stale { font-style: italic; }
    .nfs-edit { cursor: pointer; }
    .nfs-tile { -ms-flex: none; flex: none; width: 150px; padding: 10px 14px; text-align: center; border-radius: 6px; cursor: default; }
    .nfs-tile-n { font-size: 2.143rem; font-weight: 600; line-height: 36px; }
    .nfs-tile-s { font-size: .786rem; }
    .nfs-pop { min-width: 190px; }
    .nfs-pop .hd { font-weight: 600; margin-bottom: 6px; }
    .nfs-pop .r { display: -ms-flexbox; display: flex; margin-bottom: 3px; }
    .nfs-pop .r .k { -ms-flex: 1; flex: 1; margin-right: 16px; }
    .nfs-pop .tot { margin-top: 6px; padding-top: 6px; font-weight: 600; }
    .nfs-pop .meta { font-size: .786rem; margin-top: 6px; }
    .nav-item.nfs-used { position: relative; }
    .nav-item.nfs-used:after { content: ''; position: absolute; right: 14px; top: 50%; margin-top: -4px; width: 8px; height: 8px;
        border-radius: 4px; }
    .nfs-notes { padding: 8px 14px 12px 14px; }
    .nfs-notes-hd { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; margin-bottom: 6px; }
    .nfs-notes-hd .l { -ms-flex: 1; flex: 1; font-weight: 600; }
    .nfs-notes-hd .btn { margin-left: 8px; }
    #axFooter .nfs-notes .textbox textarea { width: 100%; height: 92px; min-height: 92px; box-sizing: border-box; resize: none; }
    .nfs-regen { display: none; margin-top: 6px; padding: 3px 8px; font-size: .857rem; border-radius: 4px; }
    .nfs-regen .btn { display: inline-block; margin: 0 4px; padding: 0 8px; }
    .nfs-warn { display: none; margin-top: 4px; font-size: .786rem; }
    .axtb-item.nfs-mock { border-radius: 3px; font-size: 10px; font-weight: 700; letter-spacing: .5px; padding: 0 7px; margin: 0 4px; }
    )" . StepsView.Css() . ItemsView.Css() . StaticView.Css() . SettingsView.Css() . this.Hist.Css() . (this.App.DevMode ? DevPanel(this, this.App).Css() : "")

    Build() {
        app := this.App
        st := app.Settings, cs := app.Config
        ; The look is resolved BEFORE the window exists, so the first paint already wears it (no light-then-dark flash).
        this.Look := this.ResolveLook(st)
        look := this.Look
        app.Logger.Info("look", {preset: look.PresetId, sheet: look.Sheet, look: look.Look, mode: look.Mode, modeSetting: look.ModeSetting,
            accent: look.Accent, customAccent: look.CustomAccent ? 1 : 0, font: look.FontFamily, size: look.FontSize, warnings: look.Warnings.Length})
        r := this.SavedRect()
        opts := {Title: "NFS Notes - Tech Assist", AppName: "NFSNotes",
            Width: r.w, Height: r.h, MinWidth: 640, MinHeight: 560,
            Theme: look.Mode, Stylesheet: look.Sheet, Accent: look.Accent, Css: this.Css()}
        if (r.x != "")
            opts.X := r.x, opts.Y := r.y
        this.Req := r                     ; what we asked for; Show() measures how the real window differs
        g := AxGui(opts)
        this.G := g
        g.SetExtraCss("nfstheme", look.ExtraCss)         ; queued into the page's <head> (nothing is painted yet)

        items := []
        logo := Theme.LogoPath(A_ScriptDir)                     ; only when an approved file exists in assets\
        if (logo != "")
            items.Push({Id: "logo", Kind: "html", Html: '<img src="' Theme.FileUrl(logo) '" alt="" style="height:20px;vertical-align:middle">'})
        this.LogoShown := (logo != "")
        items.Push(
            {Id: "appname", Kind: "text", Text: "NFS Notes"},
            {Id: "mock", Kind: "html", Class: "nfs-mock", Html: "MOCK DATA", Tip: "Showing mock data, not live AppBar values",
                Hidden: app.Provider.Kind != "mock"},
            {Id: "cfg", Kind: "text", Text: cs.ChipText(), Tip: cs.ChipTip(), Hidden: !this.ShowConfigChip()})
        if app.DevMode {
            this.Dev := DevPanel(this, app)
            items.Push({Id: "dev", Kind: "text", Text: "Dev", Tip: "Dev panel (nfsnotes.ini [Dev] Enabled=1)",
                Popover: this.Dev.Spec()})
        }
        items.Push({Id: "theme", Side: "right", Glyph: look.Mode = "dark" ? "E706" : "E708", Tip: "Switch light / dark",
                Click: (*) => this.ToggleTheme()},
            {Id: "pin", Side: "right", Glyph: "E718", Toggle: true, On: st.Get("alwaysOnTop") = 1, Tip: "Keep window on top",
                Click: (*) => this.TogglePin()})
        g.AddTitleBar(items, {ShowTitle: false})

        g.Header(this.TopHtml(), {Under: false, Drag: false})
        g.Footer(this.NotesHtml())

        for p in MainWindow.PAGES {
            g.AddPage(p[1], p[2], p[3])
            if (p[4] != "" && app.IsStepsCategory(p[4])) {
                v := StepsView(this, app, p[4])
                this.Steps[p[4]] := v
                g.AddHtml("v" v.RootId, v.Html())
            } else if (p[4] != "" && app.IsItemsCategory(p[4])) {
                v := ItemsView(this, app, p[4])
                this.Items[p[4]] := v
                g.AddHtml("v" v.RootId, v.Html())
            } else if (p[4] != "" && app.IsStaticCategory(p[4])) {
                v := StaticView(this, app, p[4])
                this.Statics[p[4]] := v
                g.AddHtml("v" v.RootId, v.Html())
            } else if (p[1] = "settings") {
                this.SV := SettingsView(this, app)
                g.AddHtml("v" SettingsView.RootId, this.SV.Html())
            } else
                g.AddText("", p[2] " - placeholder (built in a later milestone)")
            if (app.DevMode && p[4] != "")
                g.AddHtml("", '<span class="btn" id="nfsUse_' p[4] '">Mark used (dev)</span>')
        }

        g.On("click", "nfsCopy", (*) => this.CopyNotes())
        g.On("click", "nfsClear", (*) => this.ClearAll())
        g.On("click", "nfsHist", (*) => this.Hist.Toggle())
        g.On("click", "nfsRegenBtn", (*) => this.RegenerateClick())
        for ev in ["keyup", "change", "focusout"]
            g.On(ev, "nfsNotes", (*) => this.NoteTouched())
        for f in MainWindow.FIELDS
            g.On("click", "nfsF_" f[1], ObjBindMethod(this, "OnFieldClick", f[1]))
        if app.DevMode
            for p in MainWindow.PAGES
                if (p[4] != "")
                    g.On("click", "nfsUse_" p[4], ObjBindMethod(this, "OnUseClick", p[4]))
        g.OnPage((id := "", *) => this.OnPageChanged(id))
        g.OnReady((*) => this.OnReadyWire())
        g.OnBeforeClose((*) => this.OnClosing())
        app.Session.OnChanged(ObjBindMethod(this, "OnSessionChanged"))
        app.Stats.OnChanged(ObjBindMethod(this, "OnStatsChanged"))
    }

    Show() {
        this.G.Show()
        if (this.App.Settings.Get("alwaysOnTop") = 1)
            this.G.AlwaysOnTop(true)
        this.Calibrate()
        return this
    }

    ; The real window is a few px larger/offset than the Width/Height/X/Y we asked for (frame).
    ; Remember the difference so what we save is what we must ask for next time (no creep).
    Calibrate() {
        this.Off := {x: 0, y: 0, w: 0, h: 0}
        try {
            WinGetPos(&x, &y, &w, &h, this.G.Hwnd)
            this.Off := {x: this.Req.x != "" ? x - this.Req.x : 0, y: this.Req.y != "" ? y - this.Req.y : 0,
                w: w - this.Req.w, h: h - this.Req.h}
        }
    }

    ; --- config chip, settings persistence -------------------------------------
    UpdateConfigChip() {
        cs := this.App.Config
        this.G.TitleItem("cfg", {Text: cs.ChipText(), Tip: cs.ChipTip(), Hidden: !this.ShowConfigChip()})
    }

    ; Agents see the chip only when config fell back (warnings); dev mode always shows it.
    ShowConfigChip() => this.App.DevMode || this.App.Config.Warnings.Length > 0

    ; Settings (or a draft Map of the same keys) + the config's presets -> the look. Problems are logged once each.
    ResolveLook(values) {
        o := {}
        if (this.SystemModeHook != "")
            o.SystemMode := this.SystemModeHook
        if IsObject(this.FontNames)
            o.Fonts := this.FontNames
        res := Theme.Resolve(values, this.App.Config.Config, o)
        for w in res.Warnings
            if !this._warned.Has(w) {
                this._warned[w] := true
                this.App.Logger.Warn("look: " w)
            }
        return res
    }

    ; Paint a look on the open window (preview or apply; saving is the Settings page's job).
    ApplyLook(values) {
        res := this.ResolveLook(values)
        Theme.Apply(this.G, res, this.Look)
        this.Look := res
        try this.G.TitleItem("theme", {Glyph: res.Mode = "dark" ? "E706" : "E708"})
        this.App.Logger.Debug("look applied", {sheet: res.Sheet, mode: res.Mode, accent: res.Accent, font: res.FontFamily, size: res.FontSize})
        return res
    }

    ; Saved size/position; the position is dropped when it is off every monitor.
    SavedRect() {
        w := this.App.Settings.Get("window")
        r := {x: "", y: "", w: 820, h: 680}
        if (w["w"] != "" && w["h"] != "")
            r.w := Min(Max(w["w"], 640), 4000), r.h := Min(Max(w["h"], 560), 4000)
        if (w["x"] != "" && w["y"] != "" && Util.RectVisible(w["x"], w["y"], r.w, r.h))
            r.x := w["x"], r.y := w["y"]
        return r
    }

    Remember(key, value) {
        if !this.Persist
            return
        st := this.App.Settings
        if st.Set(key, value)
            st.Save()
        if (key = "historyOpen" && IsObject(this.SV))      ; the History button works on every page, Settings included
            try this.SV.SyncWindow()
    }

    OnPageChanged(id) {
        this.App.Logger.Debug("page", {page: id})
        prev := this.PrevPage
        this.PrevPage := id
        if (this.Ready && IsObject(this.SV)) {
            if (prev = "settings" && id != "settings")
                this.SV.Leave("page")              ; unapplied appearance changes: keep or revert?
            if (id = "settings")
                this.SV.Render()
        }
        if (id != "" && this.Ready) {
            this.Remember("lastPage", id)
            for p in MainWindow.PAGES
                if (p[1] = id && this.Steps.Has(p[4]))
                    this.Steps[p[4]].Render()          ; a page that was not in the DOM yet is drawn when first shown
                else if (p[1] = id && this.Items.Has(p[4]))
                    this.Items[p[4]].Render()
                else if (p[1] = id && this.Statics.Has(p[4]))
                    this.Statics[p[4]].Render()
        }
    }

    ; --- steps pages -----------------------------------------------------------------------------------------
    ; Session changed: patch the steps pages a moment later (never inside the click that caused it).
    QueueSteps() {
        if this.Ready
            SetTimer(this._stepsFn, -15)
    }

    RenderStepsNow() {
        for id, v in this.Steps
            v.Render()
        for id, v in this.Items
            v.Render()
        for id, v in this.Statics
            v.Render()
    }

    ; force: the call changed under the pages (new call, Clear All, History load, config): forget hints, rebuild, overwrite.
    RenderSteps(force := false) {
        for id, v in this.Steps {
            if force
                v.ResetUi()
            v.Render(force)
        }
        for id, v in this.Items {
            if force
                v.ResetUi()
            v.Render(force)
        }
        for id, v in this.Statics {
            if force
                v.ResetUi()
            v.Render(force)
        }
    }

    ; The pinger's run changed (attempt, second, cancel, done): refresh the Static page's buttons, console and status line.
    OnPingUpdate() {
        if !this.Ready
            return
        for id, v in this.Statics
            v.SyncPing()
    }

    ; Commit typing that has not reached the session yet.
    FlushSteps() {
        for id, v in this.Steps
            v.Flush()
        for id, v in this.Items
            v.Flush()
        for id, v in this.Statics
            v.Flush()
    }

    ; Page id of a category ("" if it has no page).
    PageOf(catId) {
        for p in MainWindow.PAGES
            if (p[4] = catId)
                return p[1]
        return ""
    }

    ; Runs before the window closes (any route). Never blocks the close.
    OnClosing() {
        try this.App.Pinger.Cancel()              ; a running ping stops with the window (the app's OnExit lets it finish cleanly)
        if (this.Ready && IsObject(this.SV))
            try this.SV.Leave("close")            ; unapplied appearance changes: keep or revert (the window closes either way)
        if !this.Persist
            return false
        try {
            hwnd := this.G.Hwnd
            if (WinGetMinMax(hwnd) = 0) {
                WinGetPos(&x, &y, &w, &h, hwnd)
                o := this.Off
                ; the History panel's extra height is not part of the remembered size (it is re-added on open)
                this.App.Settings.Set("window", Map("x", x - o.x, "y", y - o.y, "w", w - o.w, "h", h - o.h - this.Hist.Grown))
            }
            this.App.Settings.Save()
        } catch as e
            this.App.Logger.Warn("saving settings on close failed", {error: e.Message})
        return false
    }

    ; --- technician card ---------------------------------------------------------
    TopHtml() {
        return '<div class="nfs-top"><div class="nfs-ctx" id="nfsCtx">' this.CardInner() '</div>'
            . '<div class="nfs-tile" id="nfsCalls"><div class="nfs-tile-l">Calls today</div>'
            . '<div class="nfs-tile-n" id="nfsCallsN">' this.CallsTotal() '</div>'
            . '<div class="nfs-tile-s">local count</div></div></div>'
    }

    ; Title + health dot + one value per field, each with its status tag.
    CardInner() {
        e := (s) => Util.HtmlEscape(s)
        hl := this.App.Provider.Health()
        h := '<div class="nfs-ctx-t">Technician<span class="nfs-dot ' (hl.Ok ? 'ok' : 'bad') '" id="nfsHealth" data-tip="'
            . e(hl.Message) '"></span></div><div class="nfs-kv">'
        for f in MainWindow.FIELDS
            h .= '<div><b>' f[2] '</b>' this.ValueHtml(f[1]) '</div>'
        return h '</div>'
    }

    ; Text shown for one field: the value; "[not available]" (config text) when unavailable; a dash when empty.
    FieldText(id) {
        f := this.App.Ctx.Get(id)
        if !IsObject(f)
            return ""
        if (f.Status = "unavailable")
            return this.UnavailableText()
        if (f.Status = "empty")
            return Chr(0x2014)
        return f.Value
    }

    UnavailableText() {
        try return this.App.Config.Config["noteTemplate"]["unavailableText"]
        return "[not available]"
    }

    ValueHtml(id) {
        f := this.App.Ctx.Get(id)
        if !IsObject(f)
            return ""
        st := f.Status
        cls := "nfs-v nfs-s-" st (f.Editable ? " nfs-edit" : "")
        tip := f.Editable ? ' data-tip="Click to type a value"' : ""
        return '<span class="' cls '" id="nfsF_' id '"' tip '>' Util.HtmlEscape(this.FieldText(id)) '</span>'
            . '<span class="nfs-tag nfs-t-' st '">' MainWindow.TAGS[st] '</span>'
    }

    RenderCard() {
        if !this.Ready
            return
        try this.G.El("nfsCtx").innerHTML := this.CardInner()
        catch as e
            this.App.Logger.Warn("card render failed", {error: e.Message})
    }

    ; The agent clicked an unavailable / empty / stale value: ask for a value and keep it as Manual.
    OnFieldClick(id, *) {
        f := this.App.Ctx.Get(id)
        if !IsObject(f) || !f.Editable
            return
        label := id
        for x in MainWindow.FIELDS
            if (x[1] = id)
                label := x[2]
        v := this.G.Prompt("Type the " label " for this call. It will be shown as Manual, not live.", "Enter " label)
        if (v != "")
            this.ManualSet(id, v)
    }

    ; Store a typed value. The value is registered with the log's redaction before anything can log it.
    ManualSet(id, value) {
        value := Util.Trim(value)
        if (value != "")
            this.App.Logger.RegisterSensitive(value)
        ok := this.App.Ctx.SetManual(id, value)
        this.App.Logger.Debug("manual value", {field: id, accepted: ok ? 1 : 0})
        if ok {
            this.App.Session.Context := this.App.Ctx.Clone()
            this.RenderCard()
        }
        return ok
    }

    ; --- calls today -------------------------------------------------------------
    CallsTotal() => this.App.Stats.Today().Total

    RenderTile() {
        if !this.Ready
            return
        try {
            total := this.CallsTotal()
            el := this.G.El("nfsCallsN")
            if (el.innerText != total)
                el.innerText := total
            this.TileDate := this.App.Stats.Today().Date
        }
    }

    OnStatsChanged(*) {
        this.RenderTile()
    }

    ; Built on every hover-open from the live stats: enabled categories in config order, Uncategorized, total.
    BuildCallsPopover() {
        e := (s) => Util.HtmlEscape(s)
        sm := this.App.Stats.Summary(this.App.Config.Config["categories"])
        h := '<div class="nfs-pop"><div class="hd">Calls today</div>'
        for it in sm.Items
            h .= '<div class="r"><span class="k">' e(it.label) '</span><span>' it.count '</span></div>'
        h .= '<div class="r tot"><span class="k">Total</span><span>' sm.Total '</span></div>'
        h .= '<div class="meta">Local count ' Chr(0x2014) ' not AppBar data</div></div>'
        return h
    }

    ; Day changed while the window stayed open: the tile must show the new day's (zero) count.
    TickClock() {
        try if (this.App.Stats.Today().Date != this.TileDate)
            this.RenderTile()
        ; Mode "System" follows Windows: re-apply when the Windows app mode changed meanwhile
        try if (this.Look.ModeSetting = "system" && Theme.SystemMode() != this.Look.Mode)
            this.ApplyLook(IsObject(this.SV) && this.SV.Built ? this.SV.Draft : this.App.Settings)
    }

    ; --- call lifecycle ----------------------------------------------------------
    ; A counted new-call event has already reset the session; reset the notes and redraw.
    OnCallCounted() {
        this.NotesText := ""
        this.HideBar()
        this.RenderCard()
        this.RenderTile()
        this.UpdateRailDots()
        this.UpdateConfigChip()
        this.RenderSteps(true)
        if this.Ready
            this.G.Toast("New call", 1800)
    }

    OnConfigChanged() {
        this.UpdateConfigChip()
        this.RenderCard()
        this.RenderTile()
        for id, v in this.Steps
            v.Wire()
        for id, v in this.Items
            v.Wire()
        for id, v in this.Statics
            v.Wire()
        this.RenderSteps(true)
    }

    OnSessionChanged(*) {
        this.UpdateRailDots()
        if !this.App.Restoring
            this.Regenerate()
        this.QueueSteps()
    }

    ; A small dot on the rail item of every category used in the current call.
    UpdateRailDots() {
        if !this.Ready
            return
        ses := this.App.Session
        for p in MainWindow.PAGES {
            if (p[4] = "")
                continue
            try {
                el := this.G.Doc.querySelector('.nav-item[data-page="' p[1] '"]')
                if !IsObject(el)
                    continue
                cls := " " el.className " "
                has := InStr(cls, " nfs-used ") > 0
                want := ses.IsUsed(p[4])
                if (want && !has)
                    el.className := Trim(el.className) " nfs-used"
                else if (!want && has)
                    el.className := Trim(StrReplace(cls, " nfs-used ", " "))
            }
        }
    }

    HasRailDot(pageId) {
        try {
            el := this.G.Doc.querySelector('.nav-item[data-page="' pageId '"]')
            return InStr(" " el.className " ", " nfs-used ") > 0
        }
        return false
    }

    OnUseClick(catId, *) {
        this.App.UseCategory(catId)
    }

    NotesHtml() => '<div class="nfs-notes"><div class="nfs-notes-hd"><span class="l">Notes</span>'
        . '<span class="btn" id="nfsHist">History</span>'
        . '<span class="btn" id="nfsClear">Clear All</span>'
        . '<span class="btn accent" id="nfsCopy">Copy Notes</span></div>'
        . '<div class="textbox"><textarea id="nfsNotes" placeholder="Notes appear here (editable)"></textarea></div>'
        . '<div class="nfs-regen" id="nfsRegen">Your edits are kept.<span class="btn" id="nfsRegenBtn">Regenerate</span>(replaces your edits)</div>'
        . (this.App.DevMode ? '<div class="nfs-warn" id="nfsWarn"></div>' : '')
        . this.Hist.Html() . '</div>'

    NotesText {
        get {
            try return Composer.Crlf(this.G.El("nfsNotes").value)      ; the browser may return bare LF
            return ""
        }
        set {
            try this.G.El("nfsNotes").value := value
        }
    }

    ; Copy Notes: verified clipboard write with one retry. Never counts a call.
    CopyNotes() {
        this.FlushSteps()
        text := this.NotesText
        if (Util.Trim(text) = "") {
            this.G.Toast("Nothing to copy")
            return false
        }
        bad := this.App.MissingRequired()
        if (bad.Length > 0) {
            for b in bad
                if this.Steps.Has(b.Id)
                    this.Steps[b.Id].MarkTried()
            this.RenderSteps()
            this.App.Logger.Info("copy with missing required items", {categories: bad.Length, items: bad[1].Missing.Length})
            if !this.ConfirmMissing(bad) {
                pg := this.PageOf(bad[1].Id)
                if (pg != "")
                    this.G.ShowPage(pg)
                return false
            }
        }
        ; an items form with something chosen or typed that was never added
        for p in MainWindow.PAGES {
            if (p[4] = "" || !this.Items.Has(p[4]) || !this.Items[p[4]].HasDraft())
                continue
            v := this.Items[p[4]]
            this.App.Logger.Info("copy with an entry that was not added", {category: p[4]})
            if !this.ConfirmDraft(v) {
                this.G.ShowPage(p[1])
                return false
            }
        }
        r := NoteClipboard.Copy(text, this.ClipHooks)
        this.App.Logger.Info("copy notes", {ok: r.Ok ? 1 : 0, chars: StrLen(text)})
        if r.Ok
            this.G.Toast("Notes copied", 1800, "success")
        else
            this.G.Toast(r.Error, 5000, "error")
        return r.Ok
    }

    ; "<Label> is missing: a, b. <Label2> is missing: c. Copy anyway?" - Yes copies, No goes to the first category.
    ConfirmMissing(bad) {
        t := ""
        for b in bad {
            labels := ""
            for l in b.Labels
                labels .= (labels = "" ? "" : ", ") l
            t .= (t = "" ? "" : " ") b.Label " is missing: " labels "."
        }
        t .= " Copy anyway?"
        this.LastMissingText := t
        if IsObject(this.AutoConfirm)
            return this.AutoConfirm.Call(t)
        return this.G.Confirm(t, "Required items missing", "Copy anyway", "Go back")
    }

    ; "<Label> has an entry that wasn't added. Copy without it?" - Yes copies, No goes to that page.
    ConfirmDraft(view) {
        t := view.Label() " has an entry that wasn't added. Copy without it?"
        this.LastDraftText := t
        if IsObject(this.AutoConfirm)
            return this.AutoConfirm.Call(t)
        return this.G.Confirm(t, "Entry not added", "Copy without it", "Go back")
    }

    ; --- notes box: composer output, agent edits, regenerate bar ---------------------
    ; What the composer says for the current session. Nothing is generated until something was used or
    ; added (so a fresh call has an empty box and Clear All on it has nothing to save).
    Generate() {
        app := this.App, ses := app.Session
        if !ses.HasStructured() {
            this.LastWarnings := []
            return ""
        }
        res := Composer.Compose(ses.Context, ses, app.Config.Config)
        this.LastWarnings := res.Warnings
        app.Logger.Debug("note composed", {chars: StrLen(res.Text), warnings: res.Warnings.Length})
        return res.Text
    }

    ; Session changed: refresh the box unless the agent edited it (then offer Regenerate).
    Regenerate() {
        if !this.Ready
            return
        ses := this.App.Session
        gen := this.Generate()
        this.ShowWarnings()
        if !ses.AgentEdited {
            ses.GeneratedText := gen
            if !(Composer.Crlf(this.NotesText) == gen)
                this.NotesText := gen
            ses.NoteText := gen
            this.HideBar()
        } else
            this.UpdateBar(gen)
    }

    ; The box text changed (input / keyup / paste / cut / change): is it still the generated text?
    NoteTouched(*) {
        if (!this.Ready || this.App.Restoring)
            return
        was := this.App.Session.AgentEdited
        edited := this.SyncNote()
        if (edited != was) {
            this.App.Logger.Debug("note edited flag", {edited: edited ? 1 : 0})
            if edited
                this.UpdateBar()
            else
                this.Regenerate()           ; edited back to the generated text: take the newest generation now
        } else if edited
            this.UpdateBar()
        this.Hist.OnSearch()                ; the search box shares the document-level input events
    }

    ; Copy the box into the session. Returns whether it differs from the generated text.
    SyncNote() {
        if !this.Ready
            return this.App.Session.AgentEdited
        this.FlushSteps()
        ses := this.App.Session
        cur := Composer.Crlf(this.NotesText)
        ses.NoteText := cur
        edited := !(cur == Composer.Crlf(ses.GeneratedText))
        ses.AgentEdited := edited
        return edited
    }

    ; Show the Regenerate bar when the box is agent-edited and a new generation would differ from the last one.
    UpdateBar(gen := unset) {
        ses := this.App.Session
        if !IsSet(gen)
            gen := this.Generate()
        if (ses.AgentEdited && !(Composer.Crlf(gen) == Composer.Crlf(ses.GeneratedText)))
            this.ShowBar()
        else
            this.HideBar()
    }

    ShowBar() {
        try this.G.El("nfsRegen").style.display := "block"
    }

    HideBar() {
        try this.G.El("nfsRegen").style.display := "none"
    }

    BarShown() {
        try return this.G.El("nfsRegen").style.display = "block"
        return false
    }

    ; Dev mode only: composer warnings (placeholder names and category ids, never call content).
    ShowWarnings() {
        if !this.App.DevMode
            return
        try {
            el := this.G.El("nfsWarn")
            s := ""
            for w in this.LastWarnings
                s .= (s = "" ? "" : "  |  ") w
            el.innerText := s = "" ? "" : "Composer: " s
            el.style.display := s = "" ? "none" : "block"
        }
    }

    RegenerateClick() {
        if this.G.Confirm("Replace your edits with the generated note?", "Regenerate", "Replace", "Keep my edits")
            this.RegenerateNow()
    }

    ; Replace the agent's edits with the generated note (confirm already given).
    RegenerateNow() {
        this.App.Session.AgentEdited := false
        this.Regenerate()
        this.App.Logger.Info("note regenerated")
    }

    ; --- clear all / save failures / history load ----------------------------------------
    ; Clear All button: confirm, save to History, then reset the call. Never counts a call.
    ClearAll() {
        this.SyncNote()
        if !this.App.Session.HasContent() {
            if this.App.Session.HasStaticInput() {          ; only an IP / prefix typed: nothing to save, but the boxes must empty
                this.ClearAllNow()
                return
            }
            this.G.Toast("Nothing to clear")
            return
        }
        if this.G.Confirm("Clear this call? It will be saved to History.", "Clear All")
            this.ClearAllNow()
    }

    ; Save then reset (also used by --selftest, which skips the confirm). Does not open a call record.
    ; Returns false and keeps the call when History can't be written.
    ClearAllNow() {
        if !this.App.ClearCall() {
            this.OnSaveFailed()
            return false
        }
        this.NotesText := ""
        this.HideBar()
        this.UpdateRailDots()
        this.RenderSteps(true)
        this.App.Logger.Info("clear all", {callsToday: this.App.Stats.Today().Total})
        if this.Ready
            this.G.Toast("Call cleared")
        return true
    }

    OnSaveFailed() {
        if this.Ready
            this.G.Toast("Could not save this call to History, so nothing was cleared. Copy your notes, then try Clear All again.", 7000, "error")
    }

    ConfirmReplace() => this.G.Confirm("Replace current call? It will be saved to History first.", "Load from History")

    LoadHistoryEntry(id) {
        r := this.App.LoadFromHistory(id)
        if r.Ok
            return true
        if (!r.Cancelled && r.Error != "")
            this.G.Toast(r.Error, 6000, "error")
        return false
    }

    ; Called by App after a History entry was restored into the session: show its note exactly as saved.
    OnHistoryLoaded() {
        this.NotesText := this.App.Session.NoteText
        this.HideBar()
        this.UpdateRailDots()
        this.RenderCard()
        this.RenderSteps(true)
        if this.Ready
            this.G.Toast("Call loaded from History", 2200, "success")
    }

    ; The title-bar toggle: an explicit Light or Dark (also when the Mode was System), saved at once.
    ToggleTheme() {
        this.SV.ToggleMode()
    }

    ; Title-bar pin clicked (the library has already flipped its state).
    TogglePin() {
        on := this.G.TitleOn("pin")
        this.G.AlwaysOnTop(on)
        this.App.Logger.Info("pin", {alwaysOnTop: on ? 1 : 0})
        this.Remember("alwaysOnTop", on ? 1 : 0)
        if IsObject(this.SV)
            this.SV.SyncWindow()
    }

    ; "Keep on top" from the Settings page: same effect as the pin, and the pin follows.
    SetPin(on) {
        on := on ? true : false
        this.G.AlwaysOnTop(on)
        try this.G.TitleItem("pin", {On: on})
        this.App.Logger.Info("pin", {alwaysOnTop: on ? 1 : 0})
        this.Remember("alwaysOnTop", on ? 1 : 0)
    }

    ; A yes/no question (the selftest answers through AutoAsk).
    Ask(kind, text, title := "", yes := "Yes", no := "No") {
        this.LastAsked := {Kind: kind, Text: text}
        if IsObject(this.AutoAsk)
            return this.AutoAsk.Call(kind, text)
        return this.G.Confirm(text, title, yes, no)
    }

    ; "Keep these appearance changes?" -> "apply" | "revert" (Escape and the close box mean revert).
    AskKeep() {
        text := "Keep these appearance changes?"
        this.LastAsked := {Kind: "keep", Text: text}
        if IsObject(this.AutoAsk)
            return this.AutoAsk.Call("keep", text)
        r := this.G.Dialog(text, "Appearance", ["Apply", "Revert"], {Kind: "question", Cancel: 2})
        return r.Button = "Apply" ? "apply" : "revert"
    }

    ; Settings > About > Open folder: the per-user data folder only (a fixed path, never typed text).
    OpenDataFolder() {
        dir := Util.UserDataDir()
        try Util.EnsureDir(dir)
        cmd := 'explorer.exe "' dir '"'
        this.LastRun := cmd
        if IsObject(this.RunHook) {
            this.RunHook.Call(cmd)
            return true
        }
        try {
            Run(cmd)
            return true
        } catch as e
            this.App.Logger.Warn("could not open the data folder", {error: e.Message})
        return false
    }

    ; Popover() needs the window's internals, which exist only once the page is up.
    OnReadyWire() {
        this.G.Popover("nfsCalls", {On: "hover", Align: "right", Width: 230, Build: ObjBindMethod(this, "BuildCallsPopover")})
        if IsObject(this.Dev)
            this.Dev.Wire()
        this.Hist.Wire()
        for id, v in this.Steps
            v.Wire()
        for id, v in this.Items
            v.Wire()
        for id, v in this.Statics
            v.Wire()
        this.AttachNoteEvents()
        this.Ready := true
        if (!this.App.SelfTest && this.App.Settings.Get("historyOpen") = 1)
            SetTimer(() => this.Hist.SetOpen(true, false), -120)     ; after the first layout pass
        this.Regenerate()
        this.TileDate := this.App.Stats.Today().Date
        last := this.App.Settings.Get("lastPage")
        if (last != "" && !this.App.SelfTest)
            for p in MainWindow.PAGES
                if (p[1] = last)
                    this.G.ShowPage(last)
        if !this.App.SelfTest
            SetTimer(ObjBindMethod(this, "TickClock"), 30000)
        SetTimer(() => this.AfterReady(), -50)
    }

    ; The library's hooks cover click/keyup/change/focusout; paste and cut from the mouse menu, drag-drop and
    ; plain input only exist as document events, so they are attached directly. The edit is applied after the
    ; event returns, so the check runs a moment later.
    AttachNoteEvents() {
        this._evFn := (*) => this.OnInputEvent()
        for ev in ["oninput", "onpaste", "oncut"]
            try this.G.Doc.attachEvent(ev, this._evFn)
    }

    OnInputEvent() {
        SetTimer(this._noteChkFn, -20)
        return ComValue(0xB, -1)
    }

    AfterReady() {
        g := this.G, lg := this.App.Logger
        this.RenderSteps(true)
        mode := g.DocMode
        lg.Info("IE document mode", {documentMode: mode})
        if (mode < 11)
            g.Alert("The embedded browser is running in compatibility mode (documentMode " mode ", need 11).`n`n"
                . "The window may look broken. Windows needs this per-user registry value:`n"
                . "HKCU\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION`n"
                . "AutoHotkey64.exe = 11001 (REG_DWORD). Restart the app after it is set, or ask IT if policy blocks it.",
                "Display mode", "warning")
        if this.App.SelfTest
            this.RunSelfTest()
    }

    ; --selftest: exercise the UI programmatically, log results, exit. No personal data logged.
    ; Stats go to a temp folder (App.StatsRoot) and the clock is faked so the debounce is testable.
    RunSelfTest() {
        g := this.G, lg := this.App.Logger, app := this.App
        cs := app.Config
        lg.Info("selftest config", {source: cs.Source, revision: cs.Revision, warnings: cs.Warnings.Length,
            chip: cs.ChipText(), chipHidden: this.G.TitleItem("cfg").Hidden ? 1 : 0,
            settingsMode: app.Settings.Get("mode"), settingsInTemp: InStr(app.Settings.Dir, A_Temp) = 1 ? 1 : 0})
        try {
            this.NotesText := "selftest-notes-text"
            for p in MainWindow.PAGES {
                g.ShowPage(p[1])
                Sleep(60)
                f := g.El("axFooter")
                lg.Info("selftest page", {page: p[1], current: g.CurrentPage, notesKept: this.NotesText = "selftest-notes-text" ? 1 : 0,
                    footerH: f.offsetHeight, notesVisible: g.El("nfsNotes").offsetHeight > 0 ? 1 : 0})
            }
            hd := g.El("nfsCalls"), sh := g.El("shell")
            f := g.El("axFooter"), ta := g.El("nfsNotes"), top := g.El("axHeader"), b := g.Doc.body
            lg.Info("selftest layout", {headerTileH: hd.offsetHeight, shellH: sh.offsetHeight,
                bodyH: b.offsetHeight, viewH: g.Doc.documentElement.clientHeight,
                viewW: g.Doc.documentElement.clientWidth, headerW: top.scrollWidth,
                tileRight: hd.getBoundingClientRect().right,
                footerH: f.offsetHeight, footerScrollH: f.scrollHeight, notesH: ta.offsetHeight})
            g.ShowPage(MainWindow.PAGES[1][1])
            this.RunCallSelfTest()
        } catch as e {
            SplitPath(e.File, &eFile)
            lg.Error("selftest failed", {error: e.Message, line: e.Line, file: eFile, what: e.What,
                stack: StrReplace(RegExReplace(e.Stack, "m)^.*\\", ""), "`n", " <- ")})
        }
        lg.Info("selftest done")
        try DirDelete(app.StatsRoot, true)
        try DirDelete(app.SettingsDir, true)
        SetTimer(() => ExitApp(), -200)
    }

    ; Context, stats, session, card and dev-panel checks (M3). Logs counts and flags only.
    RunCallSelfTest() {
        g := this.G, lg := this.App.Logger, app := this.App
        p := app.Provider, st := app.Stats
        clk := {Stamp: Util.NowStamp()}
        st.Now := () => clk.Stamp
        start := clk.Stamp
        ; hmm: the stats folder is a temp one, so the real stats are untouched
        lg.Info("selftest m3 start", {statsInTemp: InStr(app.StatsRoot, A_Temp) = 1 ? 1 : 0, kind: p.Kind,
            mockBadgeHidden: g.TitleItem("mock").Hidden ? 1 : 0, startTotal: st.Today().Total})

        ; 1. one new call
        p.FireNewCall()
        total1 := st.Today().Total
        tile1 := g.El("nfsCallsN").innerText
        ; 2. a burst of five on the same job does not count again
        p.FireBurst(5)
        totalBurst := st.Today().Total
        ; 3. two categories used in this call
        app.UseCategory("notDone"), app.UseCategory("billing"), app.UseCategory("notDone")
        sm := st.Summary(app.Config.Config["categories"])
        cnt := Map()
        for it in sm.Items
            cnt[it.id] := it.count
        dots := (this.HasRailDot("notdone") ? 1 : 0) (this.HasRailDot("billing") ? 1 : 0) (this.HasRailDot("equipment") ? 1 : 0)
        g.ShowPopover("nfsCalls"), pop := g.El("axPop").innerHTML, g.ClosePopover(true)
        lg.Info("selftest m3 call", {total: total1, tile: tile1, totalAfterBurst: totalBurst,
            summaryTotal: sm.Total, notDone: cnt["notDone"], billing: cnt["billing"], equipment: cnt["equipment"],
            uncategorized: cnt["uncategorized"], sessionUsed: app.Session.UsedCategories().Length,
            railDotsNotDoneBillingEquipment: dots, popHasNotDone: InStr(pop, "Not Done") > 0 ? 1 : 0,
            popHasBilling: InStr(pop, "Billing") > 0 ? 1 : 0, popHasLabel: InStr(pop, "not AppBar data") > 0 ? 1 : 0,
            summaryOrder: this.ItemOrder(sm)})

        ; 4. Clear All: no count, session reset, later use credits the current record
        this.ClearAllNow()
        afterClear := st.Today().Total
        usedAfterClear := app.Session.UsedCategories().Length
        dotsAfterClear := (this.HasRailDot("notdone") ? 1 : 0) (this.HasRailDot("billing") ? 1 : 0)
        app.UseCategory("equipment")
        eq := st.Today().ById.Has("equipment") ? st.Today().ById["equipment"] : 0
        lg.Info("selftest m3 clearall", {total: afterClear, sessionUsed: usedAfterClear, railDots: dotsAfterClear,
            equipmentCredited: eq, totalAfterUse: st.Today().Total})

        ; 5. a second call after the debounce window (fake clock +10 s) resets the session
        clk.Stamp := FormatTime(DateAdd(SubStr(clk.Stamp, 1, 14), 10, "Seconds"), "yyyyMMddHHmmss") "000"
        this.NotesText := "selftest-notes-text"
        p.FireNewCall()
        lg.Info("selftest m3 call2", {total: st.Today().Total, tile: g.El("nfsCallsN").innerText,
            sessionUsed: app.Session.UsedCategories().Length, notesCleared: this.NotesText = "" ? 1 : 0,
            uncategorized: st.Today().Uncategorized})

        ; 6. field states in the card
        p.SetFieldState("address", "unavailable")
        card := g.El("nfsCtx").innerHTML
        el := g.El("nfsF_address")
        lg.Info("selftest m3 unavailable", {text: el.innerText, status: app.Ctx.Status("address"),
            hasUnavailableClass: InStr(el.className, "nfs-s-unavailable") > 0 ? 1 : 0,
            tagUnavailable: InStr(card, "nfs-t-unavailable") > 0 ? 1 : 0, editable: InStr(el.className, "nfs-edit") > 0 ? 1 : 0})
        p.SetFieldState("techId", "stale")
        p.SetFieldState("workOrder", "empty")
        lg.Info("selftest m3 states", {stale: app.Ctx.Status("techId"), staleTag: InStr(g.El("nfsCtx").innerHTML, "nfs-t-stale") > 0 ? 1 : 0,
            empty: app.Ctx.Status("workOrder"), emptyText: g.El("nfsF_workOrder").innerText = Chr(0x2014) ? "dash" : "other"})
        ok := this.ManualSet("address", "Selftest Manual Value")
        el := g.El("nfsF_address")
        lg.Info("selftest m3 manual", {accepted: ok ? 1 : 0, status: app.Ctx.Status("address"),
            manualTag: InStr(g.El("nfsCtx").innerHTML, "nfs-t-manual") > 0 ? 1 : 0,
            noLongerEditable: InStr(el.className, "nfs-edit") = 0 ? 1 : 0})
        p.SetFieldState("address", "unavailable")     ; provider still has nothing: the manual value stays
        lg.Info("selftest m3 manual kept", {status: app.Ctx.Status("address")})
        refused := this.ManualSet("jobNumber", "should be refused")
        lg.Info("selftest m3 refused", {accepted: refused ? 1 : 0, status: app.Ctx.Status("jobNumber")})

        ; 7. health dot
        p.SetHealthy(false)
        dot := g.El("nfsHealth")
        lg.Info("selftest m3 health", {bad: InStr(dot.className, "bad") > 0 ? 1 : 0, tip: dot.getAttribute("data-tip")})
        p.SetHealthy(true)
        lg.Info("selftest m3 health2", {ok: InStr(g.El("nfsHealth").className, "ok") > 0 ? 1 : 0})

        ; 8. dev panel: open it, check it has its buttons, press New call through the DOM
        if IsObject(this.Dev) {
            g.ShowPopover("dev")
            panel := g.El("axPop").innerHTML
            clk.Stamp := FormatTime(DateAdd(SubStr(clk.Stamp, 1, 14), 10, "Seconds"), "yyyyMMddHHmmss") "000"
            before := st.Today().Total
            clicked := 1
            try g.El("devNew").click()
            catch
                clicked := 0
            Sleep(100)
            lg.Info("selftest m3 devpanel", {open: g.PopoverOpen = "dev" ? 1 : 0, hasNew: InStr(panel, "devNew") > 0 ? 1 : 0,
                hasStates: InStr(panel, "devSt_address_unavailable") > 0 ? 1 : 0, hasUse: InStr(panel, "devUse_notDone") > 0 ? 1 : 0,
                clickCalled: clicked, totalBefore: before, totalAfterClick: st.Today().Total})
            g.ClosePopover(true)
        }
        lg.Info("selftest m3 files", {statsFile: FileExist(st.FileFor(Util.DateOfStamp(start))) != "" ? 1 : 0})
        this.RunNoteSelfTest(clk)
    }

    ; Fake-clock helper for the selftest.
    Advance(clk, sec) {
        clk.Stamp := FormatTime(DateAdd(SubStr(clk.Stamp, 1, 14), sec, "Seconds"), "yyyyMMddHHmmss") "000"
    }

    ; Composer, edit lock, Regenerate bar, History save/load, History panel, clipboard (M4).
    ; Everything runs against the temp data folder. Logs counts, flags and reasons only.
    RunNoteSelfTest(clk) {
        g := this.G, lg := this.App.Logger, app := this.App
        ses := app.Session, hs := app.History, p := app.Provider, st := app.Stats
        hs.Now := () => clk.Stamp
        day := () => Util.DateOfStamp(clk.Stamp)
        cnt := () => hs.List(day()).Length
        newest := () => hs.List(day())[1]
        this.Advance(clk, 10)
        p.FireNewCall()
        lg.Info("selftest m4 start", {historyInTemp: InStr(hs.HistDir, A_Temp) = 1 ? 1 : 0, sessionContent: ses.HasContent() ? 1 : 0,
            boxEmpty: this.NotesText = "" ? 1 : 0, entries: cnt()})

        ; 1. composer output in the box: two categories, a repeated fragment, template lines, config order
        this.SelfSample("billing")
        this.SelfSample("equipment")
        this.SelfSample("equipment", true)
        notDoneRefused := app.AddSampleFragment("notDone") ? 0 : 1      ; steps categories take no sample fragments
        ses.AddFragment("billing", "zz billing marker")
        text := this.NotesText
        first := Composer.FirstName(ses.Context.Value("techName"))
        occ := StrSplit(StrLower(text), "sample fragment for").Length - 1
        brk := InStr(text, "`r`n", , InStr(text, "Notes: "))
        lg.Info("selftest m4 compose", {occurrences: occ, techLine: InStr(text, "Tech name: " first "`r`n") = 1 ? 1 : 0,
            hasId: InStr(text, "Tech ID: ") > 0 ? 1 : 0, hasJob: InStr(text, "Job Number: ") > 0 ? 1 : 0,
            hasNotes: InStr(text, "Notes: Sample fragment for " first ".") > 0 ? 1 : 0,
            billingAfterEquipment: (brk > 0 && InStr(text, "Zz billing marker") > brk) ? 1 : 0, sampleRefusedForSteps: notDoneRefused,
            sessionNoteMatches: ses.NoteText == text ? 1 : 0, generatedMatches: ses.GeneratedText == text ? 1 : 0,
            edited: ses.AgentEdited ? 1 : 0, barShown: this.BarShown() ? 1 : 0, warnings: this.LastWarnings.Length})

        ; 2. agent edit: a session change must not overwrite it; the bar offers Regenerate
        this.NotesText := text "`r`nmy edit"
        this.NoteTouched()
        editedFlag := ses.AgentEdited ? 1 : 0
        barAfterEdit := this.BarShown() ? 1 : 0
        ses.SetValue("notDone", "unrelated", "1")                    ; composer output does not change
        barUnchanged := this.BarShown() ? 1 : 0
        this.SelfSample("static")                                    ; output changes
        lg.Info("selftest m4 edit", {edited: editedFlag, barAfterEdit: barAfterEdit, barWhenUnchanged: barUnchanged,
            editKept: InStr(this.NotesText, "my edit") > 0 ? 1 : 0, notOverwritten: InStr(this.NotesText, "Zz billing marker") > 0
            && StrSplit(StrLower(this.NotesText), "sample fragment for").Length - 1 = 2 ? 1 : 0,
            barShown: this.BarShown() ? 1 : 0, sessionEdited: ses.AgentEdited ? 1 : 0})
        this.NotesText := ses.GeneratedText                          ; edited back to identical: no longer edited
        this.NoteTouched()
        lg.Info("selftest m4 editback", {edited: ses.AgentEdited ? 1 : 0, barShown: this.BarShown() ? 1 : 0,
            newest: StrSplit(StrLower(this.NotesText), "sample fragment for").Length - 1 = 3 ? 1 : 0})
        this.NotesText := this.NotesText "`r`nmy second edit"
        this.NoteTouched()
        ses.AddFragment("billing", "second billing marker")
        shown := this.BarShown() ? 1 : 0
        this.RegenerateNow()                                         ; the confirm is skipped in selftest
        lg.Info("selftest m4 regenerate", {barBefore: shown, replaced: InStr(this.NotesText, "my second edit") = 0 ? 1 : 0,
            equalsGenerated: Composer.Crlf(this.NotesText) == this.Generate() ? 1 : 0, edited: ses.AgentEdited ? 1 : 0,
            barShown: this.BarShown() ? 1 : 0})

        ; 3. Clear All saves, then resets; an empty Clear All saves nothing
        total0 := st.Today().Total, n0 := cnt()
        ok := this.ClearAllNow()
        n1 := cnt()
        lg.Info("selftest m4 clearall", {ok: ok ? 1 : 0, entriesAdded: n1 - n0, reason: newest().Reason,
            sessionUsed: ses.UsedCategories().Length, boxEmpty: this.NotesText = "" ? 1 : 0, totalUnchanged: st.Today().Total = total0 ? 1 : 0})
        ok := this.ClearAllNow()
        lg.Info("selftest m4 clearall empty", {ok: ok ? 1 : 0, entriesAdded: cnt() - n1})

        ; 4. new call with content (agent-edited) saves with reason newCall
        this.SelfSample("billing")
        this.SelfSample("equipment")
        this.NotesText := this.NotesText "`r`nfinal edit"
        this.NoteTouched()
        saved := this.NotesText
        n0 := cnt()
        this.Advance(clk, 10)
        p.FireNewCall()
        e := newest()
        lg.Info("selftest m4 newcall", {entriesAdded: cnt() - n0, reason: e.Reason, sessionUsed: ses.UsedCategories().Length,
            boxEmpty: this.NotesText = "" ? 1 : 0})

        ; 5. load that entry: context "history", note and edited flag back, stats untouched
        id := e.Id
        total0 := st.Today().Total
        cats0 := this.StatsById()
        r := app.LoadFromHistory(id, true)
        hist := 0
        for fid in CallContext.REQUIRED
            hist += (app.Session.Context.Status(fid) = "history") ? 1 : 0
        lg.Info("selftest m4 load", {ok: r.Ok ? 1 : 0, historyFields: hist, noteRestored: Composer.Crlf(this.NotesText) == Composer.Crlf(saved) ? 1 : 0,
            sessionNote: ses.NoteText == saved ? 1 : 0, edited: ses.AgentEdited ? 1 : 0, barShown: this.BarShown() ? 1 : 0,
            totalUnchanged: st.Today().Total = total0 ? 1 : 0, categoriesUnchanged: this.StatsById() == cats0 ? 1 : 0,
            used: ses.UsedCategories().Length, railBilling: this.HasRailDot("billing") ? 1 : 0, railEquipment: this.HasRailDot("equipment") ? 1 : 0,
            cardTagHistory: InStr(g.El("nfsCtx").innerHTML, "nfs-t-history") > 0 ? 1 : 0, restoredFromSet: app.RestoredFrom = id ? 1 : 0})
        n0 := cnt()
        r := app.LoadFromHistory(id, true)                           ; loaded call unchanged: no duplicate entry
        lg.Info("selftest m4 reload unchanged", {ok: r.Ok ? 1 : 0, entriesAdded: cnt() - n0})
        n0 := cnt()
        clearedUnchanged := app.ClearCall()                          ; Clear All on an unchanged loaded call: no entry
        lg.Info("selftest m4 clear unchanged load", {ok: clearedUnchanged ? 1 : 0, entriesAdded: cnt() - n0})
        app.LoadFromHistory(id, true)
        this.SelfSample("static")                                    ; now it differs from what was loaded
        this.Regenerate()
        n0 := cnt()
        r := app.LoadFromHistory(id, true)                           ; current call has new content: saved first
        e2 := newest()
        lg.Info("selftest m4 load over content", {ok: r.Ok ? 1 : 0, entriesAdded: cnt() - n0, reason: e2.Reason,
            restoredFromSet: hs.Get(e2.Id)["restoredFrom"] = id ? 1 : 0})
        pv := app.Provider.GetContext()                              ; a provider update must not overwrite a loaded call
        app.HandleContextChanged(pv)
        lg.Info("selftest m4 load keeps ctx", {status: app.Ctx.Status("techName")})

        ; 6. the History panel: rows, preview, search, empty state, double-click, grow and shrink
        this.ClearAllNow()
        hwnd := g.Hwnd
        WinGetPos(&x0, &y0, &w0, &h0, hwnd)
        this.Hist.SetOpen(true, false)
        Sleep(200)
        WinGetPos(&x1, &y1, &w1, &h1, hwnd)
        wa := Util.WorkAreaFor(x1, y1, w1, h1)
        rowsShown := g.El("nfsHList").querySelectorAll(".nfs-hrow").length
        lg.Info("selftest m4 panel open", {open: this.Hist.Open ? 1 : 0, heightBefore: h0, heightAfter: h1, grew: h1 - h0,
            panelH: HistoryPanel.PANEL_H, grown: this.Hist.Grown, inWorkArea: (x1 >= wa.l && y1 >= wa.t && x1 + w1 <= wa.r && y1 + h1 <= wa.b) ? 1 : 0,
            panelVisible: g.El("nfsHistPanel").offsetHeight, rowsShown: rowsShown, rowsExpected: Min(cnt(), HistoryPanel.MAX_ROWS),
            daySelectorOptions: g.El("nfsHDay").options.length})
        ph := g.El("nfsHistPanel")
        lg.Info("selftest m4 panel layout", {panelH: ph.offsetHeight, styleH: ph.currentStyle.height, display: ph.currentStyle.display,
            boxSizing: ph.currentStyle.boxSizing, listH: g.El("nfsHList").offsetHeight, hdH: g.El("nfsHDay").offsetHeight,
            footerH: g.El("axFooter").offsetHeight, footerScrollH: g.El("axFooter").scrollHeight, footerClientH: g.El("axFooter").clientHeight,
            notesH: g.El("nfsNotes").offsetHeight, shellH: g.El("shell").offsetHeight, viewH: g.Doc.documentElement.clientHeight,
            firstRowH: g.El("nfsHR_1").offsetHeight, listScrollH: g.El("nfsHList").scrollHeight})
        row1 := this.Hist.Rows[1]
        g.ShowPopover("nfsHR_1")
        pop := g.El("axPop").innerHTML
        g.ClosePopover(true)
        lg.Info("selftest m4 panel preview", {popoverHasNote: InStr(pop, Util.HtmlEscape(SubStr(row1.Note, 1, 12))) > 0 ? 1 : 0,
            popHasTime: InStr(pop, row1.Time) > 0 ? 1 : 0})
        g.El("nfsHSearch").value := "zzzz-no-match"
        this.Hist.OnSearch()
        lg.Info("selftest m4 panel search", {rows: g.El("nfsHList").querySelectorAll(".nfs-hrow").length,
            emptyText: InStr(g.El("nfsHList").innerText, "No saved calls for this day.") > 0 ? 1 : 0})
        g.El("nfsHSearch").value := ""
        this.Hist.OnSearch()
        rows2 := g.El("nfsHList").querySelectorAll(".nfs-hrow").length
        g.El("nfsHDay").value := "2000-01-01"                        ; a day with no file is not an option: selector keeps today
        this.Hist.Day := "2000-01-01"
        this.Hist.RenderList()
        emptyDay := InStr(g.El("nfsHList").innerText, "No saved calls for this day.") > 0 ? 1 : 0
        this.Hist.Day := day()
        this.Hist.RenderList()
        lg.Info("selftest m4 panel restore list", {rowsAfterClear: rows2, emptyDay: emptyDay})
        ; single click selects, double-click loads (a fired DOM event goes through the library's hook)
        target := this.Hist.Rows[1].Id
        clicked := 1
        try g.El("nfsHR_1").click()
        catch
            clicked := 0
        Sleep(60)
        selected := this.Hist.SelId = target ? 1 : 0
        dbl := 1
        try g.El("nfsHR_1").fireEvent("ondblclick")
        catch
            dbl := 0
        Sleep(150)
        lg.Info("selftest m4 panel click", {clickCalled: clicked, selected: selected, dblCalled: dbl,
            loadedByDblClick: app.RestoredFrom = target ? 1 : 0})
        this.Hist.SetOpen(false, false)
        Sleep(200)
        WinGetPos(&x2, &y2, &w2, &h2, hwnd)
        lg.Info("selftest m4 panel close", {open: this.Hist.Open ? 1 : 0, heightAfterClose: h2, restored: h2 = h0 ? 1 : 0,
            hidden: g.El("nfsHistPanel").offsetHeight = 0 ? 1 : 0})

        ; 7. Copy Notes through an injected clipboard (never the real one)
        store := {v: ""}
        this.ClipHooks := {Set: (s) => (store.v := s, true), Get: () => store.v}
        this.NotesText := "copy test`nsecond line"
        total0 := st.Today().Total
        ok := this.CopyNotes()
        lg.Info("selftest m4 copy", {ok: ok ? 1 : 0, crlf: store.v == "copy test`r`nsecond line" ? 1 : 0, totalUnchanged: st.Today().Total = total0 ? 1 : 0})
        this.ClipHooks := {Set: (s) => true, Get: () => "other"}
        ok := this.CopyNotes()
        lg.Info("selftest m4 copy fails", {ok: ok ? 1 : 0, errorShown: InStr(g.El("axToast").innerText, "Clipboard is in use") > 0 ? 1 : 0})
        this.ClipHooks := ""

        ; 8. a History save failure never clears the call
        this.NotesText := ""
        this.ClearAllNow()
        this.SelfSample("equipment")
        good := hs.HistDir
        blocker := A_Temp "\NFSNotesSelfTest_blocker_" A_TickCount
        FileAppend("x", blocker)
        hs.HistDir := blocker "\history"
        n0 := cnt()
        ok := this.ClearAllNow()
        keptClear := ses.HasContent() ? 1 : 0
        toast := InStr(g.El("axToast").innerText, "Could not save") > 0 ? 1 : 0
        this.Advance(clk, 10)
        total0 := st.Today().Total
        p.FireNewCall()
        lg.Info("selftest m4 save failure", {clearOk: ok ? 1 : 0, callKeptAfterClear: keptClear, errorToast: toast,
            newCallCounted: st.Today().Total != total0 ? 1 : 0, callKeptAfterNewCall: ses.HasContent() ? 1 : 0, lastErrorSet: hs.LastError != "" ? 1 : 0})
        hs.HistDir := good
        try FileDelete(blocker)
        n0 := cnt()                                                  ; count in the real (temp) history folder
        ok := this.ClearAllNow()
        lg.Info("selftest m4 save retry", {ok: ok ? 1 : 0, entriesAdded: cnt() - n0, reason: newest().Reason, sessionContent: ses.HasContent() ? 1 : 0})
        lg.Info("selftest m4 files", {historyFile: FileExist(hs.FileFor(day())) != "" ? 1 : 0,
            realHistoryDirExists: DirExist(Util.UserDataDir() "\history") != "" ? 1 : 0})
        this.RunStepsSelfTest(clk)
    }

    ; Workflow engine + steps pages (M5): Not Done through PWO / TC yes / TC no / SRO, answer retention, flags,
    ; Close Job in config order, reset, History round trip of the answers, copy with missing required items.
    ; Everything runs against the temp data folder. Logs counts and flags only - never typed text or note text.
    RunStepsSelfTest(clk) {
        g := this.G, lg := this.App.Logger, app := this.App
        ses := app.Session, hs := app.History, p := app.Provider, st := app.Stats
        nd := this.Steps["notDone"], cj := this.Steps["closeJob"]
        eng := app.EngineFor("notDone")
        chosen := (cat, step) => WorkflowEngine.ChosenId(WorkflowEngine.Entry(ses.AnswersFor(cat), step))
        valid := () => eng.Validate(ses.AnswersFor("notDone"))
        tail := () => SubStr(ses.NoteText, InStr(ses.NoteText, "Notes: "))
        typeInto := (view, step, field, text) => (g.El(view.EditId(field)).value := text, view.OnEdit("change", step, field))
        day := () => Util.DateOfStamp(clk.Stamp)
        this.Advance(clk, 10)
        p.FireNewCall()
        g.ShowPage("notdone")
        Sleep(60)
        nd.Render(true)
        cj.Render(true)
        lg.Info("selftest m5 start", {stepsPages: this.Steps.Count, cards: nd.CardOrder(), locked: nd.LockedCount(),
            banner: nd.BannerText() = "" ? 0 : 1, used: ses.IsUsed("notDone") ? 1 : 0, closeCards: cj.CardOrder(),
            devOffersSampleForSteps: IsObject(this.Dev) ? (InStr(this.Dev.Build(), "devFrag_notDone") > 0 ? 1 : 0) : -1,
            engineIsCached: app.EngineFor("notDone") == eng ? 1 : 0})

        ; 1. PWO: choices by (DOM) click go through the library hook -> App.SetOption -> engine -> note
        okR := nd.ClickOption("reason", "r2"), Sleep(90)
        okO := nd.ClickOption("orderType", "pwo"), Sleep(90)
        v := valid()
        lg.Info("selftest m5 pwo", {clicked: (okR ? 1 : 0) (okO ? 1 : 0), used: ses.IsUsed("notDone") ? 1 : 0,
            railDot: this.HasRailDot("notdone") ? 1 : 0, credited: st.Today().ById.Has("notDone") ? 1 : 0,
            cards: nd.CardOrder(), shownReason: nd.ShownChoice("reason"), shownOrder: nd.ShownChoice("orderType"),
            answerReason: chosen("notDone", "reason"), valid: v.Ok ? 1 : 0, missing: v.Missing.Length,
            copyMissing: app.MissingRequired().Length, stars: nd.StarsOn(), hints: nd.HintsOn(),
            noteHasReason: InStr(ses.NoteText, "Reason 2 placeholder note.") > 0 ? 1 : 0})
        typeInto(nd, "supervisorPwo", "supervisorName", "Zed Selftest")
        v1 := valid()
        typeInto(nd, "supervisorPwo", "rescheduleReason", "Because selftest")
        nd.ClickOption("contact", "c1"), Sleep(90)
        nd.ClickOption("outcome", "o3"), Sleep(90)
        v2 := valid()
        expectPwo := "Notes: Reason 2 placeholder note. Order type PWO placeholder note. Supervisor Zed Selftest placeholder note."
            . " Reschedule reason Because selftest placeholder note. Contact 1 placeholder note. Outcome 3 placeholder note."
        lg.Info("selftest m5 pwo filled", {missingAfterName: v1.Missing.Length, valid: v2.Ok ? 1 : 0,
            noteExact: tail() == expectPwo ? 1 : 0, boxMatches: Composer.Crlf(this.NotesText) == ses.NoteText ? 1 : 0,
            copyMissing: app.MissingRequired().Length, hints: nd.HintsOn(), stars: nd.StarsOn()})
        ; typing is committed 250 ms after the last key
        g.El(nd.EditId("supervisorName")).value := "Zed Selftest 2"
        nd.OnEdit("keyup", "supervisorPwo", "supervisorName")
        before := WorkflowEngine.FieldValue(WorkflowEngine.Entry(ses.AnswersFor("notDone"), "supervisorPwo"), "supervisorName")
        Sleep(StepsView.DEBOUNCE_MS + 150)
        after := WorkflowEngine.FieldValue(WorkflowEngine.Entry(ses.AnswersFor("notDone"), "supervisorPwo"), "supervisorName")
        lg.Info("selftest m5 debounce", {keptBefore: before == "Zed Selftest" ? 1 : 0, committedAfter: after == "Zed Selftest 2" ? 1 : 0,
            noteUpdated: InStr(ses.NoteText, "Zed Selftest 2") > 0 ? 1 : 0, boxKeptText: nd.EditText("supervisorName") == "Zed Selftest 2" ? 1 : 0})

        ; 2. TC: the PWO answers stay in the session, hidden; the supervisor question appears
        nd.ClickOption("orderType", "tc"), Sleep(90)
        v := valid()
        retained := WorkflowEngine.FieldValue(WorkflowEngine.Entry(ses.AnswersFor("notDone"), "supervisorPwo"), "supervisorName") == "Zed Selftest 2" ? 1 : 0
        lg.Info("selftest m5 tc", {cards: nd.CardOrder(), pwoRetained: retained, pwoEditGone: nd.EditText("supervisorName") == "<none>" ? 1 : 0,
            notInNote: InStr(ses.NoteText, "Zed Selftest") = 0 ? 1 : 0, valid: v.Ok ? 1 : 0, missing: v.Missing.Length,
            state: eng.StepState("supervisorPwo", ses.AnswersFor("notDone"))})
        nd.ClickOption("supervisorTc", "yes"), Sleep(90)
        v := valid()
        lg.Info("selftest m5 tc yes", {valid: v.Ok ? 1 : 0, missing: v.Missing.Length, nameStarShown: nd.StarsOn() >= 1 ? 1 : 0,
            nameEditEnabled: nd.EditDisabled("supervisorNameTc") = 0 ? 1 : 0})
        typeInto(nd, "supervisorTc", "supervisorNameTc", "Quinn Selftest")
        typeInto(nd, "contact", "contactDetails", "Left a note")
        v := valid()
        expectTc := "Notes: Reason 2 placeholder note. Order type TC placeholder note. Tech spoke with supervisor Quinn Selftest placeholder note."
            . " Contact 1 placeholder note. Left a note. Outcome 3 placeholder note."
        lg.Info("selftest m5 tc yes filled", {valid: v.Ok ? 1 : 0, noteExact: tail() == expectTc ? 1 : 0})

        ; 3. TC No: stop - later steps locked, banner, limited note (even though contact and outcome were answered)
        nd.ClickOption("supervisorTc", "no"), Sleep(90)
        v := valid()
        expectStop := "Notes: Reason 2 placeholder note. Order type TC placeholder note."
            . " Tech has not contacted supervisor; advised tech to contact supervisor before calling back."
        stop := eng.Stop(ses.AnswersFor("notDone"))
        lg.Info("selftest m5 tc no", {stopped: stop.Stopped ? 1 : 0, stopStep: stop.StepId, locked: nd.LockedCount(),
            bannerShown: InStr(nd.BannerText(), stop.Message) > 0 && stop.Message != "" ? 1 : 0, cards: nd.CardOrder(),
            lockedEditDisabled: nd.EditDisabled("contactDetails"), contactState: eng.StepState("contact", ses.AnswersFor("notDone")),
            valid: v.Ok ? 1 : 0, noteExact: tail() == expectStop ? 1 : 0,
            noContact: InStr(ses.NoteText, "Contact 1") = 0 && InStr(ses.NoteText, "Outcome 3") = 0 ? 1 : 0,
            contactKept: chosen("notDone", "contact") = "c1" ? 1 : 0, copyMissing: app.MissingRequired().Length})
        nd.ClickOption("supervisorTc", "yes"), Sleep(90)
        v := valid()
        lg.Info("selftest m5 tc back to yes", {locked: nd.LockedCount(), banner: nd.BannerText() = "" ? 0 : 1, valid: v.Ok ? 1 : 0,
            noteExact: tail() == expectTc ? 1 : 0, detailsRestored: nd.EditText("contactDetails") == "Left a note" ? 1 : 0,
            shownContact: nd.ShownChoice("contact"), shownOutcome: nd.ShownChoice("outcome")})

        ; 4. SRO: no supervisor steps; the placeholder flag shows for Reason 4 + SRO
        nd.ClickOption("orderType", "sro"), Sleep(90)
        v := valid()
        f0 := nd.FlagCount()
        nd.ClickOption("reason", "r4"), Sleep(90)
        f1 := nd.FlagCount()
        lg.Info("selftest m5 sro", {cards: nd.CardOrder(), valid: v.Ok ? 1 : 0, flagsReason2: f0, flagsReason4: f1,
            flagBlocksCopy: app.MissingRequired().Length, flagText: InStr(g.El(nd.FlagsId).innerText, "Placeholder flag") > 0 ? 1 : 0})
        nd.ClickOption("reason", "r2"), Sleep(90)
        nd.ClickOption("orderType", "pwo"), Sleep(90)
        lg.Info("selftest m5 pwo again", {cards: nd.CardOrder(), nameRestored: nd.EditText("supervisorName") == "Zed Selftest 2" ? 1 : 0,
            reasonRestored: nd.EditText("rescheduleReason") == "Because selftest" ? 1 : 0, valid: valid().Ok ? 1 : 0, flags: nd.FlagCount()})

        ; 5. Close Job: its fragments follow Not Done's in the note (config order)
        cj.ClickOption("closeChoice", "k2"), Sleep(90)
        typeInto(cj, "closeText", "closeNote", "Zz close")
        cj.ClickOption("closeFollowUp", "yes"), Sleep(90)
        nd2 := InStr(ses.NoteText, "Outcome 3 placeholder note."), cj2 := InStr(ses.NoteText, "Close option 2 placeholder note.")
        lg.Info("selftest m5 closejob", {cards: cj.CardOrder(), used: ses.IsUsed("closeJob") ? 1 : 0, railDot: this.HasRailDot("closejob") ? 1 : 0,
            afterNotDone: (nd2 > 0 && cj2 > nd2) ? 1 : 0, hasText: InStr(ses.NoteText, "Close note Zz close placeholder note.") > 0 ? 1 : 0,
            hasYes: InStr(ses.NoteText, "Close question yes placeholder note.") > 0 ? 1 : 0,
            copyMissing: app.MissingRequired().Length, fragments: ses.Fragments("closeJob").Length})

        ; 6. Reset this category: answers, fragments and values go, the category stays used (and credited)
        cj.ResetNow()
        lg.Info("selftest m5 reset", {answers: ses.AnswersFor("closeJob").Count, fragments: ses.Fragments("closeJob").Length,
            values: ses.ValuesFor("closeJob").Count, used: ses.IsUsed("closeJob") ? 1 : 0,
            credited: st.Today().ById.Has("closeJob") ? 1 : 0, noteGone: InStr(ses.NoteText, "Close option") = 0 ? 1 : 0,
            shownChoice: cj.ShownChoice("closeChoice") = "" ? 1 : 0, boxEmpty: cj.EditText("closeNote") = "" ? 1 : 0,
            notDoneKept: ses.HasAnswers("notDone") ? 1 : 0})

        ; 7. History: the answers (hidden ones too) are saved and come back exactly; the pages show them again
        cj.ClickOption("closeChoice", "k3"), Sleep(90)
        nd.ClickOption("orderType", "tc"), Sleep(90)
        nd.ClickOption("supervisorTc", "no"), Sleep(90)
        snap := ses.Snapshot()
        canon := ConfigJson.Canon(snap["categories"]) "|" ConfigJson.Canon(snap["categoriesUsed"])
        hasAnswers := snap["categories"].Has("notDone") && snap["categories"]["notDone"].Has("answers") ? 1 : 0
        n0 := hs.List(day()).Length
        this.ClearAllNow()
        n1 := hs.List(day()).Length
        fileText := FileRead(hs.FileFor(day()), "UTF-8")
        lg.Info("selftest m5 history saved", {entriesAdded: n1 - n0, snapshotHasAnswers: hasAnswers,
            fileHasAnswers: InStr(fileText, '"answers"') > 0 ? 1 : 0, clearedAnswers: ses.HasAnswers("notDone") ? 0 : 1,
            cardsAfterClear: nd.CardOrder()})
        id := hs.List(day())[1].Id
        r := app.LoadFromHistory(id, true)
        Sleep(60)
        lg.Info("selftest m5 history loaded", {ok: r.Ok ? 1 : 0, identical: (ConfigJson.Canon(ses.Snapshot()["categories"]) "|" ConfigJson.Canon(ses.Snapshot()["categoriesUsed"])) == canon ? 1 : 0,
            cards: nd.CardOrder(), locked: nd.LockedCount(), banner: nd.BannerText() = "" ? 0 : 1,
            shownOrder: nd.ShownChoice("orderType"), shownStop: nd.ShownChoice("supervisorTc"), shownClose: cj.ShownChoice("closeChoice"),
            noteStopped: InStr(ses.NoteText, "Tech has not contacted supervisor") > 0 ? 1 : 0,
            pwoKept: WorkflowEngine.FieldValue(WorkflowEngine.Entry(ses.AnswersFor("notDone"), "supervisorPwo"), "supervisorName") == "Zed Selftest 2" ? 1 : 0})
        nd.ClickOption("supervisorTc", "yes"), Sleep(90)        ; the loaded call is editable and keeps working
        lg.Info("selftest m5 history edit", {locked: nd.LockedCount(), contactBack: InStr(ses.NoteText, "Contact 1 placeholder note.") > 0 ? 1 : 0})
        this.ClearAllNow()

        ; 8. Copy Notes with required items missing: ask first (auto-answered here), No jumps to the page
        store := {v: ""}
        this.ClipHooks := {Set: (s) => (store.v := s, true), Get: () => store.v}
        asked := {n: 0, answer: false}
        this.AutoConfirm := (t) => (asked.n += 1, asked.answer)
        g.ShowPage("billing")
        app.SetOption("notDone", "reason", "r1")
        nd.Render()
        ok := this.CopyNotes()
        lg.Info("selftest m5 copy declined", {copied: ok ? 1 : 0, asked: asked.n, clipboardEmpty: store.v = "" ? 1 : 0,
            textStartsLabel: InStr(this.LastMissingText, "Not Done is missing: ") = 1 ? 1 : 0,
            textEnds: SubStr(this.LastMissingText, -13) == " Copy anyway?" ? 1 : 0,
            namesOrderType: InStr(this.LastMissingText, "Order type") > 0 ? 1 : 0,
            jumpedToPage: g.CurrentPage = "notdone" ? 1 : 0, hintsShown: nd.HintsOn() > 0 ? 1 : 0})
        asked.answer := true
        ok := this.CopyNotes()
        lg.Info("selftest m5 copy anyway", {copied: ok ? 1 : 0, asked: asked.n, clipboardHasNote: InStr(store.v, "Reason 1 placeholder note.") > 0 ? 1 : 0})
        ; complete the answers: no question
        nd.ClickOption("orderType", "sro"), Sleep(90)
        nd.ClickOption("contact", "c2"), Sleep(90)
        nd.ClickOption("outcome", "o1"), Sleep(90)
        store.v := ""
        n := asked.n
        ok := this.CopyNotes()
        lg.Info("selftest m5 copy complete", {copied: ok ? 1 : 0, askedAgain: asked.n - n, clipboardHasNote: store.v != "" ? 1 : 0})
        ; a stopped Not Done is complete: locked steps never block a copy
        nd.ClickOption("orderType", "tc"), Sleep(90)
        nd.ClickOption("supervisorTc", "no"), Sleep(90)
        n := asked.n
        ok := this.CopyNotes()
        lg.Info("selftest m5 copy stopped", {copied: ok ? 1 : 0, askedAgain: asked.n - n})
        this.AutoConfirm := "", this.ClipHooks := ""
        this.ClearAllNow()

        ; 9. more than 4 options: a radio list instead of the segmented control (two options added for the test only)
        kinds0 := cj.ControlKind("closeChoice") "," cj.ControlKind("closeFollowUp")
        opts := app.CategoryFor("closeJob")["steps"][1]["options"]
        opts.Push(Map("id", "k4", "label", "Close option 4 (placeholder)", "fragment", "Close option 4 placeholder note."))
        opts.Push(Map("id", "k5", "label", "Close option 5 (placeholder)", "fragment", "Close option 5 placeholder note."))
        cj.Render(true)
        kinds1 := cj.ControlKind("closeChoice")
        clickedRadio := cj.ClickOption("closeChoice", "k5"), Sleep(90)
        lg.Info("selftest m5 radio", {before: kinds0, withFiveOptions: kinds1, clicked: clickedRadio ? 1 : 0,
            answer: chosen("closeJob", "closeChoice"), shown: cj.ShownChoice("closeChoice"),
            inNote: InStr(ses.NoteText, "Close option 5 placeholder note.") > 0 ? 1 : 0})
        opts.Pop(), opts.Pop()
        this.ClearAllNow()
        lg.Info("selftest m5 done", {sessionContent: ses.HasContent() ? 1 : 0, cards: nd.CardOrder(), stepsKeysIgnored: eng.Warnings(Map("nope", {option: "x", fields: Map()})).Length})
        this.RunItemsSelfTest(clk)
    }

    ; Dev-style sample fragment put straight into a category (the M4 block needs fragments in items categories, which no
    ; longer have a dev button). Marks the category used.
    SelfSample(catId, duplicate := false) {
        this.App.Session.AddFragment(catId, duplicate ? "  SAMPLE   fragment for {tech.firstName}  " : "sample fragment for {tech.firstName}")
        this.App.UseCategory(catId)
    }

    ; Items pages (M6): Equipment and Billing through DOM clicks and the real handlers - add, qty / details, edit, remove,
    ; duplicate refusal, billing outcomes, the combined note, Copy Notes with an unadded entry, History round trip.
    ; Everything runs against the temp data folder. Logs counts and flags only - never typed text or note text.
    RunItemsSelfTest(clk) {
        g := this.G, lg := this.App.Logger, app := this.App
        ses := app.Session, hs := app.History, p := app.Provider, st := app.Stats
        eq := this.Items["equipment"], bl := this.Items["billing"], nd := this.Steps["notDone"]
        day := () => Util.DateOfStamp(clk.Stamp)
        notes := () => SubStr(ses.NoteText, InStr(ses.NoteText, "Notes: "))
        ok := (b) => b ? 1 : 0
        none := (x) => x = "" ? "none" : x
        this.Advance(clk, 10)
        p.FireNewCall()
        g.ShowPage("equipment")
        Sleep(60)
        eq.Render(true)
        bl.Render(true)
        lg.Info("selftest m6 start", {itemsPages: this.Items.Count, eqAction: eq.ControlKind("action"), eqItem: eq.ControlKind("item"),
            eqQty: eq.ControlKind("qty"), eqOutcome: none(eq.ControlKind("outcome")), eqDetails: eq.ControlKind("details"),
            blAction: bl.ControlKind("action"), blOutcome: bl.ControlKind("outcome"), blQty: none(bl.ControlKind("qty")),
            blDetails: bl.ControlKind("details"), emptyShown: ok(eq.EmptyShown() && bl.EmptyShown()), addText: eq.AddText(),
            cancelHidden: ok(!eq.CancelShown()), used: ok(ses.IsUsed("equipment")),
            devSampleForItems: IsObject(this.Dev) ? ok(InStr(this.Dev.Build(), "devFrag_equipment") > 0 || InStr(this.Dev.Build(), "devFrag_billing") > 0) : -1,
            sampleRefused: ok(!app.AddSampleFragment("equipment") && !app.AddSampleFragment("billing"))})

        ; 1. Equipment: Swapped + Item 1, nothing else -> no trace of qty or details
        a1 := eq.Click("action", "swapped"), a2 := eq.Click("item", "item1"), Sleep(90)
        prev := eq.PreviewText()
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment first", {clicked: ok(a1) ok(a2), previewExact: ok(prev == "Will add: Swapped Item 1 (placeholder)."),
            rows: eq.RowCount(), emptyGone: ok(!eq.EmptyShown()), rowExact: ok(eq.RowTexts() == "Swapped Item 1 (placeholder)."),
            noteExact: ok(notes() == "Notes: Swapped Item 1 (placeholder)."), used: ok(ses.IsUsed("equipment")),
            railDot: ok(this.HasRailDot("equipment")), credited: ok(st.Today().ById.Has("equipment")),
            formCleared: ok(eq.Shown("action") = "" && eq.Shown("item") = "" && eq.InputText("qty") = "" && eq.InputText("details") = ""),
            previewHidden: ok(eq.PreviewText() = ""), entries: ses.EntriesFor("equipment").Length, fragments: ses.Fragments("equipment").Length,
            hints: eq.HintsOn(), boxMatches: ok(Composer.Crlf(this.NotesText) == ses.NoteText)})

        ; 2. qty and details appear in the entry and the note
        eq.Click("action", "added"), eq.Click("item", "item2"), eq.TypeInto("qty", "2"), eq.TypeInto("details", "Zz eq detail"), Sleep(90)
        prev := eq.PreviewText()
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment qty details", {previewExact: ok(prev == "Will add: Added 2 Item 2 (placeholder). Zz eq detail."), rows: eq.RowCount(),
            noteExact: ok(notes() == "Notes: Swapped Item 1 (placeholder). Added 2 Item 2 (placeholder). Zz eq detail."),
            entryKeptTyped: ok(ses.EntriesFor("equipment")[2].details == "Zz eq detail" && ses.EntriesFor("equipment")[2].qty == "2"),
            boxesCleared: ok(eq.InputText("qty") = "" && eq.InputText("details") = ""), orderKept: ok(InStr(ses.NoteText, "Swapped") < InStr(ses.NoteText, "Added 2")),
            noGaps: ok(!InStr(ses.NoteText, "  ") && !InStr(ses.NoteText, ". .") && !InStr(ses.NoteText, "()"))})

        ; 3. refusals: missing action / item, bad quantities, a duplicate
        n0 := eq.RowCount()
        eq.ClickAdd(), Sleep(90)
        hintsEmpty := eq.HintsOn(), hintAction := eq.HintText("action"), hintItem := eq.HintText("item")
        eq.Click("action", "removed"), Sleep(90)
        hintsAfterAction := eq.HintsOn()
        eq.Click("item", "item3"), Sleep(90)
        bad := ""
        for q in ["abc", "0", "100", "2.5", "-1", "1e1"] {
            eq.TypeInto("qty", q), eq.ClickAdd(), Sleep(90)
            bad .= (eq.RowCount() = n0 ? "0" : "1") (InStr(eq.HintText("qty"), "whole number") ? "h" : "x") ","
        }
        eq.TypeInto("qty", "5"), Sleep(90)
        hintsFixed := eq.HintsOn()
        lg.Info("selftest m6 equipment refused", {nothingAdded: ok(eq.RowCount() = n0), hintsEmptyForm: hintsEmpty, hintAction: ok(InStr(hintAction, "action") > 0),
            hintItem: ok(InStr(hintItem, "item") > 0), hintsAfterAction: hintsAfterAction, badQty: bad, hintsAfterFix: hintsFixed,
            sessionEntries: ses.EntriesFor("equipment").Length})
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment third", {rows: eq.RowCount(),
            noteExact: ok(notes() == "Notes: Swapped Item 1 (placeholder). Added 2 Item 2 (placeholder). Zz eq detail. Removed 5 Item 3 (placeholder).")})
        n0 := eq.RowCount()
        eq.Click("action", "swapped"), eq.Click("item", "item1"), Sleep(90)
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment duplicate", {refused: ok(eq.RowCount() = n0 && ses.EntriesFor("equipment").Length = n0),
            messageExact: ok(eq.MsgText() == ItemsModel.DupMessage()), messageHasEmDash: ok(InStr(eq.MsgText(), Chr(0x2014)) > 0),
            formKept: ok(eq.Shown("action") = "swapped" && eq.Shown("item") = "item1"), noteOnce: ok(StrSplit(ses.NoteText, "Swapped Item 1").Length = 2)})
        eq.Click("action", "added"), Sleep(90)                       ; changing the form clears the message
        lg.Info("selftest m6 equipment message gone", {msgGone: ok(eq.MsgText() = "")})
        eq.CancelNow(), Sleep(60)

        ; 4. edit: the entry goes into the form; Save replaces it in place; a duplicate is refused; Cancel changes nothing
        eq.ClickRow("edit", 2), Sleep(90)
        lg.Info("selftest m6 equipment edit", {title: eq.TitleText(), button: eq.AddText(), cancelShown: ok(eq.CancelShown()), action: eq.Shown("action"),
            item: eq.Shown("item"), qtyBox: eq.InputText("qty"), detailsBoxLoaded: ok(eq.InputText("details") == "Zz eq detail"),
            rowEditing: ok(InStr(g.El(eq.ListId).innerHTML, "editing") > 0), notADraft: ok(!eq.HasDraft())})
        eq.TypeInto("qty", "3"), Sleep(90)
        lg.Info("selftest m6 equipment edit preview", {previewExact: ok(eq.PreviewText() == "Will save: Added 3 Item 2 (placeholder). Zz eq detail."),
            draft: ok(eq.HasDraft())})
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment saved", {rows: eq.RowCount(), button: eq.AddText(), cancelHidden: ok(!eq.CancelShown()), title: eq.TitleText(),
            noteExact: ok(notes() == "Notes: Swapped Item 1 (placeholder). Added 3 Item 2 (placeholder). Zz eq detail. Removed 5 Item 3 (placeholder)."),
            samePlace: ok(ses.EntriesFor("equipment")[2].qty == "3"), formCleared: ok(eq.Shown("item") = "" && eq.InputText("details") = "")})
        eq.ClickRow("edit", 3), Sleep(90)
        eq.Click("action", "swapped"), eq.Click("item", "item1"), eq.TypeInto("qty", ""), Sleep(90)
        eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 equipment edit duplicate", {refused: ok(eq.MsgText() == ItemsModel.DupMessage()), stillEditing: ok(eq.AddText() == "Save"),
            entryKept: ok(ses.EntriesFor("equipment")[3].action == "removed")})
        eq.ClickCancel(), Sleep(90)
        lg.Info("selftest m6 equipment cancel", {button: eq.AddText(), formCleared: ok(eq.Shown("action") = "" && eq.FormEmpty()), rows: eq.RowCount(),
            noteExact: ok(notes() == "Notes: Swapped Item 1 (placeholder). Added 3 Item 2 (placeholder). Zz eq detail. Removed 5 Item 3 (placeholder).")})

        ; 5. remove (the confirm is skipped here); the others keep their order
        eq.RemoveNow(1), Sleep(90)
        lg.Info("selftest m6 equipment remove", {rows: eq.RowCount(),
            noteExact: ok(notes() == "Notes: Added 3 Item 2 (placeholder). Zz eq detail. Removed 5 Item 3 (placeholder)."),
            swappedGone: ok(!InStr(ses.NoteText, "Swapped")), stillUsed: ok(ses.IsUsed("equipment"))})
        eq.ClickRow("edit", 2), Sleep(60)
        eq.RemoveNow(1), Sleep(90)                                  ; removing an earlier entry while editing keeps the form on the same entry
        lg.Info("selftest m6 equipment remove while editing", {editIdx: eq.EditIdx, action: eq.Shown("action"), rows: eq.RowCount()})
        eq.RemoveNow(1), Sleep(90)
        lg.Info("selftest m6 equipment all removed", {rows: eq.RowCount(), empty: ok(eq.EmptyShown()), fragments: ses.Fragments("equipment").Length,
            formCleared: ok(eq.FormEmpty() && eq.EditIdx = 0), noteMentionsItem: ok(InStr(ses.NoteText, "Item") > 0), stillUsed: ok(ses.IsUsed("equipment"))})

        ; 6. Billing: every outcome; "completed" only when Completed was picked
        bl.Click("action", "added"), bl.Click("item", "item2"), bl.Click("outcome", "completed"), Sleep(90)
        prevB := bl.PreviewText()
        bl.ClickAdd(), Sleep(90)
        t1 := notes()
        bl.Click("action", "removed"), bl.Click("item", "item3"), bl.Click("outcome", "requested"), Sleep(90)
        bl.ClickAdd(), Sleep(90)
        t2 := notes()
        bl.Click("action", "changed"), bl.Click("item", "item4"), bl.Click("outcome", "unable"), bl.TypeInto("details", "Zz bill detail"), Sleep(90)
        bl.ClickAdd(), Sleep(90)
        t3 := notes()
        fr := ses.Fragments("billing")
        stripped := (x) => StrReplace(StrReplace(x, "not yet completed", ""), "unable to complete", "")
        lg.Info("selftest m6 billing", {outcomeControl: bl.ControlKind("outcome"), previewExact: ok(prevB == "Will add: Added Item 2 (placeholder) - completed."),
            completedExact: ok(t1 == "Notes: Added Item 2 (placeholder) - completed."),
            requestedExact: ok(t2 == "Notes: Added Item 2 (placeholder) - completed. Removed Item 3 (placeholder) - requested, not yet completed."),
            unableExact: ok(t3 == "Notes: Added Item 2 (placeholder) - completed. Removed Item 3 (placeholder) - requested, not yet completed. Changed Item 4 (placeholder) Zz bill detail - unable to complete."),
            fragments: fr.Length, completedOnlyInFirst: ok(InStr(fr[1], "completed") > 0 && InStr(stripped(fr[2]), "completed") = 0 && InStr(fr[3], "completed") = 0),
            requestedHasNotYet: ok(InStr(fr[2], "not yet completed") > 0), unableNoCompleted: ok(InStr(fr[3], "completed") = 0), rows: bl.RowCount(),
            qtyBoxAbsent: ok(bl.ControlKind("qty") = ""), used: ok(ses.IsUsed("billing")), railDot: ok(this.HasRailDot("billing"))})
        n0 := bl.RowCount()
        bl.Click("action", "changed"), bl.Click("item", "item5"), Sleep(90)
        bl.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 billing no outcome", {refused: ok(bl.RowCount() = n0), hints: bl.HintsOn(), hintText: ok(InStr(bl.HintText("outcome"), "outcome") > 0),
            nothingInNote: ok(!InStr(ses.NoteText, "Item 5")), draft: ok(bl.HasDraft())})
        bl.Click("outcome", "unable"), Sleep(90)
        lg.Info("selftest m6 billing hint cleared", {hints: bl.HintsOn(),
            previewExact: ok(bl.PreviewText() == "Will add: Changed Item 5 (placeholder) - unable to complete.")})
        bl.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 billing fourth", {rows: bl.RowCount(), noCompletedClaim: ok(InStr(stripped(ses.Fragments("billing")[4]), "completed") = 0)})

        ; 7. the combined note: Not Done, Equipment, Billing in config order, whatever the order they were filled in
        nd.ClickOption("reason", "r1"), Sleep(60)
        nd.ClickOption("orderType", "sro"), Sleep(60)
        nd.ClickOption("contact", "c1"), Sleep(60)
        nd.ClickOption("outcome", "o1"), Sleep(60)
        eq.Click("action", "swapped"), eq.Click("item", "item1"), Sleep(60)
        eq.ClickAdd(), Sleep(90)
        full := ses.NoteText
        expC := "Notes: Reason 1 placeholder note. Order type SRO placeholder note. Contact 1 placeholder note. Outcome 1 placeholder note."
            . "`r`nSwapped Item 1 (placeholder)."
            . "`r`nAdded Item 2 (placeholder) - completed. Removed Item 3 (placeholder) - requested, not yet completed."
            . " Changed Item 4 (placeholder) Zz bill detail - unable to complete. Changed Item 5 (placeholder) - unable to complete."
        lg.Info("selftest m6 combined", {notesExact: ok(notes() == expC), usedOrder: ses.UsedCategories().Length,
            templateLines: ok(InStr(full, "Tech name: ") = 1 && InStr(full, "Job Number: ") > 0), boxMatches: ok(Composer.Crlf(this.NotesText) == full),
            missingRequired: app.MissingRequired().Length})

        ; 8. History: the entries are saved, cleared with the call and come back exactly; the lists are drawn again
        eqRows := eq.RowTexts(), blRows := bl.RowTexts()
        canon := ConfigJson.Canon(ses.Snapshot()["categories"])
        cats := ses.Snapshot()["categories"]
        snapHas := ok(cats.Has("equipment") && cats["equipment"].Has("entries") && cats["billing"]["entries"].Length = 4)
        n0 := hs.List(day()).Length
        this.ClearAllNow()
        fileText := FileRead(hs.FileFor(day()), "UTF-8")
        lg.Info("selftest m6 history saved", {entriesAdded: hs.List(day()).Length - n0, snapshotHasEntries: snapHas, fileHasEntries: ok(InStr(fileText, '"entries"') > 0),
            clearedEq: ses.EntriesFor("equipment").Length, clearedBl: ses.EntriesFor("billing").Length, eqRows: eq.RowCount(), blRows: bl.RowCount(),
            emptyShown: ok(eq.EmptyShown() && bl.EmptyShown()), formsClear: ok(eq.FormEmpty() && bl.FormEmpty())})
        id := hs.List(day())[1].Id
        r := app.LoadFromHistory(id, true)
        Sleep(90)
        lg.Info("selftest m6 history loaded", {ok: ok(r.Ok), identical: ok(ConfigJson.Canon(ses.Snapshot()["categories"]) == canon), eqRows: eq.RowCount(),
            blRows: bl.RowCount(), eqRowsSame: ok(eq.RowTexts() == eqRows), blRowsSame: ok(bl.RowTexts() == blRows),
            noteBack: ok(InStr(ses.NoteText, "Changed Item 4 (placeholder) Zz bill detail - unable to complete.") > 0),
            emptyGone: ok(!eq.EmptyShown() && !bl.EmptyShown()), railEq: ok(this.HasRailDot("equipment")), railBl: ok(this.HasRailDot("billing"))})
        eq.ClickRow("edit", 1), Sleep(90)
        eq.TypeInto("qty", "7"), eq.ClickAdd(), Sleep(90)
        lg.Info("selftest m6 history edit", {saved: ok(ses.EntriesFor("equipment")[1].qty == "7"), noteHas7: ok(InStr(ses.NoteText, "Swapped 7 Item 1 (placeholder).") > 0)})
        bl.RemoveNow(4), Sleep(90)
        lg.Info("selftest m6 history remove", {blRows: bl.RowCount(), item5Gone: ok(!InStr(ses.NoteText, "Item 5"))})

        ; 9. Copy Notes: an unadded entry asks first (Go back jumps to the page); a complete page does not ask
        store := {v: ""}
        this.ClipHooks := {Set: (s) => (store.v := s, true), Get: () => store.v}
        asked := {n: 0, answer: false, text: ""}
        this.AutoConfirm := (t) => (asked.n += 1, asked.text := t, asked.answer)
        g.ShowPage("billing")
        Sleep(60)
        c0 := this.CopyNotes()
        lg.Info("selftest m6 copy no draft", {copied: ok(c0), asked: asked.n, clipboardHasNote: ok(store.v != "")})
        store.v := ""
        eq.Click("action", "added"), Sleep(60)
        draft := ok(eq.HasDraft())
        c1 := this.CopyNotes()
        lg.Info("selftest m6 copy declined", {draft: draft, copied: ok(c1), asked: asked.n,
            textExact: ok(asked.text == "Equipment has an entry that wasn't added. Copy without it?"), clipboardEmpty: ok(store.v = ""),
            jumpedToPage: ok(g.CurrentPage = "equipment"), formKept: ok(eq.Shown("action") = "added")})
        asked.answer := true
        c2 := this.CopyNotes()
        lg.Info("selftest m6 copy anyway", {copied: ok(c2), asked: asked.n, clipboardHasNote: ok(InStr(store.v, "Swapped 7 Item 1 (placeholder).") > 0)})
        eq.CancelNow(), Sleep(60)
        bl.Click("item", "item5"), Sleep(60)                         ; a draft with only an item chosen also counts
        asked.answer := false
        n := asked.n
        c3 := this.CopyNotes()
        lg.Info("selftest m6 copy draft billing", {copied: ok(c3), asked: asked.n - n,
            textExact: ok(asked.text == "Billing has an entry that wasn't added. Copy without it?"), jumpedToPage: ok(g.CurrentPage = "billing")})
        bl.CancelNow(), Sleep(60)
        eq.ClickRow("edit", 1), Sleep(60)                            ; editing without a change is not a draft
        n := asked.n
        c4 := this.CopyNotes()
        lg.Info("selftest m6 copy editing unchanged", {copied: ok(c4), asked: asked.n - n})
        eq.CancelNow(), Sleep(60)
        this.AutoConfirm := "", this.ClipHooks := ""

        ; 10. a call that ends with an unadded draft: Clear All is not blocked and the forms are empty afterwards
        eq.Click("action", "removed"), eq.TypeInto("details", "Zz leftover"), Sleep(60)
        draftBefore := ok(eq.HasDraft())
        cleared := this.ClearAllNow()
        Sleep(60)
        lg.Info("selftest m6 clear with draft", {draft: draftBefore, cleared: ok(cleared), formEmpty: ok(eq.FormEmpty() && bl.FormEmpty()),
            rows: eq.RowCount() "," bl.RowCount(), actionCleared: ok(eq.Shown("action") = ""), detailsBox: ok(eq.InputText("details") = "")})
        lg.Info("selftest m6 done", {sessionContent: ok(ses.HasContent()), eqEntries: ses.EntriesFor("equipment").Length, blEntries: ses.EntriesFor("billing").Length})
        this.RunStaticSelfTest(clk)
    }

    ; Static page (M7): the IP box (Enter / paste / blur), the prefix and mask forms, the gateway rule and its errors, the manual
    ; gateway, the four result rows and copy buttons (no network / broadcast rows, no include box), the manual ping outcome,
    ; "used" only after a ping outcome, History round trip and Copy Notes (no static question). IP addresses may appear in
    ; these lines (they are not tech data); no note text is logged.
    RunStaticSelfTest(clk) {
        g := this.G, lg := this.App.Logger, app := this.App
        ses := app.Session, hs := app.History, p := app.Provider, st := app.Stats
        sv := this.Statics["static"]
        day := () => Util.DateOfStamp(clk.Stamp)
        notes := () => SubStr(ses.NoteText, InStr(ses.NoteText, "Notes: "))
        ok := (b) => b ? 1 : 0
        used := () => ok(ses.IsUsed("static"))
        cnt := () => st.Today().ById.Has("static") ? st.Today().ById["static"] : 0
        base := {n: cnt()}
        credited := () => cnt() - base.n                              ; how many times the stats credited Static since this block began
        res := () => sv.ValueText("ip") "|" sv.ValueText("prefix") "|" sv.ValueText("mask") "|" sv.ValueText("gateway")
        enter := (txt) => (sv.TypeInto("ip", txt), sv.PressEnter("ip"), Sleep(90))
        this.Advance(clk, 10)
        p.FireNewCall()
        g.ShowPage("static")
        Sleep(60)
        sv.Render(true)
        copyAny := 0
        for f in StaticView.FIELDS
            copyAny += sv.CopyShown(f[1]) ? 1 : 0
        lg.Info("selftest m7 start", {staticPages: this.Statics.Count, ipPlaceholder: sv.Placeholder("ip"), prefixBox: ok(sv.BoxValue("prefix") = ""),
            ipBox: ok(sv.BoxValue("ip") = ""), resultsEmpty: ok(res() = "|||"), copyButtonsShown: copyAny, resultRows: sv.RowCount(),
            networkRowAbsent: ok(!sv.Exists(sv.ValId("network")) && !sv.Exists(sv.CopyId("network"))),
            broadcastRowAbsent: ok(!sv.Exists(sv.ValId("broadcast")) && !sv.Exists(sv.CopyId("broadcast"))),
            noCheckbox: ok(sv.CheckboxCount() = 0 && !sv.Exists("nfsSTinc_static")), noNotesCard: ok(!InStr(g.El(sv.FormId).innerText, "Static notes")),
            targetShown: sv.ShownChoice("target"), outcomeShown: ok(sv.ShownChoice("outcome") = ""), manualBoxShown: ok(sv.IsShown(sv.WrapId())),
            pingTip: sv.BtnTip(sv.PingBtnId()), pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId())),
            noReplyNote: ok(InStr(g.El(sv.FormId).innerText, StaticView.NO_REPLY_NOTE) > 0),
            devSampleForStatic: IsObject(this.Dev) ? ok(InStr(this.Dev.Build(), "devFrag_static") > 0) : -1,
            sampleRefused: ok(!app.AddSampleFragment("static")), unused: used()})

        ; 1. the required case: 1.1.1.1/30 + Enter splits into IP and prefix and calculates the gateway
        enter("1.1.1.1/30")
        s := sv.State
        lg.Info("selftest m7 enter", {ipBox: sv.BoxValue("ip"), prefixBox: sv.BoxValue("prefix"), results: res(), ip: s.ip, prefix: s.prefix,
            mask: s.mask, gateway: s.gateway, ready: ok(s.ready), hints: sv.HintsOn(), copyGateway: ok(sv.CopyShown("gateway")),
            manualBox: ok(sv.IsShown(sv.WrapId())), manualLink: ok(sv.IsShown(sv.ShowManualId())), usedAfterTyping: used(),
            railDot: ok(this.HasRailDot("static")), credited: credited(), noteBoxEmpty: ok(this.NotesText = ""), sessionContent: ok(ses.HasContent())})

        ; 2. copy buttons copy just that value (injected clipboard)
        store := {v: ""}
        this.ClipHooks := {Set: (s) => (store.v := s, true), Get: () => store.v}
        got := ""
        for f in StaticView.FIELDS {
            store.v := ""
            sv.ClickEl(sv.CopyId(f[1])), Sleep(40)
            got .= store.v ";"
        }
        lg.Info("selftest m7 copy", {values: got, toast: ok(InStr(g.El("axToast").innerText, "copied") > 0)})
        this.ClipHooks := {Set: (s) => true, Get: () => "other"}
        failed := sv.CopyNow("gateway")
        lg.Info("selftest m7 copy fails", {copied: ok(failed), errorShown: ok(InStr(g.El("axToast").innerText, "Clipboard is in use") > 0)})
        this.ClipHooks := ""

        ; 3. paste (the handler the document paste event ends in) and the link that reveals the manual box
        sv.TypeInto("ip", "1.1.1.9/29")
        pasted := sv.PasteCheck("ip"), Sleep(90)
        lg.Info("selftest m7 paste", {box: pasted, results: res(), ipBox: sv.BoxValue("ip"), prefixBox: sv.BoxValue("prefix")})
        el := g.El(sv.BoxId("ip"))
        el.value := "1.1.1.17/28"
        try el.focus()
        focused := ok(g.Doc.activeElement.id = sv.BoxId("ip"))
        viaActive := sv.PasteCheck()
        Sleep(90)
        lg.Info("selftest m7 paste active", {focused: focused, boxFound: viaActive, gateway: sv.ValueText("gateway")})
        lg.Info("selftest m7 manual link", {linkShown: ok(sv.IsShown(sv.ShowManualId())), boxHidden: ok(!sv.IsShown(sv.WrapId()))})
        sv.ClickEl(sv.ShowManualId()), Sleep(90)
        lg.Info("selftest m7 manual link clicked", {boxShown: ok(sv.IsShown(sv.WrapId())), linkHidden: ok(!sv.IsShown(sv.ShowManualId())),
            useAutoLink: ok(sv.IsShown(sv.AutoLinkId()))})
        sv.ClickEl(sv.AutoLinkId()), Sleep(90)

        ; 4. errors, each next to its field: network / broadcast address, bad octets, loopback, bad prefix
        errs := ""
        for tx in ["1.1.1.0/30", "1.1.1.3/30", "192.168.1.254/24", "256.1.1.1/30", "01.1.1.1/30", "127.0.0.1/8", "224.0.0.1/8", "1.1.1.1/abc", "1.1.1.1/33", "1.1.1.1/7", "1.1.1/30", "1.1.1.1/255.0.255.0"] {
            enter(tx)
            s := sv.State
            errs .= tx " -> ip:" ok(sv.HintText("ip") != "") " prefix:" ok(sv.HintText("prefix") != "") " gw:" ok(sv.HintText("gateway") != "")
                . " manualBox:" ok(sv.IsShown(sv.WrapId())) " gateway:" (s.gateway = "" ? "none" : s.gateway) " | "
        }
        lg.Info("selftest m7 errors", {table: errs})
        enter("1.1.1.0/30")
        lg.Info("selftest m7 network error", {hint: sv.HintText("gateway"), manualBox: ok(sv.IsShown(sv.WrapId())), copyGateway: ok(sv.CopyShown("gateway")),
            networkRow: ok(sv.Exists(sv.ValId("network"))), broadcastRow: ok(sv.Exists(sv.ValId("broadcast")))})

        ; 5. IP+1 is the broadcast address: the error, the manual box and the manual gateway cases
        enter("1.1.1.2/30")
        lg.Info("selftest m7 plus one", {hint: sv.HintText("gateway"), manualBox: ok(sv.IsShown(sv.WrapId())), gateway: sv.ValueText("gateway"),
            copyGateway: ok(sv.CopyShown("gateway")), prefixBox: sv.BoxValue("prefix")})
        man := ""
        for tx in ["1.1.1.2", "1.1.1.3", "1.1.1.0", "1.1.2.1", "abc", "127.0.0.1", "1.1.1.1"] {
            sv.TypeInto("manual", tx), sv.PressEnter("manual"), Sleep(60)
            man .= tx "=" ok(sv.ValueText("gateway") != "") ok(sv.HintText("manual") != "") ";"
        }
        lg.Info("selftest m7 manual cases", {table: man, finalGateway: sv.ValueText("gateway"), tagShown: ok(sv.IsShown(sv.TagId())),
            manualHintGone: ok(sv.HintText("manual") = ""), gatewayHintGone: ok(sv.HintText("gateway") = ""), manualState: ok(sv.State.gatewayManual),
            usedAfterManual: used()})
        sv.TypeInto("manual", ""), sv.PressEnter("manual"), Sleep(60)
        enter("10.0.0.4/31")
        lg.Info("selftest m7 slash 31", {hint: sv.HintText("gateway"), manualBox: ok(sv.IsShown(sv.WrapId())), gateway: sv.ValueText("gateway")})
        man := ""
        for tx in ["10.0.0.4", "10.0.0.6", "10.0.0.5"] {
            sv.TypeInto("manual", tx), sv.PressEnter("manual"), Sleep(60)
            man .= tx "=" ok(sv.ValueText("gateway") != "") ";"
        }
        lg.Info("selftest m7 slash 31 manual", {table: man, gateway: sv.ValueText("gateway")})
        sv.TypeInto("manual", ""), sv.PressEnter("manual"), Sleep(60)
        enter("10.0.0.9/32")
        lg.Info("selftest m7 slash 32", {hint: ok(sv.HintText("gateway") != ""), manualBox: ok(sv.IsShown(sv.WrapId())), gateway: sv.ValueText("gateway")})
        sv.TypeInto("manual", ""), sv.PressEnter("manual"), Sleep(60)

        ; 6. prefix / mask forms
        forms := ""
        for tx in ["8.8.8.8 255.255.255.0", "172.16.5.1/255.255.0.0", "10.0.0.1 / 8", "10.0.255.255/8", "192.168.1.253/24", "  1.1.1.1/30  "] {
            enter(tx)
            forms .= tx " => " sv.ValueText("ip") "/" sv.ValueText("prefix") "/" sv.ValueText("mask") " gw " sv.ValueText("gateway") " | "
        }
        lg.Info("selftest m7 forms", {table: forms})
        enter("1.1.1.1/30")
        pf := ""
        for tx in ["255.255.255.0", "/28", "27", "255.0.255.0", "/31", "abc"] {
            sv.TypeInto("prefix", tx), sv.PressEnter("prefix"), Sleep(60)
            pf .= tx " => " sv.BoxValue("prefix") "/" sv.ValueText("mask") " gw " sv.ValueText("gateway") " pHint:" ok(sv.HintText("prefix") != "") " | "
        }
        lg.Info("selftest m7 prefix box", {table: pf})
        sv.TypeInto("prefix", "30"), sv.PressEnter("prefix"), Sleep(60)
        lg.Info("selftest m7 prefix back", {results: res(), prefixBox: sv.BoxValue("prefix")})
        ; blur: a changed box is read when it loses the focus (the library's change / focusout hook)
        sv.TypeInto("ip", "1.1.1.5/29")
        sv.OnBox("ip", "focusout")
        Sleep(90)
        lg.Info("selftest m7 blur", {results: res()})
        enter("1.1.1.1/30")

        ; 7. typing, calculating and a manual gateway never put anything in the note or use the category
        enter("1.1.1.1/30")
        sv.TypeInto("manual", ""), sv.PressEnter("manual"), Sleep(60)
        lg.Info("selftest m7 typing only", {used: used(), railDot: ok(this.HasRailDot("static")), credited: credited(), noStaticLine: ok(!InStr(ses.NoteText, "Static IP")),
            fragments: ses.Fragments("static").Length, noteBoxEmpty: ok(this.NotesText = ""), sessionContent: ok(ses.HasContent())})
        enter("1.1.1.2/30")
        sv.TypeInto("manual", "1.1.1.1"), sv.PressEnter("manual"), Sleep(90)
        lg.Info("selftest m7 manual gateway only", {gateway: sv.ValueText("gateway"), used: used(), fragments: ses.Fragments("static").Length,
            noManualSentence: ok(!InStr(ses.NoteText, "entered manually")), noteBoxEmpty: ok(this.NotesText = "")})
        sv.ClickEl(sv.AutoLinkId()), Sleep(60)
        enter("1.1.1.1/30")

        ; 8. ping outcome (manual): target + outcome -> fragment; this is the only way the page adds to the note
        pre := used()
        sv.ClickChoice("target", "gateway"), sv.ClickChoice("outcome", "reply"), Sleep(120)
        lg.Info("selftest m7 ping reply", {target: sv.ShownChoice("target"), outcome: sv.ShownChoice("outcome"), usedBefore: pre, usedAfter: used(), credited: credited(),
            railDot: ok(this.HasRailDot("static")),
            noteExact: ok(notes() == "Notes: Ping to Gateway 1.1.1.2: reply received (placeholder wording)."),
            addr: sv.ElText(sv.AddrId()), confirmShown: ok(sv.IsShown(sv.ConfirmWrapId())), clearShown: ok(sv.IsShown(sv.ClearId()))})
        sv.ClickChoice("target", "ip"), sv.ClickChoice("outcome", "noReply"), Sleep(120)
        lg.Info("selftest m7 ping no reply", {noteHasIp: ok(InStr(ses.NoteText, "Ping to IP 1.1.1.1: no reply (placeholder wording).") > 0),
            noOldPing: ok(!InStr(ses.NoteText, "reply received")), fragments: ses.Fragments("static").Length})
        lg.Info("selftest m7 only the ping line", {noteExact: ok(notes() == "Notes: Ping to IP 1.1.1.1: no reply (placeholder wording)."), stillUsed: used()})
        sv.ClickEl(sv.ClearId()), Sleep(120)
        lg.Info("selftest m7 ping cleared", {outcome: ok(sv.ShownChoice("outcome") = ""), noPing: ok(!InStr(ses.NoteText, "Ping to")), fragments: ses.Fragments("static").Length,
            clearHidden: ok(!sv.IsShown(sv.ClearId())), stillUsed: used()})
        enter("1.1.1.0/30")
        sv.ClickChoice("target", "gateway"), sv.ClickChoice("outcome", "reply"), Sleep(120)
        lg.Info("selftest m7 ping invalid address", {noLine: ok(!InStr(ses.NoteText, "Ping to")), hint: ok(sv.HintText("ping") != ""),
            addr: sv.ElText(sv.AddrId())})

        ; 9. a category is used only after a ping outcome (not after typing an IP) - a fresh call
        this.ClearAllNow()
        Sleep(60)
        lg.Info("selftest m7 cleared", {state: ok(sv.State.ipInput = ""), ipBox: ok(sv.BoxValue("ip") = ""), prefixBox: ok(sv.BoxValue("prefix") = ""),
            manualBox: ok(sv.BoxValue("manual") = ""), results: ok(res() = "|||"), outcome: ok(sv.ShownChoice("outcome") = ""),
            target: sv.ShownChoice("target"), used: used(), sessionStatic: ok(ses.HasStaticInput())})
        enter("1.1.1.1/30")
        a := used()
        sv.ClickChoice("outcome", "reply"), Sleep(120)
        lg.Info("selftest m7 used by outcome", {usedAfterTyping: a, usedAfterOutcome: used(), railDot: ok(this.HasRailDot("static")), credited: credited(),
            noteExact: ok(notes() == "Notes: Ping to Gateway 1.1.1.2: reply received (placeholder wording).")})
        this.ClearAllNow()
        Sleep(60)

        ; 10. the M8 seam: a prefilled outcome is not in the note and does not use the category until it is confirmed
        enter("1.1.1.1/30")
        r := app.StaticPrefillPing("static", "noReply")
        Sleep(120)
        b := used()
        lg.Info("selftest m7 prefilled", {accepted: ok(r), outcomeShown: sv.ShownChoice("outcome"), confirmShown: ok(sv.IsShown(sv.ConfirmWrapId())), usedBefore: b,
            noPing: ok(!InStr(ses.NoteText, "Ping to")), confirmedState: ok(sv.State.pingConfirmed)})
        sv.ClickEl(sv.ConfirmId()), Sleep(120)
        lg.Info("selftest m7 confirmed", {confirmedState: ok(sv.State.pingConfirmed), confirmHidden: ok(!sv.IsShown(sv.ConfirmWrapId())), used: used(),
            noteExact: ok(notes() == "Notes: Ping to Gateway 1.1.1.2: no reply (placeholder wording)."), unknownRefused: ok(!app.StaticPrefillPing("static", "nope"))})
        this.ClearAllNow()
        Sleep(60)

        ; 11. History: the state is saved with the call, cleared with it and comes back exactly (boxes, results, checkbox, note)
        enter("1.1.1.2/30")
        sv.TypeInto("manual", "1.1.1.1"), sv.PressEnter("manual"), Sleep(60)
        sv.ClickChoice("target", "ip"), sv.ClickChoice("outcome", "reply"), Sleep(150)
        canon := ConfigJson.Canon(ses.Snapshot()["categories"]) "|" ConfigJson.Canon(ses.Snapshot()["categoriesUsed"])
        noteBefore := ses.NoteText
        resBefore := res()
        snap := ses.Snapshot()["categories"]
        n0 := hs.List(day()).Length
        this.ClearAllNow()
        Sleep(60)
        fileText := FileRead(hs.FileFor(day()), "UTF-8")
        lg.Info("selftest m7 history saved", {entriesAdded: hs.List(day()).Length - n0, snapshotHasStatic: ok(snap.Has("static") && snap["static"].Has("static")),
            fileHasStatic: ok(InStr(fileText, '"static": {') > 0 && InStr(fileText, '"ipInput": "1.1.1.2"') > 0), cleared: ok(sv.BoxValue("ip") = "" && res() = "|||"),
            stateCleared: ok(!ses.HasStaticInput())})
        id := hs.List(day())[1].Id
        r := app.LoadFromHistory(id, true)
        Sleep(120)
        lg.Info("selftest m7 history loaded", {ok: ok(r.Ok), identical: ok(ConfigJson.Canon(ses.Snapshot()["categories"]) "|" ConfigJson.Canon(ses.Snapshot()["categoriesUsed"]) == canon),
            noteBack: ok(ses.NoteText == noteBefore), resultsBack: ok(res() == resBefore), ipBox: sv.BoxValue("ip"), prefixBox: sv.BoxValue("prefix"), manualBox: sv.BoxValue("manual"),
            manualShown: ok(sv.IsShown(sv.WrapId())), target: sv.ShownChoice("target"), outcome: sv.ShownChoice("outcome"),
            railDot: ok(this.HasRailDot("static")), tag: ok(sv.IsShown(sv.TagId()))})
        pingBack := ok(InStr(ses.NoteText, "Ping to IP 1.1.1.2: reply received") > 0)
        sv.ClickEl(sv.ClearId()), Sleep(120)                         ; the loaded call keeps working
        lg.Info("selftest m7 history edit", {pingBack: pingBack, lineGone: ok(!InStr(ses.NoteText, "Ping to")), noStaticLine: ok(!InStr(ses.NoteText, "Static IP details"))})
        this.ClearAllNow()
        Sleep(60)

        ; 12. Copy Notes: there is no static question any more, with a valid or an invalid IP typed
        store := {v: ""}
        this.ClipHooks := {Set: (s) => (store.v := s, true), Get: () => store.v}
        asked := {n: 0, answer: false, text: ""}
        this.AutoConfirm := (t) => (asked.n += 1, asked.text := t, asked.answer)
        enter("1.1.1.1/30")
        sv.ClickChoice("target", "gateway"), sv.ClickChoice("outcome", "reply"), Sleep(120)
        g.ShowPage("billing")
        Sleep(60)
        c1 := this.CopyNotes()
        lg.Info("selftest m7 copy valid", {copied: ok(c1), asked: asked.n, clipboardHasPing: ok(InStr(store.v, "Ping to Gateway 1.1.1.2: reply received") > 0),
            noStaticLine: ok(!InStr(store.v, "Static IP details"))})
        enter("1.1.1.0/30")
        n := asked.n
        store.v := ""
        c2 := this.CopyNotes()
        lg.Info("selftest m7 copy invalid ip", {copied: ok(c2), askedAgain: asked.n - n, stayedOnPage: ok(g.CurrentPage = "billing")})
        this.AutoConfirm := "", this.ClipHooks := ""

        ; 13. typed text that was never submitted is picked up by Flush; Clear All with only an IP typed still empties the boxes
        this.ClearAllNow()
        Sleep(60)
        sv.TypeInto("ip", "10.1.1.1/24")
        before := sv.State.ipInput
        sv.Flush()
        lg.Info("selftest m7 flush", {before: before = "" ? "empty" : before, after: sv.State.ipInput, gateway: sv.State.gateway, used: used()})
        this.ClearAll()
        Sleep(60)
        lg.Info("selftest m7 clear typed only", {ipBox: ok(sv.BoxValue("ip") = ""), prefixBox: ok(sv.BoxValue("prefix") = ""), results: ok(res() = "|||"),
            stateCleared: ok(!ses.HasStaticInput())})
        lg.Info("selftest m7 done", {sessionContent: ok(ses.HasContent()), staticInput: ok(ses.HasStaticInput()), hints: sv.HintsOn()})
        this.RunPingSelfTest(clk)
    }


    ; ---------------------------------------------------------------------------------------------------------------------
    ; Pinger (M8): REAL ICMP through the Windows API (127.0.0.1 and 192.0.2.1, TEST-NET-1, never routed), through the page's buttons
    ; and the App. Logs flags, counts and IP addresses only (no tech data, no note text).
    ProcHandles() {
        n := 0
        DllCall("kernel32\GetProcessHandleCount", "ptr", DllCall("kernel32\GetCurrentProcess", "ptr"), "uint*", &n, "int")
        return n
    }

    ; Sleep (so the 50 ms timer and the UI keep running) until the current run is over / every run has drained.
    PingWait(maxMs := 9000) {
        pg := this.App.Pinger
        end := A_TickCount + maxMs
        while (pg.Running && A_TickCount < end)
            Sleep(30)
        return !pg.Running
    }

    PingIdle(maxMs := 8000) {
        pg := this.App.Pinger
        end := A_TickCount + maxMs
        while (!pg.Idle && A_TickCount < end)
            Sleep(30)
        return pg.Idle
    }

    RunPingSelfTest(clk) {
        g := this.G, lg := this.App.Logger, app := this.App
        ses := app.Session, hs := app.History, p := app.Provider, st := app.Stats, pg := app.Pinger
        sv := this.Statics["static"]
        day := () => Util.DateOfStamp(clk.Stamp)
        ok := (b) => b ? 1 : 0
        used := () => ok(ses.IsUsed("static"))
        cnt := () => st.Today().ById.Has("static") ? st.Today().ById["static"] : 0
        base := {n: cnt()}
        credited := () => cnt() - base.n
        enter := (txt) => (sv.TypeInto("ip", txt), sv.PressEnter("ip"), Sleep(90))
        firstLine := (r) => (IsObject(r) && r.Lines.Length > 0) ? r.Lines[1] : ""
        g.ShowPage("static")
        Sleep(60)
        this.ClearAllNow()
        sv.Render(true)
        Sleep(60)

        ; 0. no valid address: the buttons are off and say why; Cancel is off; a click starts nothing
        gwTip := sv.BtnTip(sv.PingBtnId())
        sv.ClickChoice("target", "ip"), Sleep(100)
        r1 := sv.OnPingClick("count")
        lg.Info("selftest m8 start", {gatewayTip: gwTip, ipTip: sv.BtnTip(sv.UntilBtnId()), pingOn: ok(sv.BtnOn(sv.PingBtnId())), untilOn: ok(sv.BtnOn(sv.UntilBtnId())),
            cancelOn: ok(sv.BtnOn(sv.CancelBtnId())), clickStarted: ok(r1), noRun: ok(!IsObject(pg.Current)), consoleEmpty: ok(sv.ConsoleText() = ""),
            statusEmpty: ok(sv.StatusLine() = ""), noReplyStatement: ok(InStr(g.El(sv.FormId).innerText, StaticView.NO_REPLY_NOTE) > 0),
            refusedLoopback: ok(!pg.Start("count", "127.0.0.1").Ok), refusedBad: ok(!pg.Start("count", "256.1.1.1").Ok), stillNoRun: ok(pg.Idle)})
        sv.ClickChoice("target", "gateway"), Sleep(100)

        ; 1. REAL ping of 127.0.0.1, count mode, 2 attempts (the address override is the selftest hook; the page's own addresses cannot be loopback)
        enter("1.1.1.1/30")
        sv.ClickChoice("target", "gateway"), Sleep(100)
        okOn := ok(sv.BtnOn(sv.PingBtnId()))
        r := app.StartPing("static", "count", {Addr: "127.0.0.1", AllowLoopback: true, Attempts: 2, Interval: 250})
        Sleep(60)
        run := pg.Current
        lg.Info("selftest m8 loopback running", {started: ok(r.Ok), pingWasOn: okOn, running: ok(pg.Running), pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId())),
            pingTip: sv.BtnTip(sv.PingBtnId()), status: sv.StatusLine()})
        done := this.PingWait()
        Sleep(200)
        lg.Info("selftest m8 loopback done", {finished: ok(done), status: run.Status, attempts: run.Done, replies: run.Successes, line1: firstLine(run), consoleLines: run.Lines.Length,
            consoleShown: ok(InStr(sv.ConsoleText(), "Reply from 127.0.0.1") > 0), statusLine: sv.StatusLine(), outcome: sv.ShownChoice("outcome"),
            confirmRow: ok(sv.IsShown(sv.ConfirmWrapId())), confirmed: ok(sv.State.pingConfirmed), notInNote: ok(!InStr(ses.NoteText, "Ping to")), used: used(), credited: credited(),
            pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId())), backendClosed: ok(run.Drained)})
        sv.ClickEl(sv.ConfirmId()), Sleep(150)
        lg.Info("selftest m8 loopback confirmed", {confirmed: ok(sv.State.pingConfirmed), inNote: ok(InStr(ses.NoteText, "Ping to Gateway 1.1.1.2: reply received") > 0), used: used(),
            railDot: ok(this.HasRailDot("static")), credited: credited()})
        this.ClearAllNow()
        Sleep(60)

        ; 2. REAL ping of 192.0.2.1 (never routed), timeout 300 ms, 2 attempts: fails, prefills "No reply" (unconfirmed)
        enter("192.0.2.1/24")
        sv.ClickChoice("target", "ip"), Sleep(100)
        r := app.StartPing("static", "count", {Timeout: 300, Attempts: 2, Interval: 250})
        run := pg.Current
        done := this.PingWait()
        Sleep(200)
        lg.Info("selftest m8 unrouted", {started: ok(r.Ok), finished: ok(done), status: run.Status, attempts: run.Done, replies: run.Successes, line1: firstLine(run), statusLine: sv.StatusLine(),
            outcome: sv.ShownChoice("outcome"), confirmRow: ok(sv.IsShown(sv.ConfirmWrapId())), confirmed: ok(sv.State.pingConfirmed), notInNote: ok(!InStr(ses.NoteText, "Ping to")),
            used: used(), target: sv.ShownChoice("target")})
        this.PingIdle()

        ; 3. until success against 192.0.2.1 through the BUTTONS (config timeout 1000): a new run clears the unconfirmed prefill; cancel after ~1 s
        h0 := IcmpBackend.Outstanding
        sv.ClickEl(sv.UntilBtnId()), Sleep(100)
        run := pg.Current
        lg.Info("selftest m8 until running", {running: ok(pg.Running), mode: IsObject(run) ? run.Mode : "none", prefillCleared: ok(sv.ShownChoice("outcome") = "" && !sv.IsShown(sv.ConfirmWrapId())),
            pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId())), tip: sv.BtnTip(sv.PingBtnId())})
        Sleep(1000)
        a1 := run.Started
        statusBefore := sv.StatusLine()
        sv.ClickEl(sv.CancelBtnId())
        orph := run.Orphans
        lg.Info("selftest m8 cancelled", {status: run.Status, immediate: ok(run.Status = "cancelled" && !pg.Running), attemptsStarted: a1, orphans: orph,
            statusBefore: statusBefore, statusLine: sv.StatusLine(), cancelledShown: ok(InStr(sv.StatusLine(), "Cancelled") > 0), consoleEndsCancelled: ok(run.Lines[run.Lines.Length] = "Cancelled"),
            cancelOn: ok(sv.BtnOn(sv.CancelBtnId())), pingOn: ok(sv.BtnOn(sv.PingBtnId())), outcome: sv.ShownChoice("outcome") = "" ? "none" : sv.ShownChoice("outcome"),
            used: used(), outstandingNow: IcmpBackend.Outstanding - h0})
        Sleep(1300)
        idle := this.PingIdle()
        lg.Info("selftest m8 cancel cleanup", {idle: ok(idle), drained: ok(run.Drained), outstanding: IcmpBackend.Outstanding, graveyard: IcmpBackend.Graveyard.Length, orphansLeft: run.Orphans,
            noPrefill: ok(sv.ShownChoice("outcome") = ""), noNoteLine: ok(!InStr(ses.NoteText, "Ping to")), startedAfterCancel: run.Started - a1})

        ; 4. until-success cap (selftest hook: a short cap): stops at the cap, no reply, prefills "No reply"
        r := app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250, CapMs: 1500})
        run := pg.Current
        done := this.PingWait()
        Sleep(200)
        lg.Info("selftest m8 cap", {finished: ok(done), status: run.Status, attempts: run.Done, elapsedOk: ok(run.Elapsed() >= 1500 && run.Elapsed() < 3500), outcome: sv.ShownChoice("outcome"),
            confirmed: ok(sv.State.pingConfirmed), statusLine: sv.StatusLine(), lastLine: run.Lines.Length > 1 ? run.Lines[run.Lines.Length] : ""})
        this.PingIdle()

        ; 5. responsiveness during an until-success run: switch pages, type in the notes box, the attempts keep coming
        r := app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run := pg.Current
        s0 := run.Started
        pagesOk := 0, typedOk := 0, n := 0
        for pgd in MainWindow.PAGES {
            g.ShowPage(pgd[1])
            Sleep(150)
            pagesOk += g.CurrentPage = pgd[1] ? 1 : 0
            n += 1
            this.NotesText := "typed during ping " n
            Sleep(30)
            typedOk += this.NotesText = "typed during ping " n ? 1 : 0
        }
        g.ShowPage("static")
        Sleep(200)
        lg.Info("selftest m8 responsive", {pages: MainWindow.PAGES.Length, pageSwitchesOk: pagesOk, typingOk: typedOk, attemptsDuring: run.Started - s0, stillRunning: ok(pg.Running),
            statusLive: sv.StatusLine(), consoleLines: run.Lines.Length, backOnStatic: ok(g.CurrentPage = "static"), cancelOn: ok(sv.BtnOn(sv.CancelBtnId()))})
        app.CancelPing("selftest")
        this.PingIdle()
        this.NotesText := ""

        ; 6. a new call, Clear All and a History load each cancel a running ping and forget its console
        this.Advance(clk, 10)
        r := app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run := pg.Current
        Sleep(500)
        p.FireNewCall()
        Sleep(150)
        lg.Info("selftest m8 new call", {status: run.Status, cancelled: ok(run.Status = "cancelled"), runForgotten: ok(!IsObject(pg.Current)), consoleEmpty: ok(sv.ConsoleText() = ""),
            statusEmpty: ok(sv.StatusLine() = ""), ipCleared: ok(sv.BoxValue("ip") = ""), pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId())),
            noOutcome: ok(sv.ShownChoice("outcome") = "")})
        this.PingIdle()
        enter("192.0.2.1/24")
        sv.ClickChoice("target", "ip"), Sleep(100)
        r := app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run := pg.Current
        Sleep(400)
        this.ClearAllNow()
        Sleep(100)
        lg.Info("selftest m8 clear all", {status: run.Status, cancelled: ok(run.Status = "cancelled"), runForgotten: ok(!IsObject(pg.Current)), consoleEmpty: ok(sv.ConsoleText() = ""), ipCleared: ok(sv.BoxValue("ip") = "")})
        this.PingIdle()
        ; a saved call to load: IP + a confirmed outcome, then Clear All saves it
        enter("192.0.2.1/24")
        sv.ClickChoice("target", "ip"), sv.ClickChoice("outcome", "noReply"), Sleep(150)
        this.ClearAllNow()
        Sleep(60)
        hid := hs.List(day())[1].Id
        enter("10.20.30.1/24")
        sv.ClickChoice("target", "ip"), Sleep(100)
        r := app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run := pg.Current
        Sleep(400)
        lr := app.LoadFromHistory(hid, true)
        Sleep(150)
        lg.Info("selftest m8 history load", {loaded: ok(lr.Ok), status: run.Status, cancelled: ok(run.Status = "cancelled"), runForgotten: ok(!IsObject(pg.Current)), consoleEmpty: ok(sv.ConsoleText() = ""),
            ipBack: sv.BoxValue("ip"), outcome: sv.ShownChoice("outcome"), confirmed: ok(sv.State.pingConfirmed), pingOn: ok(sv.BtnOn(sv.PingBtnId())), cancelOn: ok(sv.BtnOn(sv.CancelBtnId()))})
        this.PingIdle()
        ; changing the target or the IP while running cancels the run
        this.ClearAllNow()
        enter("192.0.2.1/24")
        sv.ClickChoice("target", "ip"), Sleep(100)
        app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run := pg.Current
        Sleep(300)
        sv.ClickChoice("target", "gateway"), Sleep(100)
        c1 := ok(run.Status = "cancelled")
        sv.ClickChoice("target", "ip"), Sleep(100)
        app.StartPing("static", "untilSuccess", {Timeout: 300, Interval: 250})
        run2 := pg.Current
        Sleep(300)
        enter("192.0.2.9/24")
        lg.Info("selftest m8 target change", {targetChangeCancels: c1, ipChangeCancels: ok(run2.Status = "cancelled"), runKept: ok(IsObject(pg.Current))})
        this.PingIdle()
        this.ClearAllNow()
        Sleep(60)

        ; 7. no leaked handles: after a warm-up run, ten more runs (completed, cancelled, failed) leave the process handle count where it was
        app.StartPing("static", "count", {Addr: "127.0.0.1", AllowLoopback: true, Attempts: 1})
        this.PingWait(), this.PingIdle()
        Sleep(200)
        h1 := this.ProcHandles()
        k := 0
        loop 10 {
            sel := Mod(A_Index, 5)
            if (sel = 1) {
                app.StartPing("static", "count", {Addr: "127.0.0.1", AllowLoopback: true, Attempts: 1})
                this.PingWait()
            } else if (sel = 2) {
                app.StartPing("static", "untilSuccess", {Addr: "192.0.2.1", Timeout: 400, Interval: 250})
                Sleep(300)
                app.CancelPing("selftest")
            } else if (sel = 3) {
                app.StartPing("static", "untilSuccess", {Addr: "127.0.0.1", AllowLoopback: true, Interval: 250})
                app.CancelPing("selftest")                                    ; cancelled before the first reply came back
            } else if (sel = 4) {
                app.StartPing("static", "count", {Addr: "192.0.2.1", Timeout: 200, Attempts: 1})
                this.PingWait()
            } else {
                app.StartPing("static", "count", {Addr: "127.0.0.1", AllowLoopback: true, Attempts: 2, Interval: 250})
                Sleep(120)
                app.StartPing("static", "count", {Addr: "127.0.0.1", AllowLoopback: true, Attempts: 1})   ; a new run replaces the old one
                this.PingWait()
            }
            this.PingIdle()
            k += 1
        }
        Sleep(300)
        h2 := this.ProcHandles()
        lg.Info("selftest m8 handles", {runs: k, before: h1, after: h2, delta: h2 - h1, outstanding: IcmpBackend.Outstanding, graveyard: IcmpBackend.Graveyard.Length,
            idle: ok(pg.Idle), pinnedDlls: IcmpBackend.Pinned.Length})
        this.ClearAllNow()
        Sleep(60)
        ; 8. app exit while a request is in flight: OnAppExit cancels, waits for the request and cleans up
        enter("192.0.2.1/24")
        sv.ClickChoice("target", "ip"), Sleep(100)
        app.StartPing("static", "untilSuccess", {Timeout: 1000, Interval: 250})
        Sleep(300)
        t1 := A_TickCount
        app.OnAppExit("selftest", 0)
        lg.Info("selftest m8 exit cleanup", {tookMsOk: ok(A_TickCount - t1 < 1800), idle: ok(pg.Idle), outstanding: IcmpBackend.Outstanding, graveyard: IcmpBackend.Graveyard.Length})
        this.ClearAllNow()
        Sleep(60)
        lg.Info("selftest m8 done", {idle: ok(pg.Idle), running: ok(pg.Running), sessionContent: ok(ses.HasContent())})
        ThemeSelfTest(this).Run()
    }

    ; "id=count,..." of the stats' per-category counts for today (to prove loading credits nothing).
    StatsById() {
        s := ""
        for id, n in this.App.Stats.Today().ById
            s .= id "=" n ","
        return s
    }

    ItemOrder(sm) {
        s := ""
        for it in sm.Items
            s .= (s = "" ? "" : ",") it.id
        return s
    }
}
