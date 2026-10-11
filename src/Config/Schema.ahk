#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\Defaults.ahk
; Schema.ahk - config schema version, validator and migrations (shared by the main app and Admin).
; Pure logic: no GUI. Paths in messages are 1-based, e.g. categories[2].steps[1].options.

class Schema {
    static CURRENT := 1
    static SYSTEM_CATS := [["notDone", "steps"], ["equipment", "items"], ["billing", "items"],
        ["static", "static"], ["closeJob", "steps"]]
    static REQUIRED_CONTEXT := ["techName", "techId", "address", "jobNumber", "workOrder"]
    static TOP_KEYS := ["schemaVersion", "revision", "updatedAt", "updatedBy", "noteTemplate", "contextFields",
        "categories", "themes", "ping", "callTracking", "history"]
    static ID_RE := "^[A-Za-z][A-Za-z0-9_-]*$"
    ; looks a theme preset may name: "spectrum" (win365 + the generated Spectrum colours) and the library's own sheets.
    ; Theme.LIB_SHEETS must list the same library names (TestTheme checks it).
    static SHEETS := ["spectrum", "win11", "win98", "winxp", "win365", "cyber", "rpg", "cozy", "aurora", "instrument",
        "precision", "inset", "brutalist", "macos", "riso", "blueprint", "aero", "deco", "crt"]
    static STEP_TYPES := ["choice", "yesno", "text", "group"]
    static KINDS := ["steps", "items", "static"]
    static NOTE_PREFIX_MAX := 40
    static ENTRY_KEYS := ["actions", "items", "outcomes", "outcomeRequired", "qty", "details"]
    static ENTRY_PLACEHOLDERS := ["action", "item", "qty", "details", "outcome", "tech.firstName", "tech.name", "tech.id",
        "job.number", "job.workOrder", "address"]
    static STATIC_KEYS := ["pingTargets", "pingOutcomes"]
    ; Keys that older configs had (removed features): ignored without even a warning.
    static STATIC_LEGACY_KEYS := ["fragments"]
    static STATIC_PING_PH := ["pingTarget", "pingAddress", "tech.firstName", "tech.name", "tech.id",
        "job.number", "job.workOrder", "address"]

    ; ------------------------------------------------------------------ validate
    ; Returns {Ok, Errors[], Warnings[]}. Never throws on bad input.
    static Validate(cfg) {
        r := {Ok: false, Errors: [], Warnings: []}
        if !(cfg is Map) {
            r.Errors.Push("config: must be a JSON object")
            return r
        }
        if cfg.Has("schemaVersion") && (cfg["schemaVersion"] is Integer) && cfg["schemaVersion"] > Schema.CURRENT {
            r.Errors.Push("schemaVersion: config was made by a newer version (v" cfg["schemaVersion"]
                . ", this app supports up to v" Schema.CURRENT ")")
            return r
        }
        for k in Schema.TOP_KEYS
            if !cfg.Has(k)
                Schema.Err(r, k, "required key is missing")
        for k, v in cfg
            if !Schema.InList(Schema.TOP_KEYS, k)
                r.Warnings.Push(k ": unknown key (ignored)")

        if cfg.Has("schemaVersion") {
            if !(cfg["schemaVersion"] is Integer)
                Schema.Err(r, "schemaVersion", "must be a whole number")
            else if (cfg["schemaVersion"] < Schema.CURRENT)
                Schema.Err(r, "schemaVersion", "v" cfg["schemaVersion"] " needs migration to v" Schema.CURRENT)
        }
        Schema.IntIn(r, cfg, "revision", "revision", 0, 2147483647)
        Schema.Str(r, cfg, "updatedAt", "updatedAt", false)
        Schema.Str(r, cfg, "updatedBy", "updatedBy", false)
        Schema.CheckTemplate(r, cfg)
        Schema.CheckContext(r, cfg)
        Schema.CheckCategories(r, cfg)
        Schema.CheckThemes(r, cfg)
        if Schema.Sect(r, cfg, "ping") {
            p := cfg["ping"]
            Schema.IntIn(r, p, "timeoutMs", "ping.timeoutMs", 200, 5000)
            Schema.IntIn(r, p, "attempts", "ping.attempts", 1, 20)
            Schema.IntIn(r, p, "intervalMs", "ping.intervalMs", 250, 10000)
            Schema.IntIn(r, p, "untilSuccessMaxMin", "ping.untilSuccessMaxMin", 1, 30)
        }
        if Schema.Sect(r, cfg, "callTracking")
            Schema.IntIn(r, cfg["callTracking"], "newCallDebounceMs", "callTracking.newCallDebounceMs", 0, 60000)
        if Schema.Sect(r, cfg, "history")
            Schema.IntIn(r, cfg["history"], "retentionDays", "history.retentionDays", 1, 90)
        r.Ok := r.Errors.Length = 0
        return r
    }

    ; All error messages joined (for logs and Admin dialogs).
    static Summary(r, max := 5) {
        out := ""
        for i, e in r.Errors {
            if (i > max) {
                out .= "; and " (r.Errors.Length - max) " more"
                break
            }
            out .= (out = "" ? "" : "; ") e
        }
        return out
    }

    ; ------------------------------------------------------------------ migrate
    ; Returns {Cfg, From, To, Changed, Error}. Error is set only when the config can't be used
    ; (not an object, or made by a newer version). A missing/0 schemaVersion is legacy v0.
    static Migrate(cfg) {
        res := {Cfg: cfg, From: 0, To: Schema.CURRENT, Changed: false, Error: ""}
        if !(cfg is Map) {
            res.Error := "config is not a JSON object"
            return res
        }
        v := cfg.Has("schemaVersion") ? cfg["schemaVersion"] : 0
        if (v is String && v = "")
            v := 0
        res.From := v, res.To := v
        if !(v is Integer)
            return res                                ; Validate reports the bad type
        if (v < 0) {
            res.Error := "schemaVersion " v " is not valid"
            return res
        }
        if (v > Schema.CURRENT) {
            res.Error := "config was made by a newer version (v" v ", this app supports up to v" Schema.CURRENT ")"
            return res
        }
        while (v < Schema.CURRENT) {
            if (v = 0)
                Schema.Mig0to1(cfg)
            v += 1
            cfg["schemaVersion"] := v
            res.Changed := true
        }
        res.To := v
        if Schema.FillMissing(cfg)
            res.Changed := true
        return res
    }

    ; Lists that may be added whole when a config predates them (a later milestone added the section). Other lists
    ; (steps, options, flags, categories...) are never filled: a missing one is the admin's choice or a real error.
    static FILL_LISTS := ["static.pingTargets", "static.pingOutcomes", "entry.actions", "entry.items", "entry.outcomes"]

    ; Add keys that newer app versions introduced, from the defaults, so an admin's edited config keeps validating
    ; after an update. Only MISSING keys are added: existing values (labels, fragments, lists) are never changed, and
    ; categories are matched by id (a deleted category is not brought back). True when anything was added.
    static FillMissing(cfg) {
        d := Defaults.Config()
        changed := false
        for k, v in d {
            if (k = "categories" || k = "schemaVersion" || k = "revision" || k = "updatedAt" || k = "updatedBy")
                continue
            if !cfg.Has(k) {
                if !(v is Array) {
                    cfg[k] := Util.Clone(v), changed := true
                }
            } else if (v is Map && cfg[k] is Map)
                changed := Schema._FillMap(cfg[k], v, "") || changed
        }
        if (cfg.Has("categories") && cfg["categories"] is Array && d["categories"] is Array)
            for dc in d["categories"]
                for c in cfg["categories"]
                    if (c is Map && c.Has("id") && c["id"] = dc["id"]) {
                        changed := Schema._FillMap(c, dc, "", true) || changed
                        break
                    }
        return changed
    }

    static _FillMap(m, dm, path, isCategory := false) {
        changed := false
        for k, v in dm {
            p := path = "" ? k : path "." k
            if !m.Has(k) {
                if (v is Array) {
                    if !Schema.InList(Schema.FILL_LISTS, p)
                        continue
                } else if (isCategory && (k = "id" || k = "kind" || k = "system"))
                    continue
                m[k] := Util.Clone(v), changed := true
            } else if (v is Map && m[k] is Map)
                changed := Schema._FillMap(m[k], v, p) || changed
        }
        return changed
    }

    ; v0 -> v1: top-level historyDays moved to history.retentionDays; missing sections filled from defaults.
    static Mig0to1(cfg) {
        d := Defaults.Config()
        days := ""
        if cfg.Has("historyDays") {
            days := cfg["historyDays"]
            cfg.Delete("historyDays")
        }
        hadRet := cfg.Has("history") && (cfg["history"] is Map) && cfg["history"].Has("retentionDays")
        for k, v in d
            if !cfg.Has(k)
                cfg[k] := Util.Clone(v)
        if (cfg["history"] is Map && !hadRet)
            cfg["history"]["retentionDays"] := (days is Integer) ? days : d["history"]["retentionDays"]
    }

    ; ------------------------------------------------------------------ helpers
    static Err(r, path, msg) => r.Errors.Push(path ": " msg)

    static InList(list, v) {
        for x in list
            if (x = v)
                return true
        return false
    }

    static IsBool(v) => (v is Integer) && (v = 0 || v = 1)

    ; Required non-empty section Map; returns true when usable.
    static Sect(r, m, key) {
        if !m.Has(key)
            return false                              ; missing already reported at top level
        if !(m[key] is Map) {
            Schema.Err(r, key, "must be an object")
            return false
        }
        return true
    }

    static Str(r, m, key, path, nonEmpty := true) {
        if !m.Has(key) {
            if (path != key)                          ; top-level keys are reported once elsewhere
                Schema.Err(r, path, "required key is missing")
            return false
        }
        v := m[key]
        if !(v is String) {
            Schema.Err(r, path, "must be text")
            return false
        }
        if (nonEmpty && Trim(v) = "") {
            Schema.Err(r, path, "must not be empty")
            return false
        }
        return true
    }

    static Bool(r, m, key, path, required := true) {
        if !m.Has(key) {
            if required
                Schema.Err(r, path, "required key is missing")
            return
        }
        if !Schema.IsBool(m[key])
            Schema.Err(r, path, "must be true or false")
    }

    static IntIn(r, m, key, path, lo, hi) {
        if !m.Has(key) {
            if (InStr(path, ".") || path != key)
                Schema.Err(r, path, "required key is missing")
            return false
        }
        v := m[key]
        if !(v is Integer) {
            Schema.Err(r, path, "must be a whole number between " lo " and " hi)
            return false
        }
        if (v < lo || v > hi) {
            Schema.Err(r, path, "must be between " lo " and " hi " (got " v ")")
            return false
        }
        return true
    }

    static Id(r, m, path) {
        if !Schema.Str(r, m, "id", path ".id")
            return ""
        if !RegExMatch(m["id"], Schema.ID_RE) {
            Schema.Err(r, path ".id", 'invalid id "' m["id"] '" (letters, digits, - and _; must start with a letter)')
            return ""
        }
        return m["id"]
    }

    ; ------------------------------------------------------------------ sections
    static CheckTemplate(r, cfg) {
        if !Schema.Sect(r, cfg, "noteTemplate")
            return
        t := cfg["noteTemplate"]
        if !t.Has("lines")
            Schema.Err(r, "noteTemplate.lines", "required key is missing")
        else if !(t["lines"] is Array) || t["lines"].Length = 0
            Schema.Err(r, "noteTemplate.lines", "must be a non-empty list of text lines")
        else
            for i, l in t["lines"]
                if !(l is String)
                    Schema.Err(r, "noteTemplate.lines[" i "]", "must be text")
        for k in ["unavailableText", "fragmentJoiner", "categoryJoiner", "endPunctuation"]
            Schema.Str(r, t, k, "noteTemplate." k, false)
        Schema.Bool(r, t, "sentenceCase", "noteTemplate.sentenceCase")
    }

    static CheckContext(r, cfg) {
        if !cfg.Has("contextFields")
            return
        a := cfg["contextFields"]
        if !(a is Array) || a.Length = 0 {
            Schema.Err(r, "contextFields", "must be a non-empty list")
            return
        }
        seen := Map()
        for i, f in a {
            p := "contextFields[" i "]"
            if !(f is Map) {
                Schema.Err(r, p, "must be an object")
                continue
            }
            id := Schema.Id(r, f, p)
            Schema.Str(r, f, "label", p ".label")
            if (id != "") {
                if seen.Has(id)
                    Schema.Err(r, "contextFields", 'duplicate id "' id '"')
                seen[id] := true
            }
        }
        for id in Schema.REQUIRED_CONTEXT
            if !seen.Has(id)
                Schema.Err(r, "contextFields", 'required field "' id '" is missing')
    }

    static CheckThemes(r, cfg) {
        if !Schema.Sect(r, cfg, "themes")
            return
        t := cfg["themes"]
        ids := Map()
        if !t.Has("presets") || !(t["presets"] is Array) || t["presets"].Length = 0
            Schema.Err(r, "themes.presets", "must be a non-empty list")
        else
            for i, p in t["presets"] {
                path := "themes.presets[" i "]"
                if !(p is Map) {
                    Schema.Err(r, path, "must be an object")
                    continue
                }
                id := Schema.Id(r, p, path)
                if (id != "") {
                    if ids.Has(id)
                        Schema.Err(r, "themes.presets", 'duplicate id "' id '"')
                    ids[id] := true
                }
                Schema.Str(r, p, "label", path ".label")
                if Schema.Str(r, p, "sheet", path ".sheet") && !Schema.InList(Schema.SHEETS, StrLower(p["sheet"]))
                    r.Warnings.Push(path ".sheet: unknown look '" p["sheet"] "' (win365 will be used)")
                if Schema.Str(r, p, "mode", path ".mode") && p["mode"] != "light" && p["mode"] != "dark"
                    Schema.Err(r, path ".mode", 'must be "light" or "dark"')
                if Schema.Str(r, p, "accent", path ".accent") && !RegExMatch(p["accent"], "^#[0-9A-Fa-f]{6}$")
                    Schema.Err(r, path ".accent", 'must be a colour like #0099D8 (got "' p["accent"] '")')
            }
        if Schema.Str(r, t, "default", "themes.default") && ids.Count && !ids.Has(t["default"])
            Schema.Err(r, "themes.default", 'no preset with id "' t["default"] '"')
    }

    static CheckCategories(r, cfg) {
        if !cfg.Has("categories")
            return
        a := cfg["categories"]
        if !(a is Array) {
            Schema.Err(r, "categories", "must be a list")
            return
        }
        byId := Map()
        for i, c in a {
            p := "categories[" i "]"
            if !(c is Map) {
                Schema.Err(r, p, "must be an object")
                continue
            }
            id := Schema.Id(r, c, p)
            if (id != "") {
                if byId.Has(id)
                    Schema.Err(r, "categories", 'duplicate id "' id '"')
                else
                    byId[id] := c
            }
            Schema.Str(r, c, "label", p ".label")
            if Schema.Str(r, c, "icon", p ".icon") && !RegExMatch(c["icon"], "^[0-9A-Fa-f]{4,6}$")
                Schema.Err(r, p ".icon", 'must be a hex glyph code like E711 (got "' c["icon"] '")')
            Schema.Bool(r, c, "enabled", p ".enabled")
            Schema.Bool(r, c, "system", p ".system")
            if c.Has("notePrefix") {                 ; optional text put before the category's fragments in the note
                if !(c["notePrefix"] is String)
                    Schema.Err(r, p ".notePrefix", "must be text")
                else if (StrLen(c["notePrefix"]) > Schema.NOTE_PREFIX_MAX)
                    Schema.Err(r, p ".notePrefix", "must be at most " Schema.NOTE_PREFIX_MAX " characters (got " StrLen(c["notePrefix"]) ")")
            }
            kind := ""
            if Schema.Str(r, c, "kind", p ".kind") {
                kind := c["kind"]
                if !Schema.InList(Schema.KINDS, kind)
                    Schema.Err(r, p ".kind", 'must be "steps", "items" or "static" (got "' kind '")')
            }
            if (kind = "steps")
                Schema.CheckSteps(r, c, p)
            else if (kind = "items")
                Schema.CheckEntry(r, c, p)
            else if (kind = "static")
                Schema.CheckStatic(r, c, p)
        }
        for sc in Schema.SYSTEM_CATS {
            if !byId.Has(sc[1]) {
                Schema.Err(r, "categories", 'required system category "' sc[1] '" is missing')
                continue
            }
            c := byId[sc[1]]
            if c.Has("kind") && c["kind"] != sc[2]
                Schema.Err(r, "categories", 'system category "' sc[1] '" must have kind "' sc[2] '"')
            if c.Has("system") && c["system"] != 1
                r.Warnings.Push('categories: "' sc[1] '" is a built-in category but is not marked system')
        }
        if byId.Has("notDone") {
            c := byId["notDone"], found := false
            if c.Has("steps") && (c["steps"] is Array)
                for s in c["steps"]
                    if (s is Map) && s.Has("id") && s["id"] = "reason"
                        found := true
            if !found
                Schema.Err(r, "categories (notDone)", 'required step "reason" is missing')
        }
    }

    ; Option-like entries {id, label, fragment}: unique ids. Returns Map id -> true.
    static CheckOptions(r, list, path, requireNonEmpty := false) {
        ids := Map()
        if !(list is Array) {
            Schema.Err(r, path, "must be a list")
            return ids
        }
        if (requireNonEmpty && list.Length = 0)
            Schema.Err(r, path, "must contain at least one entry")
        for i, o in list {
            p := path "[" i "]"
            if !(o is Map) {
                Schema.Err(r, p, "must be an object")
                continue
            }
            id := Schema.Id(r, o, p)
            if (id != "") {
                if ids.Has(id)
                    Schema.Err(r, path, 'duplicate id "' id '"')
                ids[id] := true
            }
            Schema.Str(r, o, "label", p ".label")
            if o.Has("fragment")
                Schema.Str(r, o, "fragment", p ".fragment", false)
            if o.Has("stop") {
                s := o["stop"]
                if !(s is Map)
                    Schema.Err(r, p ".stop", "must be an object")
                else {
                    Schema.Str(r, s, "message", p ".stop.message")
                    if s.Has("fragment")
                        Schema.Str(r, s, "fragment", p ".stop.fragment", false)
                    if s.Has("keepSteps") && !(s["keepSteps"] is Array)
                        Schema.Err(r, p ".stop.keepSteps", "must be a list of step ids")
                    for k, v in s
                        if !Schema.InList(["message", "fragment", "keepSteps"], k)
                            Schema.Err(r, p ".stop", 'unknown key "' k '" (only message, fragment, keepSteps are allowed)')
                }
            }
        }
        return ids
    }

    static CheckSteps(r, cat, cpath) {
        if !cat.Has("steps") || !(cat["steps"] is Array) || cat["steps"].Length = 0 {
            Schema.Err(r, cpath ".steps", "must be a non-empty list")
            return
        }
        steps := Map()                                ; pass 1: ids (and their order)
        order := Map()
        for i, s in cat["steps"] {
            p := cpath ".steps[" i "]"
            if !(s is Map) {
                Schema.Err(r, p, "must be an object")
                continue
            }
            id := Schema.Id(r, s, p)
            if (id != "") {
                if steps.Has(id)
                    Schema.Err(r, cpath ".steps", 'duplicate id "' id '"')
                else
                    steps[id] := s, order[id] := i
            }
        }
        fieldOwner := Map()                           ; field id -> step id (values are one flat namespace per category)
        for i, s in cat["steps"] {                    ; pass 2: contents
            if !(s is Map)
                continue
            p := cpath ".steps[" i "]"
            sid := (s.Has("id") && s["id"] is String) ? s["id"] : ""
            Schema.Str(r, s, "label", p ".label")
            Schema.Bool(r, s, "required", p ".required", false)
            type := ""
            if Schema.Str(r, s, "type", p ".type") {
                type := s["type"]
                if !Schema.InList(Schema.STEP_TYPES, type)
                    Schema.Err(r, p ".type", 'must be one of choice, yesno, text, group (got "' type '")')
            }
            if ((type = "group" || type = "text") && s.Has("options"))
                Schema.Err(r, p ".options", "a " type " step has only fields (no options)")
            else if s.Has("options") || type = "choice" || type = "yesno" {
                if !s.Has("options")
                    Schema.Err(r, p ".options", "required for type " type)
                else {
                    ids := Schema.CheckOptions(r, s["options"], p ".options", type = "choice" || type = "yesno")
                    if (type = "yesno" && (!ids.Has("yes") || !ids.Has("no") || ids.Count != 2))
                        Schema.Err(r, p ".options", 'a yesno step needs options with ids "yes" and "no" (and no others)')
                    Schema.CheckStops(r, s["options"], p ".options", order, i)
                }
            }
            if s.Has("fragment")
                Schema.Str(r, s, "fragment", p ".fragment", false)
            if s.Has("when")
                Schema.Cond(r, s["when"], p ".when", steps, order, i)
            noFields := !s.Has("fields") || !(s["fields"] is Array) || s["fields"].Length = 0
            if (type = "group" && noFields)
                Schema.Err(r, p ".fields", "a group step needs at least one field")
            if (type = "text" && noFields)
                r.Warnings.Push(p ".fields: a text step without fields collects nothing")
            if s.Has("fields") {
                if !(s["fields"] is Array)
                    Schema.Err(r, p ".fields", "must be a list")
                else {
                    fids := Map()
                    for j, f in s["fields"] {
                        fp := p ".fields[" j "]"
                        if !(f is Map) {
                            Schema.Err(r, fp, "must be an object")
                            continue
                        }
                        fid := Schema.Id(r, f, fp)
                        if (fid != "") {
                            if fids.Has(fid)
                                Schema.Err(r, p ".fields", 'duplicate id "' fid '"')
                            else if fieldOwner.Has(fid)
                                Schema.Err(r, cpath ".steps", 'field id "' fid '" is used by steps "' fieldOwner[fid] '" and "' sid '" (field ids must be unique in a category)')
                            else if steps.Has(fid)
                                Schema.Err(r, cpath ".steps", 'field id "' fid '" is also a step id')
                            fids[fid] := true
                            if !fieldOwner.Has(fid)
                                fieldOwner[fid] := sid
                        }
                        Schema.Str(r, f, "label", fp ".label")
                        Schema.Bool(r, f, "required", fp ".required", false)
                        Schema.Bool(r, f, "multiline", fp ".multiline", false)
                        if f.Has("requiredWhen")
                            Schema.Cond(r, f["requiredWhen"], fp ".requiredWhen", steps)
                    }
                }
            }
        }
        if cat.Has("flags")
            Schema.CheckFlags(r, cat["flags"], cpath ".flags", steps)
    }

    ; stop.keepSteps: every id must be a step of this category that comes BEFORE the step holding the stop.
    static CheckStops(r, options, path, order, stepIndex) {
        if !(options is Array)
            return
        for j, o in options {
            if !(o is Map) || !o.Has("stop") || !(o["stop"] is Map) || !o["stop"].Has("keepSteps")
                continue
            keep := o["stop"]["keepSteps"]
            if !(keep is Array)
                continue
            kp := path "[" j "].stop.keepSteps"
            seen := Map()
            for k, id in keep {
                if !(id is String) || !order.Has(id) {
                    Schema.Err(r, kp, 'references unknown step "' (id is String ? id : "?") '"')
                    continue
                }
                if (order[id] >= stepIndex)
                    Schema.Err(r, kp, 'step "' id '" must come before the step that stops')
                if seen.Has(id)
                    r.Warnings.Push(kp ': step "' id '" is listed twice')
                seen[id] := true
            }
        }
    }

    ; flags: [{id, when, message}] - warnings shown to the agent, never blocking.
    static CheckFlags(r, flags, path, steps) {
        if !(flags is Array) {
            Schema.Err(r, path, "must be a list")
            return
        }
        ids := Map()
        for i, f in flags {
            fp := path "[" i "]"
            if !(f is Map) {
                Schema.Err(r, fp, "must be an object")
                continue
            }
            id := Schema.Id(r, f, fp)
            if (id != "") {
                if ids.Has(id)
                    Schema.Err(r, path, 'duplicate id "' id '"')
                ids[id] := true
            }
            Schema.Str(r, f, "message", fp ".message")
            if !f.Has("when")
                Schema.Err(r, fp ".when", "required key is missing")
            else
                Schema.Cond(r, f["when"], fp ".when", steps)
            for k, v in f
                if !Schema.InList(["id", "when", "message"], k)
                    Schema.Err(r, fp, 'unknown key "' k '" (only id, when, message are allowed)')
        }
    }

    ; Conditions: {step, in:[...]} | {all:[cond...]} | {any:[cond...]}. Nothing else.
    ; `before` (with `order`: step id -> index): the referenced step must come before step number `before`
    ; (used for a step's own `when`; requiredWhen and flags may reference any step of the category).
    static Cond(r, c, path, steps, order := "", before := 0) {
        if !(c is Map) {
            Schema.Err(r, path, "must be an object")
            return
        }
        for k, v in c
            if !Schema.InList(["step", "in", "all", "any"], k)
                Schema.Err(r, path, 'unknown key "' k '" (only step+in, all, any are allowed)')
        forms := (c.Has("step") || c.Has("in") ? 1 : 0) + (c.Has("all") ? 1 : 0) + (c.Has("any") ? 1 : 0)
        if (forms != 1) {
            Schema.Err(r, path, "must use exactly one of step+in, all, any")
            return
        }
        if (c.Has("step") || c.Has("in")) {
            if !c.Has("step") || !c.Has("in") {
                Schema.Err(r, path, '"step" and "in" must be used together')
                return
            }
            if !(c["step"] is String) || !steps.Has(c["step"]) {
                Schema.Err(r, path ".step", 'references unknown step "' (c["step"] is String ? c["step"] : "?") '"')
                return
            }
            if (before > 0 && order.Has(c["step"]) && order[c["step"]] >= before) {
                Schema.Err(r, path ".step", 'step "' c["step"] '" must come before the step that uses this condition')
                return
            }
            if !(c["in"] is Array) || c["in"].Length = 0 {
                Schema.Err(r, path ".in", "must be a non-empty list of option ids")
                return
            }
            target := steps[c["step"]]
            known := Map()
            if target.Has("options") && (target["options"] is Array)
                for o in target["options"]
                    if (o is Map) && o.Has("id")
                        known[o["id"]] := true
            for v in c["in"] {
                if !(v is String)
                    Schema.Err(r, path ".in", "values must be option ids (text)")
                else if known.Count && !known.Has(v)
                    r.Warnings.Push(path '.in: step "' c["step"] '" has no option "' v '"')
            }
            return
        }
        key := c.Has("all") ? "all" : "any"
        if !(c[key] is Array) || c[key].Length = 0 {
            Schema.Err(r, path "." key, "must be a non-empty list of conditions")
            return
        }
        for i, sub in c[key]
            Schema.Cond(r, sub, path "." key "[" i "]", steps, order, before)
    }

    static CheckEntry(r, cat, cpath) {
        if !cat.Has("entry") || !(cat["entry"] is Map) {
            Schema.Err(r, cpath ".entry", "required for kind items")
            return
        }
        e := cat["entry"]
        ep := cpath ".entry"
        for k, v in e
            if !Schema.InList(Schema.ENTRY_KEYS, k)
                r.Warnings.Push(ep ': unknown key "' k '" is ignored')
        ; actions and outcomes carry a fragment (text, may be empty); items are just {id, label}
        for k in ["actions", "outcomes", "items"] {
            if !e.Has(k) {
                if (k != "outcomes")
                    Schema.Err(r, ep "." k, "required key is missing")
                continue
            }
            Schema.CheckOptions(r, e[k], ep "." k, k != "outcomes")
            if (k != "items" && (e[k] is Array))
                for i, o in e[k]
                    if (o is Map) {
                        if !o.Has("fragment")
                            Schema.Err(r, ep "." k "[" i "].fragment", 'required key is missing (use "" for no text)')
                        else
                            Schema.CheckEntryFragment(r, o["fragment"], ep "." k "[" i "].fragment")
                    }
        }
        for k in ["qty", "details", "outcomeRequired"]
            Schema.Bool(r, e, k, ep "." k, false)
        if (e.Has("outcomeRequired") && Schema.IsBool(e["outcomeRequired"]) && e["outcomeRequired"] = 1
                && (!e.Has("outcomes") || !(e["outcomes"] is Array) || e["outcomes"].Length = 0))
            Schema.Err(r, ep ".outcomes", "must contain at least one entry when outcomeRequired is true")
    }

    ; Placeholders a fragment of an items category may use; anything else is reported as a warning.
    static CheckEntryFragment(r, text, path) {
        if !(text is String)
            return
        pos := 1
        while RegExMatch(text, "\{([A-Za-z][A-Za-z0-9_.]*)\}", &m, pos) {
            pos := m.Pos + m.Len
            if !Schema.InList(Schema.ENTRY_PLACEHOLDERS, m[1])
                r.Warnings.Push(path ': unknown placeholder {' m[1] '}')
        }
    }

    ; Static category (M7): wording only. pingTargets (ids gateway and ip must exist; labels are wording), pingOutcomes (ids reply and noReply must exist; each
    ; has a fragment). Unknown keys and unknown {placeholders} are warnings. A leftover "fragments" (the removed scripted
    ; static note) is ignored silently.
    static CheckStatic(r, cat, cpath) {
        sp := cpath ".static"
        if !cat.Has("static") {
            Schema.Err(r, sp, "required for kind static")
            return
        }
        if !(cat["static"] is Map) {
            Schema.Err(r, sp, "must be an object")
            return
        }
        s := cat["static"]
        for k, v in s
            if !Schema.InList(Schema.STATIC_KEYS, k) && !Schema.InList(Schema.STATIC_LEGACY_KEYS, k)
                r.Warnings.Push(sp ': unknown key "' k '" is ignored')
        Schema.CheckFixedIds(r, s, "pingTargets", sp, ["gateway", "ip"], false)
        Schema.CheckFixedIds(r, s, "pingOutcomes", sp, ["reply", "noReply"], true)
    }

    ; A list of {id, label[, fragment]} whose ids must include `need`. withFragment: every entry needs a fragment (text,
    ; may be empty) whose placeholders are checked.
    static CheckFixedIds(r, s, key, sp, need, withFragment) {
        p := sp "." key
        if !s.Has(key) {
            Schema.Err(r, p, "required key is missing")
            return
        }
        ids := Schema.CheckOptions(r, s[key], p, true)
        if !(s[key] is Array)
            return
        for id in need
            if !ids.Has(id)
                Schema.Err(r, p, 'required id "' id '" is missing')
        if !withFragment
            return
        for i, o in s[key]
            if (o is Map) {
                if !o.Has("fragment")
                    Schema.Err(r, p "[" i "].fragment", 'required key is missing (use "" for no text)')
                else
                    Schema.CheckPlaceholders(r, o["fragment"], p "[" i "].fragment", Schema.STATIC_PING_PH)
            }
    }

    ; Warnings for {placeholders} not in the allowed list.
    static CheckPlaceholders(r, text, path, allowed) {
        if !(text is String)
            return
        pos := 1
        while RegExMatch(text, "\{([A-Za-z][A-Za-z0-9_.]*)\}", &m, pos) {
            pos := m.Pos + m.Len
            if !Schema.InList(allowed, m[1])
                r.Warnings.Push(path ': unknown placeholder {' m[1] '}')
        }
    }
}
