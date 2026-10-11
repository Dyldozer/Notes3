#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\AdminModel.ahk
#Include %A_LineFile%\..\AdminPreview.ahk
#Include %A_LineFile%\..\AdminUi.ahk
#Include %A_LineFile%\..\AdminPages.ahk
; AdminWindow.ahk - the Admin companion's window (PLAN M10): header (save / reload / status / warnings), the pages, the
; live note under them. It includes nothing from MainWindow (the SetTagHtml helper is AdminHtml.SetTagHtml).
;
; How it works
;   - AdminModel holds the working copy and every edit; this class only draws it and forwards what the admin does.
;   - Pages are redrawn from the model (AdminPages) into one mount point each (adP_<page>); controls are registered in
;     AdminHtml.Reg, and ONE handler per event type ("*" hooks: click, change, keyup, focusin) looks the control up. So
;     nothing has to be re-wired when a page is drawn again.
;   - A text edit is applied to the model at once (debounced while typing, immediately on change) and never redraws the
;     page (a redraw would swallow the click that caused the blur); structural actions (add, remove, move, pick) redraw
;     the page on a short timer, never inside the click that caused them.
;   - Questions go through Ask(): the library's Dialog normally; the selftest answers through AutoAsk.

class AdminWindow {
    ; page id, title, icon
    static PAGES := [["categories", "Categories", "E8FD"], ["edit", "Edit", "E70F"], ["template", "Note template", "E8A5"],
        ["settings", "Settings", "E713"], ["preview", "Preview", "E7B3"], ["check", "Check", "E73E"],
        ["files", "Files", "E8B7"], ["raw", "Raw JSON", "E943"]]
    static TEXT_DEBOUNCE_MS := 300

    __New(app) {
        this.App := app
        this.Model := app.Model
        this.Pv := app.Pv
        this.H := AdminHtml()
        this.Pages := AdminPages(this)
        this.G := ""
        this.Look := ""
        this.Ready := false
        this.Cur := "categories"
        this.Sel := {Cat: "", Step: ""}
        this.PvTarget := "gateway"
        this.CheckItems := []
        this.FilesMsg := ""
        this.RawMsg := ""
        this.LastBox := ""                 ; id of the placeholder-capable text box used last
        this.LastError := ""
        this.LastToast := ""
        this.LastAsked := {Kind: "", Text: "", Buttons: [], Html: ""}
        this.LastRefs := []
        this.AutoAsk := ""                 ; selftest: fn(kind, text, buttons) -> button label | {Button, Value}
        this.FileHook := ""                ; selftest: fn(mode, default) -> path
        this._pendId := ""
        this._commitFn := ObjBindMethod(this, "CommitPending")
        this._renderFn := ObjBindMethod(this, "RenderNow")
        this._noteFn := ObjBindMethod(this, "RefreshNoteNow")
        this._lastDirty := ""
        this._lastPage := ""
    }

    Log => this.App.Logger

    ; ---------------------------------------------------------------------------------------------- building
    Build() {
        m := this.Model
        look := Theme.Resolve(Settings.AppearanceDefaults(), m.Work, {})
        this.Look := look
        opts := {Title: "NFS Notes - Admin", AppName: "NFSAdmin", Width: 1120, Height: 800, MinWidth: 880, MinHeight: 600,
            Theme: look.Mode, Stylesheet: look.Sheet, Accent: look.Accent, Css: AdminHtml.Css(look.Pal)}
        g := AxGui(opts)
        this.G := g
        g.SetExtraCss("nfstheme", look.ExtraCss)
        g.Header(this.HeadHtml(), {Under: false, Drag: false})
        g.Footer(this.FootHtml())
        for p in AdminWindow.PAGES {
            g.AddPage(p[1], p[2], p[3])
            g.AddHtml("vadP_" p[1], '<div id="adP_' p[1] '"></div>')
        }
        for ev in ["click", "change", "keyup", "focusin"]
            g.On(ev, "*", ObjBindMethod(this, "On" ev))
        g.OnPage((id := "", *) => this.OnPageChanged(id))
        g.OnReady((*) => this.OnReadyWire())
        g.OnBeforeClose((w := "", why := "", *) => this.OnClosing(why))
        m.OnChanged((mm, what) => this.AfterEdit())
    }

    Show() {
        this.G.Show()
        return this
    }

    HeadHtml() {
        h := this.H
        h.Begin("head")
        sum := h.Add("btn", "showCheck", [])
        return '<div class="ad-head"><div class="ad-bar">'
            . h.Btn("save", [], "Save", "accent", "Validate, then save the configuration for everybody")
            . h.Btn("reload", [], "Reload", "", "Throw away unsaved edits and read the file again")
            . h.Btn("validate", [], "Check", "", "Look for errors and warnings")
            . '<span class="ad-dirty" id="adDirty"></span>'
            . '<span class="ad-sum" id="' sum '"></span></div>'
            . '<div class="ad-status" id="adStatus"></div>'
            . '<div class="ad-banner" id="adBanner"></div>'
            . '<div class="ad-notice" id="adNotice"></div></div>'
    }

    FootHtml() {
        h := this.H
        return '<div class="ad-foot"><div class="ad-foot-hd"><b>Live note</b>'
            . '<span class="ad-id">sample call, working copy</span>&nbsp;&nbsp;'
            . h.Chk("unavail", [], false, "Mark the call details as not available")
            . '</div><div class="textbox"><textarea id="adNote" readonly="readonly" placeholder="The note appears here"></textarea></div>'
            . '<div class="ad-foot-warn" id="adFootWarn"></div></div>'
    }

    OnReadyWire() {
        this.Ready := true
        this.UpdateChrome()
        this.UpdateBanner()
        this.RenderPage(this.Cur)
        this.RefreshNoteNow()
        SetTimer(() => this.AfterReady(), -50)
    }

    AfterReady() {
        mode := 0
        try mode := this.G.DocMode
        this.Log.Info("IE document mode", {documentMode: mode})
        if (mode > 0 && mode < 11)
            this.G.Alert("The embedded browser is running in compatibility mode (documentMode " mode ", need 11). The window may look broken.",
                "Display mode", "warning")
        if this.App.SelfTest
            AdminSelfTest.Run(this)
    }

    ; ---------------------------------------------------------------------------------------------- pages
    OnPageChanged(id) {
        if (id = "")
            return
        this.Cur := id
        if this.Ready
            this.RenderPage(id, false)
    }

    ; Draw a page from the model into its mount point. False when the page is not in the DOM yet (it is drawn when shown).
    RenderPage(page, keepScroll := true) {
        el := ""
        try el := this.G.El("adP_" page)
        if !IsObject(el)
            return false
        t0 := A_TickCount
        holder := keepScroll && this._lastPage == page ? this.ScrollHolder(el) : ""
        top := 0
        if IsObject(holder)
            try top := holder.scrollTop
        this.H.Begin(page)
        html := this.Pages.Page(page)
        AdminHtml.SetTagHtml(el, html)
        if (IsObject(holder) && top > 0)
            try holder.scrollTop := top
        this._lastPage := page
        this.Log.Debug("render", {page: page, ms: A_TickCount - t0, chars: StrLen(html), scrollKept: top})
        return true
    }

    ; The element that scrolls the page (so a redraw can put the scroll position back).
    ScrollHolder(el) {
        p := el
        loop 10 {
            try
                p := p.parentNode
            catch
                return ""
            if !IsObject(p)
                return ""
            try {
                if (p.clientHeight > 0 && p.scrollHeight > p.clientHeight + 2) {
                    ov := p.currentStyle.overflowY
                    if (ov = "auto" || ov = "scroll")
                        return p
                }
            }
        }
        return ""
    }

    QueueRender() {
        SetTimer(this._renderFn, -15)
    }

    RenderNow() {
        this.RenderPage(this.Cur)
        this.UpdateChrome()
    }

    ; Switch to a page (drawing it even when it is already the current one).
    ShowPage(page) {
        if (this.Cur = page) {
            this.RenderPage(page)
            return
        }
        this.G.ShowPage(page)
        this.Cur := page
        this.RenderPage(page)
    }

    ; Go where a validation message points.
    GoTo(nav) {
        if (nav.HasOwnProp("Cat") && nav.Cat != "")
            this.Sel.Cat := nav.Cat
        if (nav.HasOwnProp("Step") && nav.Step != "")
            this.Sel.Step := nav.Step
        this.ShowPage(nav.Page)
    }

    ; ---------------------------------------------------------------------------------------------- chrome
    AfterEdit() {
        if !this.Ready
            return
        this.UpdateChrome()
        this.QueueNote()
    }

    QueueNote() {
        SetTimer(this._noteFn, -120)
    }

    ; title (*), unsaved marker, status line, error count
    UpdateChrome() {
        if !IsObject(this.G) || !this.Ready
            return
        m := this.Model, g := this.G
        dirty := m.Dirty
        if (dirty !== this._lastDirty) {
            this._lastDirty := dirty
            try g.SetTitle("NFS Notes - Admin" (dirty ? " *" : ""))
            try g.Dirty := dirty
        }
        this.SetText("adDirty", dirty ? "Unsaved changes" : "")
        st := m.Status()
        dot := " " Chr(0x00B7) " "
        txt := (st.Shared ? "Config folder: " st.Dir : "No config folder is set") dot "loaded from " st.Source dot "revision " st.Revision
        if (st.UpdatedBy != "" || st.UpdatedAt != "")
            txt .= dot "last saved by " (st.UpdatedBy != "" ? st.UpdatedBy : "?") (st.UpdatedAt != "" ? " at " st.UpdatedAt : "")
        this.SetText("adStatus", txt)
        v := m.Validate()
        el := ""
        try el := g.El(this.H.BaseId("showCheck", []))
        if IsObject(el) {
            el.innerText := (v.Errors.Length = 0 ? "No errors" : v.Errors.Length " error" (v.Errors.Length = 1 ? "" : "s"))
                . (v.Warnings.Length > 0 ? ", " v.Warnings.Length " warning" (v.Warnings.Length = 1 ? "" : "s") : "")
            el.className := "ad-sum" (v.Errors.Length > 0 ? " bad" : "")
        }
        this.ErrorCount := v.Errors.Length
        this.WarningCount := v.Warnings.Length
    }

    SetText(id, text) {
        try {
            el := this.G.El(id)
            if (IsObject(el) && el.innerText != text)
                el.innerText := text
        }
    }

    ; Conflict copies banner + the "using a fallback copy" notice.
    UpdateBanner() {
        m := this.Model, g := this.G
        try {
            b := g.El("adBanner")
            if (m.Conflicts.Length > 0) {
                names := ""
                for n in m.Conflicts
                    names .= (names = "" ? "" : ", ") Util.HtmlEscape(n)
                b.innerHTML := "<b>OneDrive found conflicting copies of the config. Check them before saving.</b> " names
                b.style.display := "block"
            } else {
                b.innerHTML := ""
                b.style.display := "none"
            }
        }
        try {
            n := g.El("adNotice")
            msg := ""
            st := m.Store
            if !st.SharedConfigured
                msg := "No shared config folder is set: saving is not possible."
            else
                for w in st.Warnings
                    msg .= (msg = "" ? "" : "; ") w
            if (msg != "" && st.SharedConfigured && st.Source != "shared")
                msg .= ". You are editing the " st.Source " copy."
            n.innerText := msg
            n.style.display := msg = "" ? "none" : "block"
        }
    }

    BannerText() {
        try return this.G.El("adBanner").innerText
        return ""
    }

    BannerShown() {
        try return this.G.El("adBanner").style.display = "block"
        return false
    }

    ; The live note + composer warnings.
    RefreshNoteNow() {
        if !this.Ready
            return
        try {
            res := this.Pv.Compose()
            el := this.G.El("adNote")
            if (el.value !== res.Text)
                el.value := res.Text
            w := ""
            for x in res.Warnings
                w .= (w = "" ? "" : "  |  ") x
            for x in res.Extra
                w .= (w = "" ? "" : "  |  ") x
            this.SetText("adFootWarn", w = "" ? "" : "Warnings: " w)
            this.LastNote := res
        } catch as e
            this.Log.Warn("note preview failed", {error: e.Message, line: e.Line})
    }

    NoteText() {
        try return StrReplace(this.G.El("adNote").value, "`r`n", "`n")
        return ""
    }

    Toast(msg, kind := "info") {
        this.LastToast := msg
        try this.G.Toast(msg, kind = "warning" ? 4500 : 2500, kind)
    }

    ; ---------------------------------------------------------------------------------------------- events
    SpecOf(el) {
        n := 0
        while (IsObject(el) && n < 8) {
            id := ""
            try id := el.id
            if (id != "" && this.H.Reg.Has(id))
                return {Id: id, Spec: this.H.Reg[id], El: el}
            try
                el := el.parentNode
            catch
                return ""
            n += 1
        }
        return ""
    }

    Safe(fn) {
        try
            fn()
        catch as e {
            this.Log.Error("admin action failed", {error: e.Message, line: e.Line, what: e.What})
            this.LastError := e.Message
            this.Toast("Something went wrong: " e.Message, "error")
        }
    }

    Onclick(el, ev := "") {
        r := this.SpecOf(el)
        if !IsObject(r)
            return
        s := r.Spec
        switch s.K {
        case "btn": this.Safe(() => this.Do(s.A, s.P))
        case "chk":
            on := 0
            try on := r.El.checked ? 1 : 0
            this.Safe(() => this.Do(s.A, s.P, on))
        case "chip": this.Safe(() => this.InsertChip(s.P[1]))
        }
    }

    Onchange(el, ev := "") {
        r := this.SpecOf(el)
        if !IsObject(r)
            return
        s := r.Spec
        if (s.K = "sel") {
            v := ""
            try v := r.El.value
            this.Safe(() => this.Do(s.A, s.P, v))
        } else if (s.K = "txt") {
            this._pendId := ""
            this.Safe(() => this.CommitText(r.Id, r.El))
        }
    }

    Onkeyup(el, ev := "") {
        r := this.SpecOf(el)
        if !IsObject(r) || r.Spec.K != "txt"
            return
        this._pendId := r.Id
        SetTimer(this._commitFn, -AdminWindow.TEXT_DEBOUNCE_MS)
    }

    Onfocusin(el, ev := "") {
        r := this.SpecOf(el)
        if (IsObject(r) && r.Spec.K = "txt" && r.Spec.Ph)
            this.LastBox := r.Id
    }

    CommitPending() {
        id := this._pendId
        this._pendId := ""
        if (id = "")
            return
        el := ""
        try el := this.G.El(id)
        if IsObject(el)
            this.Safe(() => this.CommitText(id, el))
    }

    ; Before something reads the model (save, close): apply typing that is still waiting.
    Flush() {
        SetTimer(this._commitFn, 0)
        this.CommitPending()
    }

    ; Apply the text of a box to the model.
    CommitText(id, el) {
        if !this.H.Reg.Has(id)
            return
        s := this.H.Reg[id]
        v := ""
        try v := StrReplace(el.value, "`r`n", "`n")
        this.DoText(s, v, el)
    }

    InsertChip(text) {
        el := ""
        try el := this.G.El(this.LastBox)
        if (this.LastBox = "" || !IsObject(el)) {
            this.Toast("Click in a text box first, then click the placeholder.", "info")
            return false
        }
        v := String(el.value)
        s := 0, e := 0
        try s := el.selectionStart
        try e := el.selectionEnd
        if !(s is Integer) || s < 0 || s > StrLen(v)
            s := StrLen(v)
        if !(e is Integer) || e < s || e > StrLen(v)
            e := s
        el.value := SubStr(v, 1, s) text SubStr(v, e + 1)
        pos := s + StrLen(text)
        try el.focus()
        try el.setSelectionRange(pos, pos)
        this.CommitText(this.LastBox, el)
        return true
    }

    ; ---------------------------------------------------------------------------------------------- questions
    ; kind: a short id for the selftest. Returns {Button, Value}.
    Ask(kind, text, title := "", buttons := "", opts := "") {
        if !IsObject(buttons)
            buttons := ["OK"]
        this.LastAsked := {Kind: kind, Text: text, Buttons: buttons, Html: IsObject(opts) && opts.HasOwnProp("Html") ? opts.Html : ""}
        if IsObject(this.AutoAsk) {
            r := this.AutoAsk.Call(kind, text, buttons)
            return IsObject(r) ? r : {Button: String(r), Value: ""}
        }
        if !IsObject(opts)
            opts := {}
        if !opts.HasOwnProp("Kind")
            opts.Kind := "question"
        return this.G.Dialog(text, title, buttons, opts)
    }

    Res(r, el := "") {
        if r.Ok {
            this.LastError := ""
            this.MarkBad(el, false)
            return true
        }
        this.LastError := r.Error
        this.MarkBad(el, true)
        this.Toast(r.Error, "warning")
        return false
    }

    MarkBad(el, bad) {
        if !IsObject(el)
            return
        try {
            p := el.parentNode.parentNode
            cur := " " p.className " "
            has := InStr(cur, " ad-bad ") > 0
            if (bad && !has)
                p.className := Trim(p.className) " ad-bad"
            else if (!bad && has)
                p.className := Trim(StrReplace(cur, " ad-bad ", " "))
        }
    }

    ; ---------------------------------------------------------------------------------------------- actions
    ; The value of a form box (the add-forms) at the moment a button is pressed.
    FormVal(act, args) {
        try return this.G.El(this.H.BaseId(act, args)).value
        return ""
    }

    ClearForm(act, args) {
        try this.G.El(this.H.BaseId(act, args)).value := ""
    }

    ; An edit that changes what the page shows: draw it again shortly.
    Struct(r) {
        if this.Res(r) {
            this.QueueRender()
            return true
        }
        return false
    }

    Do(act, p, val := "") {
        m := this.Model, pv := this.Pv
        switch act {
        ; --- header ---
        case "save": this.SaveNow()
        case "reload": this.ReloadNow(true)
        case "validate": this.ShowPage("check")
        case "showCheck": this.ShowPage("check")
        case "unavail":
            pv.SetUnavailable(val = 1)
            this.QueueNote()
        ; --- categories ---
        case "catUp": this.Struct(m.MoveCategory(p[1], -1))
        case "catDown": this.Struct(m.MoveCategory(p[1], 1))
        case "catOn": this.Res(m.SetCatProp(p[1], "enabled", val))
        case "catEdit":
            this.Sel.Cat := p[1], this.Sel.Step := ""
            this.ShowPage("edit")
        case "catDel": this.DeleteCategory(p[1])
        case "catRestore": this.Struct(m.RestoreSystemCategory(p[1]))
        case "catAdd":
            r := m.AddCategory(this.FormVal("catNewKind", []), this.FormVal("catNewName", []))
            if this.Struct(r) {
                this.Sel.Cat := r.Id, this.Sel.Step := ""
                this.ClearForm("catNewName", [])
            }
        ; --- edit page ---
        case "pickCat":
            this.Sel.Cat := val, this.Sel.Step := ""
            this.QueueRender()
        case "stepSel":
            this.Sel.Cat := p[1], this.Sel.Step := p[2]
            this.QueueRender()
        case "stepUp", "stepDown": this.MoveStep(p[1], p[2], act = "stepUp" ? -1 : 1)
        case "stepDel": this.DeleteStep(p[1], p[2])
        case "stepAdd":
            r := m.AddStep(p[1], this.FormVal("stepNewName", p), this.FormVal("stepNewType", p))
            if this.Struct(r)
                this.Sel.Step := r.Id
        case "stepType": this.ChangeType(p[1], p[2], val)
        case "stepReq": this.Res(m.SetStepProp(p[1], p[2], "required", val))
        case "optAdd": this.Struct(m.AddOption(p[1], p[2], this.FormVal("optNewName", p)))
        case "optUp", "optDown": this.Struct(m.MoveOption(p[1], p[2], p[3], act = "optUp" ? -1 : 1))
        case "optDel":
            this.RemoveWithRefs("the option", (clean) => m.RemoveOption(p[1], p[2], p[3], clean))
        case "stopOn": this.Struct(m.SetStopEnabled(p[1], p[2], p[3], val))
        case "stopKeep": this.Res(m.SetStopKeep(p[1], p[2], p[3], p[4], val))
        case "fieldAdd": this.Struct(m.AddField(p[1], p[2], this.FormVal("fieldNewName", p)))
        case "fieldUp", "fieldDown": this.Struct(m.MoveField(p[1], p[2], p[3], act = "fieldUp" ? -1 : 1))
        case "fieldDel":
            this.RemoveWithRefs("the field", (clean) => m.RemoveField(p[1], p[2], p[3], clean))
        case "fieldReq": this.Res(m.SetFieldProp(p[1], p[2], p[3], "required", val))
        case "fieldMulti": this.Res(m.SetFieldProp(p[1], p[2], p[3], "multiline", val))
        case "flagAdd": this.Struct(m.AddFlag(p[1], this.FormVal("flagNewMsg", p)))
        case "flagUp", "flagDown": this.Struct(m.MoveFlag(p[1], p[2], act = "flagUp" ? -1 : 1))
        case "flagDel": this.Struct(m.RemoveFlag(p[1], p[2]))
        ; --- conditions ---
        case "condAdd": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "add"))
        case "condDel": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "del", Integer(p[5])))
        case "condStep": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "step", Integer(p[5]), val))
        case "condOpt": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "opt", Integer(p[5]), p[6]))
        case "condMode": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "mode", val))
        case "condClear": this.Struct(m.CondEdit(AdminHtml.SlotOf(p), "clear"))
        case "condJsonApply":
            this.Struct(m.SetCondJson(AdminHtml.SlotOf(p), this.FormVal("condJson", p)))
        ; --- items / static ---
        case "listAdd": this.Struct(m.AddListItem(p[1], p[2], this.FormVal("listNewName", p)))
        case "listUp", "listDown": this.Struct(m.MoveListItem(p[1], p[2], p[3], act = "listUp" ? -1 : 1))
        case "listDel": this.Struct(m.RemoveListItem(p[1], p[2], p[3]))
        case "entryFlag": this.Struct(m.SetEntryFlag(p[1], p[2], val))
        ; --- template ---
        case "tplAdd": this.Struct(m.AddTemplateLine(""))
        case "tplUp", "tplDown": this.Struct(m.MoveTemplateLine(Integer(p[1]), act = "tplUp" ? -1 : 1))
        case "tplDel": this.Struct(m.RemoveTemplateLine(Integer(p[1])))
        case "tplCase": this.Res(m.SetTemplateProp("sentenceCase", val))
        case "tplJoin": this.SetJoiner(p[1], val)
        ; --- settings ---
        case "presetAdd":
            r := m.AddPreset(this.FormVal("presetNewName", []), this.FormVal("presetNewSheet", []), this.FormVal("presetNewMode", []), this.FormVal("presetNewAccent", []))
            if this.Struct(r)
                this.ClearForm("presetNewName", [])
        case "presetDel": this.Struct(m.RemovePreset(p[1]))
        case "presetDefault": this.Struct(m.SetDefaultPreset(p[1]))
        case "presetSheet": this.Struct(m.SetPresetProp(p[1], "sheet", val))
        case "presetMode": this.Struct(m.SetPresetProp(p[1], "mode", val))
        ; --- preview ---
        case "pvChoose":
            pv.Choose(p[1], p[2], p[3])
            this.PvChanged()
        case "pvEntry":
            r := pv.AddSampleEntry(p[1])
            if !r.Ok
                this.Toast(r.Error, "warning")
            this.PvChanged()
        case "pvClearEntries", "pvReset":
            pv.ResetCategory(p[1])
            this.PvChanged()
        case "pvPing":
            pv.PickPing(p[1], p[2], this.PvTarget)
            this.PvChanged()
        case "pvTarget":
            this.PvTarget := val
            st := pv.Session.StaticFor(p[1])
            if (st.pingOutcome != "")
                pv.PickPing(p[1], st.pingOutcome, val)
            this.PvChanged()
        case "pvClearAll":
            pv.Clear()
            this.PvChanged()
        ; --- check / files / raw ---
        case "go":
            i := Integer(p[1])
            if (i >= 1 && i <= this.CheckItems.Length)
                this.GoTo(this.CheckItems[i].Nav)
        case "export": this.ExportFile()
        case "import": this.ImportFile()
        case "restoreDefaults": this.RestoreDefaultsNow()
        case "rawApply": this.ApplyRaw()
        case "rawReset":
            this.RawMsg := ""
            this.QueueRender()
        }
    }

    PvChanged() {
        this.QueueRender()
        this.QueueNote()
    }

    ; Text boxes: apply to the model (or the preview). No redraw.
    DoText(s, v, el := "") {
        m := this.Model, p := s.P, pv := this.Pv
        switch s.A {
        case "catLabel": r := m.SetCatProp(p[1], "label", v)
        case "catIcon":
            r := m.SetCatProp(p[1], "icon", v)
            if r.Ok
                this.SetGlyph(p[1])
        case "catPrefix": r := m.SetCatProp(p[1], "notePrefix", v)
        case "stepLabel": r := m.SetStepProp(p[1], p[2], "label", v)
        case "stepFrag": r := m.SetStepProp(p[1], p[2], "fragment", v)
        case "optLabel": r := m.SetOptionProp(p[1], p[2], p[3], "label", v)
        case "optFrag": r := m.SetOptionProp(p[1], p[2], p[3], "fragment", v)
        case "stopMsg": r := m.SetStopProp(p[1], p[2], p[3], "message", v)
        case "stopFrag": r := m.SetStopProp(p[1], p[2], p[3], "fragment", v)
        case "fieldLabel": r := m.SetFieldProp(p[1], p[2], p[3], "label", v)
        case "flagMsg": r := m.SetFlagMessage(p[1], p[2], v)
        case "listLabel": r := m.SetListItemProp(p[1], p[2], p[3], "label", v)
        case "listFrag": r := m.SetListItemProp(p[1], p[2], p[3], "fragment", v)
        case "stLabel": r := m.SetStaticProp(p[1], p[2], p[3], "label", v)
        case "stFrag": r := m.SetStaticProp(p[1], "pingOutcomes", p[2], "fragment", v)
        case "tplLine": r := m.SetTemplateLine(Integer(p[1]), v)
        case "tplProp", "tplCustom": r := m.SetTemplateProp(p[1], v)
        case "presetLabel": r := m.SetPresetProp(p[1], "label", v)
        case "presetAccent":
            r := m.SetPresetProp(p[1], "accent", v)
            this.SetErr("preset_" p[1], r.Ok ? "" : r.Error)
            if r.Ok
                try this.G.El("adSw_" p[1]).style.background := Trim(v)
        case "num":
            r := m.SetNumber(p[1], v)
            this.SetErr(StrReplace(p[1], ".", "_"), r.Ok ? "" : r.Error)
        case "pvType":
            pv.Type(p[1], p[2], p[3], v)
            this.QueueNote()
            return
        default:
            return                                   ; the add-forms and the raw text are read when their button is pressed
        }
        this.Res(r, el)
    }

    SetErr(key, text) {
        this.SetText("adErr_" key, text)
    }

    SetGlyph(catId) {
        c := this.Model.Cat(catId)
        try this.G.El("adGlyph_" catId).innerHTML := "&#x" c["icon"] ";"
    }

    SetJoiner(key, mode) {
        cur := this.Model.Tpl[key]
        if (mode = "nl")
            v := "`n"
        else if (mode = "sp")
            v := " "
        else
            v := (cur == "`n" || cur == " ") ? ", " : cur
        this.Struct(this.Model.SetTemplateProp(key, v))
    }

    ; ---------------------------------------------------------------------------------------------- remove / move flows
    ; fn(clean) -> model result. If the model reports references, list them and offer to remove them too.
    RemoveWithRefs(what, fn, label := "") {
        r := fn(false)
        if (!r.Ok && r.HasOwnProp("NeedConfirm") && r.NeedConfirm) {
            html := "<ul>"
            for ref in r.Refs
                html .= "<li>" Util.HtmlEscape(ref.Text) "</li>"
            html .= "</ul>"
            this.LastRefs := r.Refs
            ans := this.Ask("refs", "Removing " what " also affects " r.Refs.Length " place" (r.Refs.Length = 1 ? "" : "s") ":",
                "Used elsewhere", ["Delete and remove those references", "Cancel"], {Kind: "warning", Html: html, Danger: 1, Cancel: 2})
            if (ans.Button != "Delete and remove those references")
                return false
            r := fn(true)
        } else
            this.LastRefs := []
        return this.Struct(r)
    }

    MoveStep(cat, step, dir) {
        r := this.Model.MoveStep(cat, step, dir)
        if (!r.Ok && r.HasOwnProp("Blocked") && r.Blocked) {
            this.LastError := r.Error
            this.Ask("moveBlocked", r.Error, "Can't move this step", ["OK"], {Kind: "warning"})
            return false
        }
        return this.Struct(r)
    }

    ChangeType(cat, step, type) {
        m := this.Model
        r := m.ChangeStepType(cat, step, type, false)
        if (!r.Ok && r.HasOwnProp("NeedConfirm") && r.NeedConfirm) {
            html := "<ul>"
            for ref in r.Refs
                html .= "<li>" Util.HtmlEscape(ref.Text) "</li>"
            html .= "</ul>"
            this.LastRefs := r.Refs
            ans := this.Ask("refs", "Changing the type removes options that are used elsewhere:", "Change the type", ["Change it and remove those references", "Cancel"],
                {Kind: "warning", Html: html, Danger: 1, Cancel: 2})
            if (ans.Button != "Change it and remove those references") {
                this.QueueRender()                    ; put the type box back
                return false
            }
            r := m.ChangeStepType(cat, step, type, true)
        }
        if !this.Res(r) {
            this.QueueRender()
            return false
        }
        this.QueueRender()
        return true
    }

    DeleteStep(cat, step) {
        m := this.Model
        s := m.Step(cat, step)
        if !(s is Map)
            return false
        if m.IsRequiredStep(cat, step) {
            this.Res(m.RemoveStep(cat, step))
            return false
        }
        ans := this.Ask("delStep", 'Remove the step "' AdminModel.Label(s) '"?', "Remove step", ["Remove", "Cancel"], {Kind: "warning", Danger: 1, Cancel: 2})
        if (ans.Button != "Remove")
            return false
        return this.RemoveWithRefs('the step "' AdminModel.Label(s) '"', (clean) => m.RemoveStep(cat, step, clean))
    }

    DeleteCategory(id) {
        m := this.Model
        c := m.Cat(id)
        if !(c is Map)
            return false
        lab := AdminModel.Label(c)
        if m.IsSystem(id) {
            ans := this.Ask("delSystem", 'You are about to remove the built-in category "' lab '".' "`n`n"
                . "Agents will lose it, and History entries that used it will show its id (" id ") instead of its name. "
                . "The configuration is NOT valid without it: you can't save until you restore it (Categories page, Restore).`n`n"
                . "Type the category's name to confirm:", "Remove a built-in category", ["Remove it anyway", "Cancel"],
                {Kind: "warning", Input: true, Placeholder: lab, Danger: 1, Cancel: 2})
            if (ans.Button != "Remove it anyway" || StrCompare(Util.Trim(ans.Value), lab) != 0) {
                if (ans.Button = "Remove it anyway")
                    this.Toast("The name did not match: nothing was removed.", "warning")
                return false
            }
        } else {
            ans := this.Ask("delCategory", 'Remove the category "' lab '"?', "Remove category", ["Remove", "Cancel"], {Kind: "warning", Danger: 1, Cancel: 2})
            if (ans.Button != "Remove")
                return false
        }
        r := m.RemoveCategory(id)
        if this.Struct(r) {
            if (this.Sel.Cat == id)
                this.Sel.Cat := "", this.Sel.Step := ""
            return true
        }
        return false
    }

    ; ---------------------------------------------------------------------------------------------- save / reload / close
    SaveNow() {
        m := this.Model
        this.Flush()
        if !m.Dirty {
            this.Toast("There is nothing to save.", "info")
            return true
        }
        v := m.Validate()
        if !v.Ok {
            this.Log.Info("save refused", {reason: "validation", errors: v.Errors.Length})
            this.LastError := v.Errors[1]
            this.ShowPage("check")
            this.Ask("saveInvalid", "The configuration has " v.Errors.Length " error" (v.Errors.Length = 1 ? "" : "s") " and was not saved.`n`nFirst: "
                . m.Describe("error", v.Errors[1]).Text, "Can't save yet", ["OK"], {Kind: "error"})
            return false
        }
        m.ScanConflicts()
        this.UpdateBanner()
        if (m.Conflicts.Length > 0) {
            names := ""
            for n in m.Conflicts
                names .= (names = "" ? "" : ", ") n
            ans := this.Ask("saveCopies", "OneDrive found conflicting copies of the config. Check them before saving.`n`n" names
                . "`n`nThey are not deleted by this app. Save anyway?", "Conflicting copies", ["Save anyway", "Cancel"], {Kind: "warning", Cancel: 2})
            if (ans.Button != "Save anyway")
                return false
        }
        r := m.Save()
        if r.Ok {
            this.Log.Info("saved", {revision: r.Revision})
            this.Toast("Saved. Revision " r.Revision ".", "success")
            this.UpdateChrome()
            this.UpdateBanner()
            this.QueueRender()
            return true
        }
        this.LastError := r.Error
        this.Log.Info("save refused", {reason: r.Kind})
        msg := m.SaveMessage(r)
        if (r.Kind = "conflict") {
            ans := this.Ask("saveChanged", msg.Text, msg.Title, ["Reload (unsaved edits will be lost)", "Keep editing"], {Kind: "warning", Cancel: 2})
            if (ans.Button = "Reload (unsaved edits will be lost)")
                this.ReloadNow(false)
        } else
            this.Ask("save" r.Kind, msg.Text, msg.Title, ["OK"], {Kind: "error"})
        return false
    }

    ReloadNow(ask := true) {
        m := this.Model
        this.Flush()
        if (ask && m.Dirty) {
            ans := this.Ask("reload", "Reload the configuration from the file?`n`nYour unsaved edits will be lost.", "Reload",
                ["Reload (unsaved edits will be lost)", "Keep editing"], {Kind: "warning", Cancel: 2})
            if (ans.Button != "Reload (unsaved edits will be lost)")
                return false
        }
        m.Load()
        this._lastDirty := ""
        if !(m.Cat(this.Sel.Cat) is Map)
            this.Sel.Cat := "", this.Sel.Step := ""
        this.Pv.Compose()
        this.UpdateChrome()
        this.UpdateBanner()
        this.RenderPage(this.Cur)
        this.RefreshNoteNow()
        this.Toast("Reloaded revision " m.Store.Revision ".", "info")
        return true
    }

    ; Runs before the window closes, however it was asked for. True keeps it open.
    OnClosing(why := "") {
        m := this.Model
        try this.Flush()
        if !m.Dirty
            return false
        ans := this.Ask("close", "You have unsaved changes.`n`nSave them before closing?", "Unsaved changes", ["Save", "Discard", "Cancel"],
            {Kind: "warning", Cancel: 3})
        if (ans.Button = "Save")
            return !this.SaveNow()
        if (ans.Button = "Discard")
            return false
        return true
    }

    ; ---------------------------------------------------------------------------------------------- files
    PickFile(mode, default := "") {
        if IsObject(this.FileHook)
            return this.FileHook.Call(mode, default)
        try {
            if (mode = "save")
                return FileSelect("S16", default, "Export the configuration", "JSON file (*.json)")
            return FileSelect(3, "", "Import a configuration", "JSON file (*.json)")
        }
        return ""
    }

    ExportFile() {
        this.Flush()
        path := this.PickFile("save", "nfs-notes-config-" Util.Stamp() ".json")
        if (path = "")
            return false
        if !RegExMatch(path, "i)\.json$")
            path .= ".json"
        try {
            f := FileOpen(path, "w", "UTF-8-RAW")
            f.Write(this.Model.ExportText())
            f.Close()
        } catch as e {
            this.FilesMsg := "Could not write the file: " e.Message
            this.Toast(this.FilesMsg, "error")
            this.RenderPage("files")
            return false
        }
        SplitPath(path, &nm)
        this.FilesMsg := "Exported the working copy to " nm "."
        this.Toast(this.FilesMsg, "success")
        this.RenderPage("files")
        return true
    }

    ImportFile() {
        path := this.PickFile("open")
        if (path = "")
            return false
        text := ""
        try text := FileRead(path, "UTF-8")
        catch as e {
            this.FilesMsg := "Could not read the file: " e.Message
            this.Toast(this.FilesMsg, "error")
            this.RenderPage("files")
            return false
        }
        return this.ImportText(text)
    }

    ImportText(text) {
        m := this.Model
        r := m.ImportText(text)
        if !r.Ok {
            this.FilesMsg := "Import refused: " r.Error
            this.LastError := r.Error
            this.Ask("importBad", r.Error "`n`nNothing was changed.", "Import refused", ["OK"], {Kind: "error"})
            this.RenderPage("files")
            return false
        }
        sm := r.Summary
        names := ""
        for n in sm.Categories
            names .= (names = "" ? "" : ", ") n
        warn := sm.Warnings.Length > 0 ? "`n" sm.Warnings.Length " warning" (sm.Warnings.Length = 1 ? "" : "s") "." : ""
        who := sm.UpdatedBy != "" ? ", saved by " sm.UpdatedBy : ""
        mig := sm.Migrated ? ", upgraded from an older format" : ""
        body := "This file holds " sm.Categories.Length " categories (" names "), revision " sm.Revision who mig "." warn
        ans := this.Ask("importOk", body "`n`nReplace your working copy with it? Nothing is saved until you press Save.", "Import",
            ["Replace", "Cancel"], {Cancel: 2})
        if (ans.Button != "Replace")
            return false
        m.ApplyConfig(r.Cfg)
        this.FilesMsg := "Imported " sm.Categories.Length " categories. Not saved yet."
        this.Toast(this.FilesMsg, "success")
        this.AfterReplace()
        return true
    }

    RestoreDefaultsNow() {
        ans := this.Ask("restoreDefaults", "Replace the working copy with the built-in defaults?`n`nAll your wording is replaced by the placeholder text. "
            . "Nothing is saved until you press Save.", "Restore defaults", ["Restore defaults", "Cancel"], {Kind: "warning", Danger: 1, Cancel: 2})
        if (ans.Button != "Restore defaults")
            return false
        this.Model.RestoreDefaults()
        this.FilesMsg := "The built-in defaults are in the working copy. Not saved yet."
        this.Toast(this.FilesMsg, "info")
        this.AfterReplace()
        return true
    }

    ; The working copy was replaced as a whole.
    AfterReplace() {
        if !(this.Model.Cat(this.Sel.Cat) is Map)
            this.Sel.Cat := "", this.Sel.Step := ""
        this.RenderPage(this.Cur)
        this.UpdateChrome()
        this.RefreshNoteNow()
    }

    ApplyRaw() {
        text := this.FormVal("rawText", [])
        r := this.Model.ApplyRaw(text)
        if !r.Ok {
            this.RawMsg := "Not applied: " r.Error
            this.LastError := r.Error
            this.SetText("adRawMsg", this.RawMsg)
            this.Toast("The text was not applied.", "warning")
            return false
        }
        this.RawMsg := "Applied to the working copy. Not saved yet."
        this.AfterReplace()
        this.Toast(this.RawMsg, "success")
        return true
    }
}

; ============================================================================================================
; The app: ini, logging, the store, the model; --selftest runs against a throw-away shared folder.
class AdminApp {
    static VERSION := "1.0.0 (M10)"

    __New(iniPath := "") {
        this.IniPath := iniPath != "" ? iniPath : A_ScriptDir "\nfsnotes.ini"
        this.SharedPath := ""
        this.LogLevel := "info"
        this.SelfTest := false
        this.TempRoot := ""
        this.Logger := ""
        this.Store := ""
        this.Model := ""
        this.Pv := ""
        this.Win := ""
    }

    Run() {
        for a in A_Args
            if (a = "--selftest")
                this.SelfTest := true
        logPath := Util.UserDataDir() "\logs\nfsadmin.log"
        if this.SelfTest {
            this.TempRoot := A_Temp "\NFSAdminSelfTest_" A_TickCount
            DirCreate(this.TempRoot "\shared")
            seed := A_ScriptDir "\config\config.default.json"
            if FileExist(seed)
                FileCopy(seed, this.TempRoot "\shared\config.json", 1)
            else
                Util.AtomicWrite(this.TempRoot "\shared\config.json", ConfigJson.Stringify(Defaults.Config()))
            this.SharedPath := this.TempRoot "\shared"
            logPath := A_Temp "\NFSAdminSelfTest.log"
            try FileDelete(logPath)
            this.LogLevel := "debug"
        } else {
            this.SharedPath := Util.Trim(IniRead(this.IniPath, "Config", "SharedPath", ""))
            if (this.SharedPath = "")
                this.SharedPath := A_ScriptDir "\config"
            this.LogLevel := IniRead(this.IniPath, "Log", "Level", "info")
        }
        this.Logger := Log({Path: logPath, Level: this.LogLevel})
        this.Logger.Info("NFS Notes Admin starting", {ahk: A_AhkVersion, version: AdminApp.VERSION, selftest: this.SelfTest ? 1 : 0,
            sharedPathOverride: !this.SelfTest && IniRead(this.IniPath, "Config", "SharedPath", "") != "" ? 1 : 0})
        try {
            cacheDir := this.SelfTest ? this.TempRoot "\cache" : Util.UserDataDir()
            this.Store := ConfigStore({SharedDir: this.SharedPath, CacheDir: cacheDir, Logger: this.Logger, User: A_UserName})
            this.Model := AdminModel({Store: this.Store, Logger: this.Logger})
            this.Model.Load()
            this.Pv := AdminPreview(this.Model)
            this.Logger.Info("admin ready", {source: this.Store.Source, revision: this.Store.Revision, warnings: this.Store.Warnings.Length,
                conflicts: this.Model.Conflicts.Length, sharedConfigured: this.Store.SharedConfigured ? 1 : 0})
            this.Win := AdminWindow(this)
            this.Win.Build()
            this.Win.Show()
        } catch as e {
            this.Logger.Error("startup failed", {error: e.Message, line: e.Line, file: e.File, what: e.What})
            throw e
        }
    }
}
