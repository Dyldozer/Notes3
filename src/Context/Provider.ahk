#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\CallContext.ahk
; Provider.ahk - the ContextProvider contract (PLAN 5.2). MockProvider and (later) AppBarProvider extend it.
; Pure logic: no GUI.
;
;   p.Kind                 "mock" | "live"
;   p.Start() / p.Stop()
;   p.GetContext()         -> CallContext; never throws, failures become field Status
;   p.Health()             -> {Ok, Message}
;   p.OnContextChanged(fn) fn(ctx) when values update
;   p.OnNewCall(fn)        fn(ctx) the counted call boundary
;
; Several subscribers are allowed. A subscriber that throws is logged and does not stop the others.

class ContextProvider {
    __New(opts := "") {
        o := IsObject(opts) ? opts : {}
        this.Logger := o.HasOwnProp("Logger") ? o.Logger : ""
        this.Running := false
        this._changed := []
        this._newCall := []
    }

    Kind => "none"

    Start() {
        this.Running := true
    }

    Stop() {
        this.Running := false
    }

    GetContext() => CallContext()

    Health() => {Ok: true, Message: "OK"}

    OnContextChanged(fn) {
        this._changed.Push(fn)
        return this
    }

    OnNewCall(fn) {
        this._newCall.Push(fn)
        return this
    }

    ; --- for subclasses ----------------------------------------------------------
    RaiseContextChanged() => this._Raise(this._changed, "context changed")

    RaiseNewCall() => this._Raise(this._newCall, "new call")

    _Raise(subs, what) {
        ctx := this.GetContext()
        copy := []
        for fn in subs
            copy.Push(fn)                    ; a subscriber may add subscribers; iterate a copy
        failed := 0
        for fn in copy {
            try fn(ctx)
            catch as e {
                failed += 1
                this._Log("error", "subscriber failed on " what, {error: e.Message, line: e.Line})
            }
        }
        return copy.Length - failed
    }

    _Log(level, msg, data := unset) {
        if IsObject(this.Logger)
            try this.Logger.Write(level, msg, data?)
    }
}
