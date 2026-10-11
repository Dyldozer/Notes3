#Requires AutoHotkey v2.0
; SettingsView.ahk - the Settings rail page (PLAN 9 / M9).
;
;   Appearance : Look (a preset from the config), Mode (Light / Dark / System), Accent (the look's colour, or a custom one:
;                8 swatches + a #RRGGBB box), Font (installed ones of Segoe UI / Calibri / Arial / Tahoma / Verdana), Text size.
;                Every change is previewed on the whole window at once and is NOT saved. Apply saves, Revert goes back to
;                the saved look, Restore defaults (asks first) resets the appearance settings and applies them.
;                Leaving the page or closing the window with unapplied changes asks "Keep these appearance changes?".
;   Window     : Keep on top (same state as the title-bar pin), Open History panel at start. Saved at once.
;   About      : version, config source and revision, the data folder (+ Open folder), the log level. Read-only.
;
; The draft (this.Draft) holds the five appearance values; the saved ones live in App.Settings. Theme.Resolve turns either
; into a look; MainWindow.ApplyLook paints it. The controls are plain HTML (selects, library segmented / check tags, spans)
; wired by id; handlers run through Guard so a failure is logged and never opens an AutoHotkey error box.

class SettingsView {
    static RootId := "nfsSettings"

    __New(win, app) {
        this.Win := win
        this.App := app
        this.Draft := Map()
        this.Built := false
        this.HexErr := ""
        this.HexText := ""                 ; what the colour box holds (also while it is invalid)
        this.AccKind := "look"             ; "look" | "custom"
        this.Fonts := ""                   ; installed fonts offered (set once; the tests may inject)
        this.WiredIds := Map()
        this._guards := Map()
        this.LoadDraft()
    }

    ; --- structure ------------------------------------------------------------------------------------------------
    Html() => '<div class="nfs-set" id="' SettingsView.RootId '"></div>'

    static Css() => "
    (
    .nfs-set-row { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; margin: 8px 0; }
    .nfs-set-k { -ms-flex: none; flex: none; width: 110px; font-size: .929rem; }
    .nfs-set-val { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; word-wrap: break-word; }
    .nfs-set-h { font-weight: 600; margin: 4px 0 8px 0; padding-bottom: 6px; }
    .nfs-set-custom { margin: 0 0 8px 110px; }
    .nfs-set-sws { margin-bottom: 8px; }
    .nfs-sw { display: inline-block; width: 24px; height: 24px; margin: 0 8px 4px 0; border-radius: 4px; cursor: pointer; box-sizing: border-box; }
    .nfs-set-hexrow { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; }
    .nfs-set-hexrow .textbox { width: 160px; margin-right: 10px; }
    .nfs-set-err { display: none; font-size: .857rem; font-weight: 600; }
    .nfs-set-state { display: none; margin: 10px 0 0 0; padding: 6px 10px; border-radius: 4px; font-size: .857rem; }
    .nfs-set-btns { margin: 12px 0 2px 0; }
    .nfs-set-btns .btn { margin-right: 8px; }
    .nfs-set-note { font-size: .857rem; margin: 2px 0 6px 0; }
    .nfs-set .nfs-st-dis { opacity: .45; cursor: not-allowed; }
    )"

    ; --- ids -----------------------------------------------------------------------------------------------------
    static ID_PRESET := "nfsSetPreset"
    static ID_MODE := "nfsSetMode"
    static ID_KIND := "nfsSetAccKind"
    static ID_HEX := "nfsSetHex"
    static ID_HEXERR := "nfsSetHexErr"
    static ID_FONT := "nfsSetFont"
    static ID_SIZE := "nfsSetSize"
    static ID_APPLY := "nfsSetApply"
    static ID_REVERT := "nfsSetRevert"
    static ID_RESTORE := "nfsSetRestore"
    static ID_STATE := "nfsSetState"
    static ID_CUSTOM := "nfsSetCustom"
    static ID_TOP := "nfsSetTop"
    static ID_HIST := "nfsSetHist"
    static ID_OPEN := "nfsSetOpen"
    SwId(i) => "nfsSw_" i

    ; --- values --------------------------------------------------------------------------------------------------
    Cfg() {
        try return this.App.Config.Config
        return ""
    }

    SavedValues() {
        m := Map()
        for k in Settings.APPEARANCE_KEYS
            m[k] := this.App.Settings.Get(k)
        return m
    }

    LoadDraft() {
        this.Draft := this.SavedValues()
        this.SyncKind()
    }

    ; The custom-colour state follows the draft: a custom accent means "custom".
    SyncKind() {
        this.AccKind := (this.Draft["accent"] != "") ? "custom" : "look"
        this.HexErr := ""
        this.HexText := this.Draft["accent"]
    }

    ; The preset a draft really means (an unknown or empty id is the config's default look).
    PresetOf(id) {
        presets := Theme.Presets(this.Cfg())
        p := Theme.FindPreset(presets, id)
        if (p = "")
            p := Theme.FindPreset(presets, Theme.DefaultPresetId(this.Cfg()))
        if (p = "")
            p := presets.Length ? presets[1] : Theme.BuiltInPreset()
        return p
    }

    ; Comparable form of a set of values: the empty/default spellings are folded into one.
    Norm(v) {
        p := this.PresetOf(v["preset"])
        m := Map()
        m["preset"] := p["id"]
        m["mode"] := v["mode"] != "" ? v["mode"] : (p["mode"] = "dark" ? "dark" : "light")
        ; the look's own colour chosen by hand is the same thing as "use the look's colour"
        m["accent"] := (v["accent"] != "" && StrUpper(v["accent"]) != StrUpper(p["accent"])) ? StrUpper(v["accent"]) : ""
        m["fontFamily"] := v["fontFamily"] = "Segoe UI" ? "" : v["fontFamily"]
        m["fontSize"] := v["fontSize"]
        return m
    }

    IsDirty() {
        a := this.Norm(this.Draft), b := this.Norm(this.SavedValues())
        for k in Settings.APPEARANCE_KEYS
            if (a[k] != b[k])
                return true
        return false
    }

    ; --- drawing -------------------------------------------------------------------------------------------------
    ; Called when the page is shown (and after a forced rebuild). Builds the controls once, then syncs them.
    Render(force := false) {
        g := this.Win.G
        el := ""
        try el := g.El(SettingsView.RootId)
        if !IsObject(el)
            return
        if (!this.Built || force) {
            if (this.Fonts = "")
                this.Fonts := IsObject(this.Win.FontNames) ? Theme.AvailableFonts(this.Win.FontNames) : Theme.AvailableFonts()
            MainWindow.SetTagHtml(el, this.Content())
            this.Built := true
            this.Wire()
        }
        if !this.IsDirty()                  ; (a draft whose Apply failed on leaving is kept, as the window still shows it)
            this.LoadDraft()
        this.Sync()
    }

    FontOfId(id) {
        for f in this.Fonts
            if (Theme.FontId(f) = id)
                return f
        return ""
    }

    Content() {
        e := (s) => Util.HtmlEscape(s)
        app := this.App
        h := '<ax-card><div class="nfs-set-h">Appearance</div>'
        pairs := []
        for p in Theme.Presets(this.Cfg())
            pairs.Push([p["id"], p["label"]])
        h .= '<div class="nfs-set-row"><span class="nfs-set-k">Look</span><ax-dropdown id="' SettingsView.ID_PRESET '" options="'
            . e(Theme.DdOptions(pairs)) '" value="" width="240"></ax-dropdown></div>'
        h .= '<div class="nfs-set-row"><span class="nfs-set-k">Mode</span><ax-segmented id="' SettingsView.ID_MODE
            . '" options="light:Light,dark:Dark,system:System" value=""></ax-segmented></div>'
        h .= '<div class="nfs-set-row"><span class="nfs-set-k">Accent</span><ax-segmented id="' SettingsView.ID_KIND
            . '" options="' e("look:Use the look's colour,custom:Custom colour") '" value=""></ax-segmented></div>'
        h .= '<div class="nfs-set-custom" id="' SettingsView.ID_CUSTOM '" style="display:none"><div class="nfs-set-sws">'
        for i, c in Theme.SWATCHES
            h .= '<span class="nfs-sw" id="' this.SwId(i) '" data-hex="' c '" data-tip="' c '" style="background:' c '"></span>'
        h .= '</div><div class="nfs-set-hexrow"><ax-text id="' SettingsView.ID_HEX '" value="" placeholder="#0099D8"></ax-text>'
            . '<span class="nfs-set-err" id="' SettingsView.ID_HEXERR '"></span></div></div>'
        pairs := []
        for fam in this.Fonts
            pairs.Push([Theme.FontId(fam), fam = "Segoe UI" ? "Segoe UI (default)" : fam])
        h .= '<div class="nfs-set-row"><span class="nfs-set-k">Font</span><ax-dropdown id="' SettingsView.ID_FONT '" options="'
            . e(Theme.DdOptions(pairs)) '" value="" width="240"></ax-dropdown></div>'
        pairs := []
        loop Settings.SIZE_MAX - Settings.SIZE_MIN + 1 {
            n := Settings.SIZE_MIN + A_Index - 1
            pairs.Push([n, n = Settings.SIZE_DEFAULT ? n " (default)" : n])
        }
        h .= '<div class="nfs-set-row"><span class="nfs-set-k">Text size</span><ax-dropdown id="' SettingsView.ID_SIZE '" options="'
            . e(Theme.DdOptions(pairs)) '" value="" width="240" height="220"></ax-dropdown></div>'
        h .= '<div class="nfs-set-state" id="' SettingsView.ID_STATE '">Unapplied changes: shown on the whole window, not saved yet. '
            . 'Apply keeps them; Revert goes back.</div>'
        h .= '<div class="nfs-set-btns"><span class="btn accent" id="' SettingsView.ID_APPLY '">Apply</span>'
            . '<span class="btn" id="' SettingsView.ID_REVERT '">Revert</span>'
            . '<span class="btn" id="' SettingsView.ID_RESTORE '">Restore defaults</span></div></ax-card>'

        h .= '<ax-card><div class="nfs-set-h">Window</div>'
            . '<div class="nfs-set-row"><ax-check id="' SettingsView.ID_TOP '">Keep on top</ax-check></div>'
            . '<div class="nfs-set-row"><ax-check id="' SettingsView.ID_HIST '">Open History panel at start</ax-check></div></ax-card>'

        h .= '<ax-card><div class="nfs-set-h">About</div>'
        for r in this.AboutRows()
            h .= '<div class="nfs-set-row"><span class="nfs-set-k">' e(r[1]) '</span><span class="nfs-set-val" id="nfsSetAb_' r[3] '">' e(r[2]) '</span></div>'
        h .= '<div class="nfs-set-row"><span class="nfs-set-k"></span><span class="btn" id="' SettingsView.ID_OPEN '">Open folder</span></div></ax-card>'
        return h
    }

    ; [label, text, key] for the About card (read-only).
    AboutRows() {
        app := this.App, cs := app.Config
        src := cs.Source
        rev := cs.Revision
        cfgText := src (rev != "" ? ", revision " rev : "")
        if (cs.Warnings.Length > 0)
            cfgText .= " " Chr(0x2014) " " cs.ChipTip()
        return [["Version", "NFS Notes " NFSApp.VERSION, "ver"],
            ["Config", cfgText, "cfg"],
            ["Data folder", SettingsView.DataDir(), "dir"],
            ["Log level", app.LogLevel, "log"]]
    }

    static DataDir() => Util.UserDataDir()

    ; --- wiring ------------------------------------------------------------------------------------------------------
    Wire() {
        g := this.Win.G
        grd := (name, a*) => ObjBindMethod(this, "Guard", name, a*)
        if !this.WiredIds.Has(SettingsView.ID_MODE) {
            g.OnValue(SettingsView.ID_PRESET, grd("OnPreset"))
            g.OnValue(SettingsView.ID_FONT, grd("OnFont"))
            g.OnValue(SettingsView.ID_SIZE, grd("OnSize"))
            g.OnValue(SettingsView.ID_MODE, grd("OnMode"))
            g.OnValue(SettingsView.ID_KIND, grd("OnKind"))
            g.OnValue(SettingsView.ID_TOP, grd("OnTop"))
            g.OnValue(SettingsView.ID_HIST, grd("OnHistOpen"))
            this.WiredIds[SettingsView.ID_MODE] := true
        }
        loop Theme.SWATCHES.Length
            g.On("click", this.SwId(A_Index), ObjBindMethod(this, "Guard", "OnSwatch", A_Index))
        for ev in ["keyup", "change", "focusout"]
            g.On(ev, SettingsView.ID_HEX, ObjBindMethod(this, "Guard", "OnHex", ev))
        g.On("click", SettingsView.ID_APPLY, grd("OnApplyClick"))
        g.On("click", SettingsView.ID_REVERT, grd("OnRevertClick"))
        g.On("click", SettingsView.ID_RESTORE, grd("OnRestoreClick"))
        g.On("click", SettingsView.ID_OPEN, grd("OnOpenFolder"))
    }

    ; Event hooks run through here: a failure is logged, never shown as an AutoHotkey error box.
    Guard(name, args*) {
        try return this.%name%(args*)
        catch as e {
            SplitPath(e.File, &f)
            this.App.Logger.Error("settings handler failed", {handler: name, error: e.Message, line: e.Line, file: f})
        }
    }

    ; --- showing the draft ---------------------------------------------------------------------------------------------
    Sync() {
        if !this.Built
            return
        g := this.Win.G
        d := this.Draft
        n := this.Norm(d)
        this.SyncDropdown(SettingsView.ID_PRESET, n["preset"])
        this.SyncSegments(SettingsView.ID_MODE, d["mode"] = "system" ? "system" : n["mode"])
        this.SyncSegments(SettingsView.ID_KIND, this.AccKind)
        try g.El(SettingsView.ID_CUSTOM).style.display := (this.AccKind = "custom") ? "block" : "none"
        cur := d["accent"]
        loop Theme.SWATCHES.Length {
            el := g.El(this.SwId(A_Index))
            try StepsView.SetCls(el, "on", cur != "" && StrUpper(Theme.SWATCHES[A_Index]) = StrUpper(cur))
        }
        try {
            box := g.El(SettingsView.ID_HEX)
            if (box.value != this.HexText)
                box.value := this.HexText
        }
        this.ShowHexError()
        this.SyncDropdown(SettingsView.ID_FONT, Theme.FontId(n["fontFamily"] = "" ? "Segoe UI" : n["fontFamily"]))
        this.SyncDropdown(SettingsView.ID_SIZE, String(d["fontSize"]))
        dirty := this.IsDirty()
        try g.El(SettingsView.ID_STATE).style.display := dirty ? "block" : "none"
        for id in [SettingsView.ID_APPLY, SettingsView.ID_REVERT]
            try StepsView.SetCls(g.El(id), "nfs-st-dis", !dirty)
        this.SyncWindow()
    }

    ; The two Window checkboxes show what is saved / in force (the title-bar pin is the other half of "Keep on top").
    SyncWindow() {
        if !this.Built
            return
        this.SetCheck(SettingsView.ID_TOP, this.Win.G.TitleOn("pin"))
        this.SetCheck(SettingsView.ID_HIST, this.App.Settings.Get("historyOpen") = 1)
    }

    SetCheck(id, on) {
        try {
            inp := this.Win.G.El(id).querySelector("input")
            if (IsObject(inp) && (inp.checked ? true : false) != (on ? true : false))
                inp.checked := on ? true : false
        }
    }

    CheckOn(id) {
        try return this.Win.G.El(id).querySelector("input").checked ? true : false
        return false
    }

    ; Show the chosen item in an ax-dropdown (selected class, data-value, the visible label).
    SyncDropdown(id, chosen) {
        try {
            el := this.Win.G.El(id)
            items := el.querySelectorAll(".dd-item")
            label := ""
            loop items.length {
                it := items.item(A_Index - 1)
                on := (it.getAttribute("data-value") == chosen)
                StepsView.SetCls(it, "selected", on)
                if on
                    label := it.innerText
            }
            el.setAttribute("data-value", chosen)
            v := el.querySelector(".dd-value")
            if (IsObject(v) && label != "" && v.innerText != label)
                v.innerText := label
        }
    }

    DropdownValue(id) {
        try return this.Win.G.El(id).getAttribute("data-value")
        return ""
    }

    DropdownText(id) {
        try return this.Win.G.El(id).querySelector(".dd-value").innerText
        return ""
    }

    SyncSegments(id, value) {
        try {
            el := this.Win.G.El(id)
            segs := el.querySelectorAll(".seg")
            loop segs.length {
                sg := segs.item(A_Index - 1)
                StepsView.SetCls(sg, "active", sg.getAttribute("data-value") == value)
            }
            el.setAttribute("data-value", value)
        }
    }

    SegmentValue(id) {
        try return this.Win.G.El(id).getAttribute("data-value")
        return ""
    }

    ShowHexError() {
        try {
            el := this.Win.G.El(SettingsView.ID_HEXERR)
            if (el.innerText != this.HexErr)
                el.innerText := this.HexErr
            el.style.display := (this.HexErr != "") ? "inline" : "none"
        }
    }

    ; --- change handlers (the draft changes, the window previews it, nothing is saved) --------------------------------------
    OnPreset(value := "", *) {
        id := String(value)
        if (Theme.FindPreset(Theme.Presets(this.Cfg()), id) = "")
            return
        this.Draft["preset"] := id
        if (this.Draft["mode"] != "system")
            this.Draft["mode"] := ""                  ; the new look's own mode
        this.Changed()
    }

    OnMode(value := "", *) {
        v := String(value)
        if !Settings.InList(Settings.MODES, v)
            return
        this.Draft["mode"] := v
        this.Changed()
    }

    OnKind(value := "", *) {
        v := String(value)
        if (v = "look") {
            this.Draft["accent"] := ""
            this.AccKind := "look"
            this.HexErr := "", this.HexText := ""
        } else if (v = "custom") {
            this.AccKind := "custom"
            if (this.Draft["accent"] = "") {
                this.Draft["accent"] := this.Win.Look.Accent          ; start from the colour in force: nothing visibly changes
                this.HexText := this.Draft["accent"]
            }
        } else
            return
        this.Changed()
    }

    OnSwatch(i, *) {
        this.SetAccent(Theme.SWATCHES[i])
    }

    SetAccent(hex) {
        this.AccKind := "custom"
        this.Draft["accent"] := StrUpper(hex)
        this.HexText := this.Draft["accent"]
        this.HexErr := ""
        this.Changed()
    }

    ; The colour box. A valid #RRGGBB is applied (previewed); anything else is refused inline and NEVER applied.
    ; While typing (keyup) a half-typed value is left alone until it is 7 characters; leaving the box or Enter judges it.
    OnHex(ev := "change", *) {
        txt := ""
        try txt := Util.Trim(this.Win.G.El(SettingsView.ID_HEX).value)
        this.HexText := txt
        if Theme.IsHex(txt) {
            this.SetAccent(txt)
            return
        }
        if (ev = "keyup" && StrLen(txt) < 7) {
            if (this.HexErr != "") {
                this.HexErr := ""
                this.ShowHexError()
            }
            return
        }
        this.HexErr := "Use a colour like #0099D8"
        this.ShowHexError()
        this.App.Logger.Debug("accent refused", {chars: StrLen(txt)})
    }

    OnFont(value := "", *) {
        fam := this.FontOfId(String(value))
        if (fam = "")
            return
        this.Draft["fontFamily"] := (fam = "Segoe UI") ? "" : fam
        this.Changed()
    }

    OnSize(value := "", *) {
        v := String(value)
        if !RegExMatch(v, "^\d+$") || Integer(v) < Settings.SIZE_MIN || Integer(v) > Settings.SIZE_MAX
            return
        this.Draft["fontSize"] := Integer(v)
        this.Changed()
    }

    ; Show the draft on the whole window, then refresh the controls and the unsaved state.
    Changed() {
        this.Win.ApplyLook(this.Draft)
        this.Sync()
    }

    ; --- Apply / Revert / Restore -----------------------------------------------------------------------------------------
    OnApplyClick(*) {
        if this.IsDirty()
            this.Apply()
    }

    OnRevertClick(*) {
        if this.IsDirty()
            this.Revert()
    }

    ; Save the draft. Returns false (and keeps the draft) when the file can't be written.
    Apply() {
        st := this.App.Settings
        for k in Settings.APPEARANCE_KEYS
            st.Set(k, this.Draft[k])
        if !st.Save() {
            this.Win.G.Toast("Could not save the appearance settings. The changes are still shown but will be lost when the app closes.", 6000, "error")
            return false
        }
        this.App.Logger.Info("appearance applied", {preset: this.Draft["preset"], mode: this.Draft["mode"], accentCustom: this.Draft["accent"] != "" ? 1 : 0,
            font: this.Draft["fontFamily"], size: this.Draft["fontSize"]})
        this.LoadDraft()
        this.Win.ApplyLook(this.Draft)
        this.Sync()
        return true
    }

    Revert() {
        this.LoadDraft()
        this.Win.ApplyLook(this.Draft)
        this.Sync()
        this.App.Logger.Info("appearance reverted")
    }

    OnRestoreClick(*) {
        this.RestoreDefaults()
    }

    ; Asks first. Resets the appearance settings (not history, stats, window position) and applies them.
    RestoreDefaults(skipAsk := false) {
        if (!skipAsk && !this.Win.Ask("restore", "Restore the default appearance? Your look, mode, accent, font and text size go back to the defaults (history and statistics are not touched).",
            "Restore defaults", "Restore", "Cancel"))
            return false
        d := Settings.AppearanceDefaults()
        for k in Settings.APPEARANCE_KEYS
            this.Draft[k] := d[k]
        this.SyncKind()
        this.Win.ApplyLook(this.Draft)
        ok := this.Apply()
        this.App.Logger.Info("appearance defaults restored", {ok: ok ? 1 : 0})
        return ok
    }

    ; The title-bar light/dark toggle: an explicit Light or Dark, saved at once (other pending changes stay pending).
    ToggleMode() {
        new := this.Win.Look.Mode = "dark" ? "light" : "dark"
        this.Draft["mode"] := new
        st := this.App.Settings
        if st.Set("mode", new)
            st.Save()
        this.Changed()
    }

    ; Leaving the page or closing the window: if the draft is unapplied, ask. Returns "" (nothing to ask), "apply" or "revert".
    Leave(why := "page") {
        if !this.Built || !this.IsDirty()
            return ""
        ans := this.Win.AskKeep()
        if (ans = "apply") {
            if !this.Apply()
                return "apply"
        } else
            this.Revert()
        this.App.Logger.Info("appearance changes on leaving", {why: why, answer: ans})
        return ans
    }

    ; --- Window section -----------------------------------------------------------------------------------------------------
    OnTop(value := "", *) {
        on := (value = 1 || value = "1" || value = true)
        this.Win.SetPin(on)
    }

    OnHistOpen(value := "", *) {
        on := (value = 1 || value = "1" || value = true)
        this.Win.Remember("historyOpen", on ? 1 : 0)
        this.App.Logger.Info("history at start", {on: on ? 1 : 0})
    }

    ; --- About -----------------------------------------------------------------------------------------------------------------
    OnOpenFolder(*) {
        return this.Win.OpenDataFolder()
    }

    AboutText(key) {
        try return this.Win.G.El("nfsSetAb_" key).innerText
        return "<none>"
    }
}
