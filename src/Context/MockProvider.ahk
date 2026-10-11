#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\Provider.ahk
; MockProvider.ahk - fake technicians for development and tests. Kind "mock"; every present field has
; Status "mock". Dev controls are plain methods the DevPanel calls. No timers.
;
; Every value it produces is registered with the Logger as sensitive (full values and the first name),
; so none of it can reach the diagnostic log.

class MockProvider extends ContextProvider {
    static JOBS := [
        ["Jordan Smith", "T12345", "88412", "55-2231", "123 Example St, Mockville"],
        ["Casey Rivera", "T20417", "88390", "55-2198", "42 Sample Ave, Faketown"],
        ["Morgan LEE", "T31502", "88455", "55-2260", "7 Placeholder Rd, Testville"],
        ["alex nguyen", "T40088", "88471", "55-2284", "900 Demo Blvd, Nowhere City"],
        ["Taylor Brooks", "T51976", "88502", "55-2307", "15 Dummy Ln, Pretendton"],
        ["Riley Park", "T66231", "88519", "55-2331", "2 Fixture Ct, Mockburg"]
    ]
    static FIELD_ORDER := ["techName", "techId", "jobNumber", "workOrder", "address"]

    __New(opts := "") {
        super.__New(opts)
        this.Index := 1
        this.States := Map()              ; fieldId -> "unavailable" | "stale" | "empty"
        this.Healthy := true
        this.EventCount := 0              ; new-call events raised (for tests/dev panel)
    }

    Kind => "mock"

    Start() {
        super.Start()
        this._Register()
    }

    ; --- ContextProvider ---------------------------------------------------------
    GetContext() {
        ctx := CallContext()
        try {
            row := MockProvider.JOBS[this.Index]
            this._Register()
            for i, id in MockProvider.FIELD_ORDER {
                st := this.States.Has(id) ? this.States[id] : "normal"
                switch st {
                    case "unavailable": ctx.Set(id, "", "unavailable", "mock")
                    case "empty":       ctx.Set(id, "", "empty", "mock")
                    case "stale":       ctx.Set(id, row[i], "stale", "mock")
                    default:            ctx.Set(id, row[i], "mock", "mock")
                }
            }
        } catch as e {
            this._Log("error", "mock context failed", {error: e.Message})
            for id in CallContext.REQUIRED
                ctx.Set(id, "", "unavailable", "mock")
        }
        return ctx
    }

    Health() => this.Healthy ? {Ok: true, Message: "Mock provider running"}
        : {Ok: false, Message: "Mock provider set to unhealthy (dev)"}

    ; --- dev controls ------------------------------------------------------------
    ; Advance to the next fake technician/job and raise OnContextChanged then OnNewCall.
    ; Field states go back to normal (a new call is new data).
    FireNewCall() {
        this.Index := this.Index >= MockProvider.JOBS.Length ? 1 : this.Index + 1
        this.States := Map()
        this.EventCount += 1
        this.RaiseContextChanged()
        this.RaiseNewCall()
        return this
    }

    ; The same call reported again: OnNewCall only, same job.
    FireDuplicate() {
        this.EventCount += 1
        this.RaiseNewCall()
        return this
    }

    ; n events in quick succession for the same job.
    FireBurst(n := 5) {
        loop n
            this.FireDuplicate()
        return this
    }

    ; state: "unavailable" | "stale" | "empty" | "normal". Raises OnContextChanged.
    SetFieldState(id, state) {
        if !MockProvider._HasField(id)
            return false
        if !(state = "unavailable" || state = "stale" || state = "empty" || state = "normal")
            return false
        if (state = "normal")
            this.States.Delete(id)
        else
            this.States[id] := state
        this.RaiseContextChanged()
        return true
    }

    SetHealthy(ok) {
        this.Healthy := !!ok
        this.RaiseContextChanged()
        return this
    }

    ; --- internals ---------------------------------------------------------------
    static _HasField(id) {
        for x in MockProvider.FIELD_ORDER
            if (x = id)
                return true
        return false
    }

    _Register() {
        if !IsObject(this.Logger)
            return
        row := MockProvider.JOBS[this.Index]
        for v in row
            this.Logger.RegisterSensitive(v)
        first := StrSplit(Util.Squeeze(row[1]), " ")[1]
        this.Logger.RegisterSensitive(first)
    }
}
