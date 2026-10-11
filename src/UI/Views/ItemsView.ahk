#Requires AutoHotkey v2.0
; ItemsView.ahk - the generic page for any "items" category (Equipment, Billing, later admin-made ones).
;
; What it draws (all from the config through ItemsModel; nothing here knows an action, item or outcome name):
;   - an ENTRY FORM: action (segmented control, or a radio list when there are more than 4 options or the labels are
;     long), item (drop-down), quantity (optional text box, only when the category has qty), outcome (only when the
;     category has outcomes; marked required when outcomeRequired), details (optional text box, only when it has
;     details) and an Add button. After Add was pressed, a missing or invalid part gets an inline hint.
;   - under the form a live preview of the entry being built ("Will add: Swapped Item 1 (placeholder).")
;   - the LIST of entries in order, each with the sentence it adds to the note and Edit / Remove buttons. Edit loads the
;     entry into the form (Add becomes Save, Cancel appears); Remove asks first. Empty list: "No entries yet."
;
; The form state (this.Form) lives in this object, not only in the DOM, so a re-render never loses what was chosen or typed.
; Rendering policy, as in StepsView: the form's controls are rebuilt only when their STRUCTURE changes (config change,
; forced refresh); everything else (chosen values, hints, preview, buttons, list) is patched in place, and a text box that
; has the focus is never overwritten. Typing goes into this.Form at once (it is not part of the session until Add).
; The same library tags are used as in StepsView (ax-segmented / ax-radio / ax-text) plus ax-dropdown, put into one mount
; point with MainWindow.SetTagHtml (tags expanded as text first).

class ItemsView {
    static MAX_SEGMENTED := 4
    static MAX_SEG_CHARS := 60         ; more label text than this does not fit a segmented control: use a radio list

    __New(win, app, catId) {
        this.Win := win
        this.App := app
        this.CatId := catId
        this.RootId := "nfsIV_" catId
        this.FormId := "nfsIVF_" catId
        this.TitleId := "nfsIVT_" catId
        this.PrevId := "nfsIVP_" catId
        this.MsgId := "nfsIVM_" catId
        this.AddId := "nfsIVAdd_" catId
        this.CancelId := "nfsIVCan_" catId
        this.ListId := "nfsIVL_" catId
        this.Structure := ""
        this.ListSig := ""
        this.ListBuilt := false
        this.Rendered := false
        this.Form := ItemsView.EmptyForm()
        this.EditIdx := 0               ; 1-based index of the entry being edited, 0 = adding
        this.Tried := false             ; Add was pressed: show hints for missing parts
        this.Msg := ""                  ; refusal text under the form (duplicate)
        this.ForceInputs := false       ; overwrite the text boxes on the next sync even if one has the focus
        this.WiredIds := Map()
        this.RowIds := 0                ; how many Edit/Remove pairs are wired
    }

    static EmptyForm() => {action: "", item: "", qty: "", outcome: "", details: ""}

    ; --- ids ---------------------------------------------------------------------------------------------------
    CtlId(field) => "nfsIVC_" this.CatId "_" field
    HintId(field) => "nfsIVH_" this.CatId "_" field
    EditBtnId(i) => "nfsIVE_" this.CatId "_" i
    RemoveBtnId(i) => "nfsIVR_" this.CatId "_" i

    Model => this.App.ModelFor(this.CatId)
    Category => this.App.CategoryFor(this.CatId)

    Label() {
        c := this.Category
        return (c is Map && c.Has("label")) ? c["label"] : this.CatId
    }

    ; --- static page content -----------------------------------------------------------------------------------
    Html() => '<div class="nfs-iv-form" id="' this.FormId '"></div>'
        . '<div class="nfs-iv-prev" id="' this.PrevId '"></div>'
        . '<div class="nfs-iv-msg" id="' this.MsgId '"></div>'
        . '<div class="nfs-iv-btns"><span class="btn accent" id="' this.AddId '">Add</span>'
        . '<span class="btn" id="' this.CancelId '" style="display:none">Cancel</span></div>'
        . '<div class="nfs-iv-hd">Entries</div>'
        . '<div class="nfs-iv-list" id="' this.ListId '"></div>'

    ; Structural CSS (rem sizes follow the Text size setting); colours come from Theme.Css.
    static Css() => "
    (
    .nfs-iv-form { margin-bottom: 4px; }
    .nfs-iv-title { font-weight: 600; margin-bottom: 8px; }
    .nfs-iv-prev { display: none; margin: 8px 0 2px 0; padding: 6px 10px; border-radius: 4px; font-size: .929rem; word-wrap: break-word; }
    .nfs-iv-msg { display: none; margin-top: 8px; font-size: .857rem; font-weight: 600; }
    .nfs-iv-btns { margin: 10px 0 16px 0; }
    .nfs-iv-btns .btn { margin-right: 8px; }
    .nfs-iv-hd { font-weight: 600; margin: 6px 0; }
    .nfs-iv-row { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; padding: 6px 8px;
        margin-bottom: 4px; border-radius: 5px; }
    .nfs-iv-n { margin-right: 8px; min-width: 22px; }
    .nfs-iv-t { -ms-flex: 1 1 0px; flex: 1 1 0px; min-width: 0; margin-right: 8px; word-wrap: break-word; }
    .nfs-iv-t.bad { font-style: italic; }
    .nfs-iv-row .btn { margin-left: 6px; }
    .nfs-iv-empty { padding: 6px 0; }
    )"

    ; --- hooks ---------------------------------------------------------------------------------------------------
    ; Register every handler this category can need. The ids do not depend on the config, so this runs once; calling it
    ; again (config change) is harmless.
    Wire() {
        g := this.Win.G
        if !this.WiredIds.Has(this.AddId) {
            g.On("click", this.AddId, ObjBindMethod(this, "OnAddClick"))
            g.On("click", this.CancelId, ObjBindMethod(this, "OnCancelClick"))
            this.WiredIds[this.AddId] := true
        }
        for f in ["action", "item", "outcome"]
            if !this.WiredIds.Has(this.CtlId(f)) {
                g.OnValue(this.CtlId(f), ObjBindMethod(this, "OnPick", f))
                this.WiredIds[this.CtlId(f)] := true
            }
        for f in ["qty", "details"]
            if !this.WiredIds.Has(this.CtlId(f)) {
                for ev in ["keyup", "change", "focusout"]
                    g.On(ev, this.CtlId(f), ObjBindMethod(this, "OnType", f, ev))
                this.WiredIds[this.CtlId(f)] := true
            }
    }

    OnPick(field, value, *) {
        this.Form.%field% := String(value)
        this.Msg := ""
        this.Win.QueueSteps()
    }

    OnType(field, ev, *) {
        this.ReadInput(field)
        this.Msg := ""
        this.UpdatePreview()
        if (ev != "keyup")
            this.Win.QueueSteps()
    }

    ReadInput(field) {
        el := ""
        try el := this.Win.G.El(this.CtlId(field))
        if IsObject(el)
            try this.Form.%field% := StepsView.Norm(el.value)
    }

    ; Take the typed text from the boxes into this.Form (before anything reads the form).
    Flush() {
        if !this.Rendered
            return
        for f in ["qty", "details"]
            this.ReadInput(f)
    }

    ; --- form <-> entry -----------------------------------------------------------------------------------------
    FormEntry() {
        m := this.Model
        return IsObject(m) ? m.Clean(this.Form) : ItemsModel.Norm(this.Form)
    }

    FormEmpty() {
        f := this.Form
        return f.action = "" && f.item = "" && f.outcome = "" && Util.Trim(f.qty) = "" && Util.Trim(f.details) = ""
    }

    ; True when the form holds something that is not in the list: an action, item, outcome, qty or details that was
    ; not added (or, while editing, a change that was not saved). Used by Copy Notes.
    HasDraft() {
        this.Flush()
        if this.FormEmpty()
            return false
        if (this.EditIdx > 0) {
            list := this.App.Session.EntriesFor(this.CatId)
            if (this.EditIdx <= list.Length) {
                a := ItemsModel.ToMap(list[this.EditIdx]), b := ItemsModel.ToMap(this.FormEntry())
                for k, v in a
                    if (v != b[k])
                        return true
                return false
            }
        }
        return true
    }

    ClearForm() {
        this.Form := ItemsView.EmptyForm()
        this.EditIdx := 0
        this.Tried := false
        this.Msg := ""
        this.PushInputs()
    }

    ; Write the form's text into the boxes now (so a later Flush can never bring old text back).
    PushInputs() {
        for f in ["qty", "details"] {
            try {
                el := this.Win.G.El(this.CtlId(f))
                if (IsObject(el) && StepsView.Norm(el.value) != this.Form.%f%)
                    el.value := this.Form.%f%
            }
        }
    }

    ; New call, Clear All, History load, reset: forget the form.
    ResetUi() {
        this.Form := ItemsView.EmptyForm()
        this.EditIdx := 0
        this.Tried := false
        this.Msg := ""
        this.ForceInputs := true
    }

    ; --- buttons ---------------------------------------------------------------------------------------------------
    OnAddClick(*) {
        this.AddNow()
        this.Win.QueueSteps()
    }

    ; Add (or Save) the form's entry. Returns the App result {Ok, Error, Index, Missing}.
    AddNow() {
        this.Flush()
        e := this.FormEntry()
        this.Tried := true
        this.Msg := ""
        r := this.EditIdx > 0 ? this.App.UpdateEntry(this.CatId, this.EditIdx, e) : this.App.AddEntry(this.CatId, e)
        if r.Ok {
            this.ClearForm()
            return r
        }
        if r.HasOwnProp("Duplicate") && r.Duplicate
            this.Msg := r.Error
        else if (r.Missing.Length = 0)
            this.Msg := r.Error
        return r
    }

    OnCancelClick(*) {
        this.CancelNow()
        this.Win.QueueSteps()
    }

    CancelNow() {
        this.ClearForm()
    }

    EditNow(i) {
        list := this.App.Session.EntriesFor(this.CatId)
        if !(i is Integer) || i < 1 || i > list.Length
            return false
        m := this.Model
        e := IsObject(m) ? m.Clean(list[i]) : ItemsModel.Norm(list[i])
        this.Form := {action: e.action, item: e.item, qty: e.qty, outcome: e.outcome, details: e.details}
        this.EditIdx := i
        this.Tried := false
        this.Msg := ""
        this.PushInputs()
        return true
    }

    OnEditClick(i, *) {
        this.EditNow(i)
        this.Win.QueueSteps()
    }

    OnRemoveClick(i, *) {
        if this.Win.G.Confirm("Remove this entry?", "Remove entry", "Remove", "Keep")
            this.RemoveNow(i)
    }

    RemoveNow(i) {
        if !this.App.RemoveEntry(this.CatId, i)
            return false
        if (this.EditIdx = i)
            this.ClearForm()
        else if (this.EditIdx > i)
            this.EditIdx -= 1
        this.Win.QueueSteps()
        return true
    }

    ; --- rendering -------------------------------------------------------------------------------------------------
    ; Draw (or patch) the page. force: rebuild the form controls and overwrite the text boxes. Returns false when the page
    ; is not there yet (it is then drawn when the page is first shown).
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
            this.ListBuilt := false
        }
        this.Sync(m, full || this.ForceInputs)
        this.ForceInputs := false
        return true
    }

    ; Everything that decides which controls the form has.
    StructureKey(m) {
        k := (m.Qty ? "q" : "-") (m.Details ? "d" : "-") (m.OutcomeRequired ? "r" : "-") "|"
        for list in [m.Actions, m.Items, m.Outcomes] {
            for o in list
                k .= o["id"] "=" ItemsModel.Label(o) ";"
            k .= "|"
        }
        return k
    }

    ; "id:Label|id:Label" for the library's option lists (a ":" or "|" in a label would break them).
    OptionsOf(list) {
        s := ""
        for o in list
            s .= (s = "" ? "" : "|") o["id"] ":" StepsView.Lbl(ItemsModel.Label(o))
        if (list.Length = 1)
            s .= "|"
        return s
    }

    ; Segmented control for a few short options, else a radio list.
    ChoiceKind(list) {
        n := list.Length, chars := 0
        for o in list
            chars += StrLen(ItemsModel.Label(o))
        return (n <= ItemsView.MAX_SEGMENTED && chars <= ItemsView.MAX_SEG_CHARS) ? "ax-segmented" : "ax-radio"
    }

    FormHtml(m) {
        e := (x) => Util.HtmlEscape(x)
        star := (on) => '<span class="nfs-sv-star' (on ? " on" : "") '">*</span>'
        h := '<ax-card><div class="nfs-iv-title" id="' this.TitleId '">New entry</div>'
        tag := this.ChoiceKind(m.Actions)
        h .= '<div class="nfs-sv-fl">Action' star(true) '</div><' tag ' id="' this.CtlId("action") '" options="'
            . e(this.OptionsOf(m.Actions)) '" value=""></' tag '><div class="nfs-sv-hint" id="' this.HintId("action") '"></div>'
        h .= '<div class="nfs-sv-fl">Item' star(true) '</div><ax-dropdown id="' this.CtlId("item") '" options="'
            . e(this.OptionsOf(m.Items)) '" value="" placeholder="Choose an item" width="280"></ax-dropdown>'
            . '<div class="nfs-sv-hint" id="' this.HintId("item") '"></div>'
        if m.Qty
            h .= '<div class="nfs-sv-fl">Quantity (optional, 1-99)</div><ax-text id="' this.CtlId("qty")
                . '" value="" placeholder="Leave empty if not needed"></ax-text><div class="nfs-sv-hint" id="' this.HintId("qty") '"></div>'
        if (m.Outcomes.Length > 0) {
            tag := this.ChoiceKind(m.Outcomes)
            h .= '<div class="nfs-sv-fl">Outcome' (m.OutcomeRequired ? star(true) : " (optional)") '</div><' tag ' id="'
                . this.CtlId("outcome") '" options="' e(this.OptionsOf(m.Outcomes)) '" value=""></' tag
                . '><div class="nfs-sv-hint" id="' this.HintId("outcome") '"></div>'
        }
        if m.Details
            h .= '<div class="nfs-sv-fl">Details (optional)</div><ax-text id="' this.CtlId("details")
                . '" value="" placeholder="Anything else for the note"></ax-text>'
        return h '</ax-card>'
    }

    ; Patch the page from this.Form, the session's entries and the hint state.
    Sync(m, forceInputs) {
        g := this.Win.G
        act := ""
        try act := g.Doc.activeElement.id
        f := this.Form
        this.SyncChoice(this.CtlId("action"), f.action)
        this.SyncDropdown(this.CtlId("item"), f.item, "Choose an item")
        this.SyncChoice(this.CtlId("outcome"), f.outcome)
        for fld in ["qty", "details"] {
            try {
                el := g.El(this.CtlId(fld))
                if (IsObject(el) && StepsView.Norm(el.value) != f.%fld% && (forceInputs || act != this.CtlId(fld)))
                    el.value := f.%fld%
            }
        }
        ; hints
        miss := Map()
        if this.Tried
            for x in m.Validate(this.FormEntry()).Missing
                miss[x.field] := x
        texts := Map("action", "Choose an action.", "item", "Choose an item.", "outcome", "Choose an outcome.",
            "qty", "Quantity must be a whole number from 1 to 99 (or leave it empty).")
        for fld in ["action", "item", "qty", "outcome"]
            this.SetHint(this.HintId(fld), miss.Has(fld), texts[fld])
        ; title, buttons, message
        editing := this.EditIdx > 0
        this.SetText(this.TitleId, editing ? "Editing entry " this.EditIdx : "New entry")
        this.SetText(this.AddId, editing ? "Save" : "Add")
        try this.Win.G.El(this.CancelId).style.display := editing ? "inline-block" : "none"
        this.SetBlock(this.MsgId, this.Msg != "", this.Msg)
        this.UpdatePreview()
        this.RenderList(m)
    }

    ; "Will add: <the sentence>" while the form holds a complete entry.
    UpdatePreview() {
        m := this.Model
        txt := ""
        if (IsObject(m) && !this.FormEmpty()) {
            p := m.Preview(this.FormEntry())
            if (p != "")
                txt := (this.EditIdx > 0 ? "Will save: " : "Will add: ") p
        }
        this.SetBlock(this.PrevId, txt != "", txt)
    }

    ; The list of entries (rebuilt only when it changed).
    RenderList(m) {
        entries := this.App.Session.EntriesFor(this.CatId)
        sig := "e" this.EditIdx "|"
        rows := []
        for i, en in entries {
            t := m.Describe(en)
            rows.Push(t)
            sig .= t "|" ItemsModel.Norm(en).details "~"
        }
        g := this.Win.G
        el := ""
        try el := g.El(this.ListId)
        if !IsObject(el)
            return
        if (sig == this.ListSig && this.ListBuilt)
            return
        h := ""
        for i, t in rows {
            ok := (t != "")
            h .= '<div class="nfs-iv-row' (this.EditIdx = i ? " editing" : "") '"><span class="nfs-iv-n">' i '.</span>'
                . '<span class="nfs-iv-t' (ok ? "" : " bad") '">' Util.HtmlEscape(ok ? t : "This entry uses an option that is no longer available.") '</span>'
                . (ok ? '<span class="btn" id="' this.EditBtnId(i) '">Edit</span>' : '')
                . '<span class="btn" id="' this.RemoveBtnId(i) '">Remove</span></div>'
        }
        if (h = "")
            h := '<div class="nfs-iv-empty">No entries yet.</div>'
        el.innerHTML := h
        this.WireRows(rows.Length, rows)
        this.ListSig := sig
        this.ListBuilt := true
    }

    WireRows(n, rows) {
        g := this.Win.G
        loop n {
            g.On("click", this.EditBtnId(A_Index), ObjBindMethod(this, "OnEditClick", A_Index))
            g.On("click", this.RemoveBtnId(A_Index), ObjBindMethod(this, "OnRemoveClick", A_Index))
        }
        i := n + 1
        while (i <= this.RowIds) {
            g.Off("click", this.EditBtnId(i)), g.Off("click", this.RemoveBtnId(i))
            i += 1
        }
        this.RowIds := n
    }

    ; --- small DOM helpers ---------------------------------------------------------------------------------------------
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

    ; Show the chosen option in a segmented control / radio list.
    SyncChoice(id, chosen) {
        try {
            el := this.Win.G.El(id)
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

    SyncDropdown(id, chosen, placeholder) {
        try {
            el := this.Win.G.El(id)
            if !IsObject(el)
                return
            items := el.querySelectorAll(".dd-item")
            label := ""
            loop items.length {
                it := items.item(A_Index - 1)
                on := (it.getAttribute("data-value") == chosen) && chosen != ""
                StepsView.SetCls(it, "selected", on)
                if on
                    label := it.innerText
            }
            el.setAttribute("data-value", chosen)
            v := el.querySelector(".dd-value")
            want := (label != "") ? label : placeholder
            if (IsObject(v) && v.innerText != want)
                v.innerText := want
        }
    }

    ; --- what is on the page (selftest) --------------------------------------------------------------------------------
    ; "segmented", "radio", "dropdown", "text" or "" (no such control) for a form field.
    ControlKind(field) {
        try {
            el := this.Win.G.El(this.CtlId(field))
            if !IsObject(el)
                return ""
            if (el.querySelectorAll(".seg").length > 0)
                return "segmented"
            if (el.querySelectorAll("label.radio").length > 0)
                return "radio"
            if (el.querySelectorAll(".dd-item").length > 0)
                return "dropdown"
            return "text"
        }
        return ""
    }

    ; The option (or drop-down item) with this id, through the DOM click the library listens to.
    Click(field, optionId) {
        try {
            el := this.Win.G.El(this.CtlId(field))
            for sel in [".seg", "label.radio", ".dd-item"] {
                els := el.querySelectorAll(sel)
                loop els.length {
                    x := els.item(A_Index - 1)
                    if (x.getAttribute("data-value") == optionId) {
                        if (sel = "label.radio")
                            x.querySelector("input").click()
                        else
                            x.click()
                        return true
                    }
                }
            }
        }
        return false
    }

    ; The chosen option id shown in a control ("" when none).
    Shown(field) {
        try {
            el := this.Win.G.El(this.CtlId(field))
            segs := el.querySelectorAll(".seg.active")
            if (segs.length > 0)
                return segs.item(0).getAttribute("data-value")
            r := el.querySelector("input:checked")
            if IsObject(r)
                return r.parentNode.getAttribute("data-value")
            d := el.querySelector(".dd-item.selected")
            if IsObject(d)
                return d.getAttribute("data-value")
        }
        return ""
    }

    ; Type into a box the way a key press would (value + the handler the library calls).
    TypeInto(field, text) {
        try {
            this.Win.G.El(this.CtlId(field)).value := text
            this.OnType(field, "change")
            return true
        }
        return false
    }

    InputText(field) {
        try return StepsView.Norm(this.Win.G.El(this.CtlId(field)).value)
        return "<none>"
    }

    ; The click on the Add / Save button through the DOM.
    ClickAdd() {
        try {
            this.Win.G.El(this.AddId).click()
            return true
        }
        return false
    }

    ClickCancel() {
        try {
            this.Win.G.El(this.CancelId).click()
            return true
        }
        return false
    }

    ClickRow(kind, i) {
        try {
            this.Win.G.El(kind = "edit" ? this.EditBtnId(i) : this.RemoveBtnId(i)).click()
            return true
        }
        return false
    }

    RowCount() {
        try return this.Win.G.El(this.ListId).querySelectorAll(".nfs-iv-row").length
        return -1
    }

    RowTexts() {
        s := ""
        try {
            els := this.Win.G.El(this.ListId).querySelectorAll(".nfs-iv-t")
            loop els.length
                s .= (s = "" ? "" : " || ") els.item(A_Index - 1).innerText
        }
        return s
    }

    EmptyShown() {
        try return InStr(this.Win.G.El(this.ListId).innerText, "No entries yet.") > 0
        return false
    }

    PreviewText() {
        try {
            el := this.Win.G.El(this.PrevId)
            return el.style.display = "none" ? "" : el.innerText
        }
        return "<none>"
    }

    MsgText() {
        try {
            el := this.Win.G.El(this.MsgId)
            return el.style.display = "none" ? "" : el.innerText
        }
        return "<none>"
    }

    HintsOn() {
        try return this.Win.G.El(this.RootId).querySelectorAll(".nfs-sv-hint.on").length
        return -1
    }

    HintText(field) {
        try return this.Win.G.El(this.HintId(field)).innerText
        return ""
    }

    AddText() {
        try return this.Win.G.El(this.AddId).innerText
        return ""
    }

    CancelShown() {
        try return this.Win.G.El(this.CancelId).style.display != "none"
        return false
    }

    TitleText() {
        try return this.Win.G.El(this.TitleId).innerText
        return ""
    }
}
