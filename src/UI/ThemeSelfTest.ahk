#Requires AutoHotkey v2.0
; ThemeSelfTest.ahk - the M9 block of `NFSNotes.ahk --selftest` (Settings page, live preview, Apply / Revert / Restore
; defaults, leave and close prompts, pin sync, and the automated WCAG contrast checks on COMPUTED colours).
;
; Everything goes through the real handlers and the real DOM (DOM click(), fireEvent, the page's own wiring). The Settings
; object of a selftest lives in a temp folder (App.SettingsDir), so the user's settings.json is never touched. Questions are
; answered by MainWindow.AutoAsk; Run() is replaced by MainWindow.RunHook. No personal data is logged.
;
; Contrast: for each element, the computed text colour and the first non-transparent background up the tree (translucent
; layers composited, element opacity folded into the text colour) give a WCAG ratio. Normal text must reach 4.5, large or bold
; UI text (the tile number) 3. A failure is logged as an ERROR line, so it can't pass unnoticed.

class ThemeSelfTest {
    __New(win) {
        this.W := win
        this.App := win.App
        this.G := win.G
        this.Lg := win.App.Logger
        this.SV := win.SV
        this.Checked := 0
        this.Fails := 0
        this.Asked := 0
        this.Ans := Map("keep", "revert", "restore", true)
        this.Direct := 0                   ; how many events had to be replaced by a direct handler call
        this.Events := 0
    }

    static Ok(v) => v ? 1 : 0

    ; ------------------------------------------------------------------------------ small DOM helpers
    Q(sel) {
        try return this.G.Doc.querySelector(sel)
        return ""
    }

    Pause(ms := 60) => Sleep(ms)

    Click(el) {
        el.click()
        this.Pause(40)
    }

    ; Choose an item of an ax-dropdown through the DOM click the library listens to.
    Pick(id, value) {
        el := this.Q('#' id ' .dd-item[data-value="' value '"]')
        if !IsObject(el)
            return false
        this.Click(el)
        return true
    }

    Segment(id, value) {
        el := this.Q('#' id ' .seg[data-value="' value '"]')
        if !IsObject(el)
            return false
        this.Click(el)
        return true
    }

    ; Set a <select> / text box and fire its change event; if the page did not react, call the handler (and count that).
    Change(el, value, expectFn, handler, args*) {
        el.value := value
        try el.fireEvent("onchange")
        this.Pause(50)
        if expectFn() {
            this.Events += 1
            return "event"
        }
        this.Direct += 1
        this.SV.%handler%(args*)
        this.Pause(30)
        return "direct"
    }

    FileText() {
        p := this.App.Settings.Path
        try return FileExist(p) ? FileRead(p, "UTF-8-RAW") : "<none>"
        return "<unreadable>"
    }

    Saved(key) => this.App.Settings.Get(key)

    ; The five appearance values as stored in the file (other keys, like lastPage, change as the page changes).
    FileApp() {
        try {
            m := ConfigJson.Parse(FileRead(this.App.Settings.Path, "UTF-8"))
            s := ""
            for k in Settings.APPEARANCE_KEYS
                s .= k "=" (m.Has(k) ? m[k] : "<absent>") ";"
            return s
        }
        return "<none>"
    }

    BodyClass() => this.G.Doc.body.className

    IsDark() => InStr(" " this.BodyClass() " ", " theme-dark ") > 0 && InStr(" " this.BodyClass() " ", " theme-light ") = 0
    IsLight() => InStr(" " this.BodyClass() " ", " theme-light ") > 0 && InStr(" " this.BodyClass() " ", " theme-dark ") = 0

    ; --- computed style ------------------------------------------------------------------------------------------
    Prop(el, name) {
        try {
            cs := this.G.Doc.parentWindow.getComputedStyle(el)
            v := cs.getPropertyValue(name)
            if (v != "")
                return v
        }
        try return el.currentStyle.%ThemeSelfTest.Camel(name)%
        return ""
    }

    static Camel(n) {
        out := ""
        up := false
        loop parse n {
            if (A_LoopField = "-") {
                up := true
                continue
            }
            out .= up ? StrUpper(A_LoopField) : A_LoopField
            up := false
        }
        return out
    }

    ; "rgb(1, 2, 3)", "rgba(1, 2, 3, .5)", "#abc", "#aabbcc", "transparent" -> {Ok, R, G, B, A}
    static Parse(s) {
        s := Trim(String(s))
        if (s = "transparent")
            return {Ok: true, R: 0, G: 0, B: 0, A: 0}
        if RegExMatch(s, "i)^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$", &m)
            return {Ok: true, R: Integer(m[1]), G: Integer(m[2]), B: Integer(m[3]), A: m[4] != "" ? Number(m[4]) : 1}
        if RegExMatch(s, "i)^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$", &m)
            return {Ok: true, R: Integer("0x" m[1]), G: Integer("0x" m[2]), B: Integer("0x" m[3]), A: 1}
        if RegExMatch(s, "i)^#([0-9a-f])([0-9a-f])([0-9a-f])$", &m)
            return {Ok: true, R: Integer("0x" m[1] m[1]), G: Integer("0x" m[2] m[2]), B: Integer("0x" m[3] m[3]), A: 1}
        return {Ok: false, R: 0, G: 0, B: 0, A: 1}
    }

    static HexOf(c) => Theme.Hex(c.R, c.G, c.B)

    ; The colour behind el: translucent layers up to the first opaque one, composited. {Hex, Opaque}
    BgOf(el) {
        layers := []
        node := el
        opaque := false
        loop 40 {
            try {
                if (node.nodeType != 1)
                    break
                c := ThemeSelfTest.Parse(this.Prop(node, "background-color"))
                if (c.Ok && c.A > 0) {
                    layers.Push(c)
                    if (c.A >= 0.999) {
                        opaque := true
                        break
                    }
                }
                node := node.parentNode
            } catch
                break
        }
        base := "#FFFFFF"                     ; nothing opaque up the tree: the default canvas
        if opaque {
            base := ThemeSelfTest.HexOf(layers.Pop())
        }
        while layers.Length {
            c := layers.Pop()
            base := Theme.Mix(base, ThemeSelfTest.HexOf(c), c.A)
        }
        return {Hex: base, Opaque: opaque}
    }

    OpacityOf(el) {
        p := 1.0
        node := el
        loop 40 {
            try {
                if (node.nodeType != 1)
                    break
                v := this.Prop(node, "opacity")
                if (v != "" && IsNumber(v))
                    p *= Number(v)
                node := node.parentNode
            } catch
                break
        }
        return p
    }

    ; {Fg, Bg, Ratio, Opaque}
    Measure(el) {
        fg := ThemeSelfTest.Parse(this.Prop(el, "color"))
        bg := this.BgOf(el)
        if !fg.Ok
            return {Fg: "?", Bg: bg.Hex, Ratio: 0, Opaque: bg.Opaque}
        eff := Theme.Mix(bg.Hex, ThemeSelfTest.HexOf(fg), fg.A * this.OpacityOf(el))
        return {Fg: eff, Bg: bg.Hex, Ratio: Theme.Contrast(eff, bg.Hex), Opaque: bg.Opaque}
    }

    Probe(parent, html) {
        try {
            parent.insertAdjacentHTML("beforeend", html)
            return parent.lastChild
        }
        return ""
    }

    Drop(el) {
        try el.parentNode.removeChild(el)
    }

    ; --- the contrast table --------------------------------------------------------------------------------------------
    ; Paint `values` on the window, then check every listed element. cfg names the configuration in the log.
    Contrast(cfg, values) {
        w := this.W, g := this.G, lg := this.Lg
        w.ApplyLook(values)
        this.Pause(120)
        probes := []
        items := []
        add := (name, el, lo := 4.5) => IsObject(el) ? items.Push([name, el, lo]) : items.Push([name " (missing)", "", lo])
        rail := ""
        navs := g.Doc.querySelectorAll(".nav-item")
        loop navs.length {
            n := navs.item(A_Index - 1)
            if (!InStr(" " n.className " ", " active ") && !IsObject(rail))
                rail := n
        }
        add("body text", g.Doc.body)
        add("rail item", rail)
        add("rail selected", this.Q(".nav-item.active"))
        add("card label", this.Q(".nfs-kv b"))
        add("card value", this.Q("#nfsF_techName"))
        kv := this.Q("#nfsCtx .nfs-kv div")
        for s in ["live", "mock", "manual", "unavailable", "stale", "empty", "history"] {
            el := this.Probe(kv, '<span class="nfs-tag nfs-t-' s '">' s '</span>')
            probes.Push(el)
            add("tag " s, el)
        }
        add("static tag", this.Q(".nfs-st-tag"))
        add("MOCK badge", this.Q(".axtb-item.nfs-mock"))
        add("tile number", this.Q("#nfsCallsN"), 3.0)
        add("tile label", this.Q(".nfs-tile-l"))
        add("accent button", this.Q("#nfsCopy"))
        ap := this.Q("#nfsSetApply")
        wasDim := IsObject(ap) && InStr(ap.className, "nfs-st-dis") > 0
        if wasDim
            StepsView.SetCls(ap, "nfs-st-dis", false)             ; a dimmed (disabled) button is exempt: measure it enabled
        add("apply button", ap)
        root := ""
        try root := g.El(w.Steps["notDone"].RootId)
        card := IsObject(root) ? root.querySelector(".card") : ""
        add("stop banner", this.Probe(root, '<div class="nfs-sv-stop">The tech must contact their supervisor.</div>'))
        probes.Push(items[items.Length][2])
        add("flag bar", this.Probe(root, '<div class="nfs-sv-flags" style="display:block">flag</div>'))
        probes.Push(items[items.Length][2])
        add("hint", this.Probe(IsObject(card) ? card : root, '<div class="nfs-sv-hint on">Pick one</div>'))
        probes.Push(items[items.Length][2])
        add("static note", this.Q(".nfs-st-note"))
        add("ping console", this.Q(".nfs-st-con"))
        add("static link", this.Q(".nfs-st-link"))
        hl := g.El("nfsHList")
        add("history row", this.Probe(hl, '<div class="nfs-hrow"><span>14:02</span><span>Tech</span></div>'))
        probes.Push(items[items.Length][2])
        add("history row selected", this.Probe(hl, '<div class="nfs-hrow sel"><span>14:03</span><span>Tech</span></div>'))
        probes.Push(items[items.Length][2])
        add("history header", this.Q(".nfs-hcols"))
        add("settings error", this.Q("#nfsSetHexErr"))
        add("settings state", this.Q("#nfsSetState"))
        add("settings label", this.Q(".nfs-set-k"))
        add("regenerate bar", this.Q("#nfsRegen"))
        fails := 0
        for it in items {
            name := it[1], el := it[2], lo := it[3]
            if !IsObject(el) {
                fails += 1
                lg.Error("selftest m9 contrast element missing", {cfg: cfg, element: name})
                continue
            }
            m := this.Measure(el)
            pass := m.Ratio >= lo
            this.Checked += 1
            if !pass {
                fails += 1
                this.Fails += 1
                lg.Error("selftest m9 contrast FAIL", {cfg: cfg, element: name, ratio: Round(m.Ratio, 2), min: lo, fg: m.Fg, bg: m.Bg})
            } else
                lg.Info("selftest m9 contrast", {cfg: cfg, element: name, ratio: Round(m.Ratio, 2), min: lo, fg: m.Fg, bg: m.Bg, opaque: m.Opaque ? 1 : 0})
        }
        for el in probes
            this.Drop(el)
        if wasDim
            StepsView.SetCls(ap, "nfs-st-dis", true)
        lg.Info("selftest m9 contrast summary", {cfg: cfg, elements: items.Length, fails: fails})
        return fails
    }

    ; --------------------------------------------------------------------------------------------------- the run
    Run() {
        w := this.W, g := this.G, lg := this.Lg, app := this.App, sv := this.SV, st := app.Settings
        ok := (v) => v ? 1 : 0
        w.AutoAsk := (kind, text) => (this.Asked += 1, this.Ans.Has(kind) ? this.Ans[kind] : false)
        w.RunHook := (cmd) => 0
        g.ShowPage("settings")
        this.Pause(150)
        file0 := this.FileText()           ; (moving to a page saves lastPage, so the baseline is taken once we are on it)
        lg.Info("selftest m9 start", {settingsInTemp: InStr(st.Dir, A_Temp) = 1 ? 1 : 0, built: ok(sv.Built),
            preset: w.Look.PresetId, mode: w.Look.Mode, accent: w.Look.Accent, sheet: w.Look.Sheet, look: w.Look.Look,
            themeStyle: ok(IsObject(g.El("axExtra_nfstheme"))), cssLen: StrLen(w.Look.ExtraCss), bodyClass: this.BodyClass(),
            docMode: g.DocMode})
        ; --- the page and its controls
        ddn := (id) => g.El(id).querySelectorAll(".dd-item").length
        presets := ddn(SettingsView.ID_PRESET), fonts := ddn(SettingsView.ID_FONT), sizes := ddn(SettingsView.ID_SIZE)
        swatches := g.Doc.querySelectorAll(".nfs-sw").length
        lg.Info("selftest m9 page", {presets: presets, fonts: fonts, sizes: sizes, swatches: swatches,
            modeSegs: g.El(SettingsView.ID_MODE).querySelectorAll(".seg").length, kindSegs: g.El(SettingsView.ID_KIND).querySelectorAll(".seg").length,
            presetShown: sv.DropdownText(SettingsView.ID_PRESET), fontShown: sv.DropdownText(SettingsView.ID_FONT), sizeShown: sv.DropdownText(SettingsView.ID_SIZE),
            modeShown: sv.SegmentValue(SettingsView.ID_MODE), kindShown: sv.SegmentValue(SettingsView.ID_KIND),
            customShown: g.El(SettingsView.ID_CUSTOM).style.display, stateShown: g.El(SettingsView.ID_STATE).style.display,
            applyDim: ok(InStr(g.El(SettingsView.ID_APPLY).className, "nfs-st-dis")), revertDim: ok(InStr(g.El(SettingsView.ID_REVERT).className, "nfs-st-dis"))})
        lg.Info("selftest m9 logo", {shown: ok(w.LogoShown), assetsLogo: ok(Theme.LogoPath(A_ScriptDir) != ""), titleItem: ok(IsObject(g.El("logo")))})
        lg.Info("selftest m9 about", {version: sv.AboutText("ver"), config: sv.AboutText("cfg"), dirIsKnown: ok(sv.AboutText("dir") = Util.UserDataDir()),
            logLevel: sv.AboutText("log")})
        w.LastRun := ""
        sv.OnOpenFolder()
        this.Click(g.El(SettingsView.ID_OPEN))
        lg.Info("selftest m9 open folder", {cmdIsExplorerOnKnownPath: ok(w.LastRun = 'explorer.exe "' Util.UserDataDir() '"')})
        lg.Info("selftest m9 window boxes", {topShown: ok(sv.CheckOn(SettingsView.ID_TOP) = g.TitleOn("pin")), histShown: ok(sv.CheckOn(SettingsView.ID_HIST) = (st.Get("historyOpen") = 1))})

        ; --- mode to dark: live, unsaved
        this.Segment(SettingsView.ID_MODE, "dark")
        lg.Info("selftest m9 mode dark", {bodyDark: ok(this.IsDark()), bodyClass: this.BodyClass(), dirty: ok(sv.IsDirty()), stateShown: g.El(SettingsView.ID_STATE).style.display,
            applyDim: ok(InStr(g.El(SettingsView.ID_APPLY).className, "nfs-st-dis")), savedMode: "'" st.Get("mode") "'", fileUnchanged: ok(this.FileText() = file0),
            segActive: sv.SegmentValue(SettingsView.ID_MODE), glyph: g.TitleItem("theme").Glyph})
        ; --- revert
        this.Click(g.El(SettingsView.ID_REVERT))
        lg.Info("selftest m9 revert", {bodyLight: ok(this.IsLight()), dirty: ok(sv.IsDirty()), stateShown: g.El(SettingsView.ID_STATE).style.display,
            fileUnchanged: ok(this.FileText() = file0), segActive: sv.SegmentValue(SettingsView.ID_MODE), glyph: g.TitleItem("theme").Glyph})

        ; --- accent: a swatch, previewed, then applied
        tile := g.El("nfsCallsN")
        c0 := this.Prop(tile, "color")
        this.Segment(SettingsView.ID_KIND, "custom")
        shown := g.El(SettingsView.ID_CUSTOM).style.display
        sw := g.El(sv.SwId(5))
        want := Theme.SWATCHES[5]
        this.Click(sw)
        c1 := ThemeSelfTest.Parse(this.Prop(tile, "color"))
        lg.Info("selftest m9 accent swatch", {customShown: shown, swatch: want, tileBefore: c0, tileColourEqualsAccent: ok(ThemeSelfTest.HexOf(c1) = want), tileHex: ThemeSelfTest.HexOf(c1),
            dirty: ok(sv.IsDirty()), swatchOn: ok(InStr(sw.className, " on") || sw.className = "on"), boxShows: g.El(SettingsView.ID_HEX).value,
            lookAccent: w.Look.Accent, savedAccent: "'" st.Get("accent") "'", fileUnchanged: ok(this.FileText() = file0)})
        this.Click(g.El(SettingsView.ID_APPLY))
        saved := this.FileText()
        c2 := ThemeSelfTest.Parse(this.Prop(tile, "color"))
        lg.Info("selftest m9 accent applied", {savedAccent: st.Get("accent"), inFile: ok(InStr(saved, '"accent": "' want '"')), dirty: ok(sv.IsDirty()),
            stateShown: g.El(SettingsView.ID_STATE).style.display, tileEqualsAccent: ok(ThemeSelfTest.HexOf(c2) = want), tileComputed: this.Prop(tile, "color"),
            btnFill: ThemeSelfTest.HexOf(ThemeSelfTest.Parse(this.Prop(g.El("nfsCopy"), "background-color")))})

        ; --- an invalid colour is refused inline and never applied
        file1 := this.FileText()
        look1 := w.Look.ExtraCss
        box := g.El(SettingsView.ID_HEX)
        res := ""
        for bad in ["blue", "#GG0000", "0099D8", "#09D", "#0099D", ""] {
            this.Change(box, bad, () => g.El(SettingsView.ID_HEXERR).innerText != "", "OnHex", "change")
            res .= (res = "" ? "" : " | ") "'" bad "' err=" ok(g.El(SettingsView.ID_HEXERR).innerText = "Use a colour like #0099D8") " dirty=" ok(sv.IsDirty()) " accent=" sv.Draft["accent"]
            sv.HexErr := ""
            sv.HexText := want
            sv.ShowHexError()
            box.value := want
        }
        lg.Info("selftest m9 invalid hex", {table: res, errText: "ok", cssUnchanged: ok(w.Look.ExtraCss == look1), fileUnchanged: ok(this.FileText() = file1),
            tileStill: ok(ThemeSelfTest.HexOf(ThemeSelfTest.Parse(this.Prop(tile, "color"))) = want)})
        this.Change(box, "#ff8800", () => sv.Draft["accent"] = "#FF8800", "OnHex", "change")
        lg.Info("selftest m9 valid hex", {draft: sv.Draft["accent"], errCleared: ok(g.El(SettingsView.ID_HEXERR).innerText = ""), dirty: ok(sv.IsDirty()),
            lookAccent: w.Look.Accent, fileUnchanged: ok(this.FileText() = file1)})
        this.Click(g.El(SettingsView.ID_REVERT))
        lg.Info("selftest m9 revert accent", {draft: sv.Draft["accent"], lookAccent: w.Look.Accent, dirty: ok(sv.IsDirty()), customShown: g.El(SettingsView.ID_CUSTOM).style.display,
            swatchOn: ok(InStr(g.El(sv.SwId(5)).className, "on"))})
        ; back to the look's colour
        this.Segment(SettingsView.ID_KIND, "look")
        lg.Info("selftest m9 accent look", {draft: "'" sv.Draft["accent"] "'", lookAccent: w.Look.Accent, customShown: g.El(SettingsView.ID_CUSTOM).style.display, dirty: ok(sv.IsDirty())})
        this.Click(g.El(SettingsView.ID_APPLY))
        fileA := this.FileText()
        lg.Info("selftest m9 accent look applied", {savedAccent: "'" st.Get("accent") "'", dirty: ok(sv.IsDirty())})

        ; --- font and size: computed styles of the body and the notes box
        pick := ""
        for fam in sv.Fonts
            if (fam != "Segoe UI" && pick = "")
                pick := fam
        body := g.Doc.body, notes := g.El("nfsNotes")
        fam0 := this.Prop(body, "font-family"), size0 := this.Prop(body, "font-size"), nsize0 := this.Prop(notes, "font-size")
        via := ""
        if (pick != "")
            via := this.Pick(SettingsView.ID_FONT, Theme.FontId(pick))
        via2 := this.Pick(SettingsView.ID_SIZE, "16")
        lg.Info("selftest m9 font size", {pick: pick, via: via, via2: via2, fam0: fam0, famBody: this.Prop(body, "font-family"), famNotes: this.Prop(notes, "font-family"),
            bodyHasFont: ok(pick = "" || InStr(this.Prop(body, "font-family"), pick)), notesHasFont: ok(pick = "" || InStr(this.Prop(notes, "font-family"), pick)),
            size0: size0, sizeBody: this.Prop(body, "font-size"), expectPx: Theme.FontPx(16) "px", sizeNotes: this.Prop(notes, "font-size"), notesSize0: nsize0,
            btnSize: this.Prop(g.El("nfsCopy"), "font-size"), railSize: this.Prop(this.Q(".nav-item"), "font-size"), dirty: ok(sv.IsDirty()), fileUnchanged: ok(this.FileText() = fileA)})
        this.Click(g.El(SettingsView.ID_APPLY))
        saved := this.FileText()
        lg.Info("selftest m9 font applied", {savedFont: st.Get("fontFamily"), savedSize: st.Get("fontSize"), inFile: ok(InStr(saved, '"fontSize": 16') && (pick = "" || InStr(saved, '"fontFamily": "' pick '"')))})
        for sz in [9, 20] {
            wantPx := Theme.FontPx(sz) "px"
            this.Pick(SettingsView.ID_SIZE, String(sz))
            lg.Info("selftest m9 size edge", {size: sz, computed: this.Prop(body, "font-size"), notes: this.Prop(notes, "font-size"), expect: wantPx})
        }
        this.Click(g.El(SettingsView.ID_REVERT))

        ; --- a look from the config, Spectrum band on the title bar
        tb := g.El("titlebar")
        band := () => ThemeSelfTest.HexOf(ThemeSelfTest.Parse(this.Prop(tb, "background-color")))
        lg.Info("selftest m9 band", {light: band(), expect: Theme.SPECTRUM_NAVY})
        via := this.Pick(SettingsView.ID_PRESET, "spectrum-dark")
        lg.Info("selftest m9 look dark", {via: via, bodyDark: ok(this.IsDark()), band: band(), modeSeg: sv.SegmentValue(SettingsView.ID_MODE), dirty: ok(sv.IsDirty())})
        via := this.Pick(SettingsView.ID_PRESET, "win365")
        lg.Info("selftest m9 look plain", {via: via, bodyLight: ok(this.IsLight()), band: band(), notNavy: ok(band() != Theme.SPECTRUM_NAVY), look: w.Look.Look})
        this.Click(g.El(SettingsView.ID_REVERT))
        lg.Info("selftest m9 look reverted", {preset: w.Look.PresetId, band: band(), dirty: ok(sv.IsDirty())})

        ; --- restore defaults (declined, then confirmed)
        this.Segment(SettingsView.ID_MODE, "dark")
        hist0 := app.History.List(Util.DateOfStamp(Util.NowStamp())).Length, total0 := app.Stats.Today().Total
        this.Ans["restore"] := false
        a0 := this.Asked
        this.Click(g.El(SettingsView.ID_RESTORE))
        lg.Info("selftest m9 restore declined", {asked: this.Asked - a0, kind: w.LastAsked.Kind, stillDark: ok(this.IsDark()), dirty: ok(sv.IsDirty()), savedFont: st.Get("fontFamily"), savedSize: st.Get("fontSize")})
        this.Ans["restore"] := true
        a0 := this.Asked
        this.Click(g.El(SettingsView.ID_RESTORE))
        defaults := Settings.AppearanceDefaults()
        same := true
        for k in Settings.APPEARANCE_KEYS
            if (st.Get(k) != defaults[k])
                same := false
        saved := this.FileText()
        lg.Info("selftest m9 restore", {asked: this.Asked - a0, text: ok(InStr(w.LastAsked.Text, "history and statistics are not touched")), settingsAreDefaults: ok(same),
            inFile: ok(InStr(saved, '"fontSize": 12') && InStr(saved, '"fontFamily": ""') && InStr(saved, '"accent": ""') && InStr(saved, '"mode": ""')),
            bodyLight: ok(this.IsLight()), bodySize: this.Prop(g.Doc.body, "font-size"), dirty: ok(sv.IsDirty()), lookPreset: w.Look.PresetId, lookAccent: w.Look.Accent,
            fontShown: sv.DropdownText(SettingsView.ID_FONT), sizeShown: sv.DropdownText(SettingsView.ID_SIZE), kindShown: sv.SegmentValue(SettingsView.ID_KIND),
            historyKept: ok(app.History.List(Util.DateOfStamp(Util.NowStamp())).Length = hist0), statsKept: ok(app.Stats.Today().Total = total0)})

        ; --- leaving the page / closing the window with unapplied changes
        file2 := this.FileApp()
        this.Segment(SettingsView.ID_MODE, "dark")
        this.Ans["keep"] := "revert"
        a0 := this.Asked
        g.ShowPage("billing")
        this.Pause(100)
        lg.Info("selftest m9 leave revert", {asked: this.Asked - a0, kind: w.LastAsked.Kind, text: w.LastAsked.Text, bodyLight: ok(this.IsLight()), dirty: ok(sv.IsDirty()),
            fileUnchanged: ok(this.FileApp() = file2), page: g.CurrentPage})
        g.ShowPage("settings")
        this.Pause(100)
        this.Segment(SettingsView.ID_MODE, "dark")
        this.Ans["keep"] := "apply"
        a0 := this.Asked
        g.ShowPage("static")
        this.Pause(100)
        lg.Info("selftest m9 leave apply", {asked: this.Asked - a0, bodyDark: ok(this.IsDark()), savedMode: st.Get("mode"), inFile: ok(InStr(this.FileText(), '"mode": "dark"')), page: g.CurrentPage})
        g.ShowPage("settings")
        this.Pause(100)
        a0 := this.Asked
        g.ShowPage("billing")
        this.Pause(60)
        lg.Info("selftest m9 leave clean", {asked: this.Asked - a0})
        g.ShowPage("settings")
        this.Pause(100)
        this.Segment(SettingsView.ID_MODE, "light")
        this.Ans["keep"] := "revert"
        a0 := this.Asked
        r := w.OnClosing()
        lg.Info("selftest m9 close revert", {asked: this.Asked - a0, kind: w.LastAsked.Kind, neverBlocks: ok(r = false), bodyDark: ok(this.IsDark()), savedMode: st.Get("mode"), dirty: ok(sv.IsDirty())})
        this.Segment(SettingsView.ID_MODE, "light")
        this.Ans["keep"] := "apply"
        a0 := this.Asked
        r := w.OnClosing()
        lg.Info("selftest m9 close apply", {asked: this.Asked - a0, neverBlocks: ok(r = false), savedMode: st.Get("mode"), bodyLight: ok(this.IsLight()), dirty: ok(sv.IsDirty())})

        ; --- the title-bar toggle follows Mode; with System it becomes explicit
        w.SystemModeHook := "dark"
        this.Segment(SettingsView.ID_MODE, "system")
        this.Click(g.El(SettingsView.ID_APPLY))
        lg.Info("selftest m9 system", {savedMode: st.Get("mode"), segActive: sv.SegmentValue(SettingsView.ID_MODE), bodyDark: ok(this.IsDark()), lookMode: w.Look.Mode, lookSetting: w.Look.ModeSetting})
        w.SystemModeHook := "light"
        w.TickClock()
        lg.Info("selftest m9 system follows windows", {bodyLight: ok(this.IsLight()), lookMode: w.Look.Mode, lookSetting: w.Look.ModeSetting})
        this.Click(g.El("theme"))
        lg.Info("selftest m9 toggle from system", {savedMode: st.Get("mode"), segActive: sv.SegmentValue(SettingsView.ID_MODE), bodyDark: ok(this.IsDark()), glyph: g.TitleItem("theme").Glyph,
            inFile: ok(InStr(this.FileText(), '"mode": "dark"')), dirty: ok(sv.IsDirty())})
        this.Click(g.El("theme"))
        lg.Info("selftest m9 toggle back", {savedMode: st.Get("mode"), segActive: sv.SegmentValue(SettingsView.ID_MODE), bodyLight: ok(this.IsLight()), glyph: g.TitleItem("theme").Glyph})
        ; a toggle with other changes pending saves only the mode
        this.Pick(SettingsView.ID_SIZE, "15")
        this.Click(g.El("theme"))
        lg.Info("selftest m9 toggle with pending", {savedMode: st.Get("mode"), savedSize: st.Get("fontSize"), dirty: ok(sv.IsDirty()), bodyDark: ok(this.IsDark()), bodySize: this.Prop(body, "font-size")})
        this.Click(g.El(SettingsView.ID_REVERT))
        lg.Info("selftest m9 revert keeps the toggled mode", {savedMode: st.Get("mode"), bodyDark: ok(this.IsDark()), bodySize: this.Prop(body, "font-size")})
        this.Click(g.El("theme"))

        ; --- the pin, both ways; history at start
        topOf := () => (WinGetExStyle(g.Hwnd) & 0x8) ? 1 : 0
        this.Click(g.El("pin"))
        lg.Info("selftest m9 pin from title bar", {titleOn: ok(g.TitleOn("pin")), boxChecked: ok(sv.CheckOn(SettingsView.ID_TOP)), topmost: topOf(), saved: st.Get("alwaysOnTop")})
        this.Click(g.El("pin"))
        lg.Info("selftest m9 pin off from title bar", {titleOn: ok(g.TitleOn("pin")), boxChecked: ok(sv.CheckOn(SettingsView.ID_TOP)), topmost: topOf(), saved: st.Get("alwaysOnTop")})
        inp := g.El(SettingsView.ID_TOP).querySelector("input")
        this.Click(inp)
        viaBox := ok(g.TitleOn("pin"))
        if !viaBox {
            this.Direct += 1
            sv.OnTop(1)
        }
        lg.Info("selftest m9 pin from settings", {viaDom: viaBox, titleOn: ok(g.TitleOn("pin")), boxChecked: ok(sv.CheckOn(SettingsView.ID_TOP)), topmost: topOf(), saved: st.Get("alwaysOnTop")})
        this.Click(inp)
        if g.TitleOn("pin") {
            this.Direct += 1
            sv.OnTop(0)
        }
        lg.Info("selftest m9 pin off from settings", {titleOn: ok(g.TitleOn("pin")), boxChecked: ok(sv.CheckOn(SettingsView.ID_TOP)), topmost: topOf(), saved: st.Get("alwaysOnTop")})
        hbox := g.El(SettingsView.ID_HIST).querySelector("input")
        this.Click(hbox)
        if (st.Get("historyOpen") != 1) {
            this.Direct += 1
            sv.OnHistOpen(1)
        }
        lg.Info("selftest m9 history at start", {saved: st.Get("historyOpen"), inFile: ok(InStr(this.FileText(), '"historyOpen": true'))})
        this.Click(hbox)
        if (st.Get("historyOpen") != 0) {
            this.Direct += 1
            sv.OnHistOpen(0)
        }
        lg.Info("selftest m9 history at start off", {saved: st.Get("historyOpen")})
        w.Hist.Toggle()
        lg.Info("selftest m9 history button", {panelOpen: ok(w.Hist.Open), boxChecked: ok(sv.CheckOn(SettingsView.ID_HIST)), saved: st.Get("historyOpen")})
        w.Hist.Toggle()
        lg.Info("selftest m9 history button off", {panelOpen: ok(w.Hist.Open), boxChecked: ok(sv.CheckOn(SettingsView.ID_HIST)), saved: st.Get("historyOpen")})

        ; --- every contrast check, in every configuration
        g.ShowPage("settings")
        this.Pause(100)
        base := Map("preset", "", "mode", "", "accent", "", "fontFamily", "", "fontSize", 12)
        total := 0
        for cfg in [["light", "light", ""], ["dark", "dark", ""], ["dark+FFD200", "dark", "#FFD200"], ["dark+003057", "dark", "#003057"],
            ["light+FFD200", "light", "#FFD200"], ["light+003057", "light", "#003057"], ["plain-light", "light", ""], ["plain-dark", "dark", ""], ["plain-dark+FFD200", "dark", "#FFD200"]] {
            v := base.Clone()
            v["mode"] := cfg[2], v["accent"] := cfg[3]
            if InStr(cfg[1], "plain")
                v["preset"] := "win365"
            total += this.Contrast(cfg[1], v)
        }
        w.ApplyLook(st)
        lg.Info("selftest m9 contrast total", {configs: 9, checked: this.Checked, fails: total})
        w.AutoAsk := "", w.RunHook := "", w.SystemModeHook := ""
        w.Persist := false                 ; the exit hook must not write window.json into the temp folder that is about to be deleted
        lg.Info("selftest m9 done", {events: this.Events, directCalls: this.Direct, fails: this.Fails, asked: this.Asked, bodyClass: this.BodyClass()})
    }
}
