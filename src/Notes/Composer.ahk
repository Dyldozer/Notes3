#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; Composer.ahk - builds the note text (PLAN 5.4). Pure logic: no GUI, no clock, no files.
;
;   res := Composer.Compose(ctx, session, config)     ; config = the config Map (ConfigStore.Config)
;   res.Text       the note, lines joined with CRLF
;   res.Warnings   Array of short texts (placeholder names and category ids only, never call content)
;
; Rules
;   - Categories in CONFIG order that the session used and that have fragments. Used but disabled categories
;     are still included (the agent used them) with a warning. Used ids the config does not know are skipped
;     with a warning.
;   - Fragment: fill placeholders, collapse whitespace, capitalise the first character (sentenceCase), add
;     endPunctuation unless it already ends in . ! or ?, drop exact duplicates (case-insensitive, after
;     normalising), join with fragmentJoiner, put the category's notePrefix in front.
;   - Categories are joined with categoryJoiner; that text is {notes} in the template.
;   - Placeholders: {tech.firstName} {tech.name} {tech.id} {job.number} {job.workOrder} {address} {notes}
;     (template only) and {<valueName>} from the category's session Values (fragments only). unavailable ->
;     noteTemplate.unavailableText; empty -> ""; any other status -> the value, surrounding whitespace trimmed.
;     Unknown placeholders stay as typed and add a warning. Substitution is one pass over the template text:
;     an inserted value is never expanded again.
;   - Template lines are rendered with the same placeholder rules, trailing spaces/tabs trimmed (so an empty
;     {notes} gives "Notes:"), and joined with CRLF.

class Composer {
    static PLACEHOLDER_RE := "\{([A-Za-z][A-Za-z0-9_.]*)\}"

    static Compose(ctx, session, config) {
        warns := []
        tpl := Composer._Section(config, "noteTemplate")
        unavailable := Composer._Get(tpl, "unavailableText", "[not available]")
        fragJoin := Composer._Get(tpl, "fragmentJoiner", " ")
        catJoin := Composer._Get(tpl, "categoryJoiner", "`n")
        sentence := Composer._Get(tpl, "sentenceCase", 1) ? true : false
        endPunct := Composer._Get(tpl, "endPunctuation", ".")
        lines := Composer._Get(tpl, "lines", ["Notes: {notes}"])

        used := Map()
        for id in session.UsedCategories()
            used[id] := true
        known := Map()
        parts := []
        cats := (config is Map && config.Has("categories") && config["categories"] is Array) ? config["categories"] : []
        for c in cats {
            if !(c is Map) || !c.Has("id")
                continue
            id := c["id"]
            known[id] := true
            if !used.Has(id)
                continue
            frags := session.Fragments(id)
            if (frags.Length = 0)
                continue
            if (c.Has("enabled") && !c["enabled"])
                warns.Push('Category "' id '" is disabled in the config but was used; included.')
            scope := {ctx: ctx, values: session.ValuesFor(id), unavailable: unavailable, notes: "", allowNotes: false,
                where: 'category "' id '"', warns: warns}
            out := [], seen := Map()
            for f in frags {
                txt := Composer._Normalise(Composer._Fill(f, scope))
                if (txt = "")
                    continue
                if sentence
                    txt := StrUpper(SubStr(txt, 1, 1)) SubStr(txt, 2)
                if (endPunct != "" && !RegExMatch(txt, "[.!?]$"))
                    txt .= endPunct
                key := StrLower(txt)
                if seen.Has(key)
                    continue
                seen[key] := true
                out.Push(txt)
            }
            if (out.Length = 0)
                continue
            text := ""
            for i, x in out
                text .= (i = 1 ? "" : fragJoin) x
            prefix := c.Has("notePrefix") && c["notePrefix"] is String ? c["notePrefix"] : ""
            parts.Push(prefix text)
        }
        for id in session.UsedCategories()
            if !known.Has(id)
                warns.Push('Used category "' id '" is not in the config; skipped.')

        notes := ""
        for i, x in parts
            notes .= (i = 1 ? "" : catJoin) x
        scope := {ctx: ctx, values: Map(), unavailable: unavailable, notes: notes, allowNotes: true,
            where: "template", warns: warns}
        rendered := []
        for l in lines
            rendered.Push(RTrim(Composer._Fill(String(l), scope), " `t"))
        text := ""
        for i, x in rendered
            text .= (i = 1 ? "" : "`r`n") x
        uniq := [], seenW := Map()
        for w in warns
            if !seenW.Has(w)
                seenW[w] := true, uniq.Push(w)
        return {Text: Composer.Crlf(text), Warnings: uniq}
    }

    ; Every line break becomes CRLF.
    static Crlf(s) => StrReplace(StrReplace(StrReplace(String(s), "`r`n", "`n"), "`r", "`n"), "`n", "`r`n")

    ; Collapse whitespace runs to one space and trim.
    static _Normalise(s) => Util.Squeeze(s)

    ; One pass over the template: literal text is copied, each {name} replaced by its value; values are
    ; never scanned again.
    static _Fill(tpl, scope) {
        out := "", pos := 1
        while RegExMatch(tpl, Composer.PLACEHOLDER_RE, &m, pos) {
            out .= SubStr(tpl, pos, m.Pos - pos)
            r := Composer._Resolve(m[1], scope)
            if r.Known
                out .= r.Text
            else {
                out .= m[0]
                scope.warns.Push("Unknown placeholder {" m[1] "} in " scope.where ".")
            }
            pos := m.Pos + m.Len
        }
        return out SubStr(tpl, pos)
    }

    static _Resolve(name, scope) {
        static FIELDS := Map("tech.name", "techName", "tech.id", "techId", "job.number", "jobNumber",
            "job.workOrder", "workOrder", "address", "address")
        if (name = "tech.firstName")
            return Composer._Field(scope, "techName", true)
        if FIELDS.Has(name)
            return Composer._Field(scope, FIELDS[name], false)
        if (name = "notes" && scope.allowNotes)
            return {Known: true, Text: scope.notes}
        if (scope.values is Map && scope.values.Has(name))
            return {Known: true, Text: Util.Trim(scope.values[name])}
        return {Known: false, Text: ""}
    }

    static _Field(scope, id, firstOnly) {
        f := scope.ctx.Get(id)
        if !IsObject(f)
            return {Known: true, Text: ""}
        if (f.Status = "unavailable")
            return {Known: true, Text: scope.unavailable}
        if (f.Status = "empty")
            return {Known: true, Text: ""}
        v := Util.Trim(f.Value)
        return {Known: true, Text: firstOnly ? Composer.FirstName(v) : v}
    }

    static _Section(config, key) => (config is Map && config.Has(key) && config[key] is Map) ? config[key] : Map()

    static _Get(m, key, default) => m.Has(key) ? m[key] : default

    ; --- first name (PLAN 3.2) ---------------------------------------------------------
    ; Trim, take the first whitespace-separated word. If that word is all caps or all lowercase (ignoring
    ; characters that are not letters), title-case it, handling hyphens, apostrophes and dots inside the word
    ; (MARY-JANE -> Mary-Jane, o'neil -> O'Neil, J.R. -> J.R.); mixed case (McKenzie, DeShawn) is kept as given.
    static FirstName(fullName) {
        s := Util.Trim(fullName)
        if (s = "")
            return ""
        word := StrSplit(RegExReplace(s, "[\s" Chr(0xA0) "]+", " "), " ")[1]
        letters := RegExReplace(word, "[^\p{L}]", "")
        if (letters = "" || (!(letters == StrUpper(letters)) && !(letters == StrLower(letters))))
            return word
        out := "", cap := true
        loop parse word {
            ch := A_LoopField
            if cap
                out .= StrUpper(ch)
            else
                out .= StrLower(ch)
            cap := (ch = "-" || ch = "'" || ch = "." || ch = Chr(0x2019))
        }
        return out
    }
}
