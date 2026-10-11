#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\..\Config\ConfigJson.ahk
#Include %A_LineFile%\..\..\Config\Defaults.ahk
#Include %A_LineFile%\..\..\Config\Schema.ahk
#Include %A_LineFile%\..\..\Config\ConfigStore.ahk
; AdminModel.ahk - the Admin companion's logic (PLAN M10). Pure logic: no GUI, no AxGui.
;
;   model := AdminModel({Store: ConfigStore(...)})
;   model.Load()                    ; store.Load(), then the WORKING COPY (model.Work) is a deep copy of it
;   model.Dirty                     ; the working copy differs from what was loaded / last saved
;   model.Validate()                ; {Ok, Errors[], Warnings[], Items[]}   Items = [{Level, Text, Raw, Nav}] (readable path + where to go)
;   model.Save()                    ; Validate, then ConfigStore.Save -> {Ok, Kind, Error, ...}
;
; Editing operations never throw; each returns {Ok, Error, ...}. A refused operation changes nothing. Ids are GENERATED
; from the label (Slug + UniqueId) and never change afterwards: History entries refer to them.
;
; Rules that the operations enforce (the validator enforces the rest and the Check page lists it):
;   - a new Static category is not allowed; the five system categories can be removed (the validator then fails until
;     they are restored), the UI asks for a typed confirmation first
;   - the Not Done step `reason` can't be removed
;   - a step's `when` may only refer to EARLIER steps: a move that would break that is BLOCKED and explained
;   - deleting something that is referenced lists every reference (FindReferences) and only goes on with clean := true,
;     which removes the references (a clause that loses its last option is removed, an empty all/any is removed, a flag
;     that loses its condition is removed, {placeholders} of a removed step/field are removed from fragments)

class AdminModel {
    static CTX_PH := ["tech.firstName", "tech.name", "tech.id", "job.number", "job.workOrder", "address"]
    ; same bounds as Schema.Validate (TestAdminModel checks them against the validator)
    static BOUNDS := Map("ping.timeoutMs", [200, 5000], "ping.attempts", [1, 20], "ping.intervalMs", [250, 10000],
        "ping.untilSuccessMaxMin", [1, 30], "callTracking.newCallDebounceMs", [0, 60000], "history.retentionDays", [1, 90])
    ; ids a field/step must not use: the composer reads these names before the category's own values
    static RESERVED := ["address", "notes", "tech", "job"]
    static ICON_DEFAULT := "E8A5"
    static ITEM_FRAGMENT := "{action} {qty} {item}. {details}"

    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.Store := o.HasOwnProp("Store") ? o.Store : ""
        this.Logger := o.HasOwnProp("Logger") ? o.Logger : ""
        this.Work := Defaults.Config()
        this.SavedCanon := ""
        this.Conflicts := []
        this.LoadedAt := ""
        this._subs := []
        this._quiet := 0
    }

    ; --------------------------------------------------------------------------------------------- results
    static Fail(msg, extra := "") {
        r := {Ok: false, Error: msg}
        if IsObject(extra)
            for k, v in extra.OwnProps()
                r.%k% := v
        return r
    }

    static Good(extra := "") {
        r := {Ok: true, Error: ""}
        if IsObject(extra)
            for k, v in extra.OwnProps()
                r.%k% := v
        return r
    }

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }

    OnChanged(fn) {
        this._subs.Push(fn)
        return this
    }

    _Changed(what := "") {
        if (this._quiet > 0)
            return
        for fn in this._subs.Clone()
            try fn(this, what)
    }

    ; --------------------------------------------------------------------------------------------- loading
    ; Load through the store; the working copy is a deep copy of what the store holds. Clears nothing else.
    Load() {
        this.Store.Load()
        this._Adopt()
        this.ScanConflicts()
        this.LoadedAt := Util.IsoNow()
        this._Log("info", "admin loaded", {source: this.Store.Source, revision: this.Store.Revision,
            warnings: this.Store.Warnings.Length, conflicts: this.Conflicts.Length})
        this._Changed("load")
        return this
    }

    _Adopt() {
        this.Work := Util.Clone(this.Store.Config)
        this.SavedCanon := ConfigJson.Canon(this.Work)
    }

    Dirty => ConfigJson.Canon(this.Work) != this.SavedCanon

    ; What the status line shows.
    Status() {
        s := this.Store
        w := this.Work
        return {Source: s.Source, Revision: s.Revision, Shared: s.SharedConfigured, Warnings: s.Warnings,
            UpdatedBy: w.Has("updatedBy") ? w["updatedBy"] : "", UpdatedAt: w.Has("updatedAt") ? w["updatedAt"] : "",
            Dir: s.SharedDir}
    }

    ; --------------------------------------------------------------------------------------------- OneDrive conflict copies
    ; Names of files in the config folder that look like OneDrive conflict copies. Our own backups live in backups\ and are
    ; not looked at; a backup-style name (config-YYYYMMDD-HHMMSS[_NN].json) is not a conflict copy either.
    static FindConflictCopies(dir, machine := "") {
        out := []
        if (dir = "" || !DirExist(dir))
            return out
        if (machine = "")
            machine := A_ComputerName
        Loop Files RTrim(dir, "\") "\*.json", "F"
            if AdminModel.IsConflictName(A_LoopFileName, machine)
                out.Push(A_LoopFileName)
        return out
    }

    static IsConflictName(n, machine := "") {
        l := StrLower(n)
        if (l = "config.json" || l = "config.default.json" || l = "config.cache.json")
            return false
        if RegExMatch(n, "i)^config \(\d+\)\.json$")
            return true                                           ; config (1).json
        if RegExMatch(n, "i)^config-\d{8}-\d{6}(_\d+)?\.json$")
            return false                                          ; one of our own backups, not a OneDrive copy
        if RegExMatch(n, "i)^config-.+\.json$")
            return true                                           ; config-DESKTOP-ABC.json
        if (machine != "" && RegExMatch(n, "i)^config.*-" AdminModel.RxEsc(machine) ".*\.json$"))
            return true
        if (SubStr(l, 1, 6) = "config" && (InStr(l, "conflict") || RegExMatch(l, "^config\s*-\s*copy")))
            return true
        return false
    }

    static RxEsc(s) => RegExReplace(s, "[\\.*?+\[\](){}|^$]", "\$0")

    ; Rescan the config folder (on load and before every save). Returns the list.
    ScanConflicts() {
        this.Conflicts := AdminModel.FindConflictCopies(this.Store.SharedDir, this.Store.Machine)
        return this.Conflicts
    }

    ; --------------------------------------------------------------------------------------------- ids
    ; A readable camelCase id from a label: "My option" -> "myOption", "PWO order" -> "pwoOrder", "Cafe Unit" -> "cafeUnit".
    ; Non-ASCII letters are reduced to their ASCII base (accents dropped) or left out; an empty result (or one starting with a
    ; digit) gets `fallback` ("option", "step"...). At most 32 characters.
    static Slug(label, fallback := "item") {
        s := AdminModel.Ascii(String(label))
        words := [], pos := 1
        while RegExMatch(s, "[A-Za-z0-9]+", &m, pos) {
            words.Push(m[0])
            pos := m.Pos + m.Len
        }
        out := ""
        for i, w in words {
            if (w == StrUpper(w))
                w := StrLower(w)                                  ; PWO -> pwo
            out .= (i = 1 ? StrLower(SubStr(w, 1, 1)) : StrUpper(SubStr(w, 1, 1))) SubStr(w, 2)
        }
        if (out = "")
            return fallback
        if RegExMatch(out, "^[0-9]")
            out := fallback StrUpper(SubStr(out, 1, 1)) SubStr(out, 2)
        return SubStr(out, 1, 32)
    }

    ; NFD-decompose, then drop everything that is not ASCII (accents, other scripts).
    static Ascii(s) {
        t := s
        try {
            n := DllCall("Normaliz\NormalizeString", "int", 2, "str", s, "int", -1, "ptr", 0, "int", 0, "int")
            if (n > 0) {
                buf := Buffer(n * 2)
                r := DllCall("Normaliz\NormalizeString", "int", 2, "str", s, "int", -1, "ptr", buf, "int", n, "int")
                if (r > 0)
                    t := StrGet(buf, "UTF-16")
            }
        }
        return RegExReplace(t, "[^\x00-\x7F]", "")
    }

    ; base, base2, base3 ... the first one not in `taken` (an Array of ids; compared without regard to case).
    static UniqueId(base, taken) {
        id := base, n := 2
        while AdminModel.InIds(taken, id) {
            id := base n
            n += 1
        }
        return id
    }

    static InIds(list, id) {
        for x in list
            if (StrCompare(String(x), String(id)) = 0)
                return true
        for x in AdminModel.RESERVED
            if (StrCompare(x, String(id)) = 0)
                return true
        return false
    }

    static NewId(label, taken, fallback := "item") => AdminModel.UniqueId(AdminModel.Slug(label, fallback), taken)

    static IdsOf(list) {
        out := []
        if (list is Array)
            for x in list
                if (x is Map && x.Has("id"))
                    out.Push(x["id"])
        return out
    }

    ; --------------------------------------------------------------------------------------------- lookups
    Cat(id) {
        if (this.Work.Has("categories") && this.Work["categories"] is Array)
            for c in this.Work["categories"]
                if (c is Map && c.Has("id") && c["id"] == id)
                    return c
        return ""
    }

    CatIndex(id) {
        if (this.Work.Has("categories") && this.Work["categories"] is Array)
            for i, c in this.Work["categories"]
                if (c is Map && c.Has("id") && c["id"] == id)
                    return i
        return 0
    }

    CatIds() => AdminModel.IdsOf(this.Work.Has("categories") ? this.Work["categories"] : [])

    Steps(catId) {
        c := this.Cat(catId)
        return (c is Map && c.Has("steps") && c["steps"] is Array) ? c["steps"] : []
    }

    Step(catId, stepId) => AdminModel.Find(this.Steps(catId), stepId)

    static TypeOf(s) => (s is Map && s.Has("type")) ? String(s["type"]) : ""

    static Find(list, id) {
        if (list is Array)
            for x in list
                if (x is Map && x.Has("id") && x["id"] == id)
                    return x
        return ""
    }

    static IdxOf(list, id) {
        if (list is Array)
            for i, x in list
                if (x is Map && x.Has("id") && x["id"] == id)
                    return i
        return 0
    }

    static MoveIn(list, i, dir) {
        j := i + dir
        if (i < 1 || i > list.Length || j < 1 || j > list.Length)
            return false
        x := list.RemoveAt(i)
        list.InsertAt(j, x)
        return true
    }

    static Label(x) => (x is Map) ? (x.Has("label") && x["label"] != "" ? String(x["label"]) : (x.Has("id") ? String(x["id"]) : "")) : ""

    CatLabel(catId) {
        c := this.Cat(catId)
        return (c is Map) ? AdminModel.Label(c) : catId
    }

    Options(catId, stepId) {
        s := this.Step(catId, stepId)
        return (s is Map && s.Has("options") && s["options"] is Array) ? s["options"] : []
    }

    Fields(catId, stepId) {
        s := this.Step(catId, stepId)
        return (s is Map && s.Has("fields") && s["fields"] is Array) ? s["fields"] : []
    }

    ; Every id a step or field of this category may not reuse: step ids, field ids (one namespace, see Schema) + reserved.
    StepFieldIds(cat) {
        ids := []
        if (cat is Map && cat.Has("steps") && cat["steps"] is Array)
            for s in cat["steps"] {
                if (s is Map && s.Has("id"))
                    ids.Push(s["id"])
                if (s is Map && s.Has("fields") && s["fields"] is Array)
                    for f in s["fields"]
                        if (f is Map && f.Has("id"))
                            ids.Push(f["id"])
            }
        return ids
    }

    ; --------------------------------------------------------------------------------------------- categories
    IsSystem(id) {
        for sc in Schema.SYSTEM_CATS
            if (sc[1] == id)
                return true
        return false
    }

    ; Add a steps or items category. A new static category is refused (the Static view is built into the app).
    AddCategory(kind, label) {
        if (kind = "static")
            return AdminModel.Fail("A new Static category can't be added: the Static view is built into the app.")
        if (kind != "steps" && kind != "items")
            return AdminModel.Fail("Choose Steps or Items.")
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name for the category first.")
        id := AdminModel.NewId(label, this.CatIds(), "category")
        c := Map("id", id, "label", label, "icon", AdminModel.ICON_DEFAULT, "enabled", 1, "system", 0, "kind", kind, "notePrefix", "")
        if (kind = "steps") {
            c["steps"] := [Map("id", "step1", "label", "Step 1", "type", "choice", "required", 0,
                "options", [Map("id", "option1", "label", "Option 1", "fragment", "")])]
        } else
            c["entry"] := Map("actions", [Map("id", "added", "label", "Added", "fragment", AdminModel.ITEM_FRAGMENT)],
                "items", [Map("id", "item1", "label", "Item 1")], "outcomes", [], "outcomeRequired", 0, "qty", 1, "details", 1)
        this.Work["categories"].Push(c)
        this._Changed("cat")
        return AdminModel.Good({Id: id})
    }

    ; Remove a category (the UI asks first; for a system category it asks for a typed confirmation). The validator then
    ; reports a missing system category until it is restored.
    RemoveCategory(id) {
        i := this.CatIndex(id)
        if (i = 0)
            return AdminModel.Fail("That category does not exist.")
        sys := this.IsSystem(id)
        this.Work["categories"].RemoveAt(i)
        this._Changed("cat")
        return AdminModel.Good({System: sys})
    }

    MoveCategory(id, dir) {
        i := this.CatIndex(id)
        if (i = 0)
            return AdminModel.Fail("That category does not exist.")
        if !AdminModel.MoveIn(this.Work["categories"], i, dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("cat")
        return AdminModel.Good()
    }

    ; key: label | enabled | icon | notePrefix. label is free text; icon (hex 4-6) and notePrefix (max 40) are checked.
    SetCatProp(id, key, val) {
        c := this.Cat(id)
        if !(c is Map)
            return AdminModel.Fail("That category does not exist.")
        switch key {
        case "label":
            c["label"] := String(val)
        case "enabled":
            c["enabled"] := val ? 1 : 0
        case "icon":
            v := StrUpper(Util.Trim(val))
            if !RegExMatch(v, "^[0-9A-F]{4,6}$")
                return AdminModel.Fail("An icon code is 4 to 6 hex digits, like E711.")
            c["icon"] := v
        case "notePrefix":
            if (StrLen(String(val)) > Schema.NOTE_PREFIX_MAX)
                return AdminModel.Fail("The note prefix can be at most " Schema.NOTE_PREFIX_MAX " characters.")
            c["notePrefix"] := String(val)
        default:
            return AdminModel.Fail("Unknown property " key)
        }
        this._Changed("cat")
        return AdminModel.Good()
    }

    ; System category ids that are not in the working copy.
    MissingSystem() {
        out := []
        have := Map()
        for id in this.CatIds()
            have[id] := true
        for sc in Schema.SYSTEM_CATS
            if !have.Has(sc[1])
                out.Push(sc[1])
        return out
    }

    ; Put a system category back from the built-in defaults, at its default position.
    RestoreSystemCategory(id) {
        if !this.IsSystem(id)
            return AdminModel.Fail("Only the built-in categories can be restored.")
        if (this.CatIndex(id) > 0)
            return AdminModel.Fail("That category is already there.")
        d := Defaults.Config()["categories"]
        order := []
        for c in d
            order.Push(c["id"])
        mine := ""
        for c in d
            if (c["id"] == id)
                mine := c
        myPos := 0
        for i, oid in order
            if (oid == id)
                myPos := i
        at := this.Work["categories"].Length + 1
        for i, c in this.Work["categories"] {
            p := 0
            for j, oid in order
                if (c is Map && c.Has("id") && oid == c["id"])
                    p := j
            if (p > myPos) {
                at := i
                break
            }
        }
        this.Work["categories"].InsertAt(at, Util.Clone(mine))
        this._Changed("cat")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- steps
    AddStep(catId, label, type := "choice") {
        cat := this.Cat(catId)
        if !(cat is Map) || cat["kind"] != "steps"
            return AdminModel.Fail("Steps can only be added to a Steps category.")
        if !Schema.InList(Schema.STEP_TYPES, type)
            return AdminModel.Fail("Unknown step type " type)
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name for the step first.")
        taken := this.StepFieldIds(cat)
        id := AdminModel.NewId(label, taken, "step")
        taken.Push(id)
        s := Map("id", id, "label", label, "type", type, "required", 0)
        this._Shape(s, type, taken)
        cat["steps"].Push(s)
        this._Changed("step")
        return AdminModel.Good({Id: id})
    }

    ; Give a step the content its type needs (options for choice/yesno, one field for group/text).
    _Shape(s, type, taken) {
        if (type = "choice") {
            s["options"] := [Map("id", "option1", "label", "Option 1", "fragment", "")]
        } else if (type = "yesno") {
            s["options"] := [Map("id", "yes", "label", "Yes", "fragment", ""), Map("id", "no", "label", "No", "fragment", "")]
        } else {
            fid := AdminModel.NewId("Field 1", taken, "field")
            taken.Push(fid)
            s["fields"] := [Map("id", fid, "label", "Field 1", "required", 0)]
        }
    }

    ; The required step that can't be removed ("reason" in Not Done).
    IsRequiredStep(catId, stepId) => catId == "notDone" && stepId == "reason"

    ; Remove a step. Refused for the required `reason` step and for the only step of a category. When other things refer to the
    ; step (or its fields) the references are returned (NeedConfirm); with clean := true they are removed too.
    RemoveStep(catId, stepId, clean := false) {
        cat := this.Cat(catId)
        s := this.Step(catId, stepId)
        if !(s is Map)
            return AdminModel.Fail("That step does not exist.")
        if this.IsRequiredStep(catId, stepId)
            return AdminModel.Fail('The step "' AdminModel.Label(s) '" is required by Not Done and cannot be removed.', {Locked: true})
        if (cat["steps"].Length <= 1)
            return AdminModel.Fail("A category needs at least one step.")
        refs := this.FindReferences({Kind: "step", Cat: catId, Step: stepId})
        if (refs.Length > 0 && !clean)
            return AdminModel.Fail("This step is used elsewhere.", {NeedConfirm: true, Refs: refs})
        if clean
            this._CleanStep(cat, s)
        cat["steps"].RemoveAt(AdminModel.IdxOf(cat["steps"], stepId))
        this._Changed("step")
        return AdminModel.Good({Removed: refs.Length})
    }

    ; Move a step up (-1) or down (+1). BLOCKED when a step's `when` (or a stop's keepSteps) would then refer to a step that
    ; comes later. Returns {Ok:false, Blocked:true, Problems:[...]}.
    MoveStep(catId, stepId, dir) {
        cat := this.Cat(catId)
        if !(cat is Map) || !cat.Has("steps")
            return AdminModel.Fail("That category has no steps.")
        steps := cat["steps"]
        i := AdminModel.IdxOf(steps, stepId)
        if (i = 0)
            return AdminModel.Fail("That step does not exist.")
        j := i + dir
        if (j < 1 || j > steps.Length)
            return AdminModel.Fail(dir < 0 ? "It is already the first step." : "It is already the last step.")
        before := this.OrderProblems(steps)
        trial := steps.Clone()
        x := trial.RemoveAt(i)
        trial.InsertAt(j, x)
        after := this.OrderProblems(trial)
        fresh := []
        for p in after {
            seen := false
            for q in before
                if (p == q)
                    seen := true
            if !seen
                fresh.Push(p)
        }
        if (fresh.Length > 0) {
            msg := "Can't move this step there. A step can only depend on steps above it:"
            for p in fresh
                msg .= "`n- " p
            return AdminModel.Fail(msg, {Blocked: true, Problems: fresh})
        }
        AdminModel.MoveIn(steps, i, dir)
        this._Changed("step")
        return AdminModel.Good()
    }

    ; Problems with the order of steps: a `when` that refers to the step itself or a later one, a stop keeping a later step.
    OrderProblems(steps) {
        out := []
        pos := Map()
        for i, s in steps
            if (s is Map && s.Has("id"))
                pos[s["id"]] := i
        for i, s in steps {
            if !(s is Map)
                continue
            lab := AdminModel.Label(s)
            if s.Has("when")
                for id in AdminModel.CondSteps(s["when"])
                    if pos.Has(id) && pos[id] >= i
                        out.Push('"' lab '" is shown depending on "' AdminModel.Label(steps[pos[id]]) '", which would not be above it')
            if (s.Has("options") && s["options"] is Array)
                for o in s["options"]
                    if (o is Map && o.Has("stop") && o["stop"] is Map && o["stop"].Has("keepSteps") && o["stop"]["keepSteps"] is Array)
                        for id in o["stop"]["keepSteps"]
                            if pos.Has(id) && pos[id] >= i
                                out.Push('"' lab '" keeps "' AdminModel.Label(steps[pos[id]]) '" when it stops, which would not be above it')
        }
        return out
    }

    ; key: label | required | fragment
    SetStepProp(catId, stepId, key, val) {
        s := this.Step(catId, stepId)
        if !(s is Map)
            return AdminModel.Fail("That step does not exist.")
        switch key {
        case "label", "fragment":
            s[key] := String(val)
        case "required":
            s["required"] := val ? 1 : 0
        default:
            return AdminModel.Fail("Unknown property " key)
        }
        this._Changed("step")
        return AdminModel.Good()
    }

    ; Change a step's type. Options that disappear (choice -> text) are removed, so references to them are listed first
    ; (NeedConfirm) and removed with clean := true.
    ChangeStepType(catId, stepId, type, clean := false) {
        cat := this.Cat(catId)
        s := this.Step(catId, stepId)
        if !(s is Map)
            return AdminModel.Fail("That step does not exist.")
        if !Schema.InList(Schema.STEP_TYPES, type)
            return AdminModel.Fail("Unknown step type " type)
        old := s.Has("type") ? s["type"] : ""
        if (old = type)
            return AdminModel.Good()
        if this.IsRequiredStep(catId, stepId) && type != "choice"
            return AdminModel.Fail('The step "' AdminModel.Label(s) '" must stay a choice.')
        refs := []
        gone := []                                    ; option ids that will not exist afterwards
        if (s.Has("options") && s["options"] is Array)
            for o in s["options"]
                if (o is Map && o.Has("id")) {
                    keep := false
                    if (type = "yesno" && (o["id"] == "yes" || o["id"] == "no"))
                        keep := true
                    if (type = "choice")
                        keep := true
                    if !keep
                        gone.Push(o["id"])
                }
        if (type = "text" || type = "group")
            gone := AdminModel.IdsOf(s.Has("options") ? s["options"] : [])
        for oid in gone
            for r in this.FindReferences({Kind: "option", Cat: catId, Step: stepId, Option: oid})
                refs.Push(r)
        if (refs.Length > 0 && !clean)
            return AdminModel.Fail("Changing the type removes options that are used elsewhere.", {NeedConfirm: true, Refs: refs})
        for oid in gone
            this._CleanCond(cat, stepId, oid)
        s["type"] := type
        taken := this.StepFieldIds(cat)
        if (type = "yesno") {
            old2 := Map()
            if (s.Has("options") && s["options"] is Array)
                for o in s["options"]
                    if (o is Map && o.Has("id"))
                        old2[o["id"]] := o
            s["options"] := [old2.Has("yes") ? old2["yes"] : Map("id", "yes", "label", "Yes", "fragment", ""),
                old2.Has("no") ? old2["no"] : Map("id", "no", "label", "No", "fragment", "")]
        } else if (type = "choice") {
            if !(s.Has("options") && s["options"] is Array) || s["options"].Length = 0
                s["options"] := [Map("id", "option1", "label", "Option 1", "fragment", "")]
        } else {
            if s.Has("options")
                s.Delete("options")
            if ((type = "group" || type = "text") && !(s.Has("fields") && s["fields"] is Array && s["fields"].Length > 0)) {
                fid := AdminModel.NewId("Field 1", taken, "field")
                s["fields"] := [Map("id", fid, "label", "Field 1", "required", 0)]
            }
        }
        this._Changed("step")
        return AdminModel.Good({Removed: refs.Length})
    }

    ; --------------------------------------------------------------------------------------------- options
    AddOption(catId, stepId, label) {
        s := this.Step(catId, stepId)
        if !(s is Map) || !s.Has("options") || !(s["options"] is Array)
            return AdminModel.Fail("This step has no options.")
        if (AdminModel.TypeOf(s) = "yesno")
            return AdminModel.Fail("A Yes/No step has exactly two options.")
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name for the option first.")
        id := AdminModel.NewId(label, AdminModel.IdsOf(s["options"]), "option")
        s["options"].Push(Map("id", id, "label", label, "fragment", ""))
        this._Changed("option")
        return AdminModel.Good({Id: id})
    }

    RemoveOption(catId, stepId, optId, clean := false) {
        cat := this.Cat(catId)
        s := this.Step(catId, stepId)
        if !(s is Map) || !s.Has("options")
            return AdminModel.Fail("This step has no options.")
        if (AdminModel.TypeOf(s) = "yesno")
            return AdminModel.Fail("A Yes/No step always keeps its Yes and No options.")
        o := AdminModel.Find(s["options"], optId)
        if !(o is Map)
            return AdminModel.Fail("That option does not exist.")
        if (s["options"].Length <= 1)
            return AdminModel.Fail("A choice needs at least one option.")
        refs := this.FindReferences({Kind: "option", Cat: catId, Step: stepId, Option: optId})
        if (refs.Length > 0 && !clean)
            return AdminModel.Fail("This option is used elsewhere.", {NeedConfirm: true, Refs: refs})
        if clean
            this._CleanCond(cat, stepId, optId)
        s["options"].RemoveAt(AdminModel.IdxOf(s["options"], optId))
        this._Changed("option")
        return AdminModel.Good({Removed: refs.Length})
    }

    MoveOption(catId, stepId, optId, dir) {
        s := this.Step(catId, stepId)
        if !(s is Map) || !s.Has("options")
            return AdminModel.Fail("This step has no options.")
        if !AdminModel.MoveIn(s["options"], AdminModel.IdxOf(s["options"], optId), dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("option")
        return AdminModel.Good()
    }

    ; key: label | fragment
    SetOptionProp(catId, stepId, optId, key, val) {
        o := AdminModel.Find(this.Options(catId, stepId), optId)
        if !(o is Map)
            return AdminModel.Fail("That option does not exist.")
        if (key != "label" && key != "fragment")
            return AdminModel.Fail("Unknown property " key)
        o[key] := String(val)
        this._Changed("option")
        return AdminModel.Good()
    }

    ; --- stop ---
    Stop(catId, stepId, optId) {
        o := AdminModel.Find(this.Options(catId, stepId), optId)
        return (o is Map && o.Has("stop") && o["stop"] is Map) ? o["stop"] : ""
    }

    SetStopEnabled(catId, stepId, optId, on) {
        o := AdminModel.Find(this.Options(catId, stepId), optId)
        if !(o is Map)
            return AdminModel.Fail("That option does not exist.")
        if on {
            if !(o.Has("stop") && o["stop"] is Map)
                o["stop"] := Map("message", "Tell the agent what to do next.", "fragment", "", "keepSteps", [])
        } else if o.Has("stop")
            o.Delete("stop")
        this._Changed("stop")
        return AdminModel.Good()
    }

    ; key: message | fragment
    SetStopProp(catId, stepId, optId, key, val) {
        st := this.Stop(catId, stepId, optId)
        if !(st is Map)
            return AdminModel.Fail("This option does not stop the workflow.")
        if (key != "message" && key != "fragment")
            return AdminModel.Fail("Unknown property " key)
        st[key] := String(val)
        this._Changed("stop")
        return AdminModel.Good()
    }

    ; Tick or untick an EARLIER step in keepSteps.
    SetStopKeep(catId, stepId, optId, keepId, on) {
        st := this.Stop(catId, stepId, optId)
        if !(st is Map)
            return AdminModel.Fail("This option does not stop the workflow.")
        steps := this.Steps(catId)
        si := AdminModel.IdxOf(steps, stepId), ki := AdminModel.IdxOf(steps, keepId)
        if (ki = 0 || ki >= si)
            return AdminModel.Fail("Only steps above this one can be kept.")
        keep := (st.Has("keepSteps") && st["keepSteps"] is Array) ? st["keepSteps"] : []
        out := []
        for id in keep
            if (id != keepId)
                out.Push(id)
        if on
            out.Push(keepId)
        ; keep the steps in list order
        ordered := []
        for s in steps
            for id in out
                if (id == s["id"])
                    ordered.Push(id)
        st["keepSteps"] := ordered
        this._Changed("stop")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- fields
    AddField(catId, stepId, label) {
        cat := this.Cat(catId)
        s := this.Step(catId, stepId)
        if !(s is Map)
            return AdminModel.Fail("That step does not exist.")
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name for the field first.")
        id := AdminModel.NewId(label, this.StepFieldIds(cat), "field")
        if !(s.Has("fields") && s["fields"] is Array)
            s["fields"] := []
        s["fields"].Push(Map("id", id, "label", label, "required", 0))
        this._Changed("field")
        return AdminModel.Good({Id: id})
    }

    RemoveField(catId, stepId, fieldId, clean := false) {
        cat := this.Cat(catId)
        s := this.Step(catId, stepId)
        if !(s is Map) || !(s.Has("fields") && s["fields"] is Array)
            return AdminModel.Fail("That step has no fields.")
        if !(AdminModel.Find(s["fields"], fieldId) is Map)
            return AdminModel.Fail("That field does not exist.")
        if (AdminModel.TypeOf(s) = "group" && s["fields"].Length <= 1)
            return AdminModel.Fail("A group step needs at least one field.")
        refs := this.FindReferences({Kind: "field", Cat: catId, Field: fieldId})
        if (refs.Length > 0 && !clean)
            return AdminModel.Fail("This field is used in a fragment.", {NeedConfirm: true, Refs: refs})
        if clean
            this._CleanPlaceholder(cat, fieldId)
        s["fields"].RemoveAt(AdminModel.IdxOf(s["fields"], fieldId))
        this._Changed("field")
        return AdminModel.Good({Removed: refs.Length})
    }

    MoveField(catId, stepId, fieldId, dir) {
        s := this.Step(catId, stepId)
        if !(s is Map) || !(s.Has("fields") && s["fields"] is Array)
            return AdminModel.Fail("That step has no fields.")
        if !AdminModel.MoveIn(s["fields"], AdminModel.IdxOf(s["fields"], fieldId), dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("field")
        return AdminModel.Good()
    }

    ; key: label | required | multiline
    SetFieldProp(catId, stepId, fieldId, key, val) {
        f := AdminModel.Find(this.Fields(catId, stepId), fieldId)
        if !(f is Map)
            return AdminModel.Fail("That field does not exist.")
        switch key {
        case "label":
            f["label"] := String(val)
        case "required", "multiline":
            f[key] := val ? 1 : 0
        default:
            return AdminModel.Fail("Unknown property " key)
        }
        this._Changed("field")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- flags
    Flags(catId) {
        c := this.Cat(catId)
        return (c is Map && c.Has("flags") && c["flags"] is Array) ? c["flags"] : []
    }

    ; A flag needs a condition: the first option of the first choice step is used to start with.
    AddFlag(catId, message) {
        cat := this.Cat(catId)
        if !(cat is Map) || cat["kind"] != "steps"
            return AdminModel.Fail("Flags belong to Steps categories.")
        message := Util.Trim(message)
        if (message = "")
            return AdminModel.Fail("Type the warning text first.")
        cond := ""
        for s in this.Steps(catId)
            if (s is Map && s.Has("options") && s["options"] is Array && s["options"].Length > 0) {
                cond := Map("step", s["id"], "in", [s["options"][1]["id"]])
                break
            }
        if !(cond is Map)
            return AdminModel.Fail("A flag needs a step with options to look at.")
        if !cat.Has("flags")
            cat["flags"] := []
        id := AdminModel.NewId(message, AdminModel.IdsOf(cat["flags"]), "flag")
        cat["flags"].Push(Map("id", id, "message", message, "when", cond))
        this._Changed("flag")
        return AdminModel.Good({Id: id})
    }

    RemoveFlag(catId, flagId) {
        cat := this.Cat(catId)
        i := AdminModel.IdxOf(this.Flags(catId), flagId)
        if (i = 0)
            return AdminModel.Fail("That flag does not exist.")
        cat["flags"].RemoveAt(i)
        if (cat["flags"].Length = 0)
            cat.Delete("flags")
        this._Changed("flag")
        return AdminModel.Good()
    }

    MoveFlag(catId, flagId, dir) {
        fl := this.Flags(catId)
        if !AdminModel.MoveIn(fl, AdminModel.IdxOf(fl, flagId), dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("flag")
        return AdminModel.Good()
    }

    SetFlagMessage(catId, flagId, text) {
        f := AdminModel.Find(this.Flags(catId), flagId)
        if !(f is Map)
            return AdminModel.Fail("That flag does not exist.")
        f["message"] := String(text)
        this._Changed("flag")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- items categories
    EntryOf(catId) {
        c := this.Cat(catId)
        return (c is Map && c.Has("entry") && c["entry"] is Map) ? c["entry"] : ""
    }

    ; listKey: actions | items | outcomes
    List(catId, listKey) {
        e := this.EntryOf(catId)
        return (e is Map && e.Has(listKey) && e[listKey] is Array) ? e[listKey] : []
    }

    AddListItem(catId, listKey, label) {
        e := this.EntryOf(catId)
        if !(e is Map) || !Schema.InList(["actions", "items", "outcomes"], listKey)
            return AdminModel.Fail("That list does not exist.")
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name first.")
        if !e.Has(listKey)
            e[listKey] := []
        id := AdminModel.NewId(label, AdminModel.IdsOf(e[listKey]), listKey = "actions" ? "action" : (listKey = "items" ? "item" : "outcome"))
        o := Map("id", id, "label", label)
        if (listKey = "actions") {
            first := e[listKey].Length ? e[listKey][1] : ""
            o["fragment"] := (first is Map && first.Has("fragment")) ? first["fragment"] : AdminModel.ITEM_FRAGMENT
        } else if (listKey = "outcomes")
            o["fragment"] := ""
        e[listKey].Push(o)
        this._Changed("list")
        return AdminModel.Good({Id: id})
    }

    RemoveListItem(catId, listKey, id) {
        e := this.EntryOf(catId)
        if !(e is Map) || !e.Has(listKey) || !(e[listKey] is Array)
            return AdminModel.Fail("That list does not exist.")
        i := AdminModel.IdxOf(e[listKey], id)
        if (i = 0)
            return AdminModel.Fail("It does not exist.")
        if (listKey != "outcomes" && e[listKey].Length <= 1)
            return AdminModel.Fail("The list needs at least one entry.")
        if (listKey = "outcomes" && e[listKey].Length <= 1 && e.Has("outcomeRequired") && e["outcomeRequired"] = 1)
            return AdminModel.Fail("An outcome is required for each entry. Switch that off before removing the last outcome.")
        e[listKey].RemoveAt(i)
        this._Changed("list")
        return AdminModel.Good()
    }

    MoveListItem(catId, listKey, id, dir) {
        l := this.List(catId, listKey)
        if !AdminModel.MoveIn(l, AdminModel.IdxOf(l, id), dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("list")
        return AdminModel.Good()
    }

    ; key: label | fragment (items have no fragment)
    SetListItemProp(catId, listKey, id, key, val) {
        o := AdminModel.Find(this.List(catId, listKey), id)
        if !(o is Map)
            return AdminModel.Fail("It does not exist.")
        if (key != "label" && !(key = "fragment" && listKey != "items"))
            return AdminModel.Fail("Unknown property " key)
        o[key] := String(val)
        this._Changed("list")
        return AdminModel.Good()
    }

    ; key: qty | details | outcomeRequired. outcomeRequired needs at least one outcome.
    SetEntryFlag(catId, key, on) {
        e := this.EntryOf(catId)
        if !(e is Map) || !Schema.InList(["qty", "details", "outcomeRequired"], key)
            return AdminModel.Fail("Unknown setting " key)
        if (key = "outcomeRequired" && on && this.List(catId, "outcomes").Length = 0)
            return AdminModel.Fail("Add an outcome first: an outcome can't be required when there are none.")
        e[key] := on ? 1 : 0
        this._Changed("entry")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- static category (wording only)
    StaticOf(catId) {
        c := this.Cat(catId)
        return (c is Map && c.Has("static") && c["static"] is Map) ? c["static"] : ""
    }

    ; listKey: pingTargets | pingOutcomes. key: label | fragment (outcomes only). The ids are fixed.
    SetStaticProp(catId, listKey, id, key, val) {
        s := this.StaticOf(catId)
        if !(s is Map) || !s.Has(listKey)
            return AdminModel.Fail("That list does not exist.")
        o := AdminModel.Find(s[listKey], id)
        if !(o is Map)
            return AdminModel.Fail("It does not exist.")
        if (key != "label" && !(key = "fragment" && listKey = "pingOutcomes"))
            return AdminModel.Fail("Unknown property " key)
        o[key] := String(val)
        this._Changed("static")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- note template
    Tpl => this.Work["noteTemplate"]

    AddTemplateLine(text := "") {
        this.Tpl["lines"].Push(String(text))
        this._Changed("template")
        return AdminModel.Good()
    }

    RemoveTemplateLine(i) {
        l := this.Tpl["lines"]
        if (i < 1 || i > l.Length)
            return AdminModel.Fail("That line does not exist.")
        if (l.Length <= 1)
            return AdminModel.Fail("The template needs at least one line.")
        l.RemoveAt(i)
        this._Changed("template")
        return AdminModel.Good()
    }

    MoveTemplateLine(i, dir) {
        if !AdminModel.MoveIn(this.Tpl["lines"], i, dir)
            return AdminModel.Fail(dir < 0 ? "It is already first." : "It is already last.")
        this._Changed("template")
        return AdminModel.Good()
    }

    SetTemplateLine(i, text) {
        l := this.Tpl["lines"]
        if (i < 1 || i > l.Length)
            return AdminModel.Fail("That line does not exist.")
        l[i] := String(text)
        this._Changed("template")
        return AdminModel.Good()
    }

    ; key: unavailableText | fragmentJoiner | categoryJoiner | endPunctuation (text) | sentenceCase (bool)
    SetTemplateProp(key, val) {
        switch key {
        case "unavailableText", "fragmentJoiner", "categoryJoiner", "endPunctuation":
            this.Tpl[key] := String(val)
        case "sentenceCase":
            this.Tpl[key] := val ? 1 : 0
        default:
            return AdminModel.Fail("Unknown setting " key)
        }
        this._Changed("template")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- themes
    Presets => this.Work["themes"]["presets"]

    ; mode: light | dark; sheet: "spectrum" or a library look; accent #RRGGBB.
    AddPreset(label, sheet, mode, accent) {
        label := Util.Trim(label)
        if (label = "")
            return AdminModel.Fail("Type a name for the look first.")
        r := this.CheckPreset(sheet, mode, accent)
        if !r.Ok
            return r
        id := AdminModel.NewId(label, AdminModel.IdsOf(this.Presets), "look")
        this.Presets.Push(Map("id", id, "label", label, "sheet", StrLower(sheet), "mode", mode, "accent", StrUpper(accent)))
        this._Changed("theme")
        return AdminModel.Good({Id: id})
    }

    CheckPreset(sheet, mode, accent) {
        if !Schema.InList(Schema.SHEETS, StrLower(sheet))
            return AdminModel.Fail("Choose a look from the list.")
        if (mode != "light" && mode != "dark")
            return AdminModel.Fail("Mode must be light or dark.")
        if !RegExMatch(accent, "^#[0-9A-Fa-f]{6}$")
            return AdminModel.Fail("The accent colour must look like #0099D8 (a # and six hex digits).")
        return AdminModel.Good()
    }

    RemovePreset(id) {
        i := AdminModel.IdxOf(this.Presets, id)
        if (i = 0)
            return AdminModel.Fail("That look does not exist.")
        if (this.Presets.Length <= 1)
            return AdminModel.Fail("There must be at least one look.")
        if (this.Work["themes"]["default"] == id)
            return AdminModel.Fail("This is the default look. Choose another default first.")
        this.Presets.RemoveAt(i)
        this._Changed("theme")
        return AdminModel.Good()
    }

    ; key: label | sheet | mode | accent (checked; the accent is stored upper case)
    SetPresetProp(id, key, val) {
        p := AdminModel.Find(this.Presets, id)
        if !(p is Map)
            return AdminModel.Fail("That look does not exist.")
        switch key {
        case "label":
            p["label"] := String(val)
        case "sheet":
            r := this.CheckPreset(val, p["mode"], p["accent"])
            if !r.Ok
                return r
            p["sheet"] := StrLower(val)
        case "mode":
            r := this.CheckPreset(p["sheet"], val, p["accent"])
            if !r.Ok
                return r
            p["mode"] := val
        case "accent":
            r := this.CheckPreset(p["sheet"], p["mode"], Util.Trim(val))
            if !r.Ok
                return r
            p["accent"] := StrUpper(Util.Trim(val))
        default:
            return AdminModel.Fail("Unknown property " key)
        }
        this._Changed("theme")
        return AdminModel.Good()
    }

    SetDefaultPreset(id) {
        if (AdminModel.IdxOf(this.Presets, id) = 0)
            return AdminModel.Fail("That look does not exist.")
        this.Work["themes"]["default"] := id
        this._Changed("theme")
        return AdminModel.Good()
    }

    ; --------------------------------------------------------------------------------------------- numbers
    ; path: ping.timeoutMs | ping.attempts | ping.intervalMs | ping.untilSuccessMaxMin | callTracking.newCallDebounceMs |
    ; history.retentionDays. A value outside the bounds (or not a whole number) is refused.
    SetNumber(path, val) {
        if !AdminModel.BOUNDS.Has(path)
            return AdminModel.Fail("Unknown setting " path)
        b := AdminModel.BOUNDS[path]
        v := Util.Trim(val)
        if !RegExMatch(v, "^[0-9]{1,9}$") || Integer(v) < b[1] || Integer(v) > b[2]
            return AdminModel.Fail("Use a whole number from " b[1] " to " b[2] ".", {Min: b[1], Max: b[2]})
        parts := StrSplit(path, ".")
        this.Work[parts[1]][parts[2]] := Integer(v)
        this._Changed("number")
        return AdminModel.Good()
    }

    GetNumber(path) {
        parts := StrSplit(path, ".")
        return this.Work[parts[1]][parts[2]]
    }

    ; --------------------------------------------------------------------------------------------- conditions
    ; Step ids a condition mentions (deep).
    static CondSteps(c) {
        out := []
        if !(c is Map)
            return out
        if (c.Has("step") && c["step"] is String)
            out.Push(c["step"])
        for key in ["all", "any"]
            if (c.Has(key) && c[key] is Array)
                for sub in c[key]
                    for id in AdminModel.CondSteps(sub)
                        out.Push(id)
        return out
    }

    ; Flat view for the builder: {Simple, Mode: "all"|"any", Clauses: [{Step, Ins: []}]}. Simple is false for a nested
    ; condition (all/any inside all/any) or anything the builder can't show.
    static CondFlat(c) {
        f := {Simple: true, Mode: "all", Clauses: []}
        if !(c is Map)
            return f
        if (c.Has("step") || c.Has("in")) {
            if !(c.Has("step") && c.Has("in") && c["in"] is Array) || c.Has("all") || c.Has("any") {
                f.Simple := false
                return f
            }
            f.Clauses.Push(AdminModel._Leaf(c))
            return f
        }
        key := c.Has("all") ? "all" : (c.Has("any") ? "any" : "")
        if (key = "" || (c.Has("all") && c.Has("any")) || !(c[key] is Array)) {
            f.Simple := false
            return f
        }
        f.Mode := key
        for sub in c[key] {
            if !(sub is Map) || !sub.Has("step") || !(sub.Has("in") && sub["in"] is Array) || sub.Has("all") || sub.Has("any") {
                f.Simple := false
                return f
            }
            f.Clauses.Push(AdminModel._Leaf(sub))
        }
        return f
    }

    static _Leaf(c) {
        l := {Step: String(c["step"]), Ins: []}
        for v in c["in"]
            l.Ins.Push(String(v))
        return l
    }

    ; The condition for a flat view: "" for no clauses, a bare {step,in} for one, {all|any:[...]} for more.
    static FlatCond(f) {
        if (f.Clauses.Length = 0)
            return ""
        leaves := []
        for cl in f.Clauses {
            arr := []
            for v in cl.Ins
                arr.Push(v)
            leaves.Push(Map("step", cl.Step, "in", arr))
        }
        if (leaves.Length = 1)
            return leaves[1]
        return Map(f.Mode, leaves)
    }

    ; --- slots: where a condition lives. {K: "when", Cat, Step} | {K: "req", Cat, Step, Field} | {K: "flag", Cat, Flag}
    _SlotHolder(slot) {
        if (slot.K = "when")
            return this.Step(slot.Cat, slot.Step)
        if (slot.K = "req")
            return AdminModel.Find(this.Fields(slot.Cat, slot.Step), slot.Field)
        if (slot.K = "flag")
            return AdminModel.Find(this.Flags(slot.Cat), slot.Flag)
        return ""
    }

    static _SlotKey(slot) => slot.K = "req" ? "requiredWhen" : "when"

    GetCond(slot) {
        h := this._SlotHolder(slot)
        key := AdminModel._SlotKey(slot)
        return (h is Map && h.Has(key)) ? h[key] : ""
    }

    ; Steps a clause of this slot may look at: steps with options; for a step's own `when` only the steps ABOVE it.
    CondChoices(slot) {
        out := []
        steps := this.Steps(slot.Cat)
        limit := steps.Length + 1
        if (slot.K = "when")
            limit := AdminModel.IdxOf(steps, slot.Step)
        for i, s in steps
            if (i < limit && s is Map && s.Has("options") && s["options"] is Array && s["options"].Length > 0)
                out.Push(s)
        return out
    }

    ; Replace the condition. "" removes it (not allowed for a flag: a flag needs one).
    SetCond(slot, cond) {
        h := this._SlotHolder(slot)
        if !(h is Map)
            return AdminModel.Fail("That item does not exist.")
        key := AdminModel._SlotKey(slot)
        if (cond = "") {
            if (slot.K = "flag")
                return AdminModel.Fail("A flag needs a condition.")
            if h.Has(key)
                h.Delete(key)
        } else
            h[key] := cond
        this._Changed("cond")
        return AdminModel.Good()
    }

    ; op: add | del (a = clause index) | step (a = clause index, b = step id) | opt (a = clause, b = option id) | mode (a = all|any) | clear
    CondEdit(slot, op, a := "", b := "") {
        flat := AdminModel.CondFlat(this.GetCond(slot))
        if !flat.Simple
            return AdminModel.Fail("This condition is too complex for the builder. Use Edit as JSON.")
        switch op {
        case "add":
            ch := this.CondChoices(slot)
            if (ch.Length = 0)
                return AdminModel.Fail(slot.K = "when" ? "There is no step above this one to look at." : "There is no step with options to look at.")
            used := Map()
            for cl in flat.Clauses
                used[cl.Step] := true
            pick := ch[1]
            for s in ch
                if !used.Has(s["id"]) {
                    pick := s
                    break
                }
            flat.Clauses.Push({Step: pick["id"], Ins: [pick["options"][1]["id"]]})
        case "del":
            if (a < 1 || a > flat.Clauses.Length)
                return AdminModel.Fail("That clause does not exist.")
            flat.Clauses.RemoveAt(a)
        case "step":
            if (a < 1 || a > flat.Clauses.Length)
                return AdminModel.Fail("That clause does not exist.")
            s := this.Step(slot.Cat, b)
            if !(s is Map) || !s.Has("options") || s["options"].Length = 0
                return AdminModel.Fail("That step has no options.")
            flat.Clauses[a] := {Step: b, Ins: [s["options"][1]["id"]]}
        case "opt":
            if (a < 1 || a > flat.Clauses.Length)
                return AdminModel.Fail("That clause does not exist.")
            ins := flat.Clauses[a].Ins
            at := 0
            for i, v in ins
                if (v == b)
                    at := i
            if (at > 0)
                ins.RemoveAt(at)
            else
                ins.Push(b)
        case "mode":
            if (a != "all" && a != "any")
                return AdminModel.Fail("Choose All of or Any of.")
            flat.Mode := a
        case "clear":
            flat.Clauses := []
        default:
            return AdminModel.Fail("Unknown operation " op)
        }
        if (slot.K = "flag" && flat.Clauses.Length = 0)
            return AdminModel.Fail("A flag needs a condition.")
        return this.SetCond(slot, AdminModel.FlatCond(flat))
    }

    ; The condition as pretty JSON (for the read-only view / the JSON box).
    CondJson(slot) {
        c := this.GetCond(slot)
        return (c is Map) ? ConfigJson.Stringify(c) : ""
    }

    ; Apply condition JSON typed by the admin: parsed, checked by the schema's own condition rules, then applied.
    SetCondJson(slot, text) {
        text := Util.Trim(text)
        if (text = "")
            return this.SetCond(slot, "")
        try c := ConfigJson.Parse(text)
        catch as e
            return AdminModel.Fail("That is not valid JSON (" e.Message ").")
        steps := Map(), order := Map()
        for i, s in this.Steps(slot.Cat)
            if (s is Map && s.Has("id"))
                steps[s["id"]] := s, order[s["id"]] := i
        r := {Ok: false, Errors: [], Warnings: []}
        before := (slot.K = "when" && order.Has(slot.Step)) ? order[slot.Step] : 0
        Schema.Cond(r, c, "condition", steps, order, before)
        if (r.Errors.Length > 0)
            return AdminModel.Fail(r.Errors[1], {Errors: r.Errors})
        return this.SetCond(slot, c)
    }

    ; Human text for a condition: Order type is PWO or TC; all of / any of for several clauses.
    CondText(catId, c) {
        if !(c is Map)
            return "always"
        f := AdminModel.CondFlat(c)
        if !f.Simple
            return "(a nested condition)"
        parts := []
        for cl in f.Clauses {
            s := this.Step(catId, cl.Step)
            names := ""
            for v in cl.Ins {
                o := AdminModel.Find((s is Map && s.Has("options")) ? s["options"] : [], v)
                names .= (names = "" ? "" : " or ") (o is Map ? AdminModel.Label(o) : v)
            }
            parts.Push((s is Map ? AdminModel.Label(s) : cl.Step) " is " names)
        }
        txt := ""
        for i, p in parts
            txt .= (i = 1 ? "" : (f.Mode = "all" ? " and " : " or ")) p
        return txt
    }

    ; --------------------------------------------------------------------------------------------- references
    ; Where something is used. spec: {Kind: "option", Cat, Step, Option} | {Kind: "step", Cat, Step} | {Kind: "field", Cat, Field}.
    ; Returns [{Kind: when|requiredWhen|flag|keepSteps|placeholder, Text}] - Text names the place in words.
    FindReferences(spec) {
        out := []
        cat := this.Cat(spec.Cat)
        if !(cat is Map) || !(cat.Has("steps") && cat["steps"] is Array)
            return out
        cl := cat["label"]
        kind := spec.Kind
        stepId := spec.HasOwnProp("Step") ? spec.Step : ""
        optId := spec.HasOwnProp("Option") ? spec.Option : ""
        for s in cat["steps"] {
            if !(s is Map)
                continue
            sl := AdminModel.Label(s)
            own := (kind = "step" && s["id"] == stepId)
            if (s.Has("when") && !own && AdminModel._CondHits(s["when"], kind, stepId, optId))
                out.Push({Kind: "when", Text: cl " > " sl ": Show when " this.CondText(spec.Cat, s["when"])})
            if (s.Has("fields") && s["fields"] is Array)
                for f in s["fields"]
                    if (f is Map && f.Has("requiredWhen") && !own && AdminModel._CondHits(f["requiredWhen"], kind, stepId, optId))
                        out.Push({Kind: "requiredWhen", Text: cl " > " sl " > " AdminModel.Label(f) ": Required when " this.CondText(spec.Cat, f["requiredWhen"])})
            if (s.Has("options") && s["options"] is Array && !own && kind = "step")
                for o in s["options"]
                    if (o is Map && o.Has("stop") && o["stop"] is Map && o["stop"].Has("keepSteps") && o["stop"]["keepSteps"] is Array)
                        for id in o["stop"]["keepSteps"]
                            if (id == stepId)
                                out.Push({Kind: "keepSteps", Text: cl " > " sl " > " AdminModel.Label(o) ": keeps this step when it stops"})
        }
        if (cat.Has("flags") && cat["flags"] is Array)
            for fl in cat["flags"]
                if (fl is Map && fl.Has("when") && AdminModel._CondHits(fl["when"], kind, stepId, optId))
                    out.Push({Kind: "flag", Text: cl " > Flag " AdminModel.Label(fl) ": " this.CondText(spec.Cat, fl["when"])})
        ; {placeholders} in fragments
        names := []
        if (kind = "field")
            names.Push(spec.Field)
        else if (kind = "step") {
            names.Push(stepId)
            for f in this.Fields(spec.Cat, stepId)
                if (f is Map && f.Has("id"))
                    names.Push(f["id"])
        }
        for nm in names
            for loc in this._FragmentsOf(cat) {
                if InStr(loc.Get(), "{" nm "}") {
                    ; a step's own fragment mentioning its own field goes away with the step
                    if (kind = "step" && loc.Step == stepId)
                        continue
                    out.Push({Kind: "placeholder", Text: cl " > " loc.Where ": uses {" nm "}"})
                }
            }
        return out
    }

    ; Does condition c refer to the thing being removed? (kind option: this step AND this option; kind step: this step.)
    static _CondHits(c, kind, stepId, optId) {
        if !(c is Map)
            return false
        if c.Has("step") {
            if (kind = "field")
                return false
            if (c["step"] != stepId)
                return false
            if (kind = "step")
                return true
            if (c.Has("in") && c["in"] is Array)
                for v in c["in"]
                    if (v == optId)
                        return true
            return false
        }
        for key in ["all", "any"]
            if (c.Has(key) && c[key] is Array)
                for sub in c[key]
                    if AdminModel._CondHits(sub, kind, stepId, optId)
                        return true
        return false
    }

    ; Every fragment text of a steps category with a way to read and write it: [{Where, Step, Get(), Set(text)}].
    _FragmentsOf(cat) {
        out := []
        for s in cat["steps"] {
            if !(s is Map)
                continue
            sl := AdminModel.Label(s)
            out.Push(AdminModel._Frag(s, "fragment", sl " > fragment", s["id"]))
            if (s.Has("options") && s["options"] is Array)
                for o in s["options"] {
                    if !(o is Map)
                        continue
                    ol := AdminModel.Label(o)
                    out.Push(AdminModel._Frag(o, "fragment", sl " > " ol " > fragment", s["id"]))
                    if (o.Has("stop") && o["stop"] is Map)
                        out.Push(AdminModel._Frag(o["stop"], "fragment", sl " > " ol " > stop note", s["id"]))
                }
        }
        return out
    }

    static _Frag(holder, key, where, stepId) {
        h := holder, k := key
        return {Where: where, Step: stepId, Get: (*) => (h.Has(k) ? String(h[k]) : ""), Set: (self, txt) => (h[k] := txt)}
    }

    ; --- cleaning ---
    ; Remove a step from everything that mentions it (its own fields' {placeholders} too).
    _CleanStep(cat, s) {
        sid := s["id"]
        this._CleanCond(cat, sid, "")
        for st in cat["steps"]
            if (st is Map && st.Has("options") && st["options"] is Array)
                for o in st["options"]
                    if (o is Map && o.Has("stop") && o["stop"] is Map && o["stop"].Has("keepSteps") && o["stop"]["keepSteps"] is Array) {
                        keep := []
                        for id in o["stop"]["keepSteps"]
                            if (id != sid)
                                keep.Push(id)
                        o["stop"]["keepSteps"] := keep
                    }
        this._CleanPlaceholder(cat, sid)
        if (s.Has("fields") && s["fields"] is Array)
            for f in s["fields"]
                if (f is Map && f.Has("id"))
                    this._CleanPlaceholder(cat, f["id"])
    }

    ; Take option optId (or the whole step when optId is "") out of every condition of the category. A clause that loses its
    ; last option is removed; an all/any that becomes empty is removed; a when/requiredWhen left empty is deleted; a flag left
    ; without a condition is removed.
    _CleanCond(cat, stepId, optId) {
        for s in cat["steps"] {
            if !(s is Map)
                continue
            if (s.Has("when") && s["id"] != stepId) {
                r := AdminModel.CondClean(s["when"], stepId, optId)
                if (r = "")
                    s.Delete("when")
            }
            if (s.Has("fields") && s["fields"] is Array)
                for f in s["fields"]
                    if (f is Map && f.Has("requiredWhen")) {
                        r := AdminModel.CondClean(f["requiredWhen"], stepId, optId)
                        if (r = "")
                            f.Delete("requiredWhen")
                    }
        }
        if (cat.Has("flags") && cat["flags"] is Array) {
            keep := []
            for fl in cat["flags"] {
                if (fl is Map && fl.Has("when")) {
                    r := AdminModel.CondClean(fl["when"], stepId, optId)
                    if (r = "")
                        continue
                }
                keep.Push(fl)
            }
            if (keep.Length = 0)
                cat.Delete("flags")
            else
                cat["flags"] := keep
        }
    }

    ; In place. Returns the condition ("" when nothing is left of it).
    static CondClean(c, stepId, optId) {
        if !(c is Map)
            return ""
        if c.Has("step") {
            if (c["step"] != stepId)
                return c
            if (optId = "")
                return ""
            arr := []
            if (c.Has("in") && c["in"] is Array)
                for v in c["in"]
                    if (v != optId)
                        arr.Push(v)
            if (arr.Length = 0)
                return ""
            c["in"] := arr
            return c
        }
        for key in ["all", "any"]
            if (c.Has(key) && c[key] is Array) {
                keep := []
                for sub in c[key] {
                    r := AdminModel.CondClean(sub, stepId, optId)
                    if (r != "")
                        keep.Push(r)
                }
                if (keep.Length = 0)
                    return ""
                c[key] := keep
            }
        return c
    }

    ; Remove every {name} from the fragments of a category.
    _CleanPlaceholder(cat, name) {
        for loc in this._FragmentsOf(cat) {
            txt := loc.Get()
            if InStr(txt, "{" name "}")
                loc.Set(Util.Squeeze(StrReplace(txt, "{" name "}", "")))
        }
    }

    ; --------------------------------------------------------------------------------------------- placeholder chips
    ; The placeholders a fragment of this kind may use, as [{Text: "{x}", Hint}]. kind: template | steps | items | ping.
    Chips(kind, catId := "") {
        out := []
        if (kind = "items") {
            for p in ["action", "item", "qty", "details", "outcome"]
                out.Push({Text: "{" p "}", Hint: "the entry's " p})
        } else if (kind = "ping") {
            out.Push({Text: "{pingTarget}", Hint: "the chosen target's label"})
            out.Push({Text: "{pingAddress}", Hint: "that target's address"})
        } else if (kind = "steps") {
            cat := this.Cat(catId)
            if (cat is Map && cat.Has("steps") && cat["steps"] is Array)
                for s in cat["steps"]
                    if (s is Map && s.Has("id")) {
                        if (s.Has("options") && s["options"] is Array)
                            out.Push({Text: "{" s["id"] "}", Hint: "the option chosen in " AdminModel.Label(s)})
                        if (s.Has("fields") && s["fields"] is Array)
                            for f in s["fields"]
                                if (f is Map && f.Has("id"))
                                    out.Push({Text: "{" f["id"] "}", Hint: "what the agent types in " AdminModel.Label(f)})
                    }
        }
        for p in AdminModel.CTX_PH
            out.Push({Text: "{" p "}", Hint: "from the call"})
        if (kind = "template")
            out.Push({Text: "{notes}", Hint: "the combined notes of all categories"})
        return out
    }

    ; --------------------------------------------------------------------------------------------- validation
    ; Schema.Validate on the working copy with readable paths and a place to go to.
    Validate() {
        v := Schema.Validate(this.Work)
        items := []
        for e in v.Errors
            items.Push(this.Describe("error", e))
        for w in v.Warnings
            items.Push(this.Describe("warning", w))
        return {Ok: v.Ok, Errors: v.Errors, Warnings: v.Warnings, Items: items}
    }

    ; "categories[2].steps[1].options: duplicate id ..." -> {Level, Raw, Text, Nav}
    Describe(level, raw) {
        path := "", rest := raw
        if RegExMatch(raw, "^(categories) \((\w+)\): (.*)$", &m) {
            return {Level: level, Raw: raw, Text: "Category " this.CatLabel(m[2]) ": " m[3],
                Nav: {Page: "edit", Cat: m[2], Step: ""}}
        }
        if RegExMatch(raw, "^([A-Za-z0-9_\.\[\]]+): (.*)$", &m)
            path := m[1], rest := m[2]
        if (path = "")
            return {Level: level, Raw: raw, Text: raw, Nav: {Page: "check"}}
        return {Level: level, Raw: raw, Text: this.ReadablePath(path) ": " rest, Nav: this.NavFor(path)}
    }

    static KEYNAMES := Map("noteTemplate", "Note template", "callTracking", "Call tracking", "themes", "Looks", "history", "History",
        "contextFields", "Context fields", "categories", "Categories", "schemaVersion", "Schema version", "ping", "Ping",
        "pingTargets", "Ping targets", "pingOutcomes", "Ping outcomes", "static", "Static", "entry", "Entries", "keepSteps", "Kept steps",
        "actions", "Actions", "items", "Items", "outcomes", "Outcomes", "steps", "Steps", "options", "Options", "fields", "Fields", "flags", "Flags",
        "notePrefix", "Note prefix", "presets", "Looks", "lines", "Lines", "when", "Show when", "requiredWhen", "Required when")

    ReadablePath(path) {
        node := this.Work
        out := []
        for seg in StrSplit(path, ".") {
            if RegExMatch(seg, "^([A-Za-z0-9_]+)\[(\d+)\]$", &m) {
                child := (node is Map && node.Has(m[1])) ? node[m[1]] : ""
                idx := Integer(m[2])
                el := (child is Array && idx >= 1 && idx <= child.Length) ? child[idx] : ""
                if (el is Map)
                    out.Push(el.Has("label") && el["label"] != "" ? el["label"] : (el.Has("id") ? el["id"] : m[1] " " idx))
                else if (child is Array && idx >= 1 && idx <= child.Length)
                    out.Push("line " idx)
                else
                    out.Push(m[1] " " idx)
                node := el
            } else {
                out.Push(AdminModel.KEYNAMES.Has(seg) ? AdminModel.KEYNAMES[seg] : seg)
                node := (node is Map && node.Has(seg)) ? node[seg] : ""
            }
        }
        txt := ""
        for i, p in out
            txt .= (i = 1 ? "" : " > ") p
        return txt
    }

    ; Where the editor should go for a validation path: {Page, Cat, Step}.
    NavFor(path) {
        if RegExMatch(path, "^categories\[(\d+)\]", &m) {
            cats := this.Work.Has("categories") && this.Work["categories"] is Array ? this.Work["categories"] : []
            i := Integer(m[1])
            cid := (i >= 1 && i <= cats.Length && cats[i] is Map && cats[i].Has("id")) ? cats[i]["id"] : ""
            sid := ""
            if (cid != "" && RegExMatch(path, "\.steps\[(\d+)\]", &sm)) {
                st := this.Steps(cid)
                j := Integer(sm[1])
                if (j >= 1 && j <= st.Length && st[j] is Map && st[j].Has("id"))
                    sid := st[j]["id"]
            }
            if (cid = "")
                return {Page: "categories"}
            if (sid = "" && !RegExMatch(path, "^categories\[\d+\]\.(steps|flags|entry|static)"))
                return {Page: "categories", Cat: cid}
            return {Page: "edit", Cat: cid, Step: sid}
        }
        if (path = "categories" || InStr(path, "categories"))
            return {Page: "categories"}
        if InStr(path, "noteTemplate")
            return {Page: "template"}
        if RegExMatch(path, "^(themes|ping|callTracking|history)")
            return {Page: "settings"}
        return {Page: "raw"}
    }

    ; --------------------------------------------------------------------------------------------- saving
    ; Validate, then ConfigStore.Save. Kind: ok | invalid | locked | conflict | unreachable | verify | failed.
    ; The caller scans for conflict copies (ScanConflicts) before calling this and decides whether to go on.
    Save() {
        v := this.Validate()
        if !v.Ok
            return {Ok: false, Kind: "invalid", Error: "The configuration has " v.Errors.Length " error" (v.Errors.Length = 1 ? "" : "s") " and was not saved.",
                Errors: v.Errors, Items: v.Items, Revision: 0}
        if !IsObject(this.Store)
            return {Ok: false, Kind: "unreachable", Error: "No config store.", Revision: 0}
        r := this.Store.Save(this.Work)
        if r.Ok {
            this._Adopt()
            this._Log("info", "admin saved", {revision: r.Revision})
            this._Changed("save")
            return {Ok: true, Kind: "ok", Error: "", Revision: r.Revision}
        }
        res := this.Classify(r.Error)
        this._Log("warn", "admin save refused", {kind: res.Kind})
        return res
    }

    ; ConfigStore.Save's error text -> {Ok:false, Kind, Error, Holder, Machine, Since | By, At, Rev}
    Classify(err) {
        res := {Ok: false, Kind: "failed", Error: err, Revision: 0, Holder: "", Machine: "", Since: "", By: "", At: "", Rev: ""}
        if RegExMatch(err, "^Config is locked by (\S+)(?: on (\S+))? since (\S+)", &m) {
            res.Kind := "locked", res.Holder := m[1], res.Machine := m[2], res.Since := RTrim(m[3], ".")
        } else if RegExMatch(err, "^Config was changed by (.+?) at (\S+) \(r(\d+);", &m) {
            res.Kind := "conflict", res.By := m[1], res.At := m[2], res.Rev := m[3]
        } else if (InStr(err, "not reachable") || InStr(err, "No shared config folder"))
            res.Kind := "unreachable"
        else if InStr(err, "Verification of the temporary file failed")
            res.Kind := "verify"
        else if (SubStr(err, 1, 20) = "Config is not valid:")
            res.Kind := "invalid"
        return res
    }

    ; The text of a failed save as a short dialog (title + body). Kind "conflict" and "locked" name who and when.
    SaveMessage(res) {
        switch res.Kind {
        case "locked":
            return {Title: "The configuration is locked", Text: "Someone else is saving the configuration right now: "
                . res.Holder (res.Machine != "" ? " on " res.Machine : "") ", since " res.Since ".`n`nTry again in a few minutes. "
                . "A lock older than 30 minutes is taken over automatically."}
        case "conflict":
            return {Title: "The configuration changed", Text: "The configuration was changed by " res.By " at " res.At " (revision " res.Rev ").`n`n"
                . "Your changes were not saved. You can reload the newer version (your unsaved edits will be lost) or keep editing "
                . "(and copy your edits somewhere, for example with Export, before reloading)."}
        case "unreachable":
            return {Title: "The config folder can't be reached", Text: "The shared config folder is not reachable, so nothing was saved.`n`n"
                . "Check that OneDrive is running and the folder is synced, then try again. Your edits are still here."}
        case "verify":
            return {Title: "The file could not be verified", Text: "The new file did not read back correctly, so the existing configuration was left untouched.`n`n"
                . "Try again. If it keeps happening, check free disk space and OneDrive."}
        case "invalid":
            return {Title: "The configuration has errors", Text: res.Error "`n`nOpen the Check page to see them."}
        }
        return {Title: "Could not save", Text: res.Error}
    }

    ; --------------------------------------------------------------------------------------------- files
    ExportText() => ConfigJson.Stringify(this.Work)

    ; Parse + Schema.Migrate (incl. FillMissing) + validate a config file's text. {Ok, Error, Cfg, Summary}.
    ; Ok only when it parses, migrates and has no validation errors; Summary is filled whenever it parsed.
    ImportText(text) {
        res := {Ok: false, Error: "", Cfg: "", Summary: ""}
        text := String(text)
        if (Util.Trim(text) = "") {
            res.Error := "The file is empty."
            return res
        }
        try cfg := ConfigJson.Parse(text)
        catch as e {
            res.Error := "That is not a valid JSON file (" e.Message ")."
            return res
        }
        if !(cfg is Map) {
            res.Error := "That file does not hold a configuration (it is not a JSON object)."
            return res
        }
        m := Schema.Migrate(cfg)
        if (m.Error != "") {
            res.Error := "Can't use that file: " m.Error "."
            return res
        }
        v := Schema.Validate(m.Cfg)
        cats := []
        if (m.Cfg.Has("categories") && m.Cfg["categories"] is Array)
            for c in m.Cfg["categories"]
                if (c is Map && c.Has("label"))
                    cats.Push(c["label"])
        res.Summary := {Categories: cats, Revision: m.Cfg.Has("revision") ? m.Cfg["revision"] : 0,
            UpdatedBy: m.Cfg.Has("updatedBy") ? m.Cfg["updatedBy"] : "", From: m.From, To: m.To, Migrated: m.Changed,
            Errors: v.Errors, Warnings: v.Warnings}
        if !v.Ok {
            res.Error := "That configuration has " v.Errors.Length " error" (v.Errors.Length = 1 ? "" : "s") ": " Schema.Summary(v, 3)
            return res
        }
        res.Ok := true
        res.Cfg := m.Cfg
        return res
    }

    ; Replace the working copy. The revision stays the one we loaded so the save's conflict check still works.
    ApplyConfig(cfg) {
        c := Util.Clone(cfg)
        c["revision"] := this.Store.Revision
        this.Work := c
        this._Changed("replace")
        return AdminModel.Good()
    }

    RestoreDefaults() {
        c := Defaults.Config()
        c["updatedAt"] := this.Work.Has("updatedAt") ? this.Work["updatedAt"] : c["updatedAt"]
        c["updatedBy"] := this.Work.Has("updatedBy") ? this.Work["updatedBy"] : c["updatedBy"]
        return this.ApplyConfig(c)
    }

    ; The working copy as pretty JSON, and the other way: applied only when it parses AND validates.
    RawText() => ConfigJson.Stringify(this.Work)

    ApplyRaw(text) {
        r := this.ImportText(text)
        if !r.Ok
            return r
        this.ApplyConfig(r.Cfg)
        return r
    }

    ; Drop the unsaved edits (Reload without asking is the UI's job).
    Discard() {
        this.Load()
    }
}
