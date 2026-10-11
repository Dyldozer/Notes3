#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; AdminUi.ahk - small UI helpers of the Admin companion. No AxGui include (the entry script includes the library);
; AdminHtml only builds markup, so the model and page builders can be exercised without a window.
;
; Every control the pages draw is REGISTERED: its element id maps to {K: kind, A: action, P: [args]}. One page-wide handler
; per event type (click / change / keyup, see AdminWindow) looks the clicked element up in that registry and runs the action,
; so the pages can be thrown away and redrawn from the model at any time without re-wiring anything.

class AdminHtml {
    __New() {
        this.Reg := Map()                 ; element id -> {K, A, P, Ph}
        this.PageIds := Map()             ; page -> [ids it drew]
        this.Page := ""
    }

    ; Forget the ids of a page that is about to be drawn again.
    Begin(page) {
        if this.PageIds.Has(page)
            for id in this.PageIds[page]
                if this.Reg.Has(id)
                    this.Reg.Delete(id)
        this.PageIds[page] := []
        this.Page := page
    }

    static E(s) => Util.HtmlEscape(s)

    ; "ad_<action>_<arg>_<arg>" - readable and, because ids of the config never repeat, unique.
    BaseId(act, args) {
        base := "ad_" act
        for a in args
            base .= "_" RegExReplace(String(a), "[^A-Za-z0-9_-]", "-")
        return base
    }

    IdFor(act, args) {
        base := this.BaseId(act, args)
        id := base, n := 1
        while this.Reg.Has(id) {
            n += 1
            id := base "~" n
        }
        return id
    }

    Add(kind, act, args, ph := false) {
        id := this.IdFor(act, args)
        this.Reg[id] := {K: kind, A: act, P: args, Ph: ph}
        if this.PageIds.Has(this.Page)
            this.PageIds[this.Page].Push(id)
        return id
    }

    ; --- controls --------------------------------------------------------------------------------------------------
    ; label is HTML (escape text with AdminHtml.E first; arrows are entities).
    Btn(act, args, label, cls := "", tip := "", disabled := false) {
        id := this.Add("btn", act, args)
        t := tip != "" ? ' data-tip="' AdminHtml.E(tip) '"' : ""
        return '<span class="btn ' cls (disabled ? " ad-dis" : "") '" id="' id '"' t '>' label '</span>'
    }

    ; A text box. ph: placeholder chips may be inserted into it. cls sizes it (ad-w-s / ad-w-m / ad-w-l / ad-grow).
    Txt(act, args, value, cls := "", ph := false, hint := "", multi := false, rows := 3) {
        id := this.Add("txt", act, args, ph)
        if multi
            return '<div class="ad-in ' cls '"><ax-textarea id="' id '" rows="' rows '">' AdminHtml.E(value) '</ax-textarea></div>'
        return '<div class="ad-in ' cls '"><ax-text id="' id '" value="' AdminHtml.E(value) '" placeholder="' AdminHtml.E(hint) '"></ax-text></div>'
    }

    Chk(act, args, checked, label, disabled := false, tip := "") {
        id := this.Add("chk", act, args)
        t := tip != "" ? ' data-tip="' AdminHtml.E(tip) '"' : ""
        return '<label class="ad-chk"' t '><input type="checkbox" id="' id '"' (checked ? " checked" : "") (disabled ? " disabled" : "") '> '
            . AdminHtml.E(label) '</label>'
    }

    ; pairs: [[value, label], ...]
    Sel(act, args, pairs, value, cls := "") {
        id := this.Add("sel", act, args)
        h := '<select class="ad-sel ' cls '" id="' id '">'
        for p in pairs
            h .= '<option value="' AdminHtml.E(p[1]) '"' (p[1] == value ? " selected" : "") '>' AdminHtml.E(p[2]) '</option>'
        return h '</select>'
    }

    ; A placeholder chip: clicking inserts its text at the cursor of the text box that was last used. The chip must not
    ; take the focus (onmousedown), or the caret would be lost.
    Chip(text, hint := "") {
        id := this.Add("chip", "chip", [text])
        return '<span class="ad-chip" id="' id '" onmousedown="return false;" unselectable="on" data-tip="' AdminHtml.E(hint) '">'
            . AdminHtml.E(text) '</span>'
    }

    ; "&#x2191;" / "&#x2193;" move buttons
    Moves(actUp, actDown, args, upOk := true, downOk := true) {
        return this.Btn(actUp, args, "&#x2191;", "ad-mv", "Move up", !upOk) . this.Btn(actDown, args, "&#x2193;", "ad-mv", "Move down", !downOk)
    }

    ; The array form of a condition slot and back (slots are objects; element ids carry strings).
    static SlotArgs(slot) {
        a := [slot.K, slot.Cat, slot.HasOwnProp("Step") ? slot.Step : ""]
        a.Push(slot.K = "req" ? slot.Field : (slot.K = "flag" ? slot.Flag : ""))
        return a
    }

    static SlotOf(a) {
        s := {K: a[1], Cat: a[2], Step: a[3]}
        if (a[1] = "req")
            s.Field := a[4]
        if (a[1] = "flag")
            s.Flag := a[4]
        return s
    }

    ; Put markup that uses the library's <ax-*> tags into a mount point. The tags are expanded as TEXT first
    ; (AxTags.ExpandHtml) and written in one go: replacing elements one by one in the live page intermittently threw
    ; 0x80020101 when a page was rebuilt from an event. (The same helper as MainWindow.SetTagHtml; Admin does not include
    ; MainWindow.) The live walk is the fallback ExpandHtml asks for ("").
    static SetTagHtml(el, html) {
        x := AxTags.ExpandHtml(html, true)
        if (x != "") {
            el.innerHTML := x
            return
        }
        el.innerHTML := html
        AxTags.ExpandIn(el)
    }

    ; --- the CSS of the Admin pages ----------------------------------------------------------------------------------
    ; pal: Theme.Resolve(...).Pal. Sizes are rem so the window's text size scales them; IE11: no variables, no grid, no gap.
    static Css(p) {
        css := "
        (
        .ad-head { padding: 8px 14px 6px 14px; color: {{Text}}; }
        .ad-bar { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; -ms-flex-wrap: wrap; flex-wrap: wrap; }
        .ad-bar .btn { margin-right: 8px; }
        .ad-dirty { font-weight: 700; margin-right: 12px; color: {{Amber2}}; }
        .ad-sum { cursor: pointer; margin-right: 12px; }
        .ad-sum.bad { color: {{Red}}; font-weight: 600; }
        .ad-status { margin-top: 4px; font-size: .857rem; color: {{Muted}}; }
        .ad-banner { display: none; margin-top: 6px; padding: 6px 12px; background: {{AmberStrong}}; border-left: 4px solid {{Amber}}; color: {{Text}}; }
        .ad-banner b { font-weight: 700; }
        .ad-notice { display: none; margin-top: 6px; padding: 4px 12px; background: {{AmberPage}}; border-left: 4px solid {{Amber}}; color: {{Text}}; font-size: .857rem; }
        .ad-foot { padding: 6px 14px 10px 14px; border-top: 1px solid rgba(128,128,128,.35); color: {{Text}}; }
        .ad-foot-hd { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; -ms-flex-wrap: wrap; flex-wrap: wrap; margin-bottom: 4px; }
        .ad-foot-hd b { margin-right: 12px; }
        .ad-foot .textbox textarea { width: 100%; height: 84px; min-height: 84px; box-sizing: border-box; resize: none; }
        .ad-foot-warn { margin-top: 3px; font-size: .857rem; color: {{Muted}}; }
        .ad-pg { padding: 10px 16px 28px 16px; color: {{Text}}; }
        .ad-h { font-size: 1.286rem; font-weight: 600; margin: 0 0 2px 0; }
        .ad-sub { color: {{Muted}}; margin: 0 0 10px 0; font-size: .929rem; }
        .ad-sec { margin: 16px 0 6px 0; padding-top: 8px; border-top: 1px solid rgba(128,128,128,.35); font-weight: 600; font-size: 1.071rem; }
        .ad-card { border: 1px solid rgba(128,128,128,.35); background: {{Card}}; border-radius: 6px; padding: 6px 10px; margin: 6px 0; }
        .ad-card.sel { border-color: {{Accent}}; background: {{AccentTint}}; }
        .ad-row { display: -ms-flexbox; display: flex; -ms-flex-align: center; align-items: center; -ms-flex-wrap: wrap; flex-wrap: wrap; margin: 2px 0; }
        .ad-row > * { margin-right: 8px; margin-top: 2px; margin-bottom: 2px; }
        .ad-grow { -ms-flex: 1 1 220px; flex: 1 1 220px; min-width: 120px; }
        .ad-w-s { width: 78px; } .ad-w-m { width: 190px; } .ad-w-l { width: 330px; }
        .ad-in { display: block; }
        .ad-sel { max-width: 260px; }
        .ad-id { color: {{Muted}}; font-size: .8rem; font-family: Consolas, monospace; }
        .ad-tag { display: inline-block; font-size: .714rem; font-weight: 700; text-transform: uppercase; letter-spacing: .3px; padding: 0 5px; border-radius: 3px;
            background: {{Tag_empty}}; color: {{TagFg_empty}}; }
        .ad-tag.sys { background: {{Tag_manual}}; color: {{TagFg_manual}}; }
        .ad-tag.off { background: {{Tag_unavailable}}; color: {{TagFg_unavailable}}; }
        .ad-tag.cx { background: {{Tag_stale}}; color: {{TagFg_stale}}; }
        .ad-err { color: {{Red}}; }
        .ad-ok { color: {{Green2}}; }
        .ad-bad .textbox { border-color: {{Red}}; }
        .ad-chips { margin: 6px 0 8px 0; padding: 6px 8px; border: 1px solid rgba(128,128,128,.35); border-radius: 6px; background: {{Well}}; }
        .ad-chips .lbl { color: {{Muted}}; font-size: .857rem; margin-right: 8px; }
        .ad-chip { display: inline-block; padding: 0 7px; margin: 2px 4px 2px 0; border: 1px solid rgba(128,128,128,.45); border-radius: 10px;
            background: {{Card}}; cursor: pointer; font-family: Consolas, monospace; font-size: .857rem; color: {{Text}}; }
        .ad-chip:hover { border-color: {{Accent}}; }
        .ad-cond { margin: 4px 0; padding: 5px 8px; border-left: 3px solid {{Accent}}; background: {{Well}}; }
        .ad-cl { margin: 3px 0 3px 12px; }
        .ad-cl .ad-chk { margin-right: 12px; }
        .ad-json { font-family: Consolas, monospace; font-size: .857rem; margin: 4px 0; white-space: pre-wrap; color: {{Text}}; }
        .ad-stop { margin: 4px 0 4px 18px; padding: 5px 8px; border-left: 3px solid {{Amber}}; background: {{AmberPage}}; }
        .ad-chk { display: inline-block; margin-right: 12px; white-space: nowrap; }
        .btn.ad-dis { opacity: .45; }
        .btn.ad-mv { min-width: 28px; padding-left: 6px; padding-right: 6px; }
        .btn.on { background: {{Fill}} !important; color: {{OnFill}} !important; border-color: {{Fill}} !important; }
        .ad-glyph { font-family: 'Segoe Fluent Icons', 'Segoe MDL2 Assets'; font-size: 1.286rem; display: inline-block; width: 26px; text-align: center; }
        .ad-sw { display: inline-block; width: 18px; height: 18px; border: 1px solid rgba(128,128,128,.6); vertical-align: middle; }
        .ad-pv { margin: 8px 0; }
        .ad-pv .lock { opacity: .45; }
        .ad-pvstop { margin: 6px 0; padding: 8px 12px; border: 2px solid {{Amber}}; background: {{AmberStrong}}; font-weight: 700; }
        .ad-pvflag { margin: 4px 0; padding: 4px 8px; border-left: 3px solid {{Amber}}; background: {{AmberPage}}; font-size: .929rem; }
        .ad-li { padding: 5px 8px; margin: 3px 0; border: 1px solid rgba(128,128,128,.35); border-radius: 4px; background: {{Card}}; }
        .ad-li.err { border-left: 4px solid {{Red}}; }
        .ad-li.warn { border-left: 4px solid {{Amber}}; }
        .ad-raw .textbox textarea { width: 100%; height: 420px; box-sizing: border-box; font-family: Consolas, monospace; font-size: .857rem; }
        .ad-msg { margin: 6px 0; min-height: 1.2rem; }
        )"
        t := Map()
        for k in ["Text", "Muted", "Red", "Amber", "AmberPage", "AmberStrong", "Card", "Well", "Accent", "AccentTint", "Fill", "OnFill", "Green"]
            t[k] := p.%k%
        t["Amber2"] := p.Mode = "dark" ? "#F7A600" : "#8A5300"
        t["Green2"] := p.Mode = "dark" ? "#4CC36B" : "#1E7A38"
        tg := p.Tag
        for k in ["empty", "manual", "unavailable", "stale"] {
            t["Tag_" k] := tg[k].Bg
            t["TagFg_" k] := tg[k].Fg
        }
        for k, v in t
            css := StrReplace(css, "{{" k "}}", v)
        return css
    }
}
