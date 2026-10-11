#Requires AutoHotkey v2.0
; Theme.ahk - settings + the config's look presets -> what the AxGui window needs (PLAN 4.1 / 3.13 / 8).
;
;   res := Theme.Resolve(settings, configMap)    -> {Sheet, Mode, Accent, FontFamily, FontSize, ExtraCss, ...}
;   Theme.Apply(win, res)                        -> calls the library (SetStylesheet / SetTheme / SetExtraCss)
;
; Pure logic apart from Apply(): no AxGui include, so the tests run headless. Settings may be a Settings object or a Map
; holding the same keys (the Settings page previews a draft that way); the config is Config.Config (a Map).
;
; HOW THE SPECTRUM LOOK IS LOADED. The library can load a stylesheet from a path and honours "@extends", but it names the
; body class after the file ("spectrum.css" is not one of its own looks, so AxGui.SheetName() answers "win11"); every
; "body.sheet-win365 ..." rule of the base would then be dead. So there is no themes\spectrum.css: the preset's sheet
; "spectrum" means the library's win365 plus CSS generated here (Theme.Css) and applied with SetExtraCss. That CSS also
; carries every colour the app's own pages use, taken from the resolved accent and mode instead of fixed values, and
; picks text colours by WCAG contrast. IE11 has no CSS variables, so the colours are written out as text.
;
; Text size: the setting (9-20, default 12) is on a "Windows points" scale where 12 is the library's normal 14 px
; (FontPx). Everything the app draws sizes itself in rem from the root, so one number scales it.

#Include %A_LineFile%\..\..\Config\Settings.ahk

class Theme {
    static SPECTRUM_BLUE := "#0099D8"
    static SPECTRUM_NAVY := "#003057"
    static NEAR_BLACK := "#111111"
    ; looks the library ships (anything else in a preset's "sheet" falls back to win365)
    static LIB_SHEETS := ["win11", "win98", "winxp", "win365", "cyber", "rpg", "cozy", "aurora", "instrument", "precision",
        "inset", "brutalist", "macos", "riso", "blueprint", "aero", "deco", "crt"]
    ; the 8 swatches of the Settings page (Spectrum blue first)
    static SWATCHES := ["#0099D8", "#003057", "#0F6CBD", "#2E9E4F", "#7A5AF8", "#C42B1C", "#D98A00", "#FFD200"]

    ; ------------------------------------------------------------------ colour helpers
    static IsHex(s) => (s is String) && StrLen(s) = 7 && RegExMatch(s, "^#[0-9A-Fa-f]{6}$") > 0

    ; "#RRGGBB" -> {R, G, B} (0-255)
    static Rgb(hex) {
        if !Theme.IsHex(hex)
            throw ValueError("not a #RRGGBB colour: " String(hex))
        return {R: Integer("0x" SubStr(hex, 2, 2)), G: Integer("0x" SubStr(hex, 4, 2)), B: Integer("0x" SubStr(hex, 6, 2))}
    }

    static Hex(r, g, b) => Format("#{:02X}{:02X}{:02X}", Min(255, Max(0, Round(r))), Min(255, Max(0, Round(g))), Min(255, Max(0, Round(b))))

    static Norm(hex) => StrUpper(hex)

    ; a * (1 - t) + b * t, per channel
    static Mix(a, b, t) {
        x := Theme.Rgb(a), y := Theme.Rgb(b)
        return Theme.Hex(x.R + (y.R - x.R) * t, x.G + (y.G - x.G) * t, x.B + (y.B - x.B) * t)
    }

    static Lighten(hex, t) => Theme.Mix(hex, "#FFFFFF", t)
    static Darken(hex, t) => Theme.Mix(hex, "#000000", t)

    ; WCAG relative luminance (0-1)
    static Lum(hex) {
        c := Theme.Rgb(hex)
        return 0.2126 * Theme._Lin(c.R) + 0.7152 * Theme._Lin(c.G) + 0.0722 * Theme._Lin(c.B)
    }

    static _Lin(v) {
        x := v / 255
        return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4
    }

    ; WCAG contrast ratio, 1 to 21
    static Contrast(a, b) {
        la := Theme.Lum(a), lb := Theme.Lum(b)
        hi := Max(la, lb), lo := Min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    ; White or near-black, whichever reads better on bg.
    static TextOn(bg) => Theme.Contrast("#FFFFFF", bg) >= Theme.Contrast(Theme.NEAR_BLACK, bg) ? "#FFFFFF" : Theme.NEAR_BLACK

    ; fg moved towards white or black (whichever contrasts more with bg) until every bg in bgs reaches min.
    ; Returns fg unchanged (upper case) when it already passes. bgs is one colour or an array.
    static Ensure(fg, bgs, min) {
        if !(bgs is Array)
            bgs := [bgs]
        ok := (c) => Theme._MinContrast(c, bgs) >= min
        fg := Theme.Norm(fg)
        if ok(fg)
            return fg
        target := Theme.Contrast("#FFFFFF", bgs[1]) >= Theme.Contrast("#000000", bgs[1]) ? "#FFFFFF" : "#000000"
        Loop 100 {
            c := Theme.Mix(fg, target, A_Index / 100)
            if ok(c)
                return c
        }
        return target
    }

    static _MinContrast(c, bgs) {
        m := 1000
        for b in bgs
            m := Min(m, Theme.Contrast(c, b))
        return m
    }

    ; fill moved away from textColor until textColor on it reaches min (a tag or a button fill).
    static EnsureFill(fill, textColor, min) {
        fill := Theme.Norm(fill)
        if (Theme.Contrast(fill, textColor) >= min)
            return fill
        target := Theme.Lum(textColor) > 0.5 ? "#000000" : "#FFFFFF"
        Loop 100 {
            c := Theme.Mix(fill, target, A_Index / 100)
            if (Theme.Contrast(c, textColor) >= min)
                return c
        }
        return target
    }

    ; --------------------------------------------------------------------- fonts / sizes
    static FontPx(size) => Round(size * 7 / 6)

    ; Names of the fonts registered with Windows (machine and user), e.g. "Segoe UI Bold (TrueType)".
    static InstalledFontNames() {
        out := []
        for root in ["HKLM", "HKCU"] {
            try Loop Reg root "\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "V"
                out.Push(A_LoopRegName)
        }
        return out
    }

    ; The fonts of Settings.FONTS that are installed (Segoe UI is always offered: it is the fallback).
    ; names: the registered font names (injected by the tests); omitted = ask Windows.
    static AvailableFonts(names := unset) {
        if !IsSet(names)
            names := Theme.InstalledFontNames()
        out := []
        for fam in Settings.FONTS {
            if (fam = "Segoe UI" || Theme._HasFont(names, fam))
                out.Push(fam)
        }
        return out
    }

    static _HasFont(names, fam) {
        for n in names
            if RegExMatch(n, "i)^" Theme._Rx(fam) "(?:\s+(?:Bold|Italic|Regular|Light|Semilight|Semibold|Oblique))*\s*\(")
                return true
        return false
    }

    static _Rx(s) => RegExReplace(s, "[\\.*?+\[\](){}|^$]", "\$0")

    ; "dark" or "light" from Windows' "Choose your app mode"; light when it can't be read.
    static SystemMode() {
        try return RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme") = 0 ? "dark" : "light"
        return "light"
    }

    ; --------------------------------------------------------------------- resolve
    ; values: a Settings object or a Map with the same keys; cfg: the config tree (or "" for the built-in look); opts: {SystemMode, Fonts}
    ; (Fonts = registered font names, for the tests). Never throws; problems end up in .Warnings.
    static Resolve(values, cfg, opts := "") {
        o := IsObject(opts) ? opts : {}
        get := (k) => Theme._Get(values, k)
        warns := []

        presets := Theme.Presets(cfg)
        pid := get("preset")
        pr := Theme.FindPreset(presets, pid)
        if (pr = "" && pid != "")
            warns.Push("The saved look '" pid "' is not in the configuration; the default look is used")
        if (pr = "")
            pr := Theme.FindPreset(presets, Theme.DefaultPresetId(cfg))
        if (pr = "")
            pr := presets.Length ? presets[1] : Theme.BuiltInPreset()

        ms := get("mode")
        if !(ms is String) || (ms != "" && !Settings.InList(Settings.MODES, ms))
            ms := ""
        if (ms = "system")
            mode := HasProp(o, "SystemMode") ? o.SystemMode : Theme.SystemMode()
        else if (ms = "")
            mode := (pr["mode"] = "dark") ? "dark" : "light"
        else
            mode := StrLower(ms)
        if (mode != "dark")
            mode := "light"

        acc := get("accent")
        custom := false
        if (acc is String && acc != "") {
            if Theme.IsHex(acc)
                custom := true
            else
                warns.Push("The accent '" acc "' is not a #RRGGBB colour and was ignored")
        }
        accent := Theme.Norm(custom ? acc : (Theme.IsHex(pr["accent"]) ? pr["accent"] : Theme.SPECTRUM_BLUE))

        sh := Theme.SheetFor(pr["sheet"])
        if sh.Warning != ""
            warns.Push(sh.Warning)

        size := get("fontSize")
        if !(size is Integer) || size < Settings.SIZE_MIN || size > Settings.SIZE_MAX
            size := Settings.SIZE_DEFAULT
        fam := get("fontFamily")
        famOk := ""
        if (fam is String && fam != "" && fam != "Segoe UI") {
            avail := HasProp(o, "Fonts") ? Theme.AvailableFonts(o.Fonts) : Theme.AvailableFonts()
            for f in avail
                if (StrCompare(f, fam) = 0)
                    famOk := f
            if (famOk = "")
                warns.Push("The font '" fam "' is not installed; the default font is used")
        }

        res := {PresetId: pr["id"], PresetLabel: pr["label"], Sheet: sh.Lib, Look: sh.Look, Mode: mode, ModeSetting: ms,
            Accent: accent, CustomAccent: custom, FontFamily: famOk, FontSize: size, Warnings: warns, ExtraCss: ""}
        res.Band := sh.Look = "spectrum" ? Theme.SPECTRUM_NAVY : Theme.EnsureFill(Theme.Darken(accent, mode = "dark" ? 0.45 : 0.25), "#FFFFFF", 4.6)
        res.Pal := Theme.Palette(mode, accent)
        res.ExtraCss := Theme.Css(res)
        return res
    }

    static _Get(values, k) {
        try return values is Map ? (values.Has(k) ? values[k] : "") : values.Get(k)
        return ""
    }

    static Presets(cfg) {
        out := []
        try for p in cfg["themes"]["presets"]
            if (p is Map && p.Has("id") && p.Has("sheet") && p.Has("mode") && p.Has("accent") && p.Has("label"))
                out.Push(p)
        return out
    }

    static DefaultPresetId(cfg) {
        try return cfg["themes"]["default"]
        return ""
    }

    static FindPreset(presets, id) {
        if (id = "")
            return ""
        for p in presets
            if (StrCompare(p["id"], id) = 0)
                return p
        return ""
    }

    static BuiltInPreset() => Map("id", "spectrum-light", "label", "Spectrum", "sheet", "spectrum", "mode", "light",
        "accent", Theme.SPECTRUM_BLUE)

    ; A preset's sheet name -> {Lib: the library stylesheet, Look: "spectrum" | "plain", Warning}
    static SheetFor(name) {
        n := StrLower(String(name))
        if (n = "spectrum")
            return {Lib: "win365", Look: "spectrum", Warning: ""}
        for s in Theme.LIB_SHEETS
            if (s = n)
                return {Lib: s, Look: "plain", Warning: ""}
        return {Lib: "win365", Look: "plain", Warning: "The look's stylesheet '" name "' is not known; win365 is used"}
    }

    ; --------------------------------------------------------------------- palette
    ; Every colour the generated CSS uses, for a mode and an accent. Surfaces are win365's; text colours are pushed
    ; until they pass WCAG AA against every surface they can sit on.
    static Palette(mode, accent) {
        light := (mode = "light")
        p := {Mode: mode, Accent: accent}
        p.Page := light ? "#F3F2F1" : "#1B1A19"
        p.Card := light ? "#FFFFFF" : "#262524"
        p.Rail := light ? "#FFFFFF" : "#201F1E"
        p.Text := light ? "#242322" : "#F0EEEC"
        p.Well := Theme.Mix(p.Page, p.Text, 0.05)             ; list rows (on the page)
        p.CardWell := Theme.Mix(p.Card, p.Text, 0.05)         ; the ping console (on a card)
        surfaces := [p.Page, p.Card, p.Well, p.CardWell]
        p.Surfaces := surfaces
        p.Muted := Theme.Ensure(light ? "#605E5C" : "#A9A5A2", surfaces, 4.6)
        p.Red := Theme.Ensure("#C42B1C", surfaces, 4.6)
        p.RedFill := Theme.EnsureFill("#C42B1C", "#FFFFFF", 4.6)
        p.Amber := "#D98A00"
        p.AmberPage := Theme.Mix(p.Page, "#F7A600", 0.22)
        p.AmberCard := Theme.Mix(p.Card, "#F7A600", 0.22)
        p.AmberStrong := Theme.Mix(p.Page, "#F7A600", 0.30)
        ; the accent as a fill (buttons, the selected rail item) and the text on it
        p.Fill := accent
        p.OnFill := Theme.TextOn(p.Fill)
        if (Theme.Contrast(p.OnFill, p.Fill) < 4.6) {
            p.Fill := Theme.EnsureFill(p.Fill, p.OnFill, 4.6)
            p.OnFill := Theme.TextOn(p.Fill)
        }
        p.FillHover := Theme.Mix(p.Fill, p.OnFill = "#FFFFFF" ? "#000000" : "#FFFFFF", 0.12)
        p.OnFillHover := Theme.TextOn(p.FillHover)
        if (Theme.Contrast(p.OnFillHover, p.FillHover) < 4.6) {
            p.FillHover := Theme.EnsureFill(p.FillHover, p.OnFillHover, 4.6)
            p.OnFillHover := Theme.TextOn(p.FillHover)
        }
        ; the accent as text on the surfaces: small (links) and large (the tile number, 3:1)
        p.AccentText := Theme.Ensure(accent, surfaces, 4.6)
        p.AccentBig := Theme.Ensure(accent, [p.Card], 3.1)
        ; tinted backgrounds for notes under the accent; the text on them stays the normal text colour
        t := 0.16
        p.AccentTint := Theme.Mix(p.Page, accent, t)
        while (Theme.Contrast(p.Text, p.AccentTint) < 7 && t > 0.03) {
            t -= 0.02
            p.AccentTint := Theme.Mix(p.Page, accent, t)
        }
        p.SelRow := Theme.Mix(p.Page, accent, t + 0.04)
        while (Theme.Contrast(p.Text, p.SelRow) < 7 && t > 0.03) {
            t -= 0.02
            p.SelRow := Theme.Mix(p.Page, accent, t + 0.04)
        }
        p.HoverRow := Theme.Mix(p.Page, p.Text, 0.08)
        ; status tags: white text on a darkened fill; the amber one uses dark text instead
        p.Tag := Map()
        for k, c in Map("live", "#2E9E4F", "mock", "#7A5AF8", "manual", "#0F6CBD", "unavailable", "#C42B1C", "empty", "#6B6B6B", "history", "#5C6BC0")
            p.Tag[k] := {Bg: Theme.EnsureFill(c, "#FFFFFF", 4.6), Fg: "#FFFFFF"}
        p.Tag["stale"] := {Bg: "#D98A00", Fg: Theme.NEAR_BLACK}
        p.Green := "#2E9E4F"
        return p
    }

    ; --------------------------------------------------------------------- the generated CSS
    ; Everything colour-dependent (the app's own pages, the accent-filled library controls, the Spectrum band, the
    ; font). Structural CSS (sizes, layout) lives with the views. No variables, no grid, no gap: IE11.
    static Css(res) {
        p := res.Pal
        t := Map()
        for k in ["Page", "Card", "Rail", "Text", "Well", "CardWell", "Muted", "Red", "RedFill", "Amber", "AmberPage", "AmberCard",
            "AmberStrong", "Fill", "OnFill", "FillHover", "OnFillHover", "AccentText", "AccentBig", "AccentTint", "SelRow",
            "HoverRow", "Green", "Accent"]
            t[k] := p.%k%
        t["Line"] := "rgba(128,128,128,.35)"
        t["LineSoft"] := "rgba(128,128,128,.18)"
        t["Band"] := res.Band
        t["BandStrip"] := res.Look = "spectrum" ? res.Accent : res.Band
        px := Theme.FontPx(res.FontSize)
        t["Px"] := px
        stack := res.FontFamily != "" ? "'" res.FontFamily "', 'Segoe UI', sans-serif" : "'Segoe UI Variable Text', 'Segoe UI', sans-serif"
        t["Stack"] := stack
        tg := p.Tag
        for k in ["live", "mock", "manual", "unavailable", "stale", "empty", "history"] {
            t["Tag_" k] := tg[k].Bg
            t["TagFg_" k] := tg[k].Fg
        }

        css := Theme._Tpl()
        for k, v in t
            css := StrReplace(css, "{{" k "}}", v)
        return css
    }

    static _Tpl() => "
    (
    html { font-size: {{Px}}px; }
    body, button, input, select, textarea, .btn:not(.icon), .nav-item, .textbox input, .textbox textarea, .dd-value, .dd-item, .seg,
    .axdlg-btn, #axDlg, #axToast, #axTip, #axPop, .card, .caption, .hint, .radio, .check, .tab, .list-item
        { font-family: {{Stack}} !important; }
    body, .btn:not(.icon), .nav-item, .textbox input, .textbox textarea, .dd-value, .dd-item, .seg, .axdlg-btn, .tab, .list-item,
    select, input, textarea, #axDlgText, #axToast, #axTip, #axPop, .caption, .hint, .radio, .check
        { font-size: {{Px}}px !important; }
    #axFooter, #axHeader, #axFooter .nfs-notes { font-size: {{Px}}px; }

    body .btn.accent, body .axdlg-btn.primary, body .segmented .seg.active, body .chip.on
        { background: {{Fill}} !important; border-color: {{Fill}} !important; color: {{OnFill}} !important; }
    body .btn.accent:hover, body .axdlg-btn.primary:hover
        { background: {{FillHover}} !important; border-color: {{FillHover}} !important; color: {{OnFillHover}} !important; }
    body .nav-item.active, body .nav-item.active:hover
        { background: {{Fill}} !important; color: {{OnFill}} !important; font-weight: 600; }
    body a, body .link, body .hyperlink { color: {{AccentText}} !important; }

    body.sheet-win365:not(.inactive) #titlebar { background-color: {{Band}} !important; box-shadow: inset 0 -3px 0 {{BandStrip}}, 0 1px 4px rgba(0,0,0,.35); }
    body #titlebar .axtb-item.nfs-mock, body #titlebar .axtb-item.nfs-mock:hover
        { background: {{RedFill}} !important; color: #FFFFFF !important; }

    .nfs-ctx { border: 1px solid {{Line}}; background: {{Card}}; color: {{Text}}; }
    .nfs-ctx-t, .nfs-tile-l, .nfs-tile-s, .nfs-kv b { color: {{Muted}}; }
    .nfs-dot.ok { background: {{Green}}; }
    .nfs-dot.bad { background: {{RedFill}}; }
    .nfs-tag { color: {{TagFg_empty}}; background: {{Tag_empty}}; }
    .nfs-t-live { color: {{TagFg_live}}; background: {{Tag_live}}; }
    .nfs-t-mock { color: {{TagFg_mock}}; background: {{Tag_mock}}; }
    .nfs-t-manual { color: {{TagFg_manual}}; background: {{Tag_manual}}; }
    .nfs-t-unavailable { color: {{TagFg_unavailable}}; background: {{Tag_unavailable}}; }
    .nfs-t-stale { color: {{TagFg_stale}}; background: {{Tag_stale}}; }
    .nfs-t-empty { color: {{TagFg_empty}}; background: {{Tag_empty}}; }
    .nfs-t-history { color: {{TagFg_history}}; background: {{Tag_history}}; }
    .nfs-s-unavailable { color: {{Red}}; }
    .nfs-s-empty { color: {{Muted}}; }
    .nfs-edit { border-bottom: 1px dashed {{Muted}}; }
    .nfs-tile { border: 1px solid {{Line}}; background: {{Card}}; color: {{Text}}; }
    .nfs-tile:hover { border-color: {{Accent}}; }
    .nfs-tile-n { color: {{AccentBig}}; }
    .nfs-pop .tot { border-top: 1px solid {{Line}}; }
    .nfs-pop .meta { color: {{Muted}}; }
    .nav-item.nfs-used:after { background: #F7A600; border: 1px solid {{Rail}}; }
    .nfs-notes { border-top: 1px solid {{Line}}; }
    .nfs-regen { background: {{AmberPage}}; border: 1px solid {{Amber}}; color: {{Text}}; }
    .nfs-warn { color: {{Muted}}; }

    .nfs-sv-flags { border-left: 3px solid {{Amber}}; background: {{AmberPage}}; color: {{Text}}; }
    .nfs-sv-reqtag { color: {{Muted}}; }
    .nfs-sv-hint, .nfs-sv-star, .nfs-iv-msg, .nfs-iv-t.bad { color: {{Red}}; }
    .nfs-sv-stop { border: 2px solid {{Amber}}; background: {{AmberStrong}}; color: {{Text}}; }
    .nfs-sv-empty, .nfs-iv-empty, .nfs-iv-n { color: {{Muted}}; }

    .nfs-iv-prev { border-left: 3px solid {{Accent}}; background: {{AccentTint}}; color: {{Text}}; }
    .nfs-iv-row { border: 1px solid {{Line}}; background: {{Well}}; color: {{Text}}; }
    .nfs-iv-row.editing { border-color: {{Accent}}; background: {{AccentTint}}; }

    .nfs-st-k, .nfs-st-v.dim, .nfs-st-note, .nfs-st-addr { color: {{Muted}}; }
    .nfs-st-tag { color: {{TagFg_manual}}; background: {{Tag_manual}}; }
    .nfs-st-link { color: {{AccentText}}; border-bottom: 1px dashed {{AccentText}}; }
    .nfs-st-con { border: 1px solid {{Line}}; background: {{CardWell}}; color: {{Text}}; }
    .nfs-st-confirm { background: {{AmberCard}}; border: 1px solid {{Amber}}; color: {{Text}}; }

    .nfs-hist { border-top: 1px solid {{Line}}; }
    .nfs-hcols { color: {{Muted}}; border-bottom: 1px solid {{Line}}; }
    .nfs-hrow { color: {{Text}}; border-bottom: 1px solid {{LineSoft}}; }
    .nfs-hrow:hover { background: {{HoverRow}}; }
    .nfs-hrow.sel, .nfs-hrow.sel:hover { background: {{SelRow}}; }
    .nfs-hempty, .nfs-hhint, .nfs-hprev .m { color: {{Muted}}; }

    .nfs-dev .lbl, .nfs-dev .meta { color: {{Muted}}; }

    .nfs-set-h { border-bottom: 1px solid {{Line}}; }
    .nfs-set-k, .nfs-set-note { color: {{Muted}}; }
    .nfs-set-err { color: {{Red}}; }
    .nfs-set-state { background: {{AmberPage}}; border: 1px solid {{Amber}}; color: {{Text}}; }
    .nfs-sw { border: 1px solid {{Line}}; }
    .nfs-sw.on { border: 2px solid {{Text}}; }
    .nfs-set-val { color: {{Text}}; }
    )"

    ; --------------------------------------------------------------------- Settings page helpers
    ; "id:Label|id:Label" for an ax-dropdown (the caller escapes it for the attribute)
    static DdOptions(pairs) {
        s := ""
        for p in pairs
            s .= (s = "" ? "" : "|") p[1] ":" p[2]
        return s
    }

    ; A font's option id: letters and digits only ("Segoe UI" -> "segoeui").
    static FontId(name) => StrLower(RegExReplace(name, "[^A-Za-z0-9]", ""))

    ; --------------------------------------------------------------------- logo
    ; The logo is shown only if an approved file was put in <root>\assets (logo.png or logo.svg). Nothing is fetched and
    ; none is created; no file means no logo and no error. Returns the path, or "".
    static LogoPath(root) {
        for ext in ["png", "svg"] {
            p := RTrim(root, "\") "\assets\logo." ext
            if FileExist(p) && !InStr(FileExist(p), "D")
                return p
        }
        return ""
    }

    ; file:///C:/dir%20name/logo.png for an <img src>
    static FileUrl(path) => "file:///" StrReplace(StrReplace(StrReplace(path, "\", "/"), "%", "%25"), " ", "%20")

    ; --------------------------------------------------------------------- apply
    ; Put a resolved look on a window. prev (the previously applied result) lets a font-only change skip the heavy
    ; stylesheet / accent re-hue.
    static Apply(win, res, prev := "") {
        sheetChanged := IsObject(prev) && prev.Sheet != res.Sheet       ; the window is built with its first sheet
        if sheetChanged
            win.SetStylesheet(res.Sheet)
        if (!IsObject(prev) || sheetChanged || prev.Mode != res.Mode || prev.Accent != res.Accent)
            win.SetTheme(res.Mode, res.Accent)
        win.SetExtraCss("nfstheme", res.ExtraCss)
        return res
    }
}
