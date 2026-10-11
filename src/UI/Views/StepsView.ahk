#Requires AutoHotkey v2.0
; StepsView.ahk - the generic page for any "steps" category (Not Done, Close Job, later admin-made ones).
;
; What it draws (all from the config through WorkflowEngine; nothing here knows a step or option name):
;   - a warning list at the top for the category's flags (they never block anything)
;   - one card per VISIBLE step, in order: label, a "Required" tag, the control, inline hints, the step's fields
;       choice / yesno -> segmented control (<= 4 options, yesno always) or a radio list (more options)
;       fields         -> text boxes (multi-line when the field says so), a red * when the field is required now
;   - after the step that holds a stop: a prominent banner with the stop message; the steps after it are shown
;     LOCKED (dimmed, inputs disabled, not validated, not in the note)
;   - a "Reset this category" button (confirm; clears answers, fragments, values; the category stays "used")
;
; How it uses the library (AxGui 1.05, checked in lib\AxGui.ahk, AxTags.ahk, components\Segmented|Radio|Edit|Card):
;   - page content added after Show() is possible (AxGui.Container._LiveAdd), but a container cannot be emptied or
;     re-ordered, so the page only holds ONE mount point (g.AddHtml "nfsSV_<cat>": flags, list, reset button).
;   - the list is filled by setting its innerHTML to the library's own TAGS - <ax-card>, <ax-segmented>,
;     <ax-radio>, <ax-text>, <ax-textarea> - and writing it with MainWindow.SetTagHtml (tags expanded as text first). That is exactly what AddCard /
;     AddSegmented / AddRadio / AddEdit write, so the controls look and behave like the library's.
;   - choices are heard with g.OnValue(id, fn) (the library calls it from the segmented / radio click), text with
;     g.On("keyup"/"change"/"focusout", id, fn). All ids are made from the config ids, so the hooks are registered
;     ONCE in Wire() and keep working when the list is rebuilt.
;   - rebuild policy: the whole list is rebuilt only when its STRUCTURE changes (which steps are visible, where the
;     stop is) or on a forced refresh (reset, new call, History load). Every other change - an option picked, a
;     key typed, a hint, a flag - is patched in place, and a text box that has the focus is never overwritten.
;     Typing is committed to the session 250 ms after the last key and at once on change / blur.

class StepsView {
    static DEBOUNCE_MS := 250
    static MAX_SEGMENTED := 4

    __New(win, app, catId) {
        this.Win := win
        this.App := app
        this.CatId := catId
        this.RootId := "nfsSV_" catId
        this.ListId := "nfsSVL_" catId
        this.FlagsId := "nfsSVF_" catId
        this.ResetId := "nfsSVR_" catId
        this.Structure := ""
        this.Rendered := false
        this.Touched := Map()        ; step ids the agent has interacted with (inline hints appear for these)
        this.Tried := false          ; the agent tried to copy with required items missing
        this.Pending := Map()        ; field id -> step id, typed but not yet committed
        this.WiredIds := Map()
        this._commitFn := ObjBindMethod(this, "CommitPending")
    }

    ; --- ids ---------------------------------------------------------------------------------------------
    CardId(sid) => "nfsSVC_" this.CatId "_" sid
    OptId(sid) => "nfsSVO_" this.CatId "_" sid
    EditId(fid) => "nfsSVE_" this.CatId "_" fid
    StarId(fid) => "nfsSVQ_" this.CatId "_" fid
    HintId(sid) => "nfsSVH_" this.CatId "_" sid
    FieldHintId(fid) => "nfsSVJ_" this.CatId "_" fid
    BannerId() => "nfsSVS_" this.CatId

    Engine => this.App.EngineFor(this.CatId)

    Category => this.App.CategoryFor(this.CatId)

    ; --- static page content -----------------------------------------------------------------------------
    ; The mount point's inner markup (the page gets it from g.AddHtml); the list itself is filled by Render().
    Html() => '<div class="nfs-sv-flags" id="' this.FlagsId '"></div>'
        . '<div class="nfs-sv-list" id="' this.ListId '"></div>'
        . '<div class="nfs-sv-foot"><span class="btn" id="' this.ResetId '">Reset this category</span></div>'

    ; Structural CSS (rem sizes follow the Text size setting); colours come from Theme.Css.
    static Css() => "
    (
    .nfs-sv-flags { display: none; margin: 0 0 10px 0; padding: 6px 10px; border-radius: 4px; font-size: .857rem; }
    .nfs-sv-flag { margin: 2px 0; }
    .nfs-sv-card { margin-bottom: 10px; }
    .nfs-sv-hd { font-weight: 600; margin-bottom: 8px; }
    .nfs-sv-reqtag { font-size: .714rem; font-weight: 700; text-transform: uppercase; letter-spacing: .4px; margin-left: 8px; }
    .nfs-sv-hint { display: none; margin-top: 5px; font-size: .857rem; }
    .nfs-sv-hint.on { display: block; }
    .nfs-sv-fl { margin: 10px 0 4px 0; font-size: .857rem; }
    .nfs-sv-star { display: none; margin-left: 3px; font-weight: 700; }
    .nfs-sv-star.on { display: inline; }
    .nfs-sv-stop { margin: 2px 0 14px 0; padding: 12px 16px; border-radius: 6px; font-size: 1rem; font-weight: 700; }
    .nfs-sv-stop .ico { margin-right: 8px; }
    .nfs-sv-locked { opacity: .42; pointer-events: none; }
    .nfs-sv-foot { margin-top: 6px; }
    .nfs-sv-empty { padding: 6px 0; }
    )"

    ; --- hooks ----------------------------------------------------------------------------------------------
    ; Register every handler this category can ever need (ids come from the config). Safe to call again after
    ; a config change: ids already wired are skipped (OnValue appends, so it must not be repeated).
    Wire() {
        g := this.Win.G
        cat := this.Category
        eng := this.Engine
        if !(cat is Map) || !cat.Has("steps") || !IsObject(eng)
            return
        if !this.WiredIds.Has(this.ResetId) {
            g.On("click", this.ResetId, ObjBindMethod(this, "OnResetClick"))
            this.WiredIds[this.ResetId] := true
        }
        for s in cat["steps"] {
            sid := s["id"]
            if (WorkflowEngine.IsChoice(s) && !this.WiredIds.Has(this.OptId(sid))) {
                g.OnValue(this.OptId(sid), ObjBindMethod(this, "OnChoose", sid))
                this.WiredIds[this.OptId(sid)] := true
            }
            for f in eng.FieldsList(s) {
                eid := this.EditId(f["id"])
                if this.WiredIds.Has(eid)
                    continue
                for ev in ["keyup", "change", "focusout"]
                    g.On(ev, eid, ObjBindMethod(this, "OnEdit", ev, sid, f["id"]))
                this.WiredIds[eid] := true
            }
        }
    }

    OnChoose(stepId, value, *) {
        this.Touched[stepId] := true
        this.App.SetOption(this.CatId, stepId, String(value))
        this.Win.QueueSteps()                      ; hints / structure after the click has finished
    }

    OnEdit(ev, stepId, fieldId, *) {
        this.Pending[fieldId] := stepId
        if (ev = "keyup") {
            SetTimer(this._commitFn, -StepsView.DEBOUNCE_MS)
            return
        }
        this.CommitPending()
        if (ev = "focusout") {
            this.Touched[stepId] := true
            this.Win.QueueSteps()
        }
    }

    ; Commit what was typed since the last commit (called by the debounce timer, change and blur).
    CommitPending() {
        pend := this.Pending
        this.Pending := Map()
        for fid, sid in pend
            this.CommitField(sid, fid)
    }

    CommitField(stepId, fieldId) {
        el := ""
        try el := this.Win.G.El(this.EditId(fieldId))
        if !IsObject(el)
            return false
        v := ""
        try v := StepsView.Norm(el.value)
        return this.App.SetField(this.CatId, stepId, fieldId, v)
    }

    ; Before anything reads the session (Copy, Clear All, History): commit pending typing and the box that has the focus.
    Flush() {
        if this.Pending.Count > 0
            this.CommitPending()
        if !this.Rendered
            return
        act := ""
        try act := this.Win.G.Doc.activeElement.id
        prefix := "nfsSVE_" this.CatId "_"
        if (act != "" && SubStr(act, 1, StrLen(prefix)) = prefix) {
            fid := SubStr(act, StrLen(prefix) + 1)
            eng := this.Engine
            if IsObject(eng)
                for s in eng.Steps
                    for f in eng.FieldsList(s)
                        if (f["id"] == fid)
                            this.CommitField(s["id"], fid)
        }
    }

    static Norm(s) => StrReplace(StrReplace(String(s), "`r`n", "`n"), "`r", "`n")

    MarkTried() {
        this.Tried := true
    }

    ; Forget which steps the agent touched (new call, reset, History load).
    ResetUi() {
        this.Touched := Map()
        this.Tried := false
        this.Pending := Map()
    }

    OnResetClick(*) {
        if this.Win.G.Confirm("Reset " this.Label() "? Its answers will be cleared.", "Reset this category", "Reset", "Keep")
            this.ResetNow()
    }

    Label() {
        c := this.Category
        return (c is Map && c.Has("label")) ? c["label"] : this.CatId
    }

    ; Clear this category's answers, fragments and values. It stays used (stats keep it).
    ResetNow() {
        this.App.ResetCategory(this.CatId)
        this.ResetUi()
        this.Render(true)
    }

    ; --- rendering ---------------------------------------------------------------------------------------
    ; Draw (or patch) the page from the session's answers. force: rebuild everything and overwrite every text box.
    ; Returns false when the page is not there yet (it is then drawn when the page is first shown).
    Render(force := false) {
        if !this.Win.Ready
            return false
        g := this.Win.G
        list := ""
        try list := g.El(this.ListId)
        if !IsObject(list)
            return false
        eng := this.Engine
        if !IsObject(eng)
            return false
        ans := this.App.Session.AnswersFor(this.CatId)
        a := eng.Analyse(ans)
        keys := ""
        for s in a.Visible {
            keys .= s["id"] (a.ActSet.Has(s["id"]) ? "" : ":L") "|"
            if (a.Stop.Stopped && s["id"] == a.Stop.StepId)
                keys .= "~stop:" WorkflowEngine.ChosenId(WorkflowEngine.Entry(ans, s["id"])) "|"
        }
        full := force || !this.Rendered || keys != this.Structure
        if full {
            html := ""
            for s in a.Visible {
                html .= this.CardHtml(s, a.ActSet.Has(s["id"]), ans, eng)
                if (a.Stop.Stopped && s["id"] == a.Stop.StepId)
                    html .= '<div class="nfs-sv-stop" id="' this.BannerId() '"><span class="ico">&#x26A0;</span>'
                        . Util.HtmlEscape(a.Stop.Message) '</div>'
            }
            if (html = "")
                html := '<div class="nfs-sv-empty">This category has no steps to show.</div>'
            MainWindow.SetTagHtml(list, html)
            this.LockCards(list, a)
            this.Structure := keys
            this.Rendered := true
        }
        this.Sync(a, ans, eng, full)
        return true
    }

    ; One step card.
    CardHtml(s, active, ans, eng) {
        e := (x) => Util.HtmlEscape(x)
        sid := s["id"]
        entry := WorkflowEngine.Entry(ans, sid)
        req := s.Has("required") && WorkflowEngine.Truthy(s["required"])
        h := '<div id="' this.CardId(sid) '" class="nfs-sv-card' (active ? "" : " nfs-sv-locked") '"><ax-card>'
            . '<div class="nfs-sv-hd">' e(eng.Label(s)) (req ? '<span class="nfs-sv-reqtag">Required</span>' : "") '</div>'
        if WorkflowEngine.IsChoice(s)
            h .= this.ChoiceHtml(s, entry)
        h .= '<div class="nfs-sv-hint" id="' this.HintId(sid) '"></div>'
        for f in eng.FieldsList(s) {
            fid := f["id"]
            lab := f.Has("label") ? f["label"] : fid
            val := WorkflowEngine.FieldValue(entry, fid)
            h .= '<div class="nfs-sv-fl">' e(lab) '<span class="nfs-sv-star" id="' this.StarId(fid) '">*</span></div>'
            if (f.Has("multiline") && WorkflowEngine.Truthy(f["multiline"]))
                h .= '<ax-textarea id="' this.EditId(fid) '" rows="3">' e(val) '</ax-textarea>'
            else
                h .= '<ax-text id="' this.EditId(fid) '" value="' e(val) '"></ax-text>'
            h .= '<div class="nfs-sv-hint" id="' this.FieldHintId(fid) '"></div>'
        }
        return h '</ax-card></div>'
    }

    ; Segmented control (yesno, or a choice with up to 4 options) or a radio list. Labels go through Lbl() because the
    ; tags read "id:Label|id:Label" (a ":" in a segmented label would be taken for an icon code).
    ChoiceHtml(s, entry) {
        chosen := WorkflowEngine.ChosenId(entry)
        opts := ""
        n := 0
        for o in s["options"] {
            opts .= (opts = "" ? "" : "|") o["id"] ":" StepsView.Lbl(o.Has("label") ? o["label"] : o["id"])
            n += 1
        }
        if (n = 1)
            opts .= "|"
        tag := (WorkflowEngine.StepType(s) = "yesno" || n <= StepsView.MAX_SEGMENTED) ? "ax-segmented" : "ax-radio"
        return '<' tag ' id="' this.OptId(s["id"]) '" options="' Util.HtmlEscape(opts) '" value="' Util.HtmlEscape(chosen) '"></' tag '>'
    }

    static Lbl(s) => StrReplace(StrReplace(String(s), "|", "/"), ":", Chr(0xA789))

    ; Locked cards: inputs disabled (the dimming and click-blocking is CSS).
    LockCards(list, a) {
        try {
            els := list.querySelectorAll(".nfs-sv-locked input, .nfs-sv-locked textarea")
            loop els.length
                els.item(A_Index - 1).disabled := true
        }
    }

    ; Everything that can change without rebuilding: which option shows as chosen, text box contents, required stars,
    ; inline hints, the flag list.
    Sync(a, ans, eng, full) {
        g := this.Win.G
        act := ""
        try act := g.Doc.activeElement.id
        showAll := this.Tried
        val := eng.Validate(ans)
        missStep := Map(), missField := Map()
        for m in val.Missing {
            if (m.fieldId = "")
                missStep[m.stepId] := true
            else
                missField[m.stepId "|" m.fieldId] := true
        }
        for s in a.Visible {
            sid := s["id"]
            active := a.ActSet.Has(sid)
            entry := WorkflowEngine.Entry(ans, sid)
            show := active && (showAll || this.Touched.Has(sid))
            if WorkflowEngine.IsChoice(s)
                this.SyncChoice(s, WorkflowEngine.ChosenId(entry))
            this.SetHint(this.HintId(sid), show && missStep.Has(sid),
                WorkflowEngine.IsChoice(s) ? "Choose an option." : "This is required.")
            for f in eng.FieldsList(s) {
                fid := f["id"]
                want := StepsView.Norm(WorkflowEngine.FieldValue(entry, fid))
                try {
                    el := g.El(this.EditId(fid))
                    if (IsObject(el) && StepsView.Norm(el.value) != want && (full || act != this.EditId(fid)))
                        el.value := want
                }
                this.SetOn(this.StarId(fid), active && eng.FieldRequired(f, ans, a))
                this.SetHint(this.FieldHintId(fid), show && missField.Has(sid "|" fid), "This is required.")
            }
        }
        this.SyncFlags(eng.Flags(ans))
    }

    ; Show the chosen option in the control (the library already did when the agent clicked; this covers resets and loads).
    SyncChoice(s, chosen) {
        try {
            el := this.Win.G.El(this.OptId(s["id"]))
            if !IsObject(el)
                return
            segs := el.querySelectorAll(".seg")
            if (segs.length > 0) {
                loop segs.length {
                    sg := segs.item(A_Index - 1)
                    StepsView.SetCls(sg, "active", sg.getAttribute("data-value") == chosen)
                }
                el.setAttribute("data-value", chosen)
                return
            }
            lbls := el.querySelectorAll("label.radio")
            loop lbls.length {
                lb := lbls.item(A_Index - 1)
                inp := lb.querySelector("input")
                if IsObject(inp)
                    inp.checked := (lb.getAttribute("data-value") == chosen)
            }
        }
    }

    SyncFlags(msgs) {
        try {
            el := this.Win.G.El(this.FlagsId)
            if !IsObject(el)
                return
            h := ""
            for m in msgs
                h .= '<div class="nfs-sv-flag"><b>&#x26A0;</b> ' Util.HtmlEscape(m) '</div>'
            if (el.innerHTML != h)
                el.innerHTML := h
            el.style.display := h = "" ? "none" : "block"
        }
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

    SetOn(id, on) {
        try {
            el := this.Win.G.El(id)
            if IsObject(el)
                StepsView.SetCls(el, "on", on)
        }
    }

    static SetCls(el, cls, on) {
        cur := " " el.className " "
        has := InStr(cur, " " cls " ") > 0
        if (on && !has)
            el.className := Trim(el.className) " " cls
        else if (!on && has)
            el.className := Trim(StrReplace(cur, " " cls " ", " "))
    }

    ; --- what is on the page (selftest) ---------------------------------------------------------------------
    ; Step ids of the cards in the DOM, in order, comma separated.
    CardOrder() {
        s := ""
        try {
            els := this.Win.G.El(this.ListId).querySelectorAll(".nfs-sv-card")
            prefix := "nfsSVC_" this.CatId "_"
            loop els.length
                s .= (s = "" ? "" : ",") SubStr(els.item(A_Index - 1).id, StrLen(prefix) + 1)
        }
        return s
    }

    LockedCount() {
        try return this.Win.G.El(this.ListId).querySelectorAll(".nfs-sv-locked").length
        return -1
    }

    BannerText() {
        try return this.Win.G.El(this.BannerId()).innerText
        return ""
    }

    FlagCount() {
        try return this.Win.G.El(this.FlagsId).querySelectorAll(".nfs-sv-flag").length
        return -1
    }

    HintsOn() {
        try return this.Win.G.El(this.RootId).querySelectorAll(".nfs-sv-hint.on").length
        return -1
    }

    StarsOn() {
        try return this.Win.G.El(this.RootId).querySelectorAll(".nfs-sv-star.on").length
        return -1
    }

    ; The chosen option id shown in the DOM for a step ("" when none).
    ShownChoice(stepId) {
        try {
            el := this.Win.G.El(this.OptId(stepId))
            segs := el.querySelectorAll(".seg.active")
            if (segs.length > 0)
                return segs.item(0).getAttribute("data-value")
            r := el.querySelector("input:checked")
            if IsObject(r)
                return r.parentNode.getAttribute("data-value")
        }
        return ""
    }

    EditText(fieldId) {
        try return StepsView.Norm(this.Win.G.El(this.EditId(fieldId)).value)
        return "<none>"
    }

    EditDisabled(fieldId) {
        try return this.Win.G.El(this.EditId(fieldId)).disabled ? 1 : 0
        return -1
    }

    ; Click an option through the DOM (the library's click role fires OnValue, like a real click).
    ClickOption(stepId, optionId) {
        try {
            el := this.Win.G.El(this.OptId(stepId))
            segs := el.querySelectorAll(".seg")
            loop segs.length {
                sg := segs.item(A_Index - 1)
                if (sg.getAttribute("data-value") == optionId) {
                    sg.click()
                    return true
                }
            }
            lbls := el.querySelectorAll("label.radio")                ; the radio list (more than 4 options)
            loop lbls.length {
                lb := lbls.item(A_Index - 1)
                if (lb.getAttribute("data-value") == optionId) {
                    lb.querySelector("input").click()
                    return true
                }
            }
        }
        return false
    }

    ; "segmented", "radio" or "" - which control a step is drawn with.
    ControlKind(stepId) {
        try {
            el := this.Win.G.El(this.OptId(stepId))
            if (el.querySelectorAll(".seg").length > 0)
                return "segmented"
            if (el.querySelectorAll("label.radio").length > 0)
                return "radio"
        }
        return ""
    }
}
