#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\AdminUi.ahk
; AdminPages.ahk - the markup of the Admin pages, drawn from the model (no AxGui include: strings only). The window
; (AdminWindow) puts the markup into the page with AdminHtml.SetTagHtml and reacts to the registered controls.
;
; Pages: categories | edit (steps / items / static editor of the selected category) | template | settings | preview | check |
; files | raw. Every function returns one HTML string.

class AdminPages {
    static SHEET_LABELS := Map("spectrum", "Spectrum (win365 + Spectrum colours)")

    __New(win) {
        this.W := win
        this.H := win.H
    }

    M => this.W.Model
    PV => this.W.Pv
    static E(s) => Util.HtmlEscape(s)
    static G(m, k, d := "") => (m is Map && m.Has(k)) ? m[k] : d

    Page(name) {
        switch name {
        case "categories": return this.Categories()
        case "edit": return this.Edit()
        case "template": return this.Template()
        case "settings": return this.Settings()
        case "preview": return this.Preview()
        case "check": return this.Check()
        case "files": return this.Files()
        case "raw": return this.Raw()
        }
        return ""
    }

    static Wrap(title, sub, body, cls := "") => '<div class="ad-pg ' cls '"><div class="ad-h">' AdminPages.E(title) '</div>'
        . '<div class="ad-sub">' sub '</div>' body '</div>'

    ; ------------------------------------------------------------------------------------------------ categories
    Categories() {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        body := ""
        miss := m.MissingSystem()
        if (miss.Length > 0) {
            body .= '<div class="ad-card"><b class="ad-err">Built-in categories are missing:</b> '
            for id in miss
                body .= e(id) ' ' h.Btn("catRestore", [id], "Restore " e(id)) ' '
            body .= '<div class="ad-sub">The configuration is not valid until they are back (the main app would fall back to its last good copy).</div></div>'
        }
        cats := m.Work["categories"]
        for i, c in cats {
            id := c["id"]
            icon := AdminPages.G(c, "icon", "")
            body .= '<div class="ad-card"><div class="ad-row">'
                . h.Moves("catUp", "catDown", [id], i > 1, i < cats.Length)
                . h.Chk("catOn", [id], AdminPages.G(c, "enabled", 1) = 1, "On", false, "Switch off to hide this category from agents")
                . h.Txt("catLabel", [id], AdminPages.G(c, "label"), "ad-w-m")
                . '<span class="ad-glyph" id="adGlyph_' id '">' (RegExMatch(icon, "^[0-9A-Fa-f]{4,6}$") ? "&#x" icon ";" : "?") '</span>'
                . h.Txt("catIcon", [id], icon, "ad-w-s", false, "E711")
                . h.Txt("catPrefix", [id], AdminPages.G(c, "notePrefix"), "ad-w-m", false, "Text before this part of the note")
                . '<span class="ad-tag">' e(AdminPages.G(c, "kind")) '</span>'
                . (m.IsSystem(id) ? '<span class="ad-tag sys">built-in</span>' : "")
                . (AdminPages.G(c, "enabled", 1) = 1 ? "" : '<span class="ad-tag off">off</span>')
                . '<span class="ad-id">' e(id) '</span>'
                . h.Btn("catEdit", [id], "Edit")
                . h.Btn("catDel", [id], "Delete")
                . '</div></div>'
        }
        body .= '<div class="ad-sec">Add a category</div><div class="ad-row">'
            . h.Sel("catNewKind", [], [["steps", "Steps (questions and choices)"], ["items", "Items (a list of entries)"]], "steps")
            . h.Txt("catNewName", [], "", "ad-w-m", false, "Name, e.g. Warranty")
            . h.Btn("catAdd", [], "Add category", "accent")
            . '</div><div class="ad-sub">A new Static category cannot be added: the Static view is built into the app.</div>'
        return AdminPages.Wrap("Categories", "The categories the agents see, in order. Rename them, switch them off, change their icon (a Segoe icon code) "
            . "and the text put in front of their part of the note. Ids are made from the name and stay fixed once created.", body)
    }

    ; ------------------------------------------------------------------------------------------------ edit
    Edit() {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        sel := this.W.Sel
        if !(m.Cat(sel.Cat) is Map)
            sel.Cat := m.Work["categories"].Length ? m.Work["categories"][1]["id"] : ""
        cat := m.Cat(sel.Cat)
        pairs := []
        for c in m.Work["categories"]
            pairs.Push([c["id"], AdminModel.Label(c) . (AdminPages.G(c, "enabled", 1) = 1 ? "" : " (off)")])
        body := '<div class="ad-row"><b>Category</b>' h.Sel("pickCat", [], pairs, sel.Cat)
        if !(cat is Map)
            return AdminPages.Wrap("Edit", "", body '</div><div class="ad-sub">There is no category to edit.</div>')
        body .= '<span class="ad-tag">' e(cat["kind"]) '</span>' (m.IsSystem(cat["id"]) ? '<span class="ad-tag sys">built-in</span>' : "")
            . '<span class="ad-id">' e(cat["id"]) '</span></div>'
        switch cat["kind"] {
        case "steps": body .= this.StepsEditor(cat)
        case "items": body .= this.ItemsEditor(cat)
        case "static": body .= this.StaticEditor(cat)
        }
        return AdminPages.Wrap("Edit: " AdminModel.Label(cat), "Changes show in the live note below at once. Nothing is saved until you press Save.", body)
    }

    ; The chip bar: click a placeholder to put it at the cursor of the text box you used last.
    ChipBar(kind, catId := "") {
        h := this.H
        out := '<div class="ad-chips"><span class="lbl">Insert a placeholder at the cursor of the last box you clicked:</span>'
        for c in this.M.Chips(kind, catId)
            out .= h.Chip(c.Text, c.Hint)
        return out '</div>'
    }

    ; --- steps categories ---
    StepsEditor(cat) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s), sel := this.W.Sel
        cid := cat["id"]
        steps := cat["steps"]
        if !(AdminModel.Find(steps, sel.Step) is Map)
            sel.Step := steps.Length ? steps[1]["id"] : ""
        out := this.ChipBar("steps", cid)
        out .= '<div class="ad-sec">Steps, in the order the agent sees them</div>'
        for i, s in steps {
            sid := s["id"]
            req := AdminPages.G(s, "required", 0) = 1
            locked := m.IsRequiredStep(cid, sid)
            out .= '<div class="ad-card' (sid == sel.Step ? " sel" : "") '"><div class="ad-row">'
                . h.Moves("stepUp", "stepDown", [cid, sid], i > 1, i < steps.Length)
                . h.Btn("stepSel", [cid, sid], e(AdminModel.Label(s)), sid == sel.Step ? "on" : "")
                . '<span class="ad-tag">' e(AdminModel.TypeOf(s)) '</span>' (req ? '<span class="ad-tag sys">required</span>' : "")
                . (s.Has("when") ? '<span class="ad-tag cx">conditional</span>' : "")
                . '<span class="ad-id">' e(sid) '</span>'
                . h.Btn("stepDel", [cid, sid], "Remove", "", locked ? "This step is required by Not Done and can't be removed." : "Remove this step", locked)
                . '</div></div>'
        }
        out .= '<div class="ad-row">' h.Txt("stepNewName", [cid], "", "ad-w-m", false, "New step name")
            . h.Sel("stepNewType", [cid], [["choice", "Choice"], ["yesno", "Yes / No"], ["text", "Text"], ["group", "Group of fields"]], "choice")
            . h.Btn("stepAdd", [cid], "Add step", "accent") '</div>'
        s := AdminModel.Find(steps, sel.Step)
        if (s is Map)
            out .= this.StepDetail(cat, s)
        out .= this.FlagsEditor(cat)
        return out
    }

    StepDetail(cat, s) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"], sid := s["id"]
        type := AdminModel.TypeOf(s)
        locked := m.IsRequiredStep(cid, sid)
        out := '<div class="ad-sec">Step: ' e(AdminModel.Label(s)) ' <span class="ad-id">' e(sid) '</span></div>'
        out .= '<div class="ad-row"><span>Name</span>' h.Txt("stepLabel", [cid, sid], AdminPages.G(s, "label"), "ad-grow")
            . h.Sel("stepType", [cid, sid], [["choice", "Choice"], ["yesno", "Yes / No"], ["text", "Text"], ["group", "Group of fields"]], type)
            . h.Chk("stepReq", [cid, sid], AdminPages.G(s, "required", 0) = 1, "Required")
            . '</div>'
        if locked
            out .= '<div class="ad-sub">This step is required by Not Done: it cannot be removed or turned into another type.</div>'
        out .= '<div class="ad-row"><span>Note text</span>' h.Txt("stepFrag", [cid, sid], AdminPages.G(s, "fragment"), "ad-grow", true, "Added to the note (optional)") '</div>'
        out .= this.Cond({K: "when", Cat: cid, Step: sid, Field: "", Flag: ""}, "Show this step when")
        if s.Has("options") && s["options"] is Array
            out .= this.OptionsEditor(cat, s)
        out .= this.FieldsEditor(cat, s)
        return out
    }

    OptionsEditor(cat, s) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"], sid := s["id"]
        yesno := AdminModel.TypeOf(s) = "yesno"
        opts := s["options"]
        out := '<div class="ad-sec">Options</div>'
        if yesno
            out .= '<div class="ad-sub">A Yes / No step always has these two options; you can change their wording.</div>'
        for i, o in opts {
            oid := o["id"]
            out .= '<div class="ad-card"><div class="ad-row">'
            if !yesno
                out .= h.Moves("optUp", "optDown", [cid, sid, oid], i > 1, i < opts.Length)
            out .= h.Txt("optLabel", [cid, sid, oid], AdminPages.G(o, "label"), "ad-w-m")
                . h.Txt("optFrag", [cid, sid, oid], AdminPages.G(o, "fragment"), "ad-grow", true, "Added to the note when chosen")
                . '<span class="ad-id">' e(oid) '</span>'
            hasStop := o.Has("stop") && o["stop"] is Map
            out .= h.Chk("stopOn", [cid, sid, oid], hasStop, "Stops the workflow")
            if !yesno
                out .= h.Btn("optDel", [cid, sid, oid], "Remove", "", opts.Length <= 1 ? "A choice needs at least one option" : "Remove this option", opts.Length <= 1)
            out .= '</div>'
            if hasStop
                out .= this.StopEditor(cat, s, o)
            out .= '</div>'
        }
        if !yesno
            out .= '<div class="ad-row">' h.Txt("optNewName", [cid, sid], "", "ad-w-m", false, "New option name") h.Btn("optAdd", [cid, sid], "Add option", "accent") '</div>'
        return out
    }

    ; The stop of an option: the message the agent sees, the note text, and which earlier steps stay in the note.
    StopEditor(cat, s, o) {
        h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"], sid := s["id"], oid := o["id"]
        st := o["stop"]
        out := '<div class="ad-stop"><div class="ad-row"><span>Message to the agent</span>'
            . h.Txt("stopMsg", [cid, sid, oid], AdminPages.G(st, "message"), "ad-grow") '</div>'
            . '<div class="ad-row"><span>Note text instead</span>' h.Txt("stopFrag", [cid, sid, oid], AdminPages.G(st, "fragment"), "ad-grow", true, "Replaces the rest of the note") '</div>'
        keep := Map()
        if (st.Has("keepSteps") && st["keepSteps"] is Array)
            for k in st["keepSteps"]
                keep[k] := true
        out .= '<div class="ad-row"><span>Keep in the note:</span>'
        any := false
        for x in cat["steps"] {
            if (x["id"] == sid)
                break
            any := true
            out .= h.Chk("stopKeep", [cid, sid, oid, x["id"]], keep.Has(x["id"]), AdminModel.Label(x))
        }
        if !any
            out .= '<span class="ad-sub">(no earlier step)</span>'
        return out '</div></div>'
    }

    FieldsEditor(cat, s) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"], sid := s["id"]
        flds := (s.Has("fields") && s["fields"] is Array) ? s["fields"] : []
        out := '<div class="ad-sec">Text boxes (fields)</div>'
        if (flds.Length = 0)
            out .= '<div class="ad-sub">No text boxes. Add one to let the agent type something.</div>'
        isGroup := AdminModel.TypeOf(s) = "group"
        for i, f in flds {
            fid := f["id"]
            out .= '<div class="ad-card"><div class="ad-row">'
                . h.Moves("fieldUp", "fieldDown", [cid, sid, fid], i > 1, i < flds.Length)
                . h.Txt("fieldLabel", [cid, sid, fid], AdminPages.G(f, "label"), "ad-grow")
                . h.Chk("fieldReq", [cid, sid, fid], AdminPages.G(f, "required", 0) = 1, "Required")
                . h.Chk("fieldMulti", [cid, sid, fid], AdminPages.G(f, "multiline", 0) = 1, "Multi-line")
                . '<span class="ad-id">{' e(fid) '}</span>'
                . h.Btn("fieldDel", [cid, sid, fid], "Remove", "", isGroup && flds.Length <= 1 ? "A group needs at least one field" : "Remove this field", isGroup && flds.Length <= 1)
                . '</div>'
                . this.Cond({K: "req", Cat: cid, Step: sid, Field: fid, Flag: ""}, "Also required when")
                . '</div>'
        }
        out .= '<div class="ad-row">' h.Txt("fieldNewName", [cid, sid], "", "ad-w-m", false, "New field name") h.Btn("fieldAdd", [cid, sid], "Add field", "accent") '</div>'
        return out
    }

    FlagsEditor(cat) {
        h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"]
        flags := (cat.Has("flags") && cat["flags"] is Array) ? cat["flags"] : []
        out := '<div class="ad-sec">Warnings (flags)</div><div class="ad-sub">A flag shows a warning to the agent when its condition is true. It never blocks anything.</div>'
        for i, f in flags {
            fid := f["id"]
            out .= '<div class="ad-card"><div class="ad-row">'
                . h.Moves("flagUp", "flagDown", [cid, fid], i > 1, i < flags.Length)
                . h.Txt("flagMsg", [cid, fid], AdminPages.G(f, "message"), "ad-grow")
                . '<span class="ad-id">' e(fid) '</span>'
                . h.Btn("flagDel", [cid, fid], "Remove")
                . '</div>'
                . this.Cond({K: "flag", Cat: cid, Step: "", Field: "", Flag: fid}, "Warn when")
                . '</div>'
        }
        out .= '<div class="ad-row">' h.Txt("flagNewMsg", [cid], "", "ad-grow", false, "Warning text") h.Btn("flagAdd", [cid], "Add flag", "accent") '</div>'
        return out
    }

    ; --- the condition builder ---
    Cond(slot, title) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        sa := AdminHtml.SlotArgs(slot)
        c := m.GetCond(slot)
        flat := AdminModel.CondFlat(c)
        out := '<div class="ad-cond"><div class="ad-row"><b>' e(title) '</b>'
        if !flat.Simple {
            out .= '<span class="ad-tag cx">nested condition</span><span class="ad-sub">too complex for the builder</span></div>'
                . '<div class="ad-json">' e(m.CondJson(slot)) '</div>'
                . '<div class="ad-row"><span>Edit as JSON</span>' h.Txt("condJson", sa, m.CondJson(slot), "ad-grow", false, "", true, 5)
                . h.Btn("condJsonApply", sa, "Apply JSON", "accent") '</div>'
            return out '</div>'
        }
        if (flat.Clauses.Length = 0) {
            out .= '<span class="ad-sub">' (slot.K = "when" ? "always" : (slot.K = "req" ? "never (only the Required box above applies)" : "")) '</span>'
                . h.Btn("condAdd", sa, "+ Add condition", "", "", slot.K = "when" && m.CondChoices(slot).Length = 0) '</div>'
            return out '</div>'
        }
        if (flat.Clauses.Length > 1)
            out .= h.Sel("condMode", sa, [["all", "All of these"], ["any", "Any of these"]], flat.Mode)
        out .= '</div>'
        choices := m.CondChoices(slot)
        for i, cl in flat.Clauses {
            pairs := []
            known := false
            for s in choices {
                pairs.Push([s["id"], AdminModel.Label(s)])
                if (s["id"] == cl.Step)
                    known := true
            }
            if !known
                pairs.Push([cl.Step, cl.Step " (not allowed here)"])
            ca := sa.Clone()
            ca.Push(i)
            out .= '<div class="ad-row ad-cl">' h.Sel("condStep", ca, pairs, cl.Step) '<span>is one of</span>'
            st := m.Step(slot.Cat, cl.Step)
            on := Map()
            for v in cl.Ins
                on[v] := true
            if (st is Map && st.Has("options") && st["options"] is Array)
                for o in st["options"] {
                    oa := ca.Clone()
                    oa.Push(o["id"])
                    out .= h.Chk("condOpt", oa, on.Has(o["id"]), AdminModel.Label(o))
                }
            out .= h.Btn("condDel", ca, "&#x2715;", "ad-mv", "Remove this clause") '</div>'
        }
        out .= '<div class="ad-row">' h.Btn("condAdd", sa, "+ Add clause", "", "", choices.Length = 0)
        if (slot.K != "flag")
            out .= h.Btn("condClear", sa, "Remove condition")
        return out '</div></div>'
    }

    ; --- items categories ---
    ItemsEditor(cat) {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"]
        en := cat["entry"]
        out := this.ChipBar("items")
        for def in [["actions", "Actions", true, "What the agent did (Added, Removed...). The note text is built from this."],
                    ["items", "Items", false, "What it was done to."], ["outcomes", "Outcomes", true, "How it ended (optional unless required)."]] {
            key := def[1]
            list := (en.Has(key) && en[key] is Array) ? en[key] : []
            out .= '<div class="ad-sec">' def[2] '</div><div class="ad-sub">' def[4] '</div>'
            for i, o in list {
                oid := o["id"]
                out .= '<div class="ad-card"><div class="ad-row">'
                    . h.Moves("listUp", "listDown", [cid, key, oid], i > 1, i < list.Length)
                    . h.Txt("listLabel", [cid, key, oid], AdminPages.G(o, "label"), def[3] ? "ad-w-m" : "ad-grow")
                if def[3]
                    out .= h.Txt("listFrag", [cid, key, oid], AdminPages.G(o, "fragment"), "ad-grow", true, "Note text")
                out .= '<span class="ad-id">' e(oid) '</span>'
                    . h.Btn("listDel", [cid, key, oid], "Remove")
                    . '</div></div>'
            }
            out .= '<div class="ad-row">' h.Txt("listNewName", [cid, key], "", "ad-w-m", false, "New " StrLower(SubStr(def[2], 1, -1)) " name")
                . h.Btn("listAdd", [cid, key], "Add", "accent") '</div>'
        }
        out .= '<div class="ad-sec">Options of the form</div><div class="ad-row">'
            . h.Chk("entryFlag", [cid, "qty"], AdminPages.G(en, "qty", 0) = 1, "Quantity box (1-99)")
            . h.Chk("entryFlag", [cid, "details"], AdminPages.G(en, "details", 0) = 1, "Details box")
            . h.Chk("entryFlag", [cid, "outcomeRequired"], AdminPages.G(en, "outcomeRequired", 0) = 1, "An outcome is required")
            . '</div>'
        return out
    }

    ; --- the static category: wording only ---
    StaticEditor(cat) {
        h := this.H, e := (s) => Util.HtmlEscape(s)
        cid := cat["id"]
        st := AdminPages.G(cat, "static", Map())
        out := this.ChipBar("ping")
        out .= '<div class="ad-sub">The IP maths, the gateway rule and the ping itself are built into the app. You can change the wording here. The ids are fixed.</div>'
        out .= '<div class="ad-sec">Ping targets</div>'
        for o in AdminPages.G(st, "pingTargets", [])
            out .= '<div class="ad-row">' h.Txt("stLabel", [cid, "pingTargets", o["id"]], AdminPages.G(o, "label"), "ad-w-m") '<span class="ad-id">' e(o["id"]) '</span></div>'
        out .= '<div class="ad-sec">Ping results</div>'
        for o in AdminPages.G(st, "pingOutcomes", [])
            out .= '<div class="ad-card"><div class="ad-row">' h.Txt("stLabel", [cid, "pingOutcomes", o["id"]], AdminPages.G(o, "label"), "ad-w-m")
                . h.Txt("stFrag", [cid, o["id"]], AdminPages.G(o, "fragment"), "ad-grow", true, "Note text")
                . '<span class="ad-id">' e(o["id"]) '</span></div></div>'
        return out
    }

    ; ------------------------------------------------------------------------------------------------ note template
    Template() {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        t := m.Tpl
        lines := t["lines"]
        body := this.ChipBar("template")
        body .= '<div class="ad-sec">Lines of the note</div>'
        for i, l in lines
            body .= '<div class="ad-row">' h.Moves("tplUp", "tplDown", [i], i > 1, i < lines.Length)
                . h.Txt("tplLine", [i], l, "ad-grow", true)
                . h.Btn("tplDel", [i], "Remove", "", lines.Length <= 1 ? "The template needs at least one line" : "", lines.Length <= 1) '</div>'
        body .= '<div class="ad-row">' h.Btn("tplAdd", [], "Add line", "accent") '</div>'
        body .= '<div class="ad-sec">Wording</div>'
        body .= '<div class="ad-row"><span>Text for a value that is not available</span>' h.Txt("tplProp", ["unavailableText"], t["unavailableText"], "ad-w-m") '</div>'
        body .= this.JoinerRow("fragmentJoiner", "Between sentences of the same category", t["fragmentJoiner"])
        body .= this.JoinerRow("categoryJoiner", "Between categories", t["categoryJoiner"])
        body .= '<div class="ad-row">' h.Chk("tplCase", [], t["sentenceCase"] = 1, "Start every sentence with a capital letter")
            . '<span>End a sentence with</span>' h.Txt("tplProp", ["endPunctuation"], t["endPunctuation"], "ad-w-s") '</div>'
        return AdminPages.Wrap("Note template", "The lines the note is built from. {notes} is where the text of all the categories goes.", body)
    }

    JoinerRow(key, label, val) {
        h := this.H
        mode := (val == "`n") ? "nl" : ((val == " ") ? "sp" : "custom")
        out := '<div class="ad-row"><span>' AdminPages.E(label) '</span>'
            . h.Sel("tplJoin", [key], [["nl", "New line"], ["sp", "Space"], ["custom", "Custom text"]], mode)
        if (mode = "custom")
            out .= h.Txt("tplCustom", [key], val, "ad-w-m", false, "Text between")
        return out '</div>'
    }

    ; ------------------------------------------------------------------------------------------------ other settings
    Settings() {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        body := '<div class="ad-sec">Looks (theme presets)</div><div class="ad-sub">The look the apps start in. The default look is used until an agent picks another.</div>'
        sheets := []
        for s in Schema.SHEETS
            sheets.Push([s, AdminPages.SHEET_LABELS.Has(s) ? AdminPages.SHEET_LABELS[s] : s])
        def := m.Work["themes"]["default"]
        for p in m.Presets {
            pid := p["id"]
            acc := AdminPages.G(p, "accent")
            ok := RegExMatch(acc, "^#[0-9A-Fa-f]{6}$")
            body .= '<div class="ad-card"><div class="ad-row">'
                . h.Txt("presetLabel", [pid], AdminPages.G(p, "label"), "ad-w-m")
                . h.Sel("presetSheet", [pid], sheets, StrLower(AdminPages.G(p, "sheet")))
                . h.Sel("presetMode", [pid], [["light", "Light"], ["dark", "Dark"]], AdminPages.G(p, "mode"))
                . '<span class="ad-sw" id="adSw_' e(pid) '" style="background:' (ok ? acc : "#888888") '"></span>'
                . h.Txt("presetAccent", [pid], acc, "ad-w-s", false, "#0099D8")
                . '<span class="ad-id">' e(pid) '</span>'
                . (pid == def ? '<span class="ad-tag sys">default</span>' : h.Btn("presetDefault", [pid], "Make default"))
                . h.Btn("presetDel", [pid], "Remove", "", pid == def ? "This is the default look" : "", pid == def)
                . '</div><div class="ad-err" id="adErr_preset_' e(pid) '"></div></div>'
        }
        body .= '<div class="ad-row">' h.Txt("presetNewName", [], "", "ad-w-m", false, "New look name")
            . h.Sel("presetNewSheet", [], sheets, "spectrum") h.Sel("presetNewMode", [], [["light", "Light"], ["dark", "Dark"]], "light")
            . h.Txt("presetNewAccent", [], "#0099D8", "ad-w-s") h.Btn("presetAdd", [], "Add look", "accent") '</div>'
        body .= '<div class="ad-sec">Ping</div><div class="ad-sub">How the Static page pings. The limits are fixed in the app.</div>'
        for def2 in [["ping.timeoutMs", "Wait for a reply (ms)"], ["ping.attempts", "Attempts for Ping"], ["ping.intervalMs", "Pause between attempts (ms)"],
                     ["ping.untilSuccessMaxMin", "Stop Ping until success after (minutes)"]]
            body .= this.NumRow(def2[1], def2[2])
        body .= '<div class="ad-sec">Call tracking</div>'
        body .= this.NumRow("callTracking.newCallDebounceMs", "Ignore repeated new-call events within (ms)")
        body .= '<div class="ad-sec">History</div>'
        body .= this.NumRow("history.retentionDays", "Keep History for (days)")
        return AdminPages.Wrap("Settings", "Looks, ping timings, call tracking and how long History is kept.", body)
    }

    NumRow(path, label) {
        h := this.H
        b := AdminModel.BOUNDS[path]
        return '<div class="ad-row"><span>' AdminPages.E(label) '</span>' h.Txt("num", [path], this.M.GetNumber(path), "ad-w-s")
            . '<span class="ad-id">' b[1] ' to ' b[2] '</span><span class="ad-err" id="adErr_' StrReplace(path, ".", "_") '"></span></div>'
    }

    ; ------------------------------------------------------------------------------------------------ preview simulator
    Preview() {
        pv := this.PV, h := this.H, e := (s) => Util.HtmlEscape(s)
        body := '<div class="ad-row">' h.Btn("pvClearAll", [], "Clear all sample answers") '</div>'
        for c in pv.Categories() {
            id := c["id"]
            body .= '<div class="ad-sec">' e(AdminModel.Label(c)) ' <span class="ad-id">' e(id) '</span></div>'
            switch c["kind"] {
            case "steps": body .= this.PvSteps(c)
            case "items": body .= this.PvItems(c)
            case "static": body .= this.PvStatic(c)
            }
        }
        return AdminPages.Wrap("Preview", "Try the categories with a made-up call (Sample Tech, T00000, job 00000...). The note below updates as you click and as you edit. "
            . "This is the working copy, not what is saved.", body)
    }

    PvSteps(c) {
        pv := this.PV, h := this.H, e := (s) => Util.HtmlEscape(s), id := c["id"]
        r := pv.Analyse(id)
        if !IsObject(r)
            return ""
        a := r.A, ans := r.Answers
        out := ""
        for s in a.Visible {
            sid := s["id"]
            locked := !a.ActSet.Has(sid)
            entry := WorkflowEngine.Entry(ans, sid)
            chosen := WorkflowEngine.ChosenId(entry)
            out .= '<div class="ad-pv' (locked ? " lock" : "") '"><div><b>' e(r.Eng.Label(s)) '</b>'
                . (AdminPages.G(s, "required", 0) = 1 ? ' <span class="ad-tag sys">required</span>' : "") '</div><div class="ad-row">'
            if (WorkflowEngine.IsChoice(s) && s.Has("options") && s["options"] is Array)
                for o in s["options"]
                    out .= h.Btn("pvChoose", [id, sid, o["id"]], e(AdminModel.Label(o)), chosen == o["id"] ? "on" : "")
            out .= '</div>'
            for f in r.Eng.FieldsList(s) {
                star := r.Eng.FieldRequired(f, ans, a) ? " *" : ""
                out .= '<div class="ad-row"><span>' e(AdminPages.G(f, "label", f["id"])) star '</span>'
                    . h.Txt("pvType", [id, sid, f["id"]], WorkflowEngine.FieldValue(entry, f["id"]), "ad-w-l") '</div>'
            }
            out .= '</div>'
            if (a.Stop.Stopped && sid == a.Stop.StepId)
                out .= '<div class="ad-pvstop">' e(a.Stop.Message) '</div>'
        }
        for msg in r.Flags
            out .= '<div class="ad-pvflag">' e(msg) '</div>'
        if !r.Valid.Ok {
            miss := ""
            for mm in r.Valid.Missing
                miss .= (miss = "" ? "" : ", ") mm.label
            out .= '<div class="ad-sub">The agent would still be asked for: ' e(miss) '</div>'
        }
        return out '<div class="ad-row">' h.Btn("pvReset", [id], "Reset this category") '</div>'
    }

    PvItems(c) {
        pv := this.PV, h := this.H, e := (s) => Util.HtmlEscape(s), id := c["id"]
        m := pv.ItemsModel(id)
        out := ""
        list := pv.Session.EntriesFor(id)
        if (list.Length = 0)
            out .= '<div class="ad-sub">No sample entries yet.</div>'
        for i, en in list
            out .= '<div class="ad-li">' e(i ". " m.Describe(en)) '</div>'
        return out '<div class="ad-row">' h.Btn("pvEntry", [id], "Add a sample entry", "accent") h.Btn("pvClearEntries", [id], "Clear entries") '</div>'
    }

    PvStatic(c) {
        pv := this.PV, h := this.H, e := (s) => Util.HtmlEscape(s), id := c["id"]
        m := pv.StaticModel(id)
        st := pv.Session.StaticFor(id)
        tgt := this.W.PvTarget
        pairs := []
        for t in m.Targets
            pairs.Push([t["id"], AdminModel.Label(t)])
        out := '<div class="ad-sub">Sample address 10.0.0.1/30 (gateway 10.0.0.2). Pick the ping result the agent would confirm.</div><div class="ad-row">'
            . h.Sel("pvTarget", [id], pairs, tgt)
            . h.Btn("pvPing", [id, ""], "No result", st.pingOutcome == "" ? "on" : "")
        for o in m.Outcomes
            out .= h.Btn("pvPing", [id, o["id"]], e(AdminModel.Label(o)), (st.pingOutcome == o["id"] && st.pingConfirmed) ? "on" : "")
        return out '</div>'
    }

    ; ------------------------------------------------------------------------------------------------ check
    Check() {
        m := this.M, h := this.H, e := (s) => Util.HtmlEscape(s)
        v := m.Validate()
        this.W.CheckItems := v.Items
        body := '<div class="ad-row">' h.Btn("validate", [], "Check again", "accent")
            . '<span class="' (v.Ok ? "ad-ok" : "ad-err") '"><b>' v.Errors.Length ' error' (v.Errors.Length = 1 ? "" : "s") '</b>, ' v.Warnings.Length ' warning' (v.Warnings.Length = 1 ? "" : "s") '</span></div>'
        if (v.Items.Length = 0)
            body .= '<div class="ad-li">Everything is fine.</div>'
        for i, it in v.Items
            body .= '<div class="ad-li ' (it.Level = "error" ? "err" : "warn") '"><div class="ad-row"><span class="ad-tag ' (it.Level = "error" ? "off" : "cx") '">' it.Level '</span>'
                . '<span class="ad-grow">' e(it.Text) '</span>' h.Btn("go", [i], "Go to") '</div></div>'
        st := m.Status()
        body .= '<div class="ad-sec">The config file</div>'
        body .= '<div class="ad-li">Folder: ' e(st.Dir = "" ? "(none set)" : st.Dir) '<br>Loaded from: ' e(st.Source) ', revision ' st.Revision '</div>'
        for w in st.Warnings
            body .= '<div class="ad-li warn">' e(w) '</div>'
        if (m.Conflicts.Length > 0) {
            body .= '<div class="ad-li warn"><b>OneDrive found conflicting copies of the config. Check them before saving.</b><br>'
            for n in m.Conflicts
                body .= e(n) '<br>'
            body .= 'They are never deleted by this app.</div>'
        }
        return AdminPages.Wrap("Check", "Errors stop a save. Warnings are worth a look but don't block it.", body)
    }

    ; ------------------------------------------------------------------------------------------------ files
    Files() {
        h := this.H, e := (s) => Util.HtmlEscape(s)
        body := '<div class="ad-sec">Export</div><div class="ad-row">' h.Btn("export", [], "Export the working copy to a file...") '</div>'
            . '<div class="ad-sec">Import</div><div class="ad-row">' h.Btn("import", [], "Import a config file...") '</div>'
            . '<div class="ad-sub">The file is checked first. It replaces your working copy only after you confirm, and nothing is saved until you press Save.</div>'
            . '<div class="ad-sec">Restore defaults</div><div class="ad-row">' h.Btn("restoreDefaults", [], "Restore the built-in defaults...") '</div>'
            . '<div class="ad-sub">Replaces the working copy with the built-in configuration. The revision number stays so Save still works.</div>'
            . '<div class="ad-msg" id="adFilesMsg">' e(this.W.FilesMsg) '</div>'
        return AdminPages.Wrap("Files", "Export, import and restore the configuration.", body)
    }

    ; ------------------------------------------------------------------------------------------------ raw json
    Raw() {
        h := this.H, e := (s) => Util.HtmlEscape(s)
        body := '<div class="ad-row">' h.Btn("rawApply", [], "Apply", "accent") h.Btn("rawReset", [], "Reset the text") '</div>'
            . '<div class="ad-msg" id="adRawMsg">' e(this.W.RawMsg) '</div>'
            . h.Txt("rawText", [], this.M.RawText(), "", false, "", true, 24)
        return AdminPages.Wrap("Raw JSON (advanced)", "The whole working configuration. Apply works only when the text parses and validates; it never saves by itself.", body, "ad-raw")
    }
}
