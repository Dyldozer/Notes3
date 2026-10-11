#Requires AutoHotkey v2.0
; StaticView.ahk - the page of the "static" category: IP utility and manual ping outcome (PLAN section 7).
;
; What it draws (the maths is Ipv4 / StaticModel; the wording comes from the config through StaticModel):
;   - IP UTILITY card: an IP box (placeholder "e.g. 1.1.1.1/30") that is read on Enter, on blur and on paste: it is split into IP
;     and prefix and the gateway is calculated; a separate prefix / mask box (/30, 30 or 255.255.255.252) that recalculates
;     when changed; read-only results (IP, prefix, mask, gateway), each with a Copy button that copies just that
;     value. Network and broadcast are not shown (they stay internal maths for validation and error messages). Errors are shown under the field they belong to. When the auto gateway cannot be worked out (IP+1 is
;     the broadcast address, /31, /32) a manual gateway box is offered and checked; when it works, an "Enter gateway
;     manually" link reveals the same box.
;   - There is no note box for the IP details: the page adds to the note only through a confirmed ping outcome.
;   - PING card: target (config targets, Gateway / IP) and outcome (Reply received / No reply) segmented controls, the plain
;     statement that no reply does not mean the device is offline, the Ping / Ping until success / Cancel buttons (M8, Pinger),
;     a small console box and a status line. The buttons are disabled with a tooltip while the chosen target has no valid
;     address ("Enter a valid IP first" / "No valid gateway yet") or while a run is going; Cancel is enabled only while running.
;     When a run finishes by itself the outcome is prefilled UNCONFIRMED through App.StaticPrefillPing: a Confirm link shows and
;     the line stays out of the note until the agent confirms it. The agent can still pick an outcome by hand.
;     The console, the status and the run state live in the Pinger / PingRun, never in the call or in History.
;
; Rendering policy as in StepsView / ItemsView: the controls are rebuilt only when their STRUCTURE changes (the config's ping
; target / outcome list) or on a forced refresh; everything else is patched in place, and a text box that has the focus is never
; overwritten (except the box that was just submitted, which shows what was understood). The three text boxes are read on
; Enter / blur / paste and by Flush() (called before Copy Notes, Clear All and History).

class StaticView {
    static FIELDS := [["ip", "IP"], ["prefix", "Prefix"], ["mask", "Mask"], ["gateway", "Gateway"]]
    static BOXES := ["ip", "prefix", "manual"]
    static NO_REPLY_NOTE := "No reply doesn't mean the device is offline " Chr(0x2014) " ICMP may be filtered."

    __New(win, app, catId) {
        this.Win := win
        this.App := app
        this.CatId := catId
        this.RootId := "nfsST_" catId
        this.FormId := "nfsSTF_" catId
        this.Structure := ""
        this.Rendered := false
        this._conKey := ""              ; which console text is on the page (run id : line sequence)
        this.ForceInputs := false
        this.ManualOpen := false        ; "Enter gateway manually" was clicked
        this.WiredIds := Map()
        this.PasteHooked := false
        this._pasteFn := ""
        this._pasteChk := ObjBindMethod(this, "PasteCheck")
    }

    ; --- ids -----------------------------------------------------------------------------------------------------
    BoxId(b) => "nfsSTi_" this.CatId "_" b
    HintId(n) => "nfsSTh_" this.CatId "_" n
    ValId(f) => "nfsSTv_" this.CatId "_" f
    CopyId(f) => "nfsSTc_" this.CatId "_" f
    TagId() => "nfsSTt_" this.CatId
    WrapId() => "nfsSTw_" this.CatId
    ShowManualId() => "nfsSTl_" this.CatId
    AutoLinkId() => "nfsSTa_" this.CatId
    TargetId() => "nfsSTpt_" this.CatId
    OutcomeId() => "nfsSTpo_" this.CatId
    AddrId() => "nfsSTpa_" this.CatId
    ClearId() => "nfsSTpc_" this.CatId
    ConfirmWrapId() => "nfsSTpkw_" this.CatId
    ConfirmId() => "nfsSTpk_" this.CatId
    PingBtnId() => "nfsSTb1_" this.CatId
    UntilBtnId() => "nfsSTb2_" this.CatId
    CancelBtnId() => "nfsSTb3_" this.CatId
    ConsoleId() => "nfsSTcon_" this.CatId
    StatusId() => "nfsSTst_" this.CatId

    Model => this.App.StaticModelFor(this.CatId)
    State => this.App.Session.StaticFor(this.CatId)

    Label() {
        c := this.App.CategoryFor(this.CatId)
        return (c is Map && c.Has("label")) ? c["label"] : this.CatId
    }

    ; --- static page content -------------------------------------------------------------------------------------
    Html() => '<div class="nfs-st-form" id="' this.FormId '"></div>'

    ; Structural CSS (rem sizes follow the Text size setting); colours come from Theme.Css.
    static Css() => "
    (
    .nfs-st-form ax-card, .nfs-st-form .card { margin-bottom: 10px; }
    .nfs-st-res { margin: 14px 0 2px 0; }
    .nfs-st-row { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; padding: 3px 0; }
    .nfs-st-k { -ms-flex: none; flex: none; width: 82px; font-size: .857rem; }
    .nfs-st-v { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; font-family: Consolas, monospace; word-wrap: break-word; }
    .nfs-st-tag { display: none; font-size: .643rem; font-weight: 700; text-transform: uppercase; letter-spacing: .4px;
        padding: 0 4px; margin-left: 6px; border-radius: 3px; line-height: 14px; }
    .nfs-st-row .btn { margin-left: 8px; padding: 0 8px; }
    .nfs-st-link { display: none; margin: 8px 0 0 0; font-size: .857rem; cursor: pointer; }
    .nfs-st-link.inl { margin-left: 12px; }
    .nfs-st-wrap { display: none; margin-top: 6px; }
    .nfs-st-note { font-size: .857rem; margin: 10px 0 4px 0; }
    .nfs-st-addr { font-size: .857rem; margin: 6px 0 0 0; }
    .nfs-st-con { margin-top: 8px; height: 110px; overflow-y: auto; padding: 6px 8px; font-family: Consolas, monospace; font-size: .857rem;
        border-radius: 4px; word-wrap: break-word; }
    .nfs-st-stat { font-size: .857rem; margin: 6px 0 0 0; min-height: 16px; }
    .nfs-st-btns { margin: 10px 0 2px 0; }
    .nfs-st-btns .btn { margin-right: 8px; }
    .nfs-st-dis { opacity: .45; cursor: not-allowed; }
    .nfs-st-confirm { display: none; margin-top: 8px; padding: 4px 8px; font-size: .857rem; border-radius: 4px; }
    )"

    ; --- hooks -----------------------------------------------------------------------------------------------------
    ; Register every handler the page needs. The ids do not depend on the config, so this runs once; again is harmless.
    Wire() {
        g := this.Win.G
        for b in StaticView.BOXES
            if !this.WiredIds.Has(this.BoxId(b)) {
                for ev in ["keyup", "change", "focusout"]
                    g.On(ev, this.BoxId(b), ObjBindMethod(this, "OnBox", b, ev))
                this.WiredIds[this.BoxId(b)] := true
            }
        for f in StaticView.FIELDS
            g.On("click", this.CopyId(f[1]), ObjBindMethod(this, "OnCopyClick", f[1]))
        g.On("click", this.ShowManualId(), ObjBindMethod(this, "OnShowManual"))
        g.On("click", this.AutoLinkId(), ObjBindMethod(this, "OnUseAuto"))
        g.On("click", this.ClearId(), ObjBindMethod(this, "OnClearOutcome"))
        g.On("click", this.ConfirmId(), ObjBindMethod(this, "OnConfirmOutcome"))
        g.On("click", this.PingBtnId(), ObjBindMethod(this, "OnPingClick", "count"))
        g.On("click", this.UntilBtnId(), ObjBindMethod(this, "OnPingClick", "untilSuccess"))
        g.On("click", this.CancelBtnId(), ObjBindMethod(this, "OnCancelClick"))
        if !this.WiredIds.Has(this.TargetId()) {
            g.OnValue(this.TargetId(), ObjBindMethod(this, "OnPick", "pingTarget"))
            g.OnValue(this.OutcomeId(), ObjBindMethod(this, "OnPick", "pingOutcome"))
            this.WiredIds[this.TargetId()] := true
        }
        if !this.PasteHooked {
            ; paste from the mouse menu only exists as a document event; the text arrives after it returns
            this._pasteFn := (*) => this.OnPasteEvent()
            try g.Doc.attachEvent("onpaste", this._pasteFn)
            this.PasteHooked := true
        }
    }

    OnPasteEvent() {
        SetTimer(this._pasteChk, -40)
        return ComValue(0xB, -1)
    }

    ; The box that has the focus (after a paste) is read like an Enter.
    PasteCheck(box := "") {
        if (box = "") {
            act := ""
            try act := this.Win.G.Doc.activeElement.id
            for b in StaticView.BOXES
                if (act = this.BoxId(b))
                    box := b
        }
        if (box != "")
            this.SubmitBox(box)
        return box
    }

    OnBox(box, ev, el := "", evt := "", *) {
        if (ev = "keyup") {
            k := 0
            try k := evt.keyCode
            if (k != 13)
                return
        }
        this.SubmitBox(box)
    }

    ; Read one text box into the static state (IP, prefix / mask or manual gateway). The box shows what was understood.
    SubmitBox(box, queue := true) {
        txt := this.BoxText(box)
        if (txt = "<none>")
            return false
        patch := box = "ip" ? {ipText: txt} : (box = "prefix" ? {prefixText: txt} : {manualText: txt})
        changed := this.App.StaticSet(this.CatId, patch)
        this.PushBoxes(box)
        if queue
            this.Win.QueueSteps()
        return changed
    }

    BoxText(box) {
        try return Util.Trim(StepsView.Norm(this.Win.G.El(this.BoxId(box)).value))
        return "<none>"
    }

    ; The state's text for a box.
    StateText(box) {
        s := this.State
        return box = "ip" ? s.ipInput : (box = "prefix" ? s.prefixInput : s.manualInput)
    }

    ; Write the state's text into the boxes: the submitted box always, the others only when they do not have the focus.
    PushBoxes(submitted := "") {
        act := ""
        try act := this.Win.G.Doc.activeElement.id
        for b in StaticView.BOXES {
            try {
                el := this.Win.G.El(this.BoxId(b))
                want := this.StateText(b)
                if (IsObject(el) && StepsView.Norm(el.value) != want && (b = submitted || act != this.BoxId(b)))
                    el.value := want
            }
        }
    }

    ; Before anything reads the session (Copy, Clear All, History): take typing that was never submitted.
    Flush() {
        if !this.Rendered
            return
        for b in StaticView.BOXES {
            t := this.BoxText(b)
            if (t != "<none>" && t != this.StateText(b))
                this.SubmitBox(b, false)
        }
    }

    OnPick(field, value, *) {
        this.App.StaticSet(this.CatId, field = "pingTarget" ? {pingTarget: String(value)} : {pingOutcome: String(value)})
        this.Win.QueueSteps()
    }

    OnClearOutcome(*) {
        this.App.StaticSet(this.CatId, {pingOutcome: ""})
        this.Win.QueueSteps()
    }

    OnConfirmOutcome(*) {
        this.App.StaticSet(this.CatId, {pingConfirmed: true})
        this.Win.QueueSteps()
    }

    ; --- ping buttons ---------------------------------------------------------------------------------------------------
    ; The running (or last) run of this page, "" when none.
    Run() {
        pg := this.App.Pinger
        return (IsObject(pg) && IsObject(pg.Current) && pg.Current.Owner = this.CatId) ? pg.Current : ""
    }

    Running() {
        r := this.Run()
        return IsObject(r) && r.Running
    }

    CanStart() => StaticModel.PingAddress(this.State) != "" && !this.Running()

    ; Why the Ping buttons are off ("" when they are on).
    DisabledReason() {
        if this.Running()
            return "A ping is running. Cancel it first."
        if (StaticModel.PingAddress(this.State) != "")
            return ""
        return this.State.pingTarget = "ip" ? "Enter a valid IP first" : "No valid gateway yet"
    }

    ; mode "count" | "untilSuccess". Returns true when a run started.
    OnPingClick(mode, *) {
        if !this.CanStart()
            return false
        r := this.App.StartPing(this.CatId, mode)
        this.SyncPing()
        this.Win.QueueSteps()
        return r.Ok
    }

    OnCancelClick(*) {
        if !this.Running()
            return false
        this.App.CancelPing("cancel button")
        this.SyncPing()
        return true
    }

    OnShowManual(*) {
        this.ManualOpen := true
        this.Win.QueueSteps()
    }

    OnUseAuto(*) {
        this.ManualOpen := false
        this.App.StaticSet(this.CatId, {manualText: ""})
        this.PushBoxes("manual")
        this.Win.QueueSteps()
    }

    ; --- copy buttons ------------------------------------------------------------------------------------------------
    OnCopyClick(f, *) {
        this.CopyNow(f)
    }

    ; The text shown for a result (what Copy copies): the prefix with its "/".
    ResultText(f) {
        s := this.State
        if (f = "prefix")
            return s.prefix = "" ? "" : "/" s.prefix
        return s.%f%
    }

    ; Copy just that value (verified clipboard write through NoteClipboard, toast). False when there is nothing to copy.
    CopyNow(f) {
        txt := this.ResultText(f)
        if (txt = "")
            return false
        lbl := f
        for x in StaticView.FIELDS
            if (x[1] = f)
                lbl := x[2]
        r := NoteClipboard.Copy(txt, this.Win.ClipHooks)
        this.App.Logger.Debug("static copy", {field: f, ok: r.Ok ? 1 : 0})
        if r.Ok
            this.Win.G.Toast(lbl " copied", 1500, "success")
        else
            this.Win.G.Toast(r.Error, 5000, "error")
        return r.Ok
    }

    ; New call, Clear All, History load: forget view-only state; the boxes are overwritten from the (new) session state.
    ResetUi() {
        this.ManualOpen := false
        this.ForceInputs := true
    }

    ; --- rendering ----------------------------------------------------------------------------------------------------
    Render(force := false) {
        if !this.Win.Ready
            return false
        g := this.Win.G
        form := ""
        try form := g.El(this.FormId)
        if !IsObject(form)
            return false
        m := this.Model
        if !IsObject(m)
            return false
        key := this.StructureKey(m)
        full := force || !this.Rendered || key != this.Structure
        if full {
            MainWindow.SetTagHtml(form, this.FormHtml(m))
            this.Structure := key
            this.Rendered := true
        }
        this.Sync(m, full || this.ForceInputs)
        this.ForceInputs := false
        return true
    }

    StructureKey(m) {
        k := ""
        for list in [m.Targets, m.Outcomes] {
            for o in list
                k .= o["id"] "=" StaticModel.Label(o) ";"
            k .= "|"
        }
        return k
    }

    ; "id:Label|id:Label" for the library's option lists (a ":" or "|" in a label would break them).
    OptionsOf(list) {
        s := ""
        for o in list
            s .= (s = "" ? "" : "|") o["id"] ":" StepsView.Lbl(StaticModel.Label(o))
        if (list.Length = 1)
            s .= "|"
        return s
    }

    FormHtml(m) {
        e := (x) => Util.HtmlEscape(x)
        h := '<ax-card><div class="nfs-iv-title">IP utility</div>'
        h .= '<div class="nfs-sv-fl">IP address</div><ax-text id="' this.BoxId("ip") '" value="" placeholder="e.g. 1.1.1.1/30"></ax-text>'
            . '<div class="nfs-sv-hint" id="' this.HintId("ip") '"></div>'
        h .= '<div class="nfs-sv-fl">Prefix or mask</div><ax-text id="' this.BoxId("prefix") '" value="" placeholder="/30, 30 or 255.255.255.252"></ax-text>'
            . '<div class="nfs-sv-hint" id="' this.HintId("prefix") '"></div>'
        h .= '<div class="nfs-st-res">'
        for f in StaticView.FIELDS {
            h .= '<div class="nfs-st-row"><span class="nfs-st-k">' f[2] '</span><span class="nfs-st-v dim" id="' this.ValId(f[1]) '"></span>'
            if (f[1] = "gateway")
                h .= '<span class="nfs-st-tag" id="' this.TagId() '">manual</span>'
            h .= '<span class="btn" id="' this.CopyId(f[1]) '" style="display:none">Copy</span></div>'
        }
        h .= '</div><div class="nfs-sv-hint" id="' this.HintId("gateway") '"></div>'
        h .= '<span class="nfs-st-link" id="' this.ShowManualId() '">Enter gateway manually</span>'
        h .= '<div class="nfs-st-wrap" id="' this.WrapId() '"><div class="nfs-sv-fl">Gateway (typed by hand)</div>'
            . '<ax-text id="' this.BoxId("manual") '" value="" placeholder="e.g. 1.1.1.2"></ax-text>'
            . '<div class="nfs-sv-hint" id="' this.HintId("manual") '"></div>'
            . '<span class="nfs-st-link" id="' this.AutoLinkId() '">Use the calculated gateway</span></div>'
        h .= '</ax-card>'
        h .= '<ax-card><div class="nfs-iv-title">Ping</div>'
            . '<div class="nfs-sv-fl">Ping target</div><ax-segmented id="' this.TargetId() '" options="' e(this.OptionsOf(m.Targets)) '" value=""></ax-segmented>'
            . '<div class="nfs-st-addr" id="' this.AddrId() '"></div>'
            . '<div class="nfs-sv-fl">Ping result <span class="nfs-st-link inl" id="' this.ClearId() '" style="display:none">Clear</span></div>'
            . '<ax-segmented id="' this.OutcomeId() '" options="' e(this.OptionsOf(m.Outcomes)) '" value=""></ax-segmented>'
            . '<div class="nfs-st-confirm" id="' this.ConfirmWrapId() '">This result was filled in automatically and is not in the note yet. '
            . '<span class="nfs-st-link inl" id="' this.ConfirmId() '" style="display:inline-block">Confirm it</span></div>'
            . '<div class="nfs-sv-hint" id="' this.HintId("ping") '"></div>'
            . '<div class="nfs-st-note">' e(StaticView.NO_REPLY_NOTE) '</div>'
            . '<div class="nfs-st-btns"><span class="btn" id="' this.PingBtnId() '">Ping</span>'
            . '<span class="btn" id="' this.UntilBtnId() '">Ping until success</span>'
            . '<span class="btn nfs-st-dis" id="' this.CancelBtnId() '">Cancel</span></div>'
            . '<div class="nfs-st-con" id="' this.ConsoleId() '"></div>'
            . '<div class="nfs-st-stat" id="' this.StatusId() '"></div>'
            . '<div class="nfs-st-note">When a ping finishes, the result is filled in above for you to confirm. You can also pick it yourself.</div></ax-card>'
        return h
    }

    ; Patch the page from the session's static state.
    Sync(m, forceInputs) {
        g := this.Win.G
        s := this.State
        act := ""
        try act := g.Doc.activeElement.id
        for b in StaticView.BOXES {
            try {
                el := g.El(this.BoxId(b))
                if (IsObject(el) && StepsView.Norm(el.value) != this.StateText(b) && (forceInputs || act != this.BoxId(b)))
                    el.value := this.StateText(b)
            }
        }
        ; results
        for f in StaticView.FIELDS {
            txt := this.ResultText(f[1])
            this.SetText(this.ValId(f[1]), txt = "" ? Chr(0x2014) : txt)
            try StepsView.SetCls(g.El(this.ValId(f[1])), "dim", txt = "")
            this.Show(this.CopyId(f[1]), txt != "", "inline-block")
        }
        this.Show(this.TagId(), s.gatewayManual, "inline-block")
        ; hints: each next to the field it belongs to
        this.SetHint(this.HintId("ip"), s.ipError != "", s.ipError)
        this.SetHint(this.HintId("prefix"), s.prefixError != "", s.prefixError)
        auto := (s.gatewayErrorKind = "auto" || s.gatewayErrorKind = "host")
        this.SetHint(this.HintId("gateway"), auto && s.gatewayError != "", auto ? s.gatewayError : "")
        man := (s.gatewayErrorKind = "manual")
        this.SetHint(this.HintId("manual"), man && s.gatewayError != "", man ? s.gatewayError : "")
        ; manual gateway box: offered when the auto rule failed, when it holds text, or when the link was clicked
        open := this.ManualOpen || s.manualInput != "" || s.canManual
        this.Show(this.WrapId(), open, "block")
        this.Show(this.ShowManualId(), !open && s.ready, "inline-block")
        this.Show(this.AutoLinkId(), open && s.autoGateway != "", "inline-block")
        ; ping
        this.SyncChoice(this.TargetId(), s.pingTarget)
        this.SyncChoice(this.OutcomeId(), s.pingOutcome)
        addr := StaticModel.PingAddress(s)
        tl := m.TargetLabel(s.pingTarget)
        this.SetText(this.AddrId(), tl = "" ? "" : (addr != "" ? tl " address: " addr : tl " address: " Chr(0x2014) " (enter a valid IP and prefix above)"))
        this.Show(this.ClearId(), s.pingOutcome != "", "inline-block")
        this.Show(this.ConfirmWrapId(), s.pingOutcome != "" && !s.pingConfirmed, "block")
        pingWarn := (s.pingOutcome != "" && s.pingConfirmed && addr = "")
        this.SetHint(this.HintId("ping"), pingWarn, "The ping line is not added to the note: the " (tl = "" ? "target" : tl) " has no valid address yet.")
        if forceInputs
            this._conKey := "<redraw>"             ; the controls were rebuilt: write the console again
        this.SyncPing()
    }

    ; Buttons, console and status line from the Pinger's current run. Cheap: only changed things are written.
    SyncPing() {
        if !this.Rendered
            return
        g := this.Win.G
        run := this.Run()
        isRunning := IsObject(run) && run.Running
        why := this.DisabledReason()
        this.SetBtn(this.PingBtnId(), why = "", why)
        this.SetBtn(this.UntilBtnId(), why = "", why)
        this.SetBtn(this.CancelBtnId(), isRunning, "")
        key := IsObject(run) ? run.Id ":" run.LineSeq : ""
        if (key != this._conKey) {
            this._conKey := key
            try {
                el := g.El(this.ConsoleId())
                txt := ""
                if IsObject(run)
                    for ln in run.Lines
                        txt .= (txt = "" ? "" : "`n") ln
                el.innerText := txt
                el.scrollTop := el.scrollHeight
            }
        }
        this.SetText(this.StatusId(), IsObject(run) ? run.StatusText() : "")
    }

    SetBtn(id, on, tip) {
        try {
            el := this.Win.G.El(id)
            StepsView.SetCls(el, "nfs-st-dis", !on)
            if (tip = "")
                el.removeAttribute("data-tip")
            else
                el.setAttribute("data-tip", tip)
        }
    }

    ; --- small DOM helpers -----------------------------------------------------------------------------------------------
    SetText(id, text) {
        try {
            el := this.Win.G.El(id)
            if (IsObject(el) && el.innerText != text)
                el.innerText := text
        }
    }

    SetBlock(id, on, text) {
        try {
            el := this.Win.G.El(id)
            if !IsObject(el)
                return
            if (el.innerText != text)
                el.innerText := text
            el.style.display := on ? "block" : "none"
        }
    }

    Show(id, on, display) {
        try this.Win.G.El(id).style.display := on ? display : "none"
    }

    SetHint(id, on, text) {
        try {
            el := this.Win.G.El(id)
            if !IsObject(el)
                return
            if (el.innerText != (on ? text : ""))
                el.innerText := on ? text : ""
            StepsView.SetCls(el, "on", on)
        }
    }

    SyncCheck(id, on) {
        try {
            inp := this.Win.G.El(id).querySelector("input")
            if (IsObject(inp) && (inp.checked ? true : false) != on)
                inp.checked := on
        }
    }

    SyncChoice(id, chosen) {
        try {
            el := this.Win.G.El(id)
            if !IsObject(el)
                return
            segs := el.querySelectorAll(".seg")
            loop segs.length {
                sg := segs.item(A_Index - 1)
                StepsView.SetCls(sg, "active", sg.getAttribute("data-value") == chosen && chosen != "")
            }
            el.setAttribute("data-value", chosen)
        }
    }

    ; --- what is on the page (selftest) -----------------------------------------------------------------------------------
    ; Click a segment of the ping target / outcome control through the DOM (the library hears the click).
    ClickChoice(which, optionId) {
        try {
            el := this.Win.G.El(which = "target" ? this.TargetId() : this.OutcomeId())
            segs := el.querySelectorAll(".seg")
            loop segs.length {
                x := segs.item(A_Index - 1)
                if (x.getAttribute("data-value") == optionId) {
                    x.click()
                    return true
                }
            }
        }
        return false
    }

    ShownChoice(which) {
        try {
            segs := this.Win.G.El(which = "target" ? this.TargetId() : this.OutcomeId()).querySelectorAll(".seg.active")
            if (segs.length > 0)
                return segs.item(0).getAttribute("data-value")
        }
        return ""
    }

    ; Type into a box the way a key press would (value only; submit with PressEnter / blur / PasteCheck).
    TypeInto(box, text) {
        try {
            this.Win.G.El(this.BoxId(box)).value := text
            return true
        }
        return false
    }

    PressEnter(box) {
        this.OnBox(box, "keyup", "", {keyCode: 13})
    }

    ClickEl(id) {
        try {
            this.Win.G.El(id).click()
            return true
        }
        return false
    }

    ; The text of a result row ("" when it shows the dash), a hint, the preview.
    ValueText(f) {
        try {
            t := this.Win.G.El(this.ValId(f)).innerText
            return t = Chr(0x2014) ? "" : t
        }
        return "<none>"
    }

    HintText(name) {
        try {
            el := this.Win.G.El(this.HintId(name))
            return InStr(" " el.className " ", " on ") ? el.innerText : ""
        }
        return "<none>"
    }

    IsShown(id) {
        try return this.Win.G.El(id).style.display != "none"
        return false
    }

    ElText(id) {
        try return this.Win.G.El(id).innerText
        return "<none>"
    }

    Placeholder(box) {
        try return this.Win.G.El(this.BoxId(box)).getAttribute("placeholder")
        return "<none>"
    }

    BoxValue(box) {
        try return StepsView.Norm(this.Win.G.El(this.BoxId(box)).value)
        return "<none>"
    }

    ; True when an element with this id is in the page.
    Exists(id) {
        try return IsObject(this.Win.G.El(id))
        return false
    }

    RowCount() {
        try return this.Win.G.El(this.FormId).querySelectorAll(".nfs-st-row").length
        return -1
    }

    CheckboxCount() {
        try return this.Win.G.El(this.FormId).querySelectorAll("input[type=checkbox]").length
        return -1
    }

    ConsoleText() => this.ElText(this.ConsoleId())
    StatusLine() => this.ElText(this.StatusId())

    ; True when the button looks and acts enabled.
    BtnOn(id) {
        try return !InStr(" " this.Win.G.El(id).className " ", " nfs-st-dis ")
        return false
    }

    BtnTip(id) {
        try {
            v := this.Win.G.El(id).getAttribute("data-tip")
            return IsObject(v) ? "" : v
        }
        return "<none>"
    }

    HintsOn() {
        try return this.Win.G.El(this.FormId).querySelectorAll(".nfs-sv-hint.on").length
        return -1
    }

    CopyShown(f) => this.IsShown(this.CopyId(f))
}
