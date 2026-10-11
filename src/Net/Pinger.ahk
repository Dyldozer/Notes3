#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\Ipv4.ahk
; Pinger.ahk - asynchronous ICMP echo ("ping") for the Static page (PLAN section 7). No shell command is ever run: the
; Windows ICMP API is called directly (iphlpapi IcmpSendEcho2 with an event handle) and polled from a 50 ms timer.
;
; Three layers:
;   PingRun      pure, headless state machine. Modes "count" (N attempts, one per intervalMs) and "untilSuccess" (one attempt
;                per intervalMs until the first reply or the cap). Talks to an injectable BACKEND and an injectable CLOCK, so the
;                unit tests need no network and no real time.
;                  backend.Send(targetInt, timeoutMs)  -> token            (throws when the request cannot even be started)
;                  backend.Poll(token)                 -> "" while pending, else {Ok, Status, Address, RttMs, Reason}
;                  backend.Release(token)              frees the reply buffer / event; called ONLY after Poll reported
;                                                      completion, or after timeout + MARGIN_MS (the request is then over)
;                  backend.Close()                     optional; called once when the run has fully drained
;                clock: any callable returning milliseconds (default A_TickCount).
;   IcmpBackend  the real DllCall implementation of that backend interface.
;   Pinger       facade: owns the 50 ms timer, one current run, starts / cancels runs, keeps cancelled runs ticking until
;                their in-flight request is released, and cleans up on exit.
;
; Success is counted ONLY for a reply with status IP_SUCCESS (0) whose address equals the target. Everything else is a
; failed attempt with a plain-English reason.
;
; Config bounds are enforced here in code (PLAN 5.5), whatever the config file says:
;   timeoutMs 200-5000 (1000)   attempts 1-20 (4)   intervalMs 250-10000 (1000)   untilSuccessMaxMin 1-30 (10)

class PingRun {
    static MARGIN_MS := 1000             ; extra time an in-flight request is trusted to finish after its timeout
    static MAX_LINES := 200
    static DEFAULTS := Map("timeoutMs", 1000, "attempts", 4, "intervalMs", 1000, "untilSuccessMaxMin", 10)
    static LIMITS := Map("timeoutMs", [200, 5000], "attempts", [1, 20], "intervalMs", [250, 10000], "untilSuccessMaxMin", [1, 30])
    static _seq := 0

    ; One bounded integer from a config section (Map or object). Missing / not a number -> the default; out of range -> clamped.
    static Bound(cfg, key) {
        raw := ""
        try {
            if (cfg is Map)
                raw := cfg.Has(key) ? cfg[key] : ""
            else if IsObject(cfg)
                raw := cfg.HasOwnProp(key) ? cfg.%key% : ""
        }
        lim := PingRun.LIMITS[key]
        if (IsObject(raw) || !IsNumber(raw))
            return PingRun.DEFAULTS[key]
        v := Integer(Round(raw))
        return Max(lim[1], Min(lim[2], v))
    }

    ; opts: Mode "count"|"untilSuccess", Target (int), Cfg (Map/object with the four ping keys), Backend, Clock,
    ;       CapMs (selftest / test hook: overrides the untilSuccess cap, bypassing the whole-minute bounds), Owner (free tag)
    __New(opts) {
        PingRun._seq += 1
        this.Id := PingRun._seq
        this.Mode := (opts.HasOwnProp("Mode") && opts.Mode = "untilSuccess") ? "untilSuccess" : "count"
        this.Target := opts.Target
        cfg := opts.HasOwnProp("Cfg") ? opts.Cfg : ""
        this.TimeoutMs := PingRun.Bound(cfg, "timeoutMs")
        this.Attempts := this.Mode = "count" ? PingRun.Bound(cfg, "attempts") : 0
        this.IntervalMs := PingRun.Bound(cfg, "intervalMs")
        this.MaxMin := PingRun.Bound(cfg, "untilSuccessMaxMin")
        this.CapMs := (opts.HasOwnProp("CapMs") && IsInteger(opts.CapMs) && opts.CapMs > 0) ? opts.CapMs : this.MaxMin * 60000
        this.Backend := opts.Backend
        this.Clock := opts.HasOwnProp("Clock") ? opts.Clock : PingRun.TickNow
        this.Owner := opts.HasOwnProp("Owner") ? opts.Owner : ""
        this.Status := "idle"            ; idle | running | succeeded | failed | cancelled | error
        this.Started := 0                ; attempts sent
        this.Done := 0                   ; attempts that came back (counted in the result)
        this.Successes := 0
        this.Last := ""                  ; {Ok, Text, Short, Status, RttMs}
        this.Lines := []
        this.LineSeq := 0                ; grows with every console line (a cheap "did it change" marker)
        this.Error := ""
        this._t0 := 0
        this._endAt := 0
        this._tok := ""
        this._sentAt := 0
        this._nextAt := 0
        this._orph := []                 ; cancelled in-flight requests: {Tok, Deadline}
        this._closed := false
        this._doneFired := false
        this._inTick := false
        this._lastSec := -1
        this._upd := []
        this._don := []
    }

    static TickNow := () => A_TickCount

    OnUpdate(fn) {
        this._upd.Push(fn)
        return this
    }

    OnDone(fn) {
        this._don.Push(fn)
        return this
    }

    TargetText => Ipv4.ToText(this.Target)
    Running => this.Status = "running"
    ; Finished AND nothing of it is still in flight: the backend was closed.
    Drained => this._closed
    Pending => IsObject(this._tok) ? 1 : 0
    Orphans => this._orph.Length

    Now() => this.Clock.Call()

    Elapsed() {
        if (this.Status = "idle")
            return 0
        return Max(0, (this.Status = "running" ? this.Now() : this._endAt) - this._t0)
    }

    Result() => {Status: this.Status, Attempts: this.Done, Successes: this.Successes, AnyReply: this.Successes > 0,
        Cancelled: this.Status = "cancelled", Elapsed: this.Elapsed(), Target: this.TargetText, Error: this.Error}

    ; --- lifecycle ------------------------------------------------------------------------------------------------
    Start() {
        if (this.Status != "idle")
            return false
        this._t0 := this.Now()
        this.Status := "running"
        this._nextAt := this._t0
        this._lastSec := 0
        this._Fire()
        this.Tick()                                  ; the first attempt goes out now, not at the next timer tick
        return true
    }

    ; Stop scheduling and show "Cancelled" at once. An attempt that is already in flight keeps its buffer and event until
    ; it completes (or timeout + margin passes): the OS may still write into that buffer.
    Cancel() {
        if (this.Status != "running")
            return false
        if IsObject(this._tok) {
            this._orph.Push({Tok: this._tok, Deadline: this._sentAt + this.TimeoutMs + PingRun.MARGIN_MS})
            this._tok := ""
        }
        this._Finish("cancelled")
        return true
    }

    ; Call every ~50 ms. Never throws.
    Tick() {
        if this._inTick
            return
        this._inTick := true
        try {
            this._Step()
        } catch as e {
            this.Error := "Internal error: " e.Message
            if (this.Status = "running")
                this._Finish("error")
        } finally
            this._inTick := false
    }

    _Step() {
        now := this.Now()
        this._DrainOrphans(now)
        if (this.Status = "running") {
            if IsObject(this._tok) {
                r := this.Backend.Poll(this._tok)
                if IsObject(r)
                    this._Complete(r, now)
                else if (now - this._sentAt >= this.TimeoutMs + PingRun.MARGIN_MS)
                    this._Complete({Ok: false, Status: 11010, Address: 0, RttMs: 0, Reason: ""}, now)    ; the backend never answered: a timeout
            }
            if (this.Status = "running" && !IsObject(this._tok)) {
                if (this.Mode = "untilSuccess" && now - this._t0 >= this.CapMs)
                    this._Finish("failed")
                else if (this.Mode = "count" && this.Started >= this.Attempts)
                    this._Finish(this.Successes > 0 ? "succeeded" : "failed")
                else if (now >= this._nextAt)
                    this._Send(now)
            }
            if (this.Status = "running") {
                sec := (now - this._t0) // 1000
                if (sec != this._lastSec) {
                    this._lastSec := sec
                    this._Fire()
                }
            }
        }
        this._Finalize()
    }

    _Send(now) {
        try {
            tok := this.Backend.Send(this.Target, this.TimeoutMs)
        } catch as e {
            this.Error := "Could not send the ping: " e.Message
            this._Add("Could not send the ping: " e.Message)
            this._Finish("error")
            return
        }
        this._tok := tok
        this._sentAt := now
        this._nextAt := now + this.IntervalMs         ; one attempt per interval, measured from the previous attempt's start
        this.Started += 1
        this._Fire()
    }

    ; An attempt came back. Only status 0 from the target address counts as a reply.
    _Complete(r, now) {
        tok := this._tok
        this._tok := ""
        try this.Backend.Release(tok)
        st := 11050
        try st := Integer(r.Status)
        addr := 0
        try addr := Integer(r.Address)
        rtt := 0
        try rtt := Integer(r.RttMs)
        reason := ""
        try reason := r.Reason
        tgt := this.TargetText
        this.Done += 1
        if (st = 0 && addr = this.Target) {
            this.Successes += 1
            t := rtt < 1 ? "<1" : rtt
            this.Last := {Ok: true, Text: "Reply from " tgt ": time " t " ms", Short: "Reply " t " ms", Status: 0, RttMs: rtt}
        } else if (st = 0) {
            this.Last := {Ok: false, Text: "Reply from a different address (" Ipv4.ToText(addr) ") " Chr(0x2014) " not counted",
                Short: "Wrong address", Status: 0, RttMs: 0}
        } else {
            d := PingRun.Describe(st, reason)
            txt := st = 11010 ? "No reply (timed out after " this.TimeoutMs " ms)" : d.Text
            if (st != 11010 && addr != 0 && addr != this.Target)
                txt .= " (reported by " Ipv4.ToText(addr) ")"
            this.Last := {Ok: false, Text: txt, Short: d.Short, Status: st, RttMs: 0}
        }
        this._Add(this.Last.Text)
        if (this.Mode = "count" && this.Done >= this.Attempts)
            this._Finish(this.Successes > 0 ? "succeeded" : "failed")
        else if (this.Mode = "untilSuccess" && this.Successes > 0)
            this._Finish("succeeded")
        else if (this.Mode = "untilSuccess" && now - this._t0 >= this.CapMs)
            this._Finish("failed")
        else
            this._Fire()
    }

    _Finish(status) {
        if (this.Status != "running")
            return
        this._endAt := this.Now()
        this.Status := status
        switch status {
            case "cancelled": this._Add("Cancelled")
            case "succeeded":
                this._Add(this.Mode = "count" ? "Finished: " this.Successes " of " this.Done " attempts got a reply."
                    : "Finished: reply received after " this.Done " attempt" (this.Done = 1 ? "" : "s") ".")
            case "failed":
                this._Add(this.Mode = "count" ? "Finished: no reply to " this.Done " attempt" (this.Done = 1 ? "" : "s") "."
                    : "Finished: no reply after " PingRun.MmSs(this.CapMs) " (" this.Done " attempt" (this.Done = 1 ? "" : "s") ").")
        }
        this._Fire()
        if !this._doneFired {
            this._doneFired := true
            res := this.Result()
            for fn in this._don.Clone()
                try fn(res)
        }
        this._Finalize()
    }

    ; Cancelled requests: release each only after it completed or its deadline passed.
    _DrainOrphans(now) {
        i := this._orph.Length
        while (i >= 1) {
            o := this._orph[i]
            done := false
            try done := IsObject(this.Backend.Poll(o.Tok))
            if (done || now >= o.Deadline) {
                try this.Backend.Release(o.Tok)
                this._orph.RemoveAt(i)
            }
            i -= 1
        }
    }

    _Finalize() {
        if (this._closed || this.Status = "idle" || this.Status = "running" || IsObject(this._tok) || this._orph.Length > 0)
            return
        this._closed := true
        try if HasMethod(this.Backend, "Close")
            this.Backend.Close()
    }

    _Fire() {
        for fn in this._upd.Clone()
            try fn(this)
    }

    _Add(line) {
        this.Lines.Push(line)
        while (this.Lines.Length > PingRun.MAX_LINES)
            this.Lines.RemoveAt(1)
        this.LineSeq += 1
    }

    ; mm:ss
    static MmSs(ms) {
        s := ms // 1000
        return Format("{:02}:{:02}", s // 60, Mod(s, 60))
    }

    ; --- text for the status line ------------------------------------------------------------------------------------
    ; count:  "Attempt 3 of 4 · last: Reply 3 ms · 00:03 · Running…"
    ; until:  "Attempt 12 · 00:12 / 10:00 · Waiting for a reply…"
    StatusText() {
        dot := " " Chr(0xB7) " "
        if (this.Status = "idle")
            return ""
        n := Max(this.Started, 1)
        last := IsObject(this.Last) ? dot "last: " this.Last.Short : ""
        if (this.Mode = "count") {
            head := "Attempt " Min(n, this.Attempts) " of " this.Attempts
            tail := PingRun.MmSs(this.Elapsed()) dot
        } else {
            head := "Attempt " n
            tail := PingRun.MmSs(this.Elapsed()) " / " PingRun.MmSs(this.CapMs) dot
            last := ""
        }
        switch this.Status {
            case "running": tailTxt := this.Mode = "count" ? "Running" Chr(0x2026) : "Waiting for a reply" Chr(0x2026)
            case "succeeded": tailTxt := "Reply received"
            case "failed": tailTxt := "No reply"
            case "cancelled": tailTxt := "Cancelled"
            default: tailTxt := "Could not ping: " this.Error
        }
        return head last dot tail tailTxt
    }

    ; IP_STATUS code -> {Text (console line), Short (status line)}.
    static Describe(status, reason := "") {
        switch status {
            case 11002: return {Text: "Destination network unreachable", Short: "Unreachable"}
            case 11003: return {Text: "Destination host unreachable", Short: "Unreachable"}
            case 11004: return {Text: "Destination protocol unreachable", Short: "Unreachable"}
            case 11005: return {Text: "Destination port unreachable", Short: "Unreachable"}
            case 11006: return {Text: "The computer ran out of resources for the ping", Short: "No resources"}
            case 11008: return {Text: "Hardware error while pinging", Short: "Hardware error"}
            case 11009: return {Text: "Packet too big", Short: "Packet too big"}
            case 11010: return {Text: "No reply (timed out)", Short: "No reply"}
            case 11011: return {Text: "Bad request", Short: "Bad request"}
            case 11012: return {Text: "Bad route", Short: "Bad route"}
            case 11013: return {Text: "Time to live expired in transit", Short: "TTL expired"}
            case 11014: return {Text: "Time to live expired while reassembling", Short: "TTL expired"}
            case 11015: return {Text: "Parameter problem reported", Short: "Parameter problem"}
            case 11016: return {Text: "Source quench: the network is busy", Short: "Network busy"}
            case 11018: return {Text: "Bad destination", Short: "Bad destination"}
            case 11050: return {Text: "Ping failed (general failure)" (reason != "" ? ": " reason : ""), Short: "Failed"}
        }
        return {Text: "Ping failed (code " status ")" (reason != "" ? ": " reason : ""), Short: "Failed"}
    }
}

; ----------------------------------------------------------------------------------------------------------------------
; The real backend: iphlpapi ICMP through DllCall. One IcmpCreateFile handle per instance (the Pinger makes one per run); it
; is closed by Close() once the run has fully drained.
;
; ICMP_ECHO_REPLY on 64-bit Windows (what the reply buffer starts with; 40 bytes):
;     0  ULONG   Address        reply source, IPAddr = network byte order (1.2.3.4 -> 0x04030201)
;     4  ULONG   Status         IP_STATUS: 0 = IP_SUCCESS, 11010 = timed out, 11002.. unreachable, 11013 TTL expired ...
;     8  ULONG   RoundTripTime  ms
;    12  USHORT  DataSize       bytes of echoed data
;    14  USHORT  Reserved
;    16  PVOID   Data           8 bytes (pointer)
;    24  IP_OPTION_INFORMATION Options (UCHAR Ttl@24 Tos@25 Flags@26 OptionsSize@27, 4 bytes pad, PVOID OptionsData@32)
; The buffer must hold sizeof(ICMP_ECHO_REPLY) + request data + 8 (ICMP error message) + 16 (IO_STATUS_BLOCK) at least;
; REPLY_SIZE below is more than twice that.
class IcmpBackend {
    static REQ_SIZE := 32
    static REPLY_SIZE := 256
    static Outstanding := 0             ; requests sent and not yet released (diagnostics / selftest: must return to 0)
    static Pinned := []                 ; module handles of the DLLs we keep loaded (see Pin)
    static Graveyard := []              ; requests released while the OS still owned them: kept alive on purpose, never freed

    __New() {
        this.Handle := 0
    }

    ; 32-bit byte swap: host-order integer of a.b.c.d (a in the top byte) <-> IPAddr (a in the lowest byte). 1.2.3.4 <-> 0x04030201.
    static Swap32(n) => ((n & 255) << 24) | (((n >> 8) & 255) << 16) | (((n >> 16) & 255) << 8) | ((n >> 24) & 255)
    static ToIPAddr(n) => IcmpBackend.Swap32(n)
    static FromIPAddr(a) => IcmpBackend.Swap32(a)

    ; IMPORTANT: keep iphlpapi.dll loaded for the whole run of the program. DllCall("iphlpapi\Func") loads the DLL for the call
    ; and lets it go again afterwards; an asynchronous request completes LATER, inside iphlpapi code on a worker thread, and by
    ; then the DLL has been unloaded: the process crashes (0xC0000005 in "iphlpapi.DLL_unloaded") or the wait never ends. We
    ; therefore LoadLibrary it ourselves once and never free it. WINNSI.DLL (loaded lazily by the ICMP code) is pinned too.
    static Pin() {
        if IcmpBackend.Pinned.Length
            return
        for dll in ["iphlpapi.dll", "winnsi.dll"]
            try IcmpBackend.Pinned.Push(DllCall("kernel32\LoadLibraryW", "str", dll, "ptr"))
    }

    _Open() {
        if this.Handle
            return
        IcmpBackend.Pin()
        h := DllCall("iphlpapi\IcmpCreateFile", "ptr")
        if (h = 0 || h = -1)
            throw Error("IcmpCreateFile failed (Windows error " A_LastError ")")
        this.Handle := h
    }

    Close() {
        if this.Handle {
            DllCall("iphlpapi\IcmpCloseHandle", "ptr", this.Handle)
            this.Handle := 0
        }
    }

    Send(target, timeoutMs) {
        this._Open()
        ev := DllCall("kernel32\CreateEventW", "ptr", 0, "int", 1, "int", 0, "ptr", 0, "ptr")
        if !ev
            throw Error("CreateEvent failed (Windows error " A_LastError ")")
        tok := {Event: ev, Buf: Buffer(IcmpBackend.REPLY_SIZE, 0), Data: Buffer(IcmpBackend.REQ_SIZE, 0), Result: "", Released: false}
        loop IcmpBackend.REQ_SIZE
            NumPut("uchar", 97 + Mod(A_Index - 1, 23), tok.Data, A_Index - 1)
        ret := DllCall("iphlpapi\IcmpSendEcho2", "ptr", this.Handle, "ptr", ev, "ptr", 0, "ptr", 0,
            "uint", IcmpBackend.ToIPAddr(target), "ptr", tok.Data, "ushort", IcmpBackend.REQ_SIZE, "ptr", 0,
            "ptr", tok.Buf, "uint", IcmpBackend.REPLY_SIZE, "uint", timeoutMs, "uint")
        err := A_LastError
        IcmpBackend.Outstanding += 1
        if (ret = 0 && err != 997) {            ; 997 = ERROR_IO_PENDING (the normal asynchronous answer); anything else: not started
            st := (err >= 11000 && err < 12000) ? err : (err = 1231 ? 11002 : (err = 1232 ? 11003 : 11050))
            tok.Result := {Ok: false, Status: st, Address: 0, RttMs: 0, Reason: st = 11050 ? "Windows error " err : ""}
        }
        return tok
    }

    ; "" while the request is pending; else the parsed reply (cached in the token).
    Poll(tok) {
        if IsObject(tok.Result)
            return tok.Result
        w := DllCall("kernel32\WaitForSingleObject", "ptr", tok.Event, "uint", 0, "uint")
        if (w = 258)                              ; WAIT_TIMEOUT: still in flight
            return ""
        if (w != 0) {                             ; WAIT_FAILED / abandoned: give up on it
            tok.Result := {Ok: false, Status: 11050, Address: 0, RttMs: 0, Reason: "Wait failed (" w ")"}
            return tok.Result
        }
        n := DllCall("iphlpapi\IcmpParseReplies", "ptr", tok.Buf, "uint", IcmpBackend.REPLY_SIZE, "uint")
        if (n > 0) {
            addr := IcmpBackend.FromIPAddr(NumGet(tok.Buf, 0, "uint"))
            st := NumGet(tok.Buf, 4, "uint")
            rtt := NumGet(tok.Buf, 8, "uint")
            tok.Result := {Ok: st = 0, Status: st, Address: addr, RttMs: rtt, Reason: ""}
        } else {
            err := A_LastError                    ; no reply parsed: the error is the IP_STATUS (normally 11010, timed out)
            st := (err >= 11000 && err < 12000) ? err : 11050
            tok.Result := {Ok: false, Status: st, Address: 0, RttMs: 0, Reason: st = 11050 ? "Windows error " err : ""}
        }
        return tok.Result
    }

    ; Only completed requests are freed. A request the OS still owns (it should never happen after timeout + margin) is kept
    ; alive forever rather than freeing memory the OS may write into.
    Release(tok) {
        if tok.Released
            return
        if (!IsObject(tok.Result) && DllCall("kernel32\WaitForSingleObject", "ptr", tok.Event, "uint", 0, "uint") = 258) {
            IcmpBackend.Graveyard.Push(tok)
            tok.Released := true
            return
        }
        tok.Released := true
        DllCall("kernel32\CloseHandle", "ptr", tok.Event)
        tok.Event := 0
        tok.Buf := ""
        tok.Data := ""
        IcmpBackend.Outstanding -= 1
    }
}

; ----------------------------------------------------------------------------------------------------------------------
; Facade. One current run; starting a new one cancels the old. A cancelled run keeps ticking until its in-flight request has
; been released and its backend closed. The 50 ms timer runs only while some run still needs ticks.
class Pinger {
    static TICK_MS := 50

    ; opts: Logger, Clock (callable), BackendFactory (callable returning a backend; default IcmpBackend)
    __New(opts := "") {
        this.Logger := (IsObject(opts) && opts.HasOwnProp("Logger")) ? opts.Logger : ""
        this.Clock := (IsObject(opts) && opts.HasOwnProp("Clock")) ? opts.Clock : PingRun.TickNow
        this.Factory := (IsObject(opts) && opts.HasOwnProp("BackendFactory")) ? opts.BackendFactory : (() => IcmpBackend())
        this.Current := ""                      ; the latest run (kept after it finishes, so the page can show its console)
        this.Runs := []                         ; runs that still need ticks
        this._fn := ObjBindMethod(this, "Tick")
        this._tmOn := false
    }

    Running => IsObject(this.Current) && this.Current.Running
    Idle => this.Runs.Length = 0

    ; mode "count" | "untilSuccess"; targetText must be an IPv4 address in the usable range (Ipv4.Parse + IsUsableHostRange);
    ; opts.AllowLoopback lets 127.x through (selftest / tests only). opts: Owner, CapMs, OnUpdate(fn), OnDone(fn), AllowLoopback.
    ; Returns {Ok, Error, Run}.
    Start(mode, targetText, cfg := "", opts := "") {
        o := IsObject(opts) ? opts : {}
        p := Ipv4.Parse(targetText)
        if !p.Ok
            return {Ok: false, Error: p.Error, Run: ""}
        u := Ipv4.IsUsableHostRange(p.Int)
        if (!u.Ok && !(o.HasOwnProp("AllowLoopback") && o.AllowLoopback && (p.Int >> 24) = 127))
            return {Ok: false, Error: u.Error, Run: ""}
        this.Cancel()
        ro := {Mode: mode, Target: p.Int, Cfg: cfg, Backend: this.Factory.Call(), Clock: this.Clock,
            Owner: o.HasOwnProp("Owner") ? o.Owner : ""}
        if o.HasOwnProp("CapMs")
            ro.CapMs := o.CapMs
        run := PingRun(ro)
        if o.HasOwnProp("OnUpdate")
            run.OnUpdate(o.OnUpdate)
        run.OnDone(ObjBindMethod(this, "_Done"))
        if o.HasOwnProp("OnDone")
            run.OnDone(o.OnDone)
        this.Current := run
        this.Runs.Push(run)
        this._Timer(true)
        this._Log("ping start", {target: run.TargetText, mode: mode, timeoutMs: run.TimeoutMs, attempts: run.Attempts,
            intervalMs: run.IntervalMs, capMs: run.CapMs})
        run.Start()
        return {Ok: true, Error: "", Run: run}
    }

    _Done(res) {
        this._Log("ping done", {target: res.Target, status: res.Status, attempts: res.Attempts, replies: res.Successes,
            elapsedMs: res.Elapsed})
    }

    Cancel() {
        if (IsObject(this.Current) && this.Current.Cancel()) {
            this._Log("ping cancelled", {target: this.Current.TargetText, orphans: this.Current.Orphans})
            return true
        }
        return false
    }

    ; Cancel and forget the current run (new call, Clear All, History load): the page then shows no console.
    Reset() {
        this.Cancel()
        this.Current := ""
    }

    Tick() {
        for run in this.Runs.Clone()
            run.Tick()
        i := this.Runs.Length
        while (i >= 1) {
            if this.Runs[i].Drained
                this.Runs.RemoveAt(i)
            i -= 1
        }
        if (this.Runs.Length = 0)
            this._Timer(false)
    }

    ; App exit / window close: cancel, wait briefly for in-flight requests so their buffers are released cleanly, then stop.
    ; A request that is still pending after maxWaitMs is abandoned WITHOUT freeing its buffer (the process is ending).
    Shutdown(maxWaitMs := 1000) {
        this.Cancel()
        end := A_TickCount + maxWaitMs
        while (this.Runs.Length > 0 && A_TickCount < end) {
            this.Tick()
            if (this.Runs.Length > 0)
                Sleep(20)
        }
        this._Timer(false)
        return this.Runs.Length = 0
    }

    _Timer(on) {
        if (on = this._tmOn)
            return
        this._tmOn := on
        SetTimer(this._fn, on ? Pinger.TICK_MS : 0)
    }

    _Log(msg, data) {
        if IsObject(this.Logger)
            try this.Logger.Debug(msg, data)
    }
}
