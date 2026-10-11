#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; Items.ahk - the model of one "items" category (Equipment, Billing, later admin-made ones; PLAN 5.3).
; Pure logic: no GUI, no files, no clock.
;
;   m := ItemsModel(categoryMap)                     ; a category Map from the config (kind "items")
;   e := {action: "swapped", item: "item1", qty: "2", outcome: "", details: ""}   ; an entry (strings; Map form works too)
;   m.Validate(e)             -> {Ok, Missing: [{field, label, reason}]}       field: action|item|outcome|qty,
;                                reason: "missing" | "unknown" | "invalid"
;   m.Clean(e)                -> plain entry {action, item, qty, outcome, details}: trimmed, qty canonical ("02" -> "2"),
;                                qty / details emptied when the category does not use them
;   m.Fragments(entries)      -> {Fragments: [text...], Values: Map, Warnings: [text...]} in entry order
;   m.Preview(e)              -> the note sentence of one entry as the composer would print it ("" when not renderable)
;   m.FindDuplicate(list, e, skipIndex := 0) -> index of an entry that would print identically, else 0
;
; Rules
;   - An entry's text is the chosen action's `fragment`, then (when an outcome is chosen) the outcome's `fragment`,
;     separated by a space. The five placeholders {action} {item} {qty} {details} {outcome} are replaced by the
;     entry's own values in ONE pass (an inserted value is never scanned again). Context placeholders such as
;     {tech.firstName} are left for the Composer, which also normalises spacing, so an empty {qty} leaves no gap.
;   - What the agent typed is inserted literally. The Composer scans every fragment again, so a value that
;     contains "{" is not put into the fragment: the fragment gets a private placeholder ({itemsDetails3}) and the
;     text goes into Values, which the Composer inserts without expanding. Values with no "{" are inserted directly.
;   - No value is ever invented: an empty qty / details adds nothing. The note says whatever the configured
;     fragments say, and the outcome text comes only from the outcome the agent chose.
;   - Stored entries whose ids the config no longer has (action, item, outcome) are skipped with a warning; nothing
;     here throws. Warnings hold ids and positions only, never typed text.
;   - Two entries that would print the same sentence are one sentence in the note (the Composer drops exact
;     duplicates), so the UI refuses to add the second one: see FindDuplicate / DupMessage.

class ItemsModel {
    static QTY_MIN := 1
    static QTY_MAX := 99

    static DupMessage() => "That entry is already in the list " Chr(0x2014) " change the quantity instead"

    __New(category) {
        this.Category := category
        this.Actions := [], this.Items := [], this.Outcomes := []
        this.ActionById := Map(), this.ItemById := Map(), this.OutcomeById := Map()
        this.Qty := false, this.Details := false, this.OutcomeRequired := false
        this.SentenceCase := true          ; the Composer's note-template switches (App.ModelFor copies them from the config)
        this.EndPunct := "."
        e := (category is Map && category.Has("entry") && category["entry"] is Map) ? category["entry"] : Map()
        ItemsModel._Load(e, "actions", this.Actions, this.ActionById)
        ItemsModel._Load(e, "items", this.Items, this.ItemById)
        ItemsModel._Load(e, "outcomes", this.Outcomes, this.OutcomeById)
        this.Qty := ItemsModel.Truthy(e.Has("qty") ? e["qty"] : 0)
        this.Details := ItemsModel.Truthy(e.Has("details") ? e["details"] : 0)
        this.OutcomeRequired := ItemsModel.Truthy(e.Has("outcomeRequired") ? e["outcomeRequired"] : 0)
    }

    static _Load(e, key, list, byId) {
        if (e.Has(key) && e[key] is Array)
            for o in e[key]
                if (o is Map && o.Has("id") && o["id"] is String && !byId.Has(o["id"])) {
                    list.Push(o)
                    byId[o["id"]] := o
                }
    }

    static Truthy(v) => !IsObject(v) && (v = 1 || v = "1" || v = "true")

    ; The label of an option Map (its id when it has none).
    static Label(o) => (o is Map && o.Has("label")) ? String(o["label"]) : (o is Map && o.Has("id") ? String(o["id"]) : "")

    ; --- entries -----------------------------------------------------------------------------------------------
    static _Field(e, k) {
        if !IsObject(e)
            return ""
        try {
            if (e is Map)
                return e.Has(k) ? String(e[k]) : ""
            return e.HasProp(k) ? String(e.%k%) : ""
        }
        return ""
    }

    ; A plain object with the five keys, as strings. Ids and qty are trimmed; a qty that is a whole number with up to
    ; three digits is written canonically (no leading zeros). Details keep what was typed (trimmed at the ends).
    static Norm(e) {
        qty := Util.Trim(ItemsModel._Field(e, "qty"))
        if RegExMatch(qty, "^[0-9]{1,3}$")
            qty := String(Integer(qty))
        return {action: Util.Trim(ItemsModel._Field(e, "action")), item: Util.Trim(ItemsModel._Field(e, "item")),
            qty: qty, outcome: Util.Trim(ItemsModel._Field(e, "outcome")), details: Util.Trim(ItemsModel._Field(e, "details"))}
    }

    Clean(e) {
        n := ItemsModel.Norm(e)
        if !this.Qty
            n.qty := ""
        if !this.Details
            n.details := ""
        return n
    }

    ; Plain Map form of an entry (for snapshots).
    static ToMap(e) {
        n := ItemsModel.Norm(e)
        return Map("action", n.action, "item", n.item, "qty", n.qty, "outcome", n.outcome, "details", n.details)
    }

    ; --- validation --------------------------------------------------------------------------------------------
    Validate(entry) {
        e := this.Clean(entry)
        miss := []
        if (e.action = "")
            miss.Push({field: "action", label: "Action", reason: "missing"})
        else if !this.ActionById.Has(e.action)
            miss.Push({field: "action", label: "Action", reason: "unknown"})
        if (e.item = "")
            miss.Push({field: "item", label: "Item", reason: "missing"})
        else if !this.ItemById.Has(e.item)
            miss.Push({field: "item", label: "Item", reason: "unknown"})
        if (e.outcome = "") {
            if this.OutcomeRequired
                miss.Push({field: "outcome", label: "Outcome", reason: "missing"})
        } else if !this.OutcomeById.Has(e.outcome)
            miss.Push({field: "outcome", label: "Outcome", reason: "unknown"})
        if (e.qty != "" && !ItemsModel.QtyOk(e.qty))
            miss.Push({field: "qty", label: "Quantity (" ItemsModel.QTY_MIN "-" ItemsModel.QTY_MAX ")", reason: "invalid"})
        return {Ok: miss.Length = 0, Missing: miss}
    }

    ; A whole number from 1 to 99 (digits only: no sign, no decimals, no spaces).
    static QtyOk(q) {
        q := String(q)
        return RegExMatch(q, "^[0-9]{1,3}$") && Integer(q) >= ItemsModel.QTY_MIN && Integer(q) <= ItemsModel.QTY_MAX
    }

    ; "Action, Item" for a Validate result.
    static MissingText(v) {
        s := ""
        for m in v.Missing
            s .= (s = "" ? "" : ", ") m.label
        return s
    }

    ; --- rendering ---------------------------------------------------------------------------------------------
    ; The template text of an entry: action fragment, then the outcome fragment. "" when the action is unknown.
    _Template(e) {
        if !this.ActionById.Has(e.action)
            return ""
        a := this.ActionById[e.action]
        tpl := a.Has("fragment") ? String(a["fragment"]) : ""
        if (e.outcome != "" && this.OutcomeById.Has(e.outcome)) {
            o := this.OutcomeById[e.outcome]
            f := o.Has("fragment") ? String(o["fragment"]) : ""
            if (f != "")
                tpl .= (tpl = "" ? "" : " ") f
        }
        return tpl
    }

    ; The five values of a cleaned entry (labels for ids; "" for what is not set or not known).
    _Values(e) {
        v := Map()
        v["action"] := this.ActionById.Has(e.action) ? ItemsModel.Label(this.ActionById[e.action]) : ""
        v["item"] := this.ItemById.Has(e.item) ? ItemsModel.Label(this.ItemById[e.item]) : ""
        v["qty"] := ItemsModel.QtyOk(e.qty) ? e.qty : ""
        v["details"] := e.details
        v["outcome"] := (e.outcome != "" && this.OutcomeById.Has(e.outcome)) ? ItemsModel.Label(this.OutcomeById[e.outcome]) : ""
        return v
    }

    ; One pass over the template. holder: Map to receive private placeholders for values that contain "{" (with
    ; index idx in their names), or "" to insert every value as it is (previews and comparisons).
    _Fill(tpl, vals, idx, holder) {
        out := "", pos := 1
        while RegExMatch(tpl, "\{(action|item|qty|details|outcome)\}", &m, pos) {
            out .= SubStr(tpl, pos, m.Pos - pos)
            txt := vals[m[1]]
            if (IsObject(holder) && InStr(txt, "{")) {
                key := "items" StrUpper(SubStr(m[1], 1, 1)) SubStr(m[1], 2) idx
                holder[key] := txt
                out .= "{" key "}"
            } else
                out .= txt
            pos := m.Pos + m.Len
        }
        return out SubStr(tpl, pos)
    }

    ; Fragments for a list of entries, in order: {Fragments, Values, Warnings}.
    Fragments(entries) {
        frags := [], values := Map(), warns := []
        if (entries is Array)
            for i, raw in entries {
                e := this.Clean(raw)
                v := this.Validate(e)
                skip := false
                for m in v.Missing {
                    if (m.reason = "unknown") {
                        warns.Push("Entry " i " skipped: unknown " StrLower(m.field) ' "' e.%m.field% '".')
                        skip := true
                    } else if (m.field = "action" || m.field = "item") {
                        warns.Push("Entry " i " skipped: no " StrLower(m.field) ".")
                        skip := true
                    } else if (m.field = "outcome")
                        warns.Push("Entry " i " has no outcome.")
                    else if (m.field = "qty")
                        warns.Push("Entry " i ": the quantity is not a whole number from 1 to 99 and was left out.")
                }
                if skip
                    continue
                tpl := this._Template(e)
                if (Util.Trim(tpl) = "")
                    continue
                frags.Push(this._Fill(tpl, this._Values(e), i, values))
            }
        return {Fragments: frags, Values: values, Warnings: warns}
    }

    ; The sentence this entry adds to the note, written the way the Composer writes it ("" when it cannot be rendered:
    ; missing or unknown action / item / outcome, or a bad qty).
    Preview(entry) {
        e := this.Clean(entry)
        if !this.Validate(e).Ok
            return ""
        return this._Style(this._Fill(this._Template(e), this._Values(e), 0, ""))
    }

    ; Like Preview, but for a STORED entry: as long as its action and item still exist it is described (an outcome the
    ; config no longer has, or a bad qty, is left out - exactly what Fragments() prints).
    Describe(entry) {
        e := this.Clean(entry)
        if !this.ActionById.Has(e.action) || !this.ItemById.Has(e.item) || (e.outcome != "" && !this.OutcomeById.Has(e.outcome))
            return ""
        return this._Style(this._Fill(this._Template(e), this._Values(e), 0, ""))
    }

    ; Composer's own steps for one fragment: collapse whitespace, capital first letter, end punctuation.
    _Style(txt) {
        txt := Util.Squeeze(txt)
        if (txt = "")
            return ""
        if this.SentenceCase
            txt := StrUpper(SubStr(txt, 1, 1)) SubStr(txt, 2)
        if (this.EndPunct != "" && !RegExMatch(txt, "[.!?]$"))
            txt .= this.EndPunct
        return txt
    }

    ; --- duplicates ----------------------------------------------------------------------------------------------
    ; What the Composer compares: the printed sentence, lower case.
    _Key(raw) {
        e := this.Clean(raw)
        p := this.Preview(e)
        if (p != "")
            return StrLower(p)
        return "|" StrLower(e.action "|" e.item "|" e.qty "|" e.outcome "|" Util.Squeeze(e.details))
    }

    ; Index of the first entry in `list` (other than skipIndex) that prints the same sentence as `entry`, else 0.
    FindDuplicate(list, entry, skipIndex := 0) {
        key := this._Key(entry)
        if (list is Array)
            for i, x in list
                if (i != skipIndex && this._Key(x) == key)
                    return i
        return 0
    }
}
