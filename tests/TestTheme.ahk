#Requires AutoHotkey v2.0

; TestTheme - colour helpers, WCAG contrast, Theme.Resolve (preset fallback, mode, accent, font, size) and the
; generated CSS (no var(), no grid, only valid colours). Headless: Theme has no GUI dependency.

class TestTheme {
    static Name := "Theme"

    static Run() {
        for name in ["Hex", "Contrast", "TextOn", "MixEnsure", "Palette", "Presets", "ResolveBasics", "ResolveMode", "ResolveAccent",
                "ResolveFont", "ResolveSheet", "Css", "CssColours", "Fonts", "Apply", "Sizes", "SchemaSync", "Swatches", "Logo", "ViewHelpers"]
            T.Case(name, ObjBindMethod(TestTheme, name))
    }

    static Cfg() => Defaults.Config()

    ; Settings stand-in: the same keys, as a Map.
    static S(kv*) {
        m := Map("preset", "", "mode", "", "accent", "", "fontFamily", "", "fontSize", 12)
        i := 1
        while (i < kv.Length) {
            m[kv[i]] := kv[i + 1]
            i += 2
        }
        return m
    }

    static R(settings, opts := "") => Theme.Resolve(settings, TestTheme.Cfg(), opts)

    static Hex() {
        for h in ["#0099D8", "#0099d8", "#000000", "#FFFFFF", "#aBcDeF"]
            T.True(Theme.IsHex(h), "valid: " h)
        for h in ["0099D8", "#09D", "#GG0000", "blue", "", "#0099D8F", "#0099D", " #0099D8", "#0099D8 ", "#0099D8`n", "rgb(0,0,0)"]
            T.False(Theme.IsHex(h), 'invalid: "' StrReplace(h, "`n", "\n") '"')
        T.False(Theme.IsHex(0), "a number is not a colour")
        T.False(Theme.IsHex(""), "empty is not a colour")
        c := Theme.Rgb("#0099D8")
        T.True(c.R = 0 && c.G = 153 && c.B = 216, "Rgb parses #0099D8")
        T.Eq(Theme.Hex(0, 153, 216), "#0099D8", "Hex formats upper case")
        T.Eq(Theme.Hex(-5, 300, 12.4), "#00FF0C", "Hex clamps and rounds")
        T.Throws(() => Theme.Rgb("blue"), "Rgb throws on junk")
    }

    static Contrast() {
        near := (v, e, name) => T.True(Abs(v - e) < 0.005, name " (got " Round(v, 4) ")")
        near(Theme.Contrast("#000000", "#FFFFFF"), 21, "black on white = 21")
        near(Theme.Contrast("#FFFFFF", "#000000"), 21, "white on black = 21 (order does not matter)")
        near(Theme.Contrast("#FFFFFF", "#FFFFFF"), 1, "white on white = 1")
        near(Theme.Contrast("#777777", "#FFFFFF"), 4.48, "#777777 on white = 4.48")
        near(Theme.Contrast("#767676", "#FFFFFF"), 4.54, "#767676 on white = 4.54 (the lightest grey that passes AA)")
        near(Theme.Contrast("#0099D8", "#FFFFFF"), 3.21, "Spectrum blue on white = 3.21")
        near(Theme.Lum("#FFFFFF"), 1, "luminance of white")
        near(Theme.Lum("#000000"), 0, "luminance of black")
    }

    static TextOn() {
        T.Eq(Theme.TextOn("#003057"), "#FFFFFF", "white on Spectrum navy")
        T.Eq(Theme.TextOn("#FFD200"), Theme.NEAR_BLACK, "near-black on yellow")
        T.Eq(Theme.TextOn("#0099D8"), Theme.NEAR_BLACK, "near-black on Spectrum blue (6:1 beats white 3.2:1)")
        T.Eq(Theme.TextOn("#000000"), "#FFFFFF", "white on black")
        T.Eq(Theme.TextOn("#FFFFFF"), Theme.NEAR_BLACK, "near-black on white")
        T.Eq(Theme.NEAR_BLACK, "#111111", "near-black is #111111")
    }

    static MixEnsure() {
        T.Eq(Theme.Mix("#000000", "#FFFFFF", 0), "#000000", "mix 0 = first")
        T.Eq(Theme.Mix("#000000", "#FFFFFF", 1), "#FFFFFF", "mix 1 = second")
        T.Eq(Theme.Mix("#000000", "#FFFFFF", 0.5), "#808080", "mix .5 = mid grey")
        T.Eq(Theme.Lighten("#000000", 1), "#FFFFFF", "lighten fully")
        T.Eq(Theme.Darken("#FFFFFF", 1), "#000000", "darken fully")
        T.Eq(Theme.Ensure("#242322", "#FFFFFF", 4.5), "#242322", "a passing colour is left alone")
        T.Eq(Theme.Ensure("#0099d8", "#FFFFFF", 1), "#0099D8", "a passing colour comes back upper case")
        c := Theme.Ensure("#FFD200", "#FFFFFF", 4.5)
        T.True(Theme.Contrast(c, "#FFFFFF") >= 4.5, "yellow on white is darkened until it passes: " c)
        c := Theme.Ensure("#003057", "#1B1A19", 4.5)
        T.True(Theme.Contrast(c, "#1B1A19") >= 4.5, "navy on a dark surface is lightened until it passes: " c)
        c := Theme.Ensure("#808080", ["#FFFFFF", "#000000"], 3)
        T.True(Theme.Contrast(c, "#FFFFFF") >= 3 || Theme.Contrast(c, "#000000") >= 3, "Ensure always ends at the better extreme")
        f := Theme.EnsureFill("#2E9E4F", "#FFFFFF", 4.6)
        T.True(Theme.Contrast(f, "#FFFFFF") >= 4.6, "a green tag fill is darkened for white text: " f)
        f := Theme.EnsureFill("#FFD200", Theme.NEAR_BLACK, 4.6)
        T.Eq(f, "#FFD200", "yellow already carries dark text")
    }

    ; Property test: for every accent and both modes, every text/background pair the CSS uses clears WCAG AA.
    static Palette() {
        accents := Theme.SWATCHES.Clone()
        for x in ["#000000", "#FFFFFF", "#808080", "#7A7A7A", "#767676", "#FF0000", "#00FF00", "#0000FF", "#336699", "#CCCC00", "#111111", "#EEEEEE"]
            accents.Push(x)
        bad := ""
        for mode in ["light", "dark"] {
            for a in accents {
                p := Theme.Palette(mode, a)
                tag := mode " " a
                chk := (name, ratio, min) => (ratio >= min ? "" : name " " Round(ratio, 2) " < " min "; ")
                for s in p.Surfaces {
                    bad .= chk(tag " text/" s, Theme.Contrast(p.Text, s), 7)
                    bad .= chk(tag " muted/" s, Theme.Contrast(p.Muted, s), 4.5)
                    bad .= chk(tag " red/" s, Theme.Contrast(p.Red, s), 4.5)
                    bad .= chk(tag " accentText/" s, Theme.Contrast(p.AccentText, s), 4.5)
                }
                bad .= chk(tag " accentBig/card", Theme.Contrast(p.AccentBig, p.Card), 3)
                bad .= chk(tag " onFill", Theme.Contrast(p.OnFill, p.Fill), 4.5)
                bad .= chk(tag " onFillHover", Theme.Contrast(p.OnFillHover, p.FillHover), 4.5)
                bad .= chk(tag " text/accentTint", Theme.Contrast(p.Text, p.AccentTint), 4.5)
                bad .= chk(tag " text/selRow", Theme.Contrast(p.Text, p.SelRow), 4.5)
                bad .= chk(tag " text/hoverRow", Theme.Contrast(p.Text, p.HoverRow), 4.5)
                bad .= chk(tag " text/amberPage", Theme.Contrast(p.Text, p.AmberPage), 4.5)
                bad .= chk(tag " text/amberStrong", Theme.Contrast(p.Text, p.AmberStrong), 4.5)
                bad .= chk(tag " text/amberCard", Theme.Contrast(p.Text, p.AmberCard), 4.5)
                bad .= chk(tag " white/redFill", Theme.Contrast("#FFFFFF", p.RedFill), 4.5)
                for k, tg in p.Tag
                    bad .= chk(tag " tag " k, Theme.Contrast(tg.Fg, tg.Bg), 4.5)
            }
        }
        T.Eq(bad, "", "all palette pairs pass AA for 20 accents x 2 modes")
        p := Theme.Palette("light", "#0099D8")
        T.Eq(p.AccentBig, "#0099D8", "Spectrum blue is large enough on its own for the tile number (3.2:1 on the white tile)")
        T.Eq(p.Fill, "#0099D8", "Spectrum blue fills a button as it is")
        T.Eq(p.OnFill, Theme.NEAR_BLACK, "and carries dark text")
        p := Theme.Palette("dark", "#FFD200")
        T.Eq(p.OnFill, Theme.NEAR_BLACK, "dark text on a yellow fill")
        p := Theme.Palette("dark", "#003057")
        T.Eq(p.OnFill, "#FFFFFF", "white text on a navy fill")
        T.True(Theme.Contrast(p.AccentBig, p.Card) >= 3 && p.AccentBig != "#003057", "navy as text on dark is lightened for the tile number")
    }

    static Presets() {
        cfg := TestTheme.Cfg()
        ps := Theme.Presets(cfg)
        T.Eq(ps.Length, 3, "three presets in the defaults")
        T.Eq(Theme.DefaultPresetId(cfg), "spectrum-light", "default preset id")
        T.Eq(Theme.FindPreset(ps, "spectrum-dark")["mode"], "dark", "find by id")
        T.Eq(Theme.FindPreset(ps, "SPECTRUM-DARK")["id"], "spectrum-dark", "find ignores case")
        T.True(Theme.FindPreset(ps, "nope") = "", "missing id finds nothing")
        T.True(Theme.FindPreset(ps, "") = "", "empty id finds nothing")
        T.Eq(Theme.Presets("").Length, 0, "no config: no presets")
        cfg["themes"]["presets"].Push(Map("id", "broken"))
        T.Eq(Theme.Presets(cfg).Length, 3, "a preset missing keys is skipped")
    }

    static ResolveBasics() {
        r := TestTheme.R(TestTheme.S())
        T.Eq(r.PresetId, "spectrum-light", "defaults: the config's default look")
        T.Eq(r.Sheet, "win365", "spectrum is the library's win365 plus generated CSS")
        T.Eq(r.Look, "spectrum", "look is spectrum")
        T.Eq(r.Mode, "light", "mode follows the look")
        T.Eq(r.Accent, "#0099D8", "the look's accent")
        T.False(r.CustomAccent, "not a custom accent")
        T.Eq(r.FontFamily, "", "default font")
        T.Eq(r.FontSize, 12, "default size")
        T.Eq(r.Band, "#003057", "Spectrum navy band")
        T.Eq(r.Warnings.Length, 0, "no warnings")
        T.True(StrLen(r.ExtraCss) > 1000, "CSS was generated")
        ; the same with a Settings object
        s := Settings({Dir: A_Temp "\NFSNotesTest_Theme_none_" A_TickCount}).Load()
        r2 := Theme.Resolve(s, TestTheme.Cfg())
        T.Eq(r2.ExtraCss, r.ExtraCss, "a Settings object resolves like the same values in a Map")
        ; preset fallback
        r := TestTheme.R(TestTheme.S("preset", "no-such-look"))
        T.Eq(r.PresetId, "spectrum-light", "unknown preset: the default look")
        T.Eq(r.Warnings.Length, 1, "unknown preset: one warning")
        T.Contains(r.Warnings[1], "no-such-look", "the warning names the preset")
        cfg := TestTheme.Cfg()
        cfg["themes"]["default"] := "gone"
        r := Theme.Resolve(TestTheme.S("preset", "gone2"), cfg)
        T.Eq(r.PresetId, "spectrum-light", "default id missing too: the first preset")
        cfg["themes"]["presets"] := []
        r := Theme.Resolve(TestTheme.S(), cfg)
        T.Eq(r.PresetId, "spectrum-light", "no presets at all: the built-in Spectrum look")
        r := Theme.Resolve(TestTheme.S(), "")
        T.Eq(r.Accent, "#0099D8", "no config at all: still Spectrum")
        r := TestTheme.R(TestTheme.S("preset", "spectrum-dark"))
        T.Eq(r.PresetId, "spectrum-dark", "a known preset is used")
        T.Eq(r.Mode, "dark", "the preset's mode applies when the mode is not set")
        r := TestTheme.R(TestTheme.S("preset", "win365"))
        T.Eq(r.Look, "plain", "the plain preset is not Spectrum")
        T.Eq(r.Sheet, "win365", "plain preset: win365")
        T.Eq(r.Accent, "#0F6CBD", "plain preset accent")
    }

    static ResolveMode() {
        T.Eq(TestTheme.R(TestTheme.S("mode", "dark")).Mode, "dark", "mode dark")
        T.Eq(TestTheme.R(TestTheme.S("mode", "light", "preset", "spectrum-dark")).Mode, "light", "explicit light beats a dark look")
        T.Eq(TestTheme.R(TestTheme.S("mode", "dark", "preset", "spectrum-light")).Mode, "dark", "explicit dark beats a light look")
        r := TestTheme.R(TestTheme.S("mode", "system"), {SystemMode: "dark"})
        T.Eq(r.Mode, "dark", "system follows Windows (dark)")
        T.Eq(r.ModeSetting, "system", "the setting is remembered as system")
        r := TestTheme.R(TestTheme.S("mode", "system", "preset", "spectrum-dark"), {SystemMode: "light"})
        T.Eq(r.Mode, "light", "system follows Windows (light) even for a dark look")
        r := TestTheme.R(TestTheme.S("mode", "sepia"))
        T.Eq(r.Mode, "light", "a bad mode falls back to the look's")
        T.True(Theme.SystemMode() = "light" || Theme.SystemMode() = "dark", "SystemMode is light or dark")
        ; the palette, and so the CSS, differ by mode
        a := TestTheme.R(TestTheme.S("mode", "light")).ExtraCss
        b := TestTheme.R(TestTheme.S("mode", "dark")).ExtraCss
        T.True(a != b, "light and dark CSS differ")
    }

    static ResolveAccent() {
        r := TestTheme.R(TestTheme.S("accent", "#FFD200"))
        T.Eq(r.Accent, "#FFD200", "a custom accent overrides the preset")
        T.True(r.CustomAccent, "flagged custom")
        T.Contains(r.ExtraCss, "#FFD200", "the custom accent is in the CSS")
        r := TestTheme.R(TestTheme.S("accent", "#ffd200"))
        T.Eq(r.Accent, "#FFD200", "lower case is normalised")
        r := TestTheme.R(TestTheme.S("accent", "banana"))
        T.Eq(r.Accent, "#0099D8", "an invalid accent is ignored")
        T.Eq(r.Warnings.Length, 1, "and warned about")
        r := TestTheme.R(TestTheme.S("accent", "#FFD200", "preset", "win365"))
        T.Eq(r.Accent, "#FFD200", "custom accent on the plain look too")
        T.Contains(r.ExtraCss, ".nfs-tile:hover { border-color: #FFD200; }", "the custom accent is what the CSS uses on the plain look too")
        ; Spectrum keeps its navy band whatever the accent; a plain look gets a band made from the accent
        r := TestTheme.R(TestTheme.S("accent", "#FFD200"))
        T.Eq(r.Band, "#003057", "navy band stays with a yellow accent")
        r := TestTheme.R(TestTheme.S("accent", "#FFD200", "preset", "win365"))
        T.True(r.Band != "#003057" && Theme.Contrast(r.Band, "#FFFFFF") >= 4.5, "plain look: the band is derived from the accent and carries white text")
    }

    static ResolveFont() {
        names := ["Segoe UI (TrueType)", "Arial (TrueType)", "Arial Bold (TrueType)", "Tahoma (TrueType)", "Verdana Pro (OpenType)"]
        r := TestTheme.R(TestTheme.S("fontFamily", "Arial"), {Fonts: names})
        T.Eq(r.FontFamily, "Arial", "an installed font is used")
        T.Contains(r.ExtraCss, "'Arial', 'Segoe UI', sans-serif", "the font stack has a fallback")
        r := TestTheme.R(TestTheme.S("fontFamily", "Calibri"), {Fonts: names})
        T.Eq(r.FontFamily, "", "a font that is not installed falls back to the default")
        T.Eq(r.Warnings.Length, 1, "with a warning")
        T.Contains(r.Warnings[1], "Calibri", "naming the font")
        T.NotContains(r.ExtraCss, "Calibri", "and it is not in the CSS")
        r := TestTheme.R(TestTheme.S("fontFamily", "Verdana"), {Fonts: names})
        T.Eq(r.FontFamily, "", "Verdana Pro is not Verdana")
        r := TestTheme.R(TestTheme.S("fontFamily", "Segoe UI"), {Fonts: []})
        T.Eq(r.FontFamily, "", "Segoe UI is the default and needs no check")
        T.Eq(r.Warnings.Length, 0, "and no warning")
        r := TestTheme.R(TestTheme.S("fontFamily", "Comic Sans MS"), {Fonts: names})
        T.Eq(r.FontFamily, "", "a font outside the allowed list is never used")
        ; size
        T.Eq(TestTheme.R(TestTheme.S("fontSize", 9)).FontSize, 9, "size 9")
        T.Eq(TestTheme.R(TestTheme.S("fontSize", 20)).FontSize, 20, "size 20")
        T.Eq(TestTheme.R(TestTheme.S("fontSize", 99)).FontSize, 12, "size 99 falls back to 12")
        T.Eq(TestTheme.R(TestTheme.S("fontSize", "big")).FontSize, 12, "size text falls back to 12")
        T.Contains(TestTheme.R(TestTheme.S("fontSize", 20)).ExtraCss, "html { font-size: 23px; }", "size 20 -> 23px root")
        T.Contains(TestTheme.R(TestTheme.S("fontSize", 12)).ExtraCss, "html { font-size: 14px; }", "size 12 -> 14px root (the library's normal)")
    }

    static ResolveSheet() {
        cfg := TestTheme.Cfg()
        cfg["themes"]["presets"].Push(Map("id", "old", "label", "Old", "sheet", "win98", "mode", "light", "accent", "#000080"))
        cfg["themes"]["presets"].Push(Map("id", "odd", "label", "Odd", "sheet", "nosuchsheet", "mode", "light", "accent", "#000080"))
        r := Theme.Resolve(TestTheme.S("preset", "old"), cfg)
        T.True(r.Sheet = "win98" && r.Look = "plain", "a library look is passed through")
        r := Theme.Resolve(TestTheme.S("preset", "odd"), cfg)
        T.Eq(r.Sheet, "win365", "an unknown sheet becomes win365")
        T.Eq(r.Warnings.Length, 1, "with a warning")
        s := Theme.SheetFor("Spectrum")
        T.True(s.Lib = "win365" && s.Look = "spectrum", "Spectrum is case-insensitive")
    }

    static Css() {
        accents := ["#0099D8", "#FFD200", "#003057", "#000000", "#FFFFFF"]
        for preset in ["spectrum-light", "spectrum-dark", "win365"]
            for a in accents
                for fam in ["", "Arial"]
                    for sz in [9, 12, 20] {
                        r := TestTheme.R(TestTheme.S("preset", preset, "accent", a, "fontFamily", fam, "fontSize", sz), {Fonts: ["Arial (TrueType)"]})
                        css := r.ExtraCss
                        id := preset " " a " " fam " " sz
                        if (InStr(css, "var(") || RegExMatch(css, "i)\bgrid\b") || RegExMatch(css, "i)\bgap\s*:") || InStr(css, "{{") || InStr(css, "}}"))
                            T.Record(false, "css hygiene " id, "var( / grid / gap / unresolved token")
                        bad := TestTheme.BadColours(css)
                        if (bad != "")
                            T.Record(false, "css colours " id, bad)
                    }
        T.Record(true, "generated CSS: no var(, no grid, no gap, no unresolved token, only hex/rgba colours (90 combinations)")
        r := TestTheme.R(TestTheme.S())
        css := r.ExtraCss
        T.NotContains(css, "var(", "no CSS variables")
        T.False(RegExMatch(css, "i)\bgrid\b") > 0, "no grid")
        T.False(RegExMatch(css, "i)\bgap\b") > 0, "no gap")
        T.NotContains(css, "backdrop-filter", "no backdrop-filter")
        T.Contains(css, "#003057", "the Spectrum navy band is in the Spectrum CSS")
        T.Contains(css, "#titlebar", "the band rule targets the title bar")
        T.Contains(css, "inset 0 -3px 0 #0099D8", "a thin accent strip under the band")
        T.NotContains(TestTheme.R(TestTheme.S("preset", "win365")).ExtraCss, "#003057", "the plain look has no Spectrum navy")
        for sel in [".nfs-tile-n", ".nfs-tag", ".nfs-t-mock", ".nfs-sv-stop", ".nfs-sv-hint", ".nfs-st-con", ".nfs-hrow", ".btn.accent", ".nav-item.active", ".nfs-set-err", ".nfs-sw.on"]
            T.Contains(css, sel, "CSS covers " sel)
        ; the accent is where the app used to hard-code #0099D8
        css := TestTheme.R(TestTheme.S("accent", "#FFD200")).ExtraCss
        T.Contains(css, ".nfs-tile:hover { border-color: #FFD200; }", "tile hover border uses the accent")
        T.NotContains(css, "#0099D8", "no leftover Spectrum blue with another accent (the band strip follows the accent too)")
    }

    ; Every colour in a colour-bearing declaration must be #RRGGBB or rgba(); returns "" or a list of offenders.
    static BadColours(css) {
        bad := ""
        pos := 1
        while RegExMatch(css, "([a-z-]+)\s*:\s*([^;{}]*)", &m, pos) {
            pos := m.Pos + m.Len
            prop := m[1]
            if !RegExMatch(prop, "^(?:color|background|background-color|border|border-(?:left|right|top|bottom|color)|box-shadow|outline)$")
                continue
            v := m[2]
            v := RegExReplace(v, "#[0-9A-F]{6}(?![0-9A-Za-z])", "")
            v := RegExReplace(v, "rgba\(\d{1,3},\s*\d{1,3},\s*\d{1,3},\s*\.?\d+(?:\.\d+)?\)", "")
            v := RegExReplace(v, "i)!important|\binset\b|\bsolid\b|\bdashed\b|-?\d*\.?\d+px|\b0\b|,", "")
            if (Trim(v) != "")
                bad .= prop ": " m[2] " [left: " Trim(v) "]; "
        }
        return bad
    }

    static CssColours() {
        ; the checker itself must catch bad values
        T.True(TestTheme.BadColours(".a { color: #12345; }") != "", "checker: short hex is caught")
        T.True(TestTheme.BadColours(".a { background: blue; }") != "", "checker: a colour name is caught")
        T.True(TestTheme.BadColours(".a { border: 1px solid red; }") != "", "checker: red is caught")
        T.True(TestTheme.BadColours(".a { color: rgb(1,2,3); }") != "", "checker: rgb() is caught")
        T.Eq(TestTheme.BadColours(".a { border: 1px dashed #AABBCC; color: #FFFFFF !important; background: rgba(128,128,128,.35); box-shadow: inset 0 -3px 0 #0099D8, 0 1px 4px rgba(0,0,0,.35); }"), "", "checker: valid values pass")
    }

    static Fonts() {
        names := ["Arial (TrueType)", "Tahoma Bold (TrueType)", "Verdana Pro (OpenType)", "Calibri Light (TrueType)"]
        got := ""
        for f in Theme.AvailableFonts(names)
            got .= (got = "" ? "" : ",") f
        T.Eq(got, "Segoe UI,Calibri,Arial,Tahoma", "present fonts only (Segoe UI always; Verdana Pro is not Verdana)")
        got := ""
        for f in Theme.AvailableFonts([])
            got .= (got = "" ? "" : ",") f
        T.Eq(got, "Segoe UI", "nothing registered: Segoe UI only")
        got := ""
        for f in Theme.AvailableFonts(["arial (truetype)", "TAHOMA (TrueType)"])
            got .= (got = "" ? "" : ",") f
        T.Eq(got, "Segoe UI,Arial,Tahoma", "matching ignores case")
        all := Theme.AvailableFonts(["Calibri (TrueType)", "Arial (TrueType)", "Tahoma (TrueType)", "Verdana (TrueType)"])
        T.Eq(all.Length, 5, "all five when all are present")
        ; the real registry: Segoe UI always, and nothing outside the list
        real := Theme.AvailableFonts()
        T.True(real.Length >= 1 && real[1] = "Segoe UI", "the real list starts with Segoe UI")
        for f in real
            T.True(Settings.InList(Settings.FONTS, f), "real font " f " is in the allowed list")
        T.True(Theme.InstalledFontNames() is Array, "InstalledFontNames returns an array")
    }

    static Apply() {
        calls := []
        w := {}
        w.SetStylesheet := (self, n) => calls.Push("sheet:" n)
        w.SetTheme := (self, m, a) => calls.Push("theme:" m "," a)
        w.SetExtraCss := (self, id, css) => calls.Push("css:" id)
        r1 := TestTheme.R(TestTheme.S())
        Theme.Apply(w, r1)
        T.Eq(calls.Length, 2, "first apply: theme and css (the window was built with the sheet)")
        T.Eq(calls[1], "theme:light,#0099D8", "theme and accent are set")
        T.Eq(calls[2], "css:nfstheme", "generated CSS goes in as nfstheme")
        calls.Length := 0
        r2 := TestTheme.R(TestTheme.S("fontSize", 15))
        Theme.Apply(w, r2, r1)
        T.Eq(calls.Length, 1, "a size-only change repaints only the CSS")
        calls.Length := 0
        r3 := TestTheme.R(TestTheme.S("fontSize", 15, "mode", "dark"))
        Theme.Apply(w, r3, r2)
        T.Eq(calls.Length, 2, "a mode change sets the theme and the CSS")
        calls.Length := 0
        r4 := TestTheme.R(TestTheme.S("preset", "win365", "mode", "dark"))
        Theme.Apply(w, r4, r3)
        T.Eq(calls.Length, 2, "same library sheet (win365): no stylesheet swap")
        cfg := TestTheme.Cfg()
        cfg["themes"]["presets"].Push(Map("id", "old", "label", "Old", "sheet", "win98", "mode", "light", "accent", "#000080"))
        calls.Length := 0
        r5 := Theme.Resolve(TestTheme.S("preset", "old"), cfg)
        Theme.Apply(w, r5, r4)
        T.Eq(calls[1], "sheet:win98", "another library sheet is swapped in first")
        T.Eq(calls.Length, 3, "then theme and CSS")
    }

    static Sizes() {
        T.Eq(Theme.FontPx(12), 14, "12 -> 14 px")
        T.Eq(Theme.FontPx(9), 11, "9 -> 11 px")
        T.Eq(Theme.FontPx(20), 23, "20 -> 23 px")
        last := 0
        for n in [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20] {
            px := Theme.FontPx(n)
            T.True(px > last, "sizes grow: " n " -> " px)
            last := px
        }
    }

    static SchemaSync() {
        ; the Schema list and Theme's list of library looks must agree (Schema adds "spectrum")
        a := Map(), b := Map()
        for s in Schema.SHEETS
            a[s] := 1
        for s in Theme.LIB_SHEETS
            b[s] := 1
        b["spectrum"] := 1
        ok := a.Count = b.Count
        for k in a
            ok := ok && b.Has(k)
        T.True(ok, "Schema.SHEETS == Theme.LIB_SHEETS + spectrum")
    }

    static Swatches() {
        T.Eq(Theme.SWATCHES.Length, 8, "8 swatches")
        T.Eq(Theme.SWATCHES[1], "#0099D8", "Spectrum blue is the first swatch")
        seen := Map()
        for c in Theme.SWATCHES {
            T.True(Theme.IsHex(c), "swatch " c " is a colour")
            seen[c] := 1
        }
        T.Eq(seen.Count, 8, "swatches are distinct")
        T.True(Settings.InList(["#0099D8"], Theme.SWATCHES[1]), "sanity")
    }

    ; A logo is shown only when an approved file exists in assets\ (png or svg); nothing is created or fetched.
    static Logo() {
        root := A_Temp "\NFSNotesTest_Logo_" A_TickCount
        DirCreate(root)
        T.Eq(Theme.LogoPath(root), "", "no assets folder: no logo")
        DirCreate(root "\assets")
        T.Eq(Theme.LogoPath(root), "", "empty assets folder: no logo")
        DirCreate(root "\assets\logo.png")
        T.Eq(Theme.LogoPath(root), "", "a folder named logo.png is not a logo")
        DirDelete(root "\assets\logo.png")
        FileAppend("<svg/>", root "\assets\logo.svg", "UTF-8-RAW")
        T.Eq(Theme.LogoPath(root), root "\assets\logo.svg", "logo.svg is found")
        FileAppend("x", root "\assets\logo.png", "UTF-8-RAW")
        T.Eq(Theme.LogoPath(root), root "\assets\logo.png", "logo.png wins over logo.svg")
        FileAppend("x", root "\assets\logo.jpg", "UTF-8-RAW")
        FileDelete(root "\assets\logo.png")
        FileDelete(root "\assets\logo.svg")
        T.Eq(Theme.LogoPath(root), "", "other formats are not used")
        T.Eq(Theme.FileUrl("C:\My Dir\assets\logo.png"), "file:///C:/My%20Dir/assets/logo.png", "file URL escapes spaces")
        try DirDelete(root, true)
        T.Eq(Theme.LogoPath(A_ScriptDir "\.."), "", "this project ships no logo (none is created or downloaded)")
    }

    static ViewHelpers() {
        T.Eq(Theme.FontId("Segoe UI"), "segoeui", "font option id: letters and digits only")
        T.Eq(Theme.FontId("Calibri"), "calibri", "font option id lower case")
        T.Eq(Theme.DdOptions([["a", "Alpha"], ["b", "Beta (default)"]]), "a:Alpha|b:Beta (default)", "dropdown options string")
        d := Settings.AppearanceDefaults()
        T.Eq(d.Count, 5, "five appearance defaults")
        T.True(d["preset"] = "" && d["mode"] = "" && d["accent"] = "" && d["fontFamily"] = "" && d["fontSize"] = 12, "the appearance defaults")
        for k in Settings.APPEARANCE_KEYS
            T.True(d.Has(k), "appearance default for " k)
        T.False(d.Has("window") || d.Has("alwaysOnTop") || d.Has("historyOpen") || d.Has("lastPage"), "Restore defaults leaves window, pin, history and page alone")
    }
}
