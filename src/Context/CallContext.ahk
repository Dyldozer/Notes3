#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; CallContext.ahk - the technician/job values for one call, each with a status (PLAN 5.1).
; Pure logic: no GUI.
;
; Rule: Value is "" only when Status is "empty" or "unavailable" (and those two always have "").
; A value typed by the agent is Status "manual" and is never shown as live.

class ContextField {
    __New(value := "", status := "empty", source := "", readAt := "") {
        this.Value := value
        this.Status := status
        this.Source := source
        this.ReadAt := readAt != "" ? readAt : A_Now
    }

    Clone() => ContextField(this.Value, this.Status, this.Source, this.ReadAt)

    ; True when the agent may type a value over this field.
    Editable => CallContext.IsEditableStatus(this.Status)
}

class CallContext {
    static STATUSES := ["live", "mock", "manual", "unavailable", "stale", "empty", "history"]
    static REQUIRED := ["techName", "techId", "address", "jobNumber", "workOrder"]

    static IsStatus(s) {
        for x in CallContext.STATUSES
            if (x = s)
                return true
        return false
    }

    static IsEditableStatus(s) => s = "unavailable" || s = "empty" || s = "stale"

    ; Every required field starts as empty.
    __New() {
        this.Fields := Map()
        for id in CallContext.REQUIRED
            this.Fields[id] := ContextField("", "empty", "")
    }

    Has(id) => this.Fields.Has(id)

    Get(id) => this.Fields.Has(id) ? this.Fields[id] : ""

    Value(id) => this.Fields.Has(id) ? this.Fields[id].Value : ""

    Status(id) => this.Fields.Has(id) ? this.Fields[id].Status : ""

    Ids() {
        out := []
        for id, f in this.Fields
            out.Push(id)
        return out
    }

    ; Set a field, enforcing the value/status rule: an unknown status or a blank value becomes "empty";
    ; "empty"/"unavailable" never carry a value.
    Set(id, value, status, source := "", readAt := "") {
        value := value = "" ? "" : String(value)
        if !CallContext.IsStatus(status)
            status := "empty"
        if (status = "empty" || status = "unavailable")
            value := ""
        else if (value = "")
            status := "empty"
        this.Fields[id] := ContextField(value, status, source, readAt)
        return this
    }

    ; The agent types a value over an unavailable / empty / stale field. Refused (false) for any other
    ; status, an unknown field, or a blank value.
    SetManual(id, value) {
        if !this.Fields.Has(id)
            return false
        value := Util.Trim(value)
        if (value = "" || !this.Fields[id].Editable)
            return false
        this.Fields[id] := ContextField(value, "manual", "agent")
        return true
    }

    Clone() {
        c := CallContext()
        c.Fields := Map()
        for id, f in this.Fields
            c.Fields[id] := f.Clone()
        return c
    }

    ; Take a provider update but keep the agent's manual entries where the provider still has nothing
    ; usable (unavailable / empty / stale). A fresh live/mock value replaces a manual one.
    MergeProvider(ctx) {
        merged := Map()
        for id, f in ctx.Fields {
            old := this.Fields.Has(id) ? this.Fields[id] : ""
            if (IsObject(old) && old.Status = "manual" && f.Editable)
                merged[id] := old
            else
                merged[id] := f.Clone()
        }
        this.Fields := merged
        return this
    }
}
