#Requires AutoHotkey v2.0
; DevPanel.ahk - mock/dev controls, shown as a popover from the "Dev" title-bar item (only when
; nfsnotes.ini [Dev] Enabled=1). Buttons are plain markup with ids; clicks are routed with g.On().
; Every action is logged at debug level with no personal data.

class DevPanel {
    static FIELDS := [["techName", "Name"], ["techId", "ID"], ["jobNumber", "Job"], ["workOrder", "WO"], ["address", "Addr"]]
    static STATES := [["unavailable", "Unavail."], ["stale", "Stale"], ["empty", "Empty"], ["normal", "Normal"]]

    __New(win, app) {
        this.Win := win
        this.App := app
        this.Wired := false
    }

    ; Popover spec for the "dev" title item.
    Spec() => {Build: ObjBindMethod(this, "Build"), OnOpen: ObjBindMethod(this, "OnOpen"), Width: 330, Align: "left"}

    Css() => "
    (
    .nfs-dev { font-size: .857rem; }
    .nfs-dev .hd { font-weight: 600; margin: 8px 0 4px 0; }
    .nfs-dev .hd.first { margin-top: 0; }
    .nfs-dev .row { margin-bottom: 4px; }
    .nfs-dev .lbl { display: inline-block; width: 52px; }
    .nfs-dev .btn { display: inline-block; margin: 0 4px 4px 0; padding: 2px 8px; cursor: pointer; }
    .nfs-dev .meta { font-size: .786rem; margin-top: 6px; }
    )"

    ; Called once the window is ready: hook up every button id (hooks are looked up by id, so they keep
    ; working when the panel is rebuilt on each open).
    Wire() {
        g := this.Win.G
        for id, act in this.Actions()
            g.On("click", id, act)
        this.Wired := true
    }

    OnOpen(*) {
        this.Wire()                       ; picks up category buttons if the config changed
    }

    ; id -> bound function. Rebuilt from the current config so the use-category list is current.
    Actions() {
        m := Map()
        m["devNew"] := ObjBindMethod(this, "Do", "newCall")
        m["devDup"] := ObjBindMethod(this, "Do", "duplicate")
        m["devBurst"] := ObjBindMethod(this, "Do", "burst")
        m["devHealthy"] := ObjBindMethod(this, "Do", "healthy")
        m["devUnhealthy"] := ObjBindMethod(this, "Do", "unhealthy")
        for f in DevPanel.FIELDS
            for s in DevPanel.STATES
                m["devSt_" f[1] "_" s[1]] := ObjBindMethod(this, "Do", "state", f[1], s[1])
        for c in this.Categories() {
            m["devUse_" c["id"]] := ObjBindMethod(this, "Do", "use", c["id"])
        }
        return m
    }

    ; Enabled categories in config order.
    Categories() {
        out := []
        try for c in this.App.Config.Config["categories"]
            if (c["enabled"])
                out.Push(c)
        return out
    }

    Build() {
        e := (s) => Util.HtmlEscape(s)
        p := this.App.Provider
        h := '<div class="nfs-dev"><div class="hd first">Context events (mock)</div><div class="row">'
            . '<span class="btn" id="devNew">New call</span><span class="btn" id="devDup">Duplicate event</span>'
            . '<span class="btn" id="devBurst">Burst x5</span></div>'
        h .= '<div class="hd">Field state</div>'
        for f in DevPanel.FIELDS {
            h .= '<div class="row"><span class="lbl">' f[2] '</span>'
            for s in DevPanel.STATES
                h .= '<span class="btn" id="devSt_' f[1] '_' s[1] '">' s[2] '</span>'
            h .= '</div>'
        }
        h .= '<div class="hd">Provider health</div><div class="row">'
            . '<span class="btn" id="devHealthy">Healthy</span><span class="btn" id="devUnhealthy">Unhealthy</span></div>'
        h .= '<div class="hd">Use category (counts for the current call)</div><div class="row">'
        for c in this.Categories()
            h .= '<span class="btn" id="devUse_' c["id"] '">' e(c["label"]) '</span>'
        h .= '</div>'
        hl := p.Health()
        h .= '<div class="meta">' e(hl.Ok ? "Provider healthy" : "Provider unhealthy") ' - mock job ' p.Index ' of ' MockProvider.JOBS.Length '</div></div>'
        return h
    }

    ; One dispatcher so each action is logged the same way. Hook args (element, event) are ignored.
    Do(action, args*) {
        p := this.App.Provider
        lg := this.App.Logger
        detail := ""
        for a in args
            detail .= (detail = "" ? "" : " ") (IsObject(a) ? "" : a)
        ; the hook passes (element, event) after the bound args; keep only the strings/ints we bound
        keep := []
        for a in args
            if !IsObject(a)
                keep.Push(a)
        lg.Debug("dev action", {action: action, detail: Util.Trim(RegExReplace(detail, "\s+", " "))})
        switch action {
            case "newCall":   p.FireNewCall()
            case "duplicate": p.FireDuplicate()
            case "burst":     p.FireBurst(5)
            case "healthy":   p.SetHealthy(true)
            case "unhealthy": p.SetHealthy(false)
            case "state":     p.SetFieldState(keep[1], keep[2])
            case "use":       this.App.UseCategory(keep[1])
        }
        this.Refresh()
    }

    ; Redraw the open panel (health text, job index) without closing it.
    Refresh() {
        try {
            g := this.Win.G
            if (g.PopoverOpen = "dev")
                g.El("axPop").innerHTML := this.Build()
        }
    }
}
