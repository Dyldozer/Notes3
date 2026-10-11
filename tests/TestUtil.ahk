#Requires AutoHotkey v2.0

class TestUtil {
    static Name := "Util"

    static Run() {
        base := A_Temp "\NFSNotesTest_Util_" A_TickCount
        T.Case("trim", () => TestUtil.Trims())
        T.Case("titlecase", () => TestUtil.Title())
        T.Case("ensuredir", () => TestUtil.Dirs(base))
        T.Case("atomicwrite", () => TestUtil.Atomic(base))
        T.Case("iso", () => TestUtil.Iso())
        T.Case("rect", () => TestUtil.Rect())
        T.Case("clone", () => TestUtil.CloneTree())
        T.Case("fitrect", () => TestUtil.Fit())
        try DirDelete(base, true)
    }

    static Fit() {
        ; work area 0,0 - 1000,800
        r := Util.FitRect(100, 50, 600, 500, 0, 0, 1000, 800)
        T.True(r.x = 100 && r.y = 50 && r.w = 600 && r.h = 500, "already inside: unchanged")
        r := Util.FitRect(100, 500, 600, 500, 0, 0, 1000, 800)
        T.True(r.y = 300 && r.h = 500, "too low: moved up so the bottom edge fits")
        r := Util.FitRect(700, 50, 600, 500, 0, 0, 1000, 800)
        T.True(r.x = 400, "too far right: moved left")
        r := Util.FitRect(-50, -20, 600, 500, 0, 0, 1000, 800)
        T.True(r.x = 0 && r.y = 0, "off the top left: pulled in")
        r := Util.FitRect(100, 0, 600, 900, 0, 0, 1000, 800)
        T.True(r.h = 800 && r.y = 0, "monitor too short: height capped to the work area")
        r := Util.FitRect(0, 0, 1200, 500, 0, 0, 1000, 800)
        T.True(r.w = 1000, "width capped")
        wa := Util.WorkAreaFor(100, 100, 400, 300)
        T.True(wa.r > wa.l && wa.b > wa.t, "work area of the window's monitor has a size")
    }

    static Trims() {
        T.Eq(Util.Trim("  a b `t"), "a b", "Trim strips ends")
        T.Eq(Util.Trim(""), "", "Trim empty")
        T.Eq(Util.Squeeze("  a   b`r`n c "), "a b c", "Squeeze collapses whitespace")
    }

    static Title() {
        T.Eq(Util.TitleCase("JORDAN SMITH"), "Jordan Smith", "TitleCase upper")
        T.Eq(Util.TitleCase("jordan  smith"), "Jordan Smith", "TitleCase lower and spaces")
        T.Eq(Util.TitleCase(""), "", "TitleCase empty")
        T.Eq(Util.HtmlEscape('<b a="1">&'), "&lt;b a=&quot;1&quot;&gt;&amp;", "HtmlEscape")
    }

    static Dirs(base) {
        d := base "\a\b\c"
        Util.EnsureDir(d)
        T.True(DirExist(d), "EnsureDir creates nested dirs")
        Util.EnsureDir(d)
        T.True(DirExist(d), "EnsureDir idempotent")
        T.Throws(() => Util.EnsureDir(""), "EnsureDir empty path throws")
    }

    static Atomic(base) {
        p := base "\sub\file.json"
        text := '{"a": "caf' Chr(0xE9) '", "n": 1}`nline2'
        T.True(Util.AtomicWrite(p, text), "AtomicWrite returns true (creates dirs)")
        T.True(FileExist(p), "destination exists")
        T.False(FileExist(p ".tmp"), "no .tmp left behind")
        T.Eq(FileRead(p, "UTF-8-RAW"), text, "content round-trips exactly (UTF-8, newline)")
        Util.AtomicWrite(p, "second")
        T.Eq(FileRead(p, "UTF-8-RAW"), "second", "overwrite replaces content")
        Util.AtomicWrite(p, "")
        T.Eq(FileRead(p, "UTF-8-RAW"), "", "empty write works")
        ; failure keeps original: make the temp path unusable by creating a directory named file.json.tmp
        Util.AtomicWrite(p, "keep me")
        DirCreate(p ".tmp")
        T.Throws(() => Util.AtomicWrite(p, "new"), "AtomicWrite throws when temp cannot be written")
        T.Eq(FileRead(p, "UTF-8-RAW"), "keep me", "original intact after failed write")
        DirDelete(p ".tmp")
    }

    static Iso() {
        T.True(RegExMatch(Util.IsoNow(), "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"), "IsoNow format")
        T.True(RegExMatch(Util.IsoNow(true), "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}$"), "IsoNow with ms")
        T.True(RegExMatch(Util.Today(), "^\d{4}-\d{2}-\d{2}$"), "Today format")
    }

    static Rect() {
        MonitorGetWorkArea(1, &l, &tp, &r, &b)
        T.True(Util.RectVisible(l + 10, tp + 10, 800, 600), "window on the primary monitor is visible")
        T.False(Util.RectVisible(l - 5000, tp - 5000, 800, 600), "window far off every monitor is not visible")
        T.False(Util.RectVisible(r + 10, tp, 800, 600), "window just right of the last monitor is not visible")
        T.True(Util.RectVisible(l - 600, tp + 10, 800, 600), "window mostly off the left edge but 200px showing is partly visible")
    }

    static CloneTree() {
        a := Map("k", [1, Map("x", "y")])
        b := Util.Clone(a)
        b["k"][2]["x"] := "z"
        T.Eq(a["k"][2]["x"], "y", "Clone is deep")
        T.Eq(Util.Clone("s"), "s", "Clone passes scalars")
    }
}