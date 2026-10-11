#Requires AutoHotkey v2.0
; Util.ahk - small shared helpers. Pure logic: no GUI, no globals.

class Util {
    ; Trim whitespace (space, tab, CR, LF, NBSP) from both ends.
    static Trim(s) => Trim(String(s), " `t`r`n" Chr(0xA0))

    ; Collapse any run of whitespace to a single space and trim.
    static Squeeze(s) => Trim(RegExReplace(String(s), "\s+", " "))

    ; "jORDAN smith" -> "Jordan Smith". Words split on whitespace, hyphen and apostrophe are kept.
    static TitleCase(s) {
        out := ""
        for word in StrSplit(Util.Squeeze(s), " ") {
            if (out != "")
                out .= " "
            out .= StrUpper(SubStr(word, 1, 1)) StrLower(SubStr(word, 2))
        }
        return out
    }

    ; Escape text for safe insertion into HTML.
    static HtmlEscape(s) {
        s := StrReplace(String(s), "&", "&amp;")
        s := StrReplace(s, "<", "&lt;")
        s := StrReplace(s, ">", "&gt;")
        return StrReplace(s, '"', "&quot;")
    }

    ; Create a directory (and parents) if missing. Throws on failure.
    static EnsureDir(dir) {
        if (dir = "")
            throw ValueError("EnsureDir: empty path")
        if !DirExist(dir)
            DirCreate(dir)
        if !DirExist(dir)
            throw OSError("Could not create directory: " dir)
        return dir
    }

    ; Parent directory of a file path.
    static ParentDir(path) {
        SplitPath(path, , &dir)
        return dir
    }

    ; Write text to path safely: write path.tmp, re-read and verify it matches,
    ; then replace the destination. The original is untouched on any failure.
    static AtomicWrite(path, text) {
        text := String(text)
        dir := Util.ParentDir(path)
        if (dir != "")
            Util.EnsureDir(dir)
        tmp := path ".tmp"
        try FileDelete(tmp)
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        if !IsObject(f)
            throw OSError("Could not open temp file: " tmp)
        f.Write(text)
        f.Close()
        back := FileRead(tmp, "UTF-8-RAW")
        if !(back == text) {
            try FileDelete(tmp)
            throw Error("AtomicWrite verification failed for: " path)
        }
        FileMove(tmp, path, 1)
        return true
    }

    ; Read a UTF-8 text file; returns default if it does not exist.
    static ReadText(path, default := "") {
        if !FileExist(path)
            return default
        return FileRead(path, "UTF-8")
    }

    ; ISO-8601 local timestamp, e.g. 2026-10-10T14:02:33 (optionally with milliseconds).
    static IsoNow(withMs := false) {
        s := FormatTime(A_Now, "yyyy-MM-dd'T'HH:mm:ss")
        return withMs ? s "." Format("{:03}", A_MSec) : s
    }

    ; Deep copy of a Map/Array tree (scalars returned as-is).
    static Clone(v) {
        if (v is Map) {
            m := Map()
            for k, x in v
                m[k] := Util.Clone(x)
            return m
        }
        if (v is Array) {
            a := []
            for x in v
                a.Push(Util.Clone(x))
            return a
        }
        return v
    }

    ; True if at least minW x minH px of the rectangle lies inside some monitor's work area.
    ; Used to ignore a saved window position that is now off every screen.
    static RectVisible(x, y, w, h, minW := 120, minH := 40) {
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            iw := Min(x + w, r) - Max(x, l)
            ih := Min(y + h, b) - Max(y, t)
            if (iw >= Min(minW, w) && ih >= Min(minH, h))
                return true
        }
        return false
    }

    ; Move/shrink a window rectangle so it lies inside a work area (l,t,r,b): the size is capped to the area,
    ; then the position is pulled in. Used when the History panel grows the window downward.
    static FitRect(x, y, w, h, l, t, r, b) {
        w := Min(w, r - l), h := Min(h, b - t)
        if (x + w > r)
            x := r - w
        if (x < l)
            x := l
        if (y + h > b)
            y := b - h
        if (y < t)
            y := t
        return {x: x, y: y, w: w, h: h}
    }

    ; Work area (l,t,r,b) of the monitor that holds most of the rectangle (the primary one if none does).
    static WorkAreaFor(x, y, w, h) {
        best := MonitorGetPrimary(), bestArea := -1
        loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            iw := Min(x + w, r) - Max(x, l), ih := Min(y + h, b) - Max(y, t)
            area := (iw > 0 && ih > 0) ? iw * ih : 0
            if (area > bestArea)
                best := A_Index, bestArea := area
        }
        MonitorGetWorkArea(best, &l, &t, &r, &b)
        return {l: l, t: t, r: r, b: b}
    }

    ; Compact local stamp yyyyMMdd-HHmmss (file names).
    static Stamp() => FormatTime(A_Now, "yyyyMMdd-HHmmss")

    ; Per-user data folder (settings, history, stats, logs): Documents\NotesForNFS.
    ; A_MyDocuments follows a redirected (e.g. OneDrive) Documents folder.
    static UserDataDir() => A_MyDocuments "\NotesForNFS"

    ; Date stamp yyyy-MM-dd.
    static Today() => FormatTime(A_Now, "yyyy-MM-dd")

    ; --- injectable clock ------------------------------------------------------
    ; A "stamp" is YYYYMMDDHH24MISS optionally followed by 3 millisecond digits (17 digits).
    ; Services take a Now function returning a stamp so tests control time without sleeping.
    static NowStamp() => A_Now Format("{:03}", A_MSec)

    ; Milliseconds since 1970-01-01 (wall clock, no time zone) for a stamp.
    static StampMs(s) {
        s := String(s)
        ms := StrLen(s) >= 17 ? Integer(SubStr(s, 15, 3)) : 0
        return DateDiff(SubStr(s, 1, 14), "19700101000000", "Seconds") * 1000 + ms
    }

    ; "2026-10-10" from a stamp.
    static DateOfStamp(s) => SubStr(s, 1, 4) "-" SubStr(s, 5, 2) "-" SubStr(s, 7, 2)

    ; "2026-10-10T14:02:33" from a stamp.
    static IsoOfStamp(s) => FormatTime(SubStr(s, 1, 14), "yyyy-MM-dd'T'HH:mm:ss")
}
