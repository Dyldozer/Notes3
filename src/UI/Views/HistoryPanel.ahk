#Requires AutoHotkey v2.0
; HistoryPanel.ahk - the History pop-out under the notes (PLAN 6 "History panel").
;
; The panel is markup inside the footer band, below the notes box. Opening it grows the window downward by
; PANEL_H (the page area keeps its height); closing shrinks it back. If the work area under the window is
; too short the window is moved up so it fits; if the monitor itself is too short the growth is capped.
;
; Interaction (how the library's events were used):
;   - Rows are plain markup with ids nfsHR_<n>. g.On("dblclick", id, fn) is supported by the library
;     (AxWindow.On: click dblclick mousedown ... ), so DOUBLE-CLICK on a row loads the call. A single click
;     selects the row and a Load button loads the selected row (a fallback that needs no double-click).
;   - The hover preview of the full note is the library's Popover (On: "hover") registered per row id; the
;     panel is built on every open from the History entry, so it is always current.
;   - Search: typing in the box (keyup/change) filters; the day selector is a plain <select> (change).
;
; Nothing here logs names, jobs or note text.

class HistoryPanel {
    static PANEL_H := 260
    static MAX_ROWS := 300

    __New(win, app) {
        this.Win := win
        this.App := app
        this.Open := false
        this.Grown := 0              ; px the window actually grew when the panel opened
        this.Rows := []              ; item objects shown now (History.List)
        this.SelId := ""             ; id of the selected entry
        this.Day := ""               ; selected date ("" = today)
        this.Query := ""
        this._wired := 0             ; row hooks registered so far
        this._dirty := true
    }

    ; Structural CSS (rem sizes follow the Text size setting); colours come from Theme.Css.
    Css() => "
    (
    .nfs-hist { display: none; box-sizing: border-box; height: 260px; margin: 0; padding: 8px 0 0 0; overflow: hidden; }
    .nfs-hist-hd { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; margin-bottom: 6px; }
    .nfs-hist-hd .l { font-weight: 600; margin-right: 12px; }
    .nfs-hist-hd .textbox { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; margin-right: 8px; }
    .nfs-hist-hd .textbox input { width: 100%; box-sizing: border-box; }
    .nfs-hist-hd select { margin-right: 8px; min-width: 110px; }
    .nfs-hcols, .nfs-hrow { display: -ms-flexbox; display: flex; padding: 2px 6px; box-sizing: border-box; }
    .nfs-hcols { font-size: .786rem; text-transform: uppercase; letter-spacing: .5px; }
    .nfs-hlist { height: 164px; overflow-y: auto; overflow-x: hidden; }
    .nfs-hrow { cursor: default; }
    .nfs-hcols span, .nfs-hrow span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-right: 8px; }
    .nfs-hc1 { -ms-flex: none; flex: none; width: 44px; }
    .nfs-hc2 { -ms-flex: none; flex: none; width: 90px; }
    .nfs-hc3 { -ms-flex: none; flex: none; width: 70px; }
    .nfs-hc4 { -ms-flex: none; flex: none; width: 150px; }
    .nfs-hc5 { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; }
    .nfs-hempty { padding: 18px 6px; }
    .nfs-hhint { font-size: .786rem; padding: 4px 6px 0 6px; }
    .nfs-hprev { max-width: 360px; white-space: pre-wrap; word-wrap: break-word; }
    .nfs-hprev .m { font-size: .786rem; margin-bottom: 4px; }
    )"

    Html() => '<div class="nfs-hist" id="nfsHistPanel"><div class="nfs-hist-hd"><span class="l">History</span>'
        . '<span class="textbox"><input type="text" id="nfsHSearch" placeholder="Search name, job, work order, category"></span>'
        . '<select id="nfsHDay"></select><span class="btn" id="nfsHLoad">Load</span></div>'
        . '<div class="nfs-hcols"><span class="nfs-hc1">Time</span><span class="nfs-hc2">Tech</span><span class="nfs-hc3">Job</span>'
        . '<span class="nfs-hc4">Categories</span><span class="nfs-hc5">Note preview</span></div>'
        . '<div class="nfs-hlist" id="nfsHList"></div>'
        . '<div class="nfs-hhint" id="nfsHHint"></div></div>'

    ; Hook everything up once the window is ready.
    Wire() {
        g := this.Win.G
        g.On("click", "nfsHLoad", (*) => this.LoadSelected())
        g.On("keyup", "nfsHSearch", (*) => this.OnSearch())
        g.On("change", "nfsHSearch", (*) => this.OnSearch())
        g.On("change", "nfsHDay", (*) => this.OnDay())
        this.App.History.OnChanged((*) => this.OnHistoryChanged())
    }

    ; --- open / close -------------------------------------------------------------
    Toggle() => this.SetOpen(!this.Open)

    SetOpen(on, persist := true) {
        on := !!on
        if (on = this.Open)
            return this
        g := this.Win.G
        this.Open := on
        if on {
            this.Refresh()
            try g.El("nfsHistPanel").style.display := "block"
            this.Grow()
        } else {
            try g.El("nfsHistPanel").style.display := "none"
            this.Shrink()
        }
        if persist
            this.Win.Remember("historyOpen", on ? 1 : 0)
        this.App.Logger.Debug("history panel", {open: on ? 1 : 0, grownPx: this.Grown})
        return this
    }

    ; Make the window taller by the panel height, moved up if needed so it stays inside the work area.
    Grow() {
        this.Grown := 0
        hwnd := this.Win.G.Hwnd
        try {
            if (WinGetMinMax(hwnd) != 0)
                return
            WinGetPos(&x, &y, &w, &h, hwnd)
            wa := Util.WorkAreaFor(x, y, w, h)
            r := Util.FitRect(x, y, w, h + HistoryPanel.PANEL_H, wa.l, wa.t, wa.r, wa.b)
            this.Grown := Max(0, r.h - h)
            WinMove(r.x, r.y, r.w, r.h, hwnd)
        }
    }

    Shrink() {
        grown := this.Grown
        this.Grown := 0
        if (grown <= 0)
            return
        hwnd := this.Win.G.Hwnd
        try {
            if (WinGetMinMax(hwnd) != 0)
                return
            WinGetPos(&x, &y, &w, &h, hwnd)
            WinMove(x, y, w, Max(h - grown, 100), hwnd)
        }
    }

    ; --- content -------------------------------------------------------------------
    OnHistoryChanged() {
        this._dirty := true
        if this.Open
            this.Refresh()
    }

    OnSearch() {
        try q := this.Win.G.El("nfsHSearch").value
        catch
            return
        if (q == this.Query)
            return
        this.Query := q
        this.RenderList()
    }

    OnDay() {
        try d := this.Win.G.El("nfsHDay").value
        catch
            return
        this.Day := d
        this.SelId := ""
        this.RenderList()
    }

    Today() => this.App.Stats.Today().Date

    ; Rebuild the day selector (Today first) and the list.
    Refresh() {
        if !this.Win.Ready
            return
        g := this.Win.G
        today := this.Today()
        if (this.Day = "")
            this.Day := today
        h := '<option value="' today '">Today</option>'
        has := (this.Day = today)
        for d in this.App.History.Days() {
            if (d = today)
                continue
            h .= '<option value="' d '"' (d = this.Day ? " selected" : "") '>' d '</option>'
            if (d = this.Day)
                has := true
        }
        if !has
            this.Day := today
        try {
            sel := g.El("nfsHDay")
            sel.innerHTML := h
            sel.value := this.Day
        }
        this.RenderList()
        this._dirty := false
    }

    RenderList() {
        if !this.Win.Ready
            return
        g := this.Win.G
        e := (s) => Util.HtmlEscape(s)
        this.Rows := this.App.History.List(this.Day, this.Query, this.App.HistoryLabels())
        if (this.Rows.Length > HistoryPanel.MAX_ROWS)
            this.Rows.RemoveAt(HistoryPanel.MAX_ROWS + 1, this.Rows.Length - HistoryPanel.MAX_ROWS)
        keep := false
        for it in this.Rows
            if (it.Id = this.SelId)
                keep := true
        if !keep
            this.SelId := ""
        h := ""
        for i, it in this.Rows
            h .= '<div class="nfs-hrow' (it.Id = this.SelId ? " sel" : "") '" id="nfsHR_' i '"><span class="nfs-hc1">' e(it.Time)
                . '</span><span class="nfs-hc2">' e(it.Tech) '</span><span class="nfs-hc3">' e(it.Job)
                . '</span><span class="nfs-hc4">' e(it.Categories) '</span><span class="nfs-hc5">' e(it.Preview) '</span></div>'
        if (this.Rows.Length = 0)
            h := '<div class="nfs-hempty">No saved calls for this day.</div>'
        try g.El("nfsHList").innerHTML := h
        try g.El("nfsHHint").innerText := "Double-click a call to load it, or select it and press Load. Kept "
            . this.App.RetentionDays() " days."
        this.WireRows()
    }

    ; Row hooks are looked up by id: register one set per shown row, drop the ones that are gone.
    WireRows() {
        g := this.Win.G
        n := this.Rows.Length
        loop n {
            id := "nfsHR_" A_Index
            g.On("click", id, ObjBindMethod(this, "OnRowClick", A_Index))
            g.On("dblclick", id, ObjBindMethod(this, "OnRowDbl", A_Index))
            g.Popover(id, {On: "hover", Align: "left", Width: 360, Delay: 350, Build: ObjBindMethod(this, "BuildPreview", A_Index)})
        }
        i := n + 1
        while (i <= this._wired) {
            id := "nfsHR_" i
            g.Off("click", id), g.Off("dblclick", id), g.Popover(id, "")
            i += 1
        }
        this._wired := n
    }

    ; Full note for the hover popover (built when it opens).
    BuildPreview(i, *) {
        if (i < 1 || i > this.Rows.Length)
            return ""
        it := this.Rows[i]
        note := it.Note = "" ? "(no note text)" : it.Note
        return '<div class="nfs-hprev"><div class="m">' Util.HtmlEscape(it.Time " - " it.Categories) '</div>'
            . Util.HtmlEscape(note) '</div>'
    }

    OnRowClick(i, *) {
        if (i < 1 || i > this.Rows.Length)
            return
        this.SelectRow(i)
    }

    SelectRow(i) {
        this.SelId := this.Rows[i].Id
        g := this.Win.G
        for k, it in this.Rows {
            try {
                el := g.El("nfsHR_" k)
                cls := " " el.className " "
                has := InStr(cls, " sel ") > 0
                if (k = i && !has)
                    el.className := Trim(el.className) " sel"
                else if (k != i && has)
                    el.className := Trim(StrReplace(cls, " sel ", " "))
            }
        }
    }

    OnRowDbl(i, *) {
        if (i < 1 || i > this.Rows.Length)
            return
        this.SelectRow(i)
        this.Win.LoadHistoryEntry(this.Rows[i].Id)
    }

    LoadSelected() {
        if (this.SelId = "") {
            this.Win.G.Toast("Select a saved call first")
            return
        }
        this.Win.LoadHistoryEntry(this.SelId)
    }
}
