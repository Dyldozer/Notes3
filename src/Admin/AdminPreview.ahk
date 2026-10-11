#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\..\Context\CallContext.ahk
#Include %A_LineFile%\..\..\Call\CallSession.ahk
#Include %A_LineFile%\..\..\Workflow\Engine.ahk
#Include %A_LineFile%\..\..\Workflow\Items.ahk
#Include %A_LineFile%\..\..\Net\StaticModel.ahk
#Include %A_LineFile%\..\..\Notes\Composer.ahk
; AdminPreview.ahk - the live preview of the Admin companion (PLAN M10). Pure logic: no GUI.
;
; A fake call ("Sample Tech", "T00000", ...) and a CallSession that is driven exactly the way the main app drives its own:
; Choose / Type through the WorkflowEngine, entries through ItemsModel, the Static state through StaticModel, then
; Composer.Compose with the WORKING (unsaved) config. Engines and models are rebuilt from the working copy every time, so
; an edit shows at once; the sample answers stay (answers for things the edit removed are ignored, as in the main app).
;
;   pv := AdminPreview(model)             ; model: AdminModel (pv.Config can also be set to any config Map)
;   pv.Choose("notDone", "reason", "r1")
;   pv.Compose() -> {Text, Warnings, Extra}   Warnings = composer warnings; Extra = engine / items / static notes

class AdminPreview {
    static SAMPLE := Map("techName", "Sample Tech", "techId", "T00000", "address", "1 Sample St",
        "jobNumber", "00000", "workOrder", "WO-0000")

    __New(model := "") {
        this.Model := model
        this.Cfg := ""                      ; used when there is no model
        this.Session := CallSession()
        this.Unavailable := false
        this.Ctx := ""
        this.SetUnavailable(false)
    }

    Config => IsObject(this.Model) ? this.Model.Work : this.Cfg

    ; Mark every context field unavailable (or restore the sample values).
    SetUnavailable(on) {
        this.Unavailable := on ? true : false
        c := CallContext()
        for id, v in AdminPreview.SAMPLE
            if this.Unavailable
                c.Set(id, "", "unavailable", "mock")
            else
                c.Set(id, v, "mock", "mock")
        this.Ctx := c
        this.Session.Context := c.Clone()
        return this
    }

    Category(catId) {
        cfg := this.Config
        if (cfg is Map && cfg.Has("categories") && cfg["categories"] is Array)
            for c in cfg["categories"]
                if (c is Map && c.Has("id") && c["id"] == catId)
                    return c
        return ""
    }

    ; Enabled categories in config order: the ones the simulator offers.
    Categories() {
        out := []
        cfg := this.Config
        if (cfg is Map && cfg.Has("categories") && cfg["categories"] is Array)
            for c in cfg["categories"]
                if (c is Map && c.Has("id") && c.Has("kind") && !(c.Has("enabled") && !c["enabled"]))
                    out.Push(c)
        return out
    }

    Engine(catId) {
        c := this.Category(catId)
        return (c is Map && c.Has("kind") && c["kind"] = "steps") ? WorkflowEngine(c) : ""
    }

    ItemsModel(catId) {
        c := this.Category(catId)
        if !(c is Map) || !c.Has("kind") || c["kind"] != "items"
            return ""
        m := ItemsModel(c)
        this._Style(m)
        return m
    }

    StaticModel(catId) {
        c := this.Category(catId)
        if !(c is Map) || !c.Has("kind") || c["kind"] != "static"
            return ""
        m := StaticModel(c)
        this._Style(m)
        return m
    }

    ; the note template's switches, as App.ModelFor copies them
    _Style(m) {
        try {
            t := this.Config["noteTemplate"]
            m.SentenceCase := t["sentenceCase"] ? true : false
            m.EndPunct := t["endPunctuation"]
        }
    }

    ; --- simulating (mirrors App.SetOption / SetField / AddEntry / StaticSet) ---------------------------------------
    Choose(catId, stepId, optionId) {
        eng := this.Engine(catId)
        if !IsObject(eng)
            return false
        if (optionId != "" && !this.Session.IsUsed(catId))
            this.Session.UseCategory(catId)
        return this.Session.Choose(catId, stepId, String(optionId), eng)
    }

    Type(catId, stepId, fieldId, text) {
        eng := this.Engine(catId)
        if !IsObject(eng)
            return false
        if (Util.Trim(text) != "" && !this.Session.IsUsed(catId))
            this.Session.UseCategory(catId)
        return this.Session.Type(catId, stepId, fieldId, String(text), eng)
    }

    ; Add one sample entry to an items category: the next action/item pair in turn, an outcome when the category has them.
    AddSampleEntry(catId) {
        m := this.ItemsModel(catId)
        if !IsObject(m) || m.Actions.Length = 0 || m.Items.Length = 0
            return {Ok: false, Error: "This category has no actions or items yet."}
        n := this.Session.EntriesFor(catId).Length
        e := {action: m.Actions[Mod(n, m.Actions.Length) + 1]["id"], item: m.Items[Mod(n, m.Items.Length) + 1]["id"],
            qty: m.Qty ? String(n + 1) : "", outcome: "", details: m.Details ? "Sample details" : ""}
        if (m.Outcomes.Length > 0)
            e.outcome := m.Outcomes[Mod(n, m.Outcomes.Length) + 1]["id"]
        r := this.Session.AddEntry(catId, e, m)
        if r.Ok && !this.Session.IsUsed(catId)
            this.Session.UseCategory(catId)
        return r
    }

    ClearEntries(catId) {
        this.Session.ResetCategory(catId)
    }

    ResetCategory(catId) {
        this.Session.ResetCategory(catId)
    }

    ; Pick a ping outcome for the Static category (sample address 10.0.0.1/30 -> gateway 10.0.0.2).
    PickPing(catId, outcomeId, targetId := "gateway") {
        m := this.StaticModel(catId)
        if !IsObject(m)
            return false
        old := this.Session.StaticFor(catId)
        patch := {ipText: "10.0.0.1/30", pingTarget: targetId, pingOutcome: outcomeId}
        nxt := m.Apply(old, patch)
        this.Session.SetStatic(catId, nxt, m)
        if (StaticModel.AddsToNote(nxt) && !this.Session.IsUsed(catId))
            this.Session.UseCategory(catId)
        else if (outcomeId = "" && !StaticModel.AddsToNote(nxt) && this.Session.IsUsed(catId))
            this.Session.ResetCategory(catId)
        return true
    }

    ; Throw away every sample answer.
    Clear() {
        this.Session.Reset()
    }

    ; --- composing -----------------------------------------------------------------------------------------------------
    ; Rebuild every category's fragments from the working config (so an edit shows), forget what the config no longer has,
    ; then compose. Extra holds notes from the engines/models (unknown ids, skipped entries).
    Compose() {
        extra := []
        keepUsed := []
        known := Map()
        for c in this.Categories()
            known[c["id"]] := true
        for id in this.Session.UsedCategories()
            if known.Has(id)
                keepUsed.Push(id)
        this.Session.Used := keepUsed
        for c in this.Categories() {
            id := c["id"]
            if !this.Session.IsUsed(id)
                continue
            if (c["kind"] = "steps") {
                r := this.Session.ApplyEngine(id, WorkflowEngine(c))
                for w in r.Warnings
                    extra.Push(c["label"] ": " w)
            } else if (c["kind"] = "items") {
                r := this.Session.ApplyEntries(id, this.ItemsModel(id))
                for w in r.Warnings
                    extra.Push(c["label"] ": " w)
            } else if (c["kind"] = "static") {
                r := this.Session.ApplyStatic(id, this.StaticModel(id))
                for w in r.Warnings
                    extra.Push(c["label"] ": " w)
            }
        }
        res := Composer.Compose(this.Session.Context, this.Session, this.Config)
        return {Text: res.Text, Warnings: res.Warnings, Extra: extra}
    }

    ; The engine's view of a steps category with the current sample answers (for the simulator page).
    Analyse(catId) {
        eng := this.Engine(catId)
        if !IsObject(eng)
            return ""
        ans := this.Session.AnswersFor(catId)
        a := eng.Analyse(ans)
        return {Eng: eng, A: a, Answers: ans, Flags: eng.Flags(ans), Valid: eng.Validate(ans)}
    }
}
