#Requires AutoHotkey v2.0

class TestSettings {
    static Name := "Settings"
    static Root := ""

    static Run() {
        TestSettings.Root := A_Temp "\NFSNotesTest_Settings_" A_TickCount
        for name in ["Defaults", "RoundTrip", "Corrupt", "Invalid", "Repair", "Migrate", "Appearance", "Fallbacks"]
            T.Case(name, ObjBindMethod(TestSettings, name))
        try DirDelete(TestSettings.Root, true)
    }

    static Dir(name) => TestSettings.Root "\" name

    static Defaults() {
        s := Settings({Dir: TestSettings.Dir("defaults")}).Load()
        T.Eq(s.Warnings.Length, 0, "missing file: no warning")
        T.Eq(s.Get("mode"), "", "default mode: the look's own")
        T.Eq(s.Get("preset"), "", "default preset: the config's default look")
        T.Eq(s.Get("fontFamily"), "", "default font: the look's own")
        T.Throws(() => s.Get("theme"), "the old theme key is no longer a setting")
        T.Eq(s.Get("accent"), "", "default accent is empty (use config)")
        T.Eq(s.Get("fontSize"), 12, "default font size")
        T.Eq(s.Get("alwaysOnTop"), 0, "default pin off")
        T.Eq(s.Get("historyOpen"), 0, "default history closed")
        T.Eq(s.Get("lastPage"), "", "default last page")
        w := s.Get("window")
        T.True(w["x"] = "" && w["y"] = "" && w["w"] = "" && w["h"] = "", "window unset by default")
        T.False(FileExist(s.Path), "Load does not create the file")
        T.Eq(Settings({}).Dir, A_MyDocuments "\NotesForNFS", "default directory is Documents\NotesForNFS")
    }

    static RoundTrip() {
        dir := TestSettings.Dir("round")
        s := Settings({Dir: dir}).Load()
        T.True(s.Set("mode", "dark"), "set mode")
        T.True(s.Set("preset", "spectrum-dark"), "set preset")
        T.True(s.Set("accent", "#12abEF"), "set accent")
        T.True(s.Set("fontFamily", "Segoe UI"), "set font family")
        T.True(s.Set("fontSize", 15), "set font size")
        T.True(s.Set("alwaysOnTop", true), "set pin (true)")
        T.True(s.Set("historyOpen", 1), "set history open")
        T.True(s.Set("lastPage", "billing"), "set last page")
        T.True(s.Set("window", Map("x", 100, "y", -20, "w", 820, "h", 680)), "set window")
        T.True(s.Save(), "save")
        T.False(FileExist(s.Path ".tmp"), "no .tmp left")
        T.Contains(FileRead(s.Path, "UTF-8-RAW"), '"alwaysOnTop": true', "booleans written as true/false")
        s2 := Settings({Dir: dir}).Load()
        T.Eq(s2.Warnings.Length, 0, "reload: no warnings")
        T.Eq(s2.Get("mode"), "dark", "round trip mode")
        T.Eq(s2.Get("preset"), "spectrum-dark", "round trip preset")
        T.NotContains(FileRead(s.Path, "UTF-8-RAW"), '"theme"', "the file has no theme key any more")
        T.Eq(s2.Get("accent"), "#12ABEF", "round trip accent (normalised)")
        T.Eq(s2.Get("fontFamily"), "Segoe UI", "round trip font")
        T.Eq(s2.Get("fontSize"), 15, "round trip size")
        T.Eq(s2.Get("alwaysOnTop"), 1, "round trip pin")
        T.Eq(s2.Get("historyOpen"), 1, "round trip history")
        T.Eq(s2.Get("lastPage"), "billing", "round trip page")
        w := s2.Get("window")
        T.True(w["x"] = 100 && w["y"] = -20 && w["w"] = 820 && w["h"] = 680, "round trip window")
        ; partial window (size only)
        s2.Set("window", Map("w", 700, "h", 600))
        w := s2.Get("window")
        T.True(w["x"] = "" && w["w"] = 700, "partial window keeps unset fields empty")
        ; Get returns a copy
        w["w"] := 1
        T.Eq(s2.Get("window")["w"], 700, "Get returns a copy")
    }

    static Corrupt() {
        dir := TestSettings.Dir("corrupt")
        DirCreate(dir)
        FileAppend('{"theme": "dark", ', dir "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir}).Load()
        T.Eq(s.Get("mode"), "", "corrupt file: defaults used")
        T.True(s.Warnings.Length >= 1, "corrupt file: warning")
        T.False(FileExist(dir "\settings.json"), "corrupt file moved away")
        n := 0
        Loop Files dir "\settings.bad-*.json" {
            n += 1
            T.Eq(FileRead(A_LoopFileFullPath, "UTF-8-RAW"), '{"theme": "dark", ', "bad file content kept")
        }
        T.Eq(n, 1, "exactly one settings.bad-*.json kept")
        T.True(s.BadFile != "", "BadFile path reported")
        s.Set("mode", "dark"), s.Save()
        T.Eq(Settings({Dir: dir}).Load().Get("mode"), "dark", "usable after recovery")
        ; valid JSON that is not an object counts as corrupt too
        dir2 := TestSettings.Dir("corrupt2")
        DirCreate(dir2)
        FileAppend("[1,2,3]", dir2 "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir2}).Load()
        T.True(s.Warnings.Length >= 1 && s.BadFile != "", "non-object JSON treated as corrupt")
    }

    static Invalid() {
        s := Settings({Dir: TestSettings.Dir("invalid")}).Load()
        T.False(s.Set("accent", "blue"), 'accent "blue" rejected')
        T.False(s.Set("accent", "#12345"), "short accent rejected")
        T.False(s.Set("fontSize", 99), "fontSize 99 rejected")
        T.False(s.Set("fontSize", 8), "fontSize 8 rejected")
        T.False(s.Set("fontSize", "12"), "fontSize text rejected")
        T.False(s.Set("mode", "sepia"), "mode sepia rejected")
        T.False(s.Set("theme", "dark"), "theme is not a setting any more")
        T.False(s.Set("alwaysOnTop", 2), "pin 2 rejected")
        T.False(s.Set("lastPage", "a b/c"), "bad page id rejected")
        T.False(s.Set("window", Map("x", "left")), "window text coordinate rejected")
        T.False(s.Set("window", Map("q", 1)), "unknown window field rejected")
        T.False(s.Set("window", Map("w", 5)), "tiny window width rejected")
        T.False(s.Set("nosuchkey", 1), "unknown key rejected")
        T.Eq(s.Get("fontSize"), 12, "rejected value did not change the setting")
        T.Eq(s.Get("accent"), "", "rejected accent did not change the setting")
        T.True(s.Set("fontSize", 9) && s.Set("fontSize", 20), "font size bounds 9 and 20 accepted")
        T.True(s.Set("accent", ""), "empty accent (use config default) accepted")
        T.Throws(() => s.Get("nosuchkey"), "Get unknown key throws")
    }

    static Repair() {
        dir := TestSettings.Dir("repair")
        DirCreate(dir)
        FileAppend('{"mode": "dark", "fontSize": 99, "accent": "blue", "extra": 1}', dir "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir}).Load()
        T.Eq(s.Get("mode"), "dark", "valid field kept")
        T.Eq(s.Get("fontSize"), 12, "invalid font size reset on load")
        T.Eq(s.Get("accent"), "", "invalid accent reset on load")
        T.Eq(s.Warnings.Length, 2, "one warning per repaired field")
        T.True(FileExist(dir "\settings.json") != "", "file with some bad fields is not quarantined")
    }

    ; Files from before M9 only have theme: light|dark. It becomes mode; the next save writes mode and no theme.
    static Migrate() {
        for pair in [["dark", "dark"], ["light", "light"]] {
            dir := TestSettings.Dir("mig_" pair[1])
            DirCreate(dir)
            FileAppend('{"theme": "' pair[1] '", "fontSize": 14, "lastPage": "billing"}', dir "\settings.json", "UTF-8-RAW")
            s := Settings({Dir: dir}).Load()
            T.Eq(s.Get("mode"), pair[2], "old theme " pair[1] " becomes mode")
            T.Eq(s.Warnings.Length, 0, "old theme " pair[1] ": no warning")
            T.Eq(s.Get("fontSize"), 14, "other old values are kept")
            s.Save()
            txt := FileRead(dir "\settings.json", "UTF-8-RAW")
            T.NotContains(txt, '"theme"', "saved again: no theme key")
            T.Contains(txt, '"mode": "' pair[2] '"', "saved again: mode written")
            T.Eq(Settings({Dir: dir}).Load().Get("mode"), pair[2], "mode survives the round trip")
        }
        ; mode wins over a leftover theme
        dir := TestSettings.Dir("mig_both")
        DirCreate(dir)
        FileAppend('{"theme": "light", "mode": "system"}', dir "\settings.json", "UTF-8-RAW")
        T.Eq(Settings({Dir: dir}).Load().Get("mode"), "system", "mode beats the old theme key")
        ; a bad old theme: warning, default
        dir := TestSettings.Dir("mig_bad")
        DirCreate(dir)
        FileAppend('{"theme": "sepia"}', dir "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir}).Load()
        T.Eq(s.Get("mode"), "", "bad old theme: default mode")
        T.Eq(s.Warnings.Length, 1, "bad old theme: one warning")
        ; the real-life file of this PC (written by M2): theme light, no appearance keys
        dir := TestSettings.Dir("mig_m2")
        DirCreate(dir)
        FileAppend('{"accent": "", "alwaysOnTop": false, "fontFamily": "", "fontSize": 12, "historyOpen": false, "lastPage": "static", "theme": "light", "window": {"h": 1373, "w": 1000, "x": 2413, "y": 0}}', dir "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir}).Load()
        T.True(s.Warnings.Length = 0 && s.Get("mode") = "light" && s.Get("preset") = "" && s.Get("fontSize") = 12, "an M2 settings file loads clean")
    }

    ; preset / mode / font / size validation
    static Appearance() {
        s := Settings({Dir: TestSettings.Dir("appearance")}).Load()
        for m in ["light", "dark", "system", "", "Dark", "SYSTEM"]
            T.True(s.Set("mode", m), 'mode "' m '" accepted')
        T.Eq(s.Get("mode"), "system", "mode is stored in lower case")
        for m in ["sepia", "auto", 1, "dark "]
            T.False(s.Set("mode", m), 'mode "' m '" rejected')
        T.Eq(s.Get("mode"), "system", "rejected mode changed nothing")
        for p in ["spectrum-light", "win365", "A", ""]
            T.True(s.Set("preset", p), 'preset "' p '" accepted')
        for p in ["1abc", "has space", "a/b", "x;y", 5]
            T.False(s.Set("preset", p), 'preset "' p '" rejected')
        for f in Settings.FONTS
            T.True(s.Set("fontFamily", f), "font " f " accepted")
        T.True(s.Set("fontFamily", "calibri") && s.Get("fontFamily") = "Calibri", "font names are matched ignoring case and stored in canonical case")
        T.True(s.Set("fontFamily", ""), "empty font (the look's own) accepted")
        for f in ["Comic Sans MS", "Segoe UI; color:red", "Arial}", "<b>"]
            T.False(s.Set("fontFamily", f), 'font "' f '" rejected')
        T.True(s.Set("fontSize", 9) && s.Set("fontSize", 20) && s.Set("fontSize", 12), "text sizes 9, 20 and 12 accepted")
        for z in [8, 21, 0, -1, "12", 12.5, ""]
            T.False(s.Set("fontSize", z), "text size " z " rejected")
        T.False(s.Set("accent", "#0099D8`n"), "an accent with a trailing newline is rejected")
        T.False(s.Set("accent", " #0099D8"), "an accent with a leading space is rejected")
        T.True(s.Set("accent", "#0099d8") && s.Get("accent") = "#0099D8", "accent accepted and upper-cased")
        T.Eq(Settings.APPEARANCE_KEYS.Length, 5, "five appearance keys")
    }

    ; invalid values in a file fall back to the defaults, one warning each (as in M2); good ones stay
    static Fallbacks() {
        dir := TestSettings.Dir("fallbacks")
        DirCreate(dir)
        FileAppend('{"preset": "1bad", "mode": "sepia", "accent": "#12345", "fontFamily": "Comic Sans MS", "fontSize": 3, "alwaysOnTop": true, "lastPage": "billing"}', dir "\settings.json", "UTF-8-RAW")
        s := Settings({Dir: dir}).Load()
        T.Eq(s.Warnings.Length, 5, "five bad appearance values: five warnings")
        T.Eq(s.Get("preset"), "", "bad preset falls back")
        T.Eq(s.Get("mode"), "", "bad mode falls back")
        T.Eq(s.Get("accent"), "", "bad accent falls back")
        T.Eq(s.Get("fontFamily"), "", "bad font falls back")
        T.Eq(s.Get("fontSize"), 12, "bad size falls back")
        T.Eq(s.Get("alwaysOnTop"), 1, "good values are kept")
        T.Eq(s.Get("lastPage"), "billing", "good page is kept")
        T.True(FileExist(dir "\settings.json") != "", "the file is not quarantined for bad values")
    }
}
