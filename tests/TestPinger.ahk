#Requires AutoHotkey v2.0
; TestPinger.ahk - the async pinger (PLAN section 7). PingRun is driven with a mock backend and a fake clock, so nothing here
; needs a network or real time. The one integration test pings 127.0.0.1 through the real IcmpBackend (local, < 1 s).

class MockPingBackend {
    ; script: array of entries {Delay, Status, Addr, Rtt}; the last entry repeats. Delay = ms until the request completes.
    __New(clk, script) {
        this.Clk := clk
        this.Script := script
        this.Sent := []                 ; {At, Tok}
        this.Released := []             ; {Tok, PollReported}
        this.Closed := 0
        this.ThrowOnSend := false
        this.N := 0
    }

    Send(target, timeoutMs) {
        if this.ThrowOnSend
            throw Error("no icmp handle")
        this.N += 1
        e := this.Script[Min(this.N, this.Script.Length)]
        tok := {Id: this.N, Target: target, ReadyAt: this.Clk.Ms + e.Delay, E: e, Reported: false, TimeoutMs: timeoutMs}
        this.Sent.Push({At: this.Clk.Ms, Tok: tok})
        return tok
    }

    Poll(tok) {
        if (this.Clk.Ms < tok.ReadyAt)
            return ""
        tok.Reported := true
        e := tok.E
        st := e.HasOwnProp("Status") ? e.Status : 0
        return {Ok: st = 0, Status: st, Address: e.HasOwnProp("Addr") ? e.Addr : tok.Target, RttMs: e.HasOwnProp("Rtt") ? e.Rtt : 3, Reason: ""}
    }

    Release(tok) {
        this.Released.Push({Tok: tok, PollReported: tok.Reported})
    }

    Close() {
        this.Closed += 1
    }
}

class TestPinger {
    static Name := "Pinger"

    static Run() {
        for name in ["CountAllReplies", "MixedReplies", "AllTimeouts", "WrongAddress", "StatusReasons", "UntilFirstReply", "UntilCap",
                "UntilCapWaitsForInFlight", "CancelPending", "CancelDeadline", "CancelIdleAndTwice", "NewRunCancelsOld", "StartValidation",
                "IntervalTiming", "SlowAttemptWaits", "BoundsClamped", "ConsoleCapped", "ByteOrder", "StatusLine", "SendThrows",
                "WatchdogTimeout", "ElapsedFrozen", "FastReplyText", "LoopbackIntegration"]
            T.Case(name, ObjBindMethod(TestPinger, name))
    }

    ; --- helpers ---------------------------------------------------------------------------------------------------
    static R(delay := 10, rtt := 3) => {Delay: delay, Status: 0, Rtt: rtt}
    static TO(timeout := 1000) => {Delay: timeout, Status: 11010}
    static NEVER() => {Delay: 1000000000, Status: 11010}
    static Cfg(timeout := 1000, attempts := 4, interval := 1000, cap := 10) => Map("timeoutMs", timeout, "attempts", attempts,
        "intervalMs", interval, "untilSuccessMaxMin", cap)

    ; -> {Run, Be, Clk}
    static Make(mode, script, cfg := "", extra := "") {
        clk := {Ms: 0}
        be := MockPingBackend(clk, script)
        o := {Mode: mode, Target: Ipv4.Parse("1.1.1.2").Int, Cfg: IsObject(cfg) ? cfg : TestPinger.Cfg(), Backend: be, Clock: () => clk.Ms}
        if IsObject(extra)
            for k, v in extra.OwnProps()
                o.%k% := v
        return {Run: PingRun(o), Be: be, Clk: clk}
    }

    static Pump(c, totalMs, step := 50) {
        n := totalMs // step
        loop n {
            c.Clk.Ms += step
            c.Run.Tick()
        }
    }

    ; --- count mode ----------------------------------------------------------------------------------------------
    static CountAllReplies() {
        c := TestPinger.Make("count", [TestPinger.R()])
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        T.Eq(c.Run.Status, "running", "running after Start")
        T.Eq(c.Be.Sent.Length, 1, "first attempt is sent at Start")
        TestPinger.Pump(c, 5000)
        T.Eq(c.Run.Status, "succeeded", "all replies: succeeded")
        T.Eq(c.Run.Done, 4, "4 attempts")
        T.Eq(c.Run.Successes, 4, "4 successes")
        T.Eq(c.Be.Sent.Length, 4, "exactly 4 sends")
        T.Eq(done.Length, 1, "OnDone fired once")
        T.True(done[1].AnyReply, "result AnyReply")
        T.False(done[1].Cancelled, "result not cancelled")
        T.Eq(done[1].Attempts, 4, "result attempts")
        T.Eq(done[1].Target, "1.1.1.2", "result target")
        T.Eq(c.Be.Released.Length, 4, "every token released")
        T.Eq(c.Be.Closed, 1, "backend closed once")
        T.True(c.Run.Drained, "drained")
        T.Eq(c.Run.Lines[1], "Reply from 1.1.1.2: time 3 ms", "console line wording")
    }

    static MixedReplies() {
        c := TestPinger.Make("count", [TestPinger.TO(), TestPinger.R(), TestPinger.TO(), TestPinger.TO()])
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        TestPinger.Pump(c, 8000)
        T.Eq(c.Run.Status, "succeeded", "mixed: succeeded (a reply came back)")
        T.True(done[1].AnyReply, "mixed: AnyReply")
        T.Eq(done[1].Successes, 1, "mixed: 1 success")
        T.Eq(done[1].Attempts, 4, "mixed: 4 attempts")
        T.Contains(c.Run.Lines[1], "No reply (timed out after 1000 ms)", "mixed: timeout line")
    }

    static AllTimeouts() {
        c := TestPinger.Make("count", [TestPinger.TO()])
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        TestPinger.Pump(c, 9000)
        T.Eq(c.Run.Status, "failed", "all timeouts: failed")
        T.False(done[1].AnyReply, "all timeouts: no reply")
        T.Eq(done[1].Attempts, 4, "all timeouts: 4 attempts")
        T.Eq(c.Be.Sent.Length, 4, "all timeouts: 4 sends")
    }

    static WrongAddress() {
        other := Ipv4.Parse("9.9.9.9").Int
        c := TestPinger.Make("count", [{Delay: 10, Status: 0, Addr: other, Rtt: 5}], TestPinger.Cfg(1000, 2, 1000, 10))
        c.Run.Start()
        TestPinger.Pump(c, 4000)
        T.Eq(c.Run.Successes, 0, "wrong address: not a success")
        T.Eq(c.Run.Status, "failed", "wrong address: failed")
        T.Contains(c.Run.Lines[1], "Reply from a different address (9.9.9.9)", "wrong address: line names the address")
        T.Contains(c.Run.Lines[1], "not counted", "wrong address: not counted")
        ; status 0 from the right address but a non-success status elsewhere is never a success either
        c2 := TestPinger.Make("count", [{Delay: 10, Status: 11003, Addr: c.Run.Target}], TestPinger.Cfg(1000, 1, 1000, 10))
        c2.Run.Start()
        TestPinger.Pump(c2, 2000)
        T.Eq(c2.Run.Successes, 0, "right address, bad status: not a success")
    }

    static StatusReasons() {
        table := [[11002, "Destination network unreachable"], [11003, "Destination host unreachable"], [11004, "Destination protocol unreachable"],
            [11005, "Destination port unreachable"], [11010, "No reply (timed out after 1000 ms)"], [11013, "Time to live expired in transit"],
            [11050, "Ping failed (general failure)"], [12345, "Ping failed (code 12345)"], [11006, "ran out of resources"], [11009, "Packet too big"]]
        for row in table {
            c := TestPinger.Make("count", [{Delay: 10, Status: row[1]}], TestPinger.Cfg(1000, 1, 1000, 10))
            c.Run.Start()
            TestPinger.Pump(c, 500)
            T.Eq(c.Run.Successes, 0, "status " row[1] ": never a success")
            T.Contains(c.Run.Lines[1], row[2], "status " row[1] ": reason text")
            T.Eq(c.Run.Status, "failed", "status " row[1] ": run failed")
        }
        ; a router reporting unreachable names itself
        router := Ipv4.Parse("10.0.0.1").Int
        c := TestPinger.Make("count", [{Delay: 10, Status: 11003, Addr: router}], TestPinger.Cfg(1000, 1, 1000, 10))
        c.Run.Start()
        TestPinger.Pump(c, 500)
        T.Contains(c.Run.Lines[1], "(reported by 10.0.0.1)", "unreachable from a router names the router")
    }

    ; --- until success ---------------------------------------------------------------------------------------------
    static UntilFirstReply() {
        c := TestPinger.Make("untilSuccess", [TestPinger.TO(), TestPinger.TO(), TestPinger.R()])
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        TestPinger.Pump(c, 10000)
        T.Eq(c.Run.Status, "succeeded", "until: succeeded on the first reply")
        T.Eq(c.Be.Sent.Length, 3, "until: no attempt after the reply")
        T.Eq(done[1].Attempts, 3, "until: 3 attempts")
        T.Eq(done.Length, 1, "until: one OnDone")
        T.True(done[1].AnyReply, "until: AnyReply")
    }

    static UntilCap() {
        c := TestPinger.Make("untilSuccess", [TestPinger.TO()], TestPinger.Cfg(1000, 4, 1000, 10), {CapMs: 5000})
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        TestPinger.Pump(c, 20000)
        T.Eq(c.Run.Status, "failed", "until: stops at the cap with failed")
        T.False(done[1].AnyReply, "until cap: no reply")
        T.Eq(c.Be.Sent.Length, 5, "until cap: no attempt scheduled after the cap")
        T.True(done[1].Elapsed >= 5000 && done[1].Elapsed < 6500, "until cap: elapsed ~ cap (" done[1].Elapsed ")")
        ; the cap from minutes (config)
        c2 := TestPinger.Make("untilSuccess", [TestPinger.TO()], TestPinger.Cfg(1000, 4, 10000, 1))
        T.Eq(c2.Run.CapMs, 60000, "1 minute cap is 60000 ms")
        c2.Run.Start()
        TestPinger.Pump(c2, 61000, 100)
        T.Eq(c2.Run.Status, "failed", "until: 1 minute cap reached with the fake clock")
        T.True(c2.Be.Sent.Length <= 7, "until: attempts follow the interval (" c2.Be.Sent.Length ")")
    }

    static UntilCapWaitsForInFlight() {
        ; an attempt in flight at the cap is waited for (it may still be a reply); nothing new is sent
        c := TestPinger.Make("untilSuccess", [TestPinger.R(900)], TestPinger.Cfg(1000, 4, 250, 10), {CapMs: 1000})
        c.Run.Start()
        TestPinger.Pump(c, 5000)
        T.True(c.Run.Status = "succeeded" || c.Run.Status = "failed", "cap: finished")
        T.True(c.Be.Sent.Length <= 5, "cap: bounded sends (" c.Be.Sent.Length ")")
        T.Eq(c.Be.Released.Length, c.Be.Sent.Length, "cap: all released")
    }

    ; --- cancel ----------------------------------------------------------------------------------------------------
    static CancelPending() {
        c := TestPinger.Make("untilSuccess", [TestPinger.R(2000)])
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        T.Eq(c.Be.Sent.Length, 1, "cancel: one attempt in flight")
        c.Clk.Ms := 500
        T.True(c.Run.Cancel(), "Cancel returns true")
        T.Eq(c.Run.Status, "cancelled", "cancelled immediately")
        T.Eq(done.Length, 1, "OnDone fired at Cancel")
        T.True(done[1].Cancelled, "result says cancelled")
        T.Eq(c.Run.Lines[c.Run.Lines.Length], "Cancelled", "console says Cancelled")
        T.Eq(c.Be.Released.Length, 0, "in-flight request NOT released at Cancel")
        T.Eq(c.Run.Orphans, 1, "in-flight request kept")
        T.False(c.Run.Drained, "not drained while in flight")
        TestPinger.Pump(c, 1400)              ; to 1900
        T.Eq(c.Be.Released.Length, 0, "still not released before it completes")
        T.Eq(c.Be.Closed, 0, "backend not closed while in flight")
        TestPinger.Pump(c, 200)               ; past 2000
        T.Eq(c.Be.Released.Length, 1, "released after it completed")
        T.True(c.Be.Released[1].PollReported, "Release came after Poll reported completion")
        T.Eq(c.Be.Sent.Length, 1, "no Send after Cancel")
        T.True(c.Run.Drained, "drained after release")
        T.Eq(c.Be.Closed, 1, "backend closed after the last release")
        TestPinger.Pump(c, 3000)
        T.Eq(c.Be.Sent.Length, 1, "still no Send long after Cancel")
        T.Eq(done.Length, 1, "still one OnDone")
        T.Eq(c.Run.Elapsed(), 500, "elapsed frozen at the Cancel")
    }

    static CancelDeadline() {
        ; a request that never completes is released only after timeout + margin (1000 + 1000)
        c := TestPinger.Make("untilSuccess", [TestPinger.NEVER()])
        c.Run.Start()
        c.Run.Cancel()
        TestPinger.Pump(c, 1950)
        T.Eq(c.Be.Released.Length, 0, "deadline: not released before timeout + margin")
        TestPinger.Pump(c, 100)
        T.Eq(c.Be.Released.Length, 1, "deadline: released after timeout + margin")
        T.False(c.Be.Released[1].PollReported, "deadline: it never completed")
        T.True(c.Run.Drained, "deadline: drained")
    }

    static CancelIdleAndTwice() {
        c := TestPinger.Make("count", [TestPinger.R()])
        T.False(c.Run.Cancel(), "Cancel before Start does nothing")
        c.Run.Start()
        T.True(c.Run.Cancel(), "first Cancel")
        T.False(c.Run.Cancel(), "second Cancel does nothing")
        T.Eq(c.Be.Released.Length, 0, "not released before completion")
        TestPinger.Pump(c, 100)
        T.Eq(c.Be.Released.Length, 1, "released once")
        T.False(c.Run.Start(), "a finished run cannot be started again")
        ; cancel between attempts: nothing in flight, drained right away
        c2 := TestPinger.Make("count", [TestPinger.R()])
        c2.Run.Start()
        TestPinger.Pump(c2, 100)
        T.Eq(c2.Run.Pending, 0, "between attempts: nothing in flight")
        c2.Run.Cancel()
        T.True(c2.Run.Drained, "cancel between attempts drains at once")
        T.Eq(c2.Be.Closed, 1, "closed")
    }

    static NewRunCancelsOld() {
        clk := {Ms: 0}
        made := []
        pg := Pinger({Clock: () => clk.Ms, BackendFactory: () => (made.Push(MockPingBackend(clk, made.Length = 0 ? [TestPinger.R(300)] : [TestPinger.NEVER()])), made[made.Length])})
        r1 := pg.Start("count", "1.1.1.2", TestPinger.Cfg())
        T.True(r1.Ok, "first run starts")
        run1 := r1.Run
        T.Eq(run1.Status, "running", "first run running")
        clk.Ms := 100
        r2 := pg.Start("untilSuccess", "1.1.1.3", TestPinger.Cfg())
        T.True(r2.Ok, "second run starts")
        T.Eq(run1.Status, "cancelled", "a new run cancels the old one")
        T.Eq(r2.Run.Status, "running", "new run running")
        T.True(pg.Current == r2.Run, "Current is the new run")
        T.True(pg.Running, "Running")
        T.Eq(made.Length, 2, "one backend per run")
        T.Eq(made[1].Released.Length, 0, "old request not released until it completes")
        loop 12 {
            clk.Ms += 50
            pg.Tick()
        }
        T.Eq(made[1].Released.Length, 1, "old request released after it completed")
        T.Eq(made[1].Closed, 1, "old backend closed")
        T.Eq(made[1].Sent.Length, 1, "old run sent nothing after the cancel")
        pg.Reset()
        T.Eq(r2.Run.Status, "cancelled", "Reset cancels")
        T.True(pg.Current = "", "Reset forgets the run")
        loop 60 {
            clk.Ms += 50
            pg.Tick()
        }
        T.True(pg.Idle, "everything drained")
        pg._Timer(false)
    }

    static StartValidation() {
        clk := {Ms: 0}
        pg := Pinger({Clock: () => clk.Ms, BackendFactory: () => MockPingBackend(clk, [TestPinger.R()])})
        for bad in ["", "abc", "1.1.1", "256.1.1.1", "01.1.1.1", "127.0.0.1", "0.1.2.3", "224.0.0.1", "255.255.255.255", "1.1.1.1/30", "1.1.1.1; calc"] {
            r := pg.Start("count", bad, TestPinger.Cfg())
            T.False(r.Ok, "refused: [" bad "]")
            T.True(r.Error != "", "refusal has a message: [" bad "]")
        }
        T.True(pg.Idle, "refused targets start nothing")
        r := pg.Start("count", "127.0.0.1", TestPinger.Cfg())
        T.False(r.Ok, "loopback refused by default")
        r := pg.Start("count", "127.0.0.1", TestPinger.Cfg(), {AllowLoopback: true})
        T.True(r.Ok, "loopback allowed only with the explicit test flag")
        r2 := pg.Start("count", "10.0.0.1", TestPinger.Cfg(), {AllowLoopback: true})
        T.True(r2.Ok, "normal address with the flag")
        r3 := pg.Start("count", "224.0.0.1", TestPinger.Cfg(), {AllowLoopback: true})
        T.False(r3.Ok, "the flag does not open multicast")
        pg.Reset()
        pg._Timer(false)
    }

    ; --- timing ----------------------------------------------------------------------------------------------------
    static IntervalTiming() {
        for iv in [1000, 250, 2500] {
            c := TestPinger.Make("count", [TestPinger.R()], TestPinger.Cfg(1000, 4, iv, 10))
            c.Run.Start()
            TestPinger.Pump(c, iv * 5 + 500)
            T.Eq(c.Be.Sent.Length, 4, "interval " iv ": 4 sends")
            ok := true
            loop 4
                if (c.Be.Sent[A_Index].At != (A_Index - 1) * iv)
                    ok := false
            T.True(ok, "interval " iv ": attempts start exactly one interval apart")
        }
    }

    static SlowAttemptWaits() {
        ; an attempt that takes longer than the interval delays the next one until it is back (never two in flight)
        c := TestPinger.Make("count", [TestPinger.R(800)], TestPinger.Cfg(1000, 3, 250, 10))
        c.Run.Start()
        TestPinger.Pump(c, 4000)
        T.Eq(c.Be.Sent.Length, 3, "slow: 3 sends")
        T.Eq(c.Be.Sent[2].At, 800, "slow: the next attempt starts when the previous one is back")
        T.Eq(c.Be.Sent[3].At, 1600, "slow: and the next")
        T.Eq(c.Run.Status, "succeeded", "slow: succeeded")
    }

    static BoundsClamped() {
        tgt := Ipv4.Parse("1.1.1.2").Int
        mk := (cfg) => PingRun({Mode: "count", Target: tgt, Cfg: cfg, Backend: MockPingBackend({Ms: 0}, [TestPinger.R()])})
        r := mk(Map("timeoutMs", 50, "attempts", 0, "intervalMs", 10, "untilSuccessMaxMin", 0))
        T.Eq(r.TimeoutMs, 200, "timeout 50 -> 200")
        T.Eq(r.Attempts, 1, "attempts 0 -> 1")
        T.Eq(r.IntervalMs, 250, "interval 10 -> 250")
        T.Eq(r.MaxMin, 1, "cap 0 -> 1")
        r := mk(Map("timeoutMs", 99999, "attempts", 99, "intervalMs", 99999, "untilSuccessMaxMin", 99))
        T.Eq(r.TimeoutMs, 5000, "timeout 99999 -> 5000")
        T.Eq(r.Attempts, 20, "attempts 99 -> 20")
        T.Eq(r.IntervalMs, 10000, "interval 99999 -> 10000")
        T.Eq(r.MaxMin, 30, "cap 99 -> 30")
        T.Eq(r.CapMs, 1800000, "cap 30 min in ms")
        r := mk(Map("timeoutMs", -5, "attempts", -1, "intervalMs", -1, "untilSuccessMaxMin", -1))
        T.Eq(r.TimeoutMs, 200, "negative timeout -> 200")
        T.Eq(r.Attempts, 1, "negative attempts -> 1")
        r := mk(Map("timeoutMs", "abc", "attempts", "", "intervalMs", Map(), "untilSuccessMaxMin", "x"))
        T.Eq(r.TimeoutMs, 1000, "junk timeout -> default")
        T.Eq(r.Attempts, 4, "junk attempts -> default")
        T.Eq(r.IntervalMs, 1000, "junk interval -> default")
        T.Eq(r.MaxMin, 10, "junk cap -> default")
        r := mk(Map())
        T.Eq(r.TimeoutMs, 1000, "missing keys -> defaults")
        r := mk("")
        T.Eq(r.Attempts, 4, "no config -> defaults")
        r := mk(Map("timeoutMs", "2500", "attempts", 7.4, "intervalMs", 500, "untilSuccessMaxMin", 5))
        T.Eq(r.TimeoutMs, 2500, "numeric text accepted")
        T.Eq(r.Attempts, 7, "float rounded")
        r := mk({timeoutMs: 300, attempts: 2, intervalMs: 400, untilSuccessMaxMin: 3})
        T.Eq(r.TimeoutMs "/" r.Attempts "/" r.IntervalMs "/" r.MaxMin, "300/2/400/3", "plain object config")
        ; an untilSuccess run has no attempt count of its own
        u := PingRun({Mode: "untilSuccess", Target: tgt, Cfg: Map("attempts", 9), Backend: MockPingBackend({Ms: 0}, [TestPinger.R()])})
        T.Eq(u.Attempts, 0, "until mode ignores attempts")
        ; the facade clamps too
        clk := {Ms: 0}
        pg := Pinger({Clock: () => clk.Ms, BackendFactory: () => MockPingBackend(clk, [TestPinger.R()])})
        s := pg.Start("count", "1.1.1.2", Map("timeoutMs", 1, "attempts", 500))
        T.Eq(s.Run.TimeoutMs "/" s.Run.Attempts, "200/20", "Pinger.Start clamps odd config")
        pg.Reset()
        pg._Timer(false)
    }

    static ConsoleCapped() {
        c := TestPinger.Make("untilSuccess", [TestPinger.TO(250)], TestPinger.Cfg(250, 4, 250, 30))
        c.Run.Start()
        TestPinger.Pump(c, 300 * 250 + 500)
        T.True(c.Run.Done >= 300, "300+ attempts happened (" c.Run.Done ")")
        T.Eq(c.Run.Lines.Length, 200, "console capped at 200 lines")
        T.Eq(c.Run.LineSeq, c.Run.Done, "every attempt added a line")
        c.Run.Cancel()
        T.Eq(c.Run.Lines.Length, 200, "still 200 after the Cancelled line")
        T.Eq(c.Run.Lines[200], "Cancelled", "newest line kept")
    }

    static ByteOrder() {
        T.Eq(IcmpBackend.ToIPAddr(Ipv4.Parse("1.2.3.4").Int), 0x04030201, "1.2.3.4 -> 0x04030201")
        T.Eq(IcmpBackend.ToIPAddr(Ipv4.Parse("192.168.1.1").Int), 0x0101A8C0, "192.168.1.1 -> 0x0101A8C0")
        T.Eq(IcmpBackend.ToIPAddr(Ipv4.Parse("255.0.0.1").Int), 0x010000FF, "255.0.0.1 -> 0x010000FF")
        T.Eq(IcmpBackend.ToIPAddr(Ipv4.Parse("223.255.255.253").Int), 0xFDFFFFDF, "223.255.255.253 -> 0xFDFFFFDF (fits an unsigned 32-bit)")
        T.Eq(IcmpBackend.ToIPAddr(0), 0, "0 -> 0")
        T.Eq(IcmpBackend.ToIPAddr(Ipv4.Parse("1.1.1.2").Int), 0x02010101, "1.1.1.2 -> 0x02010101")
        for ip in ["1.2.3.4", "10.0.0.1", "192.0.2.1", "255.255.255.254", "128.0.0.1", "8.8.8.8"] {
            n := Ipv4.Parse(ip).Int
            a := IcmpBackend.ToIPAddr(n)
            T.True(a >= 0 && a <= 0xFFFFFFFF, "unsigned 32-bit: " ip)
            T.Eq(IcmpBackend.FromIPAddr(a), n, "round trip " ip)
        }
        ; stored as 4 bytes in memory the first byte is the first octet
        b := Buffer(4, 0)
        NumPut("uint", IcmpBackend.ToIPAddr(Ipv4.Parse("1.2.3.4").Int), b)
        T.Eq(NumGet(b, 0, "uchar") "." NumGet(b, 1, "uchar") "." NumGet(b, 2, "uchar") "." NumGet(b, 3, "uchar"), "1.2.3.4", "memory bytes are in network order")
    }

    static StatusLine() {
        c := TestPinger.Make("count", [TestPinger.R(10, 3)])
        c.Run.Start()
        T.Eq(c.Run.StatusText(), "Attempt 1 of 4 " Chr(0xB7) " 00:00 " Chr(0xB7) " Running" Chr(0x2026), "status at start")
        c.Clk.Ms := 1000
        c.Run.Tick()                                   ; attempt 1 back, attempt 2 out
        c.Clk.Ms := 2000
        c.Run.Tick()
        c.Clk.Ms := 2050
        c.Run.Tick()
        c.Clk.Ms := 3000
        c.Run.Tick()                                   ; attempt 4 sent
        c.Clk.Ms := 3040
        T.Eq(c.Run.Started, 4, "4 sent")
        c2 := TestPinger.Make("count", [TestPinger.R(10, 3)])
        c2.Run.Start()
        TestPinger.Pump(c2, 2100)                      ; attempts at 0, 1000, 2000
        T.Eq(c2.Run.StatusText(), "Attempt 3 of 4 " Chr(0xB7) " last: Reply 3 ms " Chr(0xB7) " 00:02 " Chr(0xB7) " Running" Chr(0x2026), "count status line")
        u := TestPinger.Make("untilSuccess", [TestPinger.TO(250)], TestPinger.Cfg(250, 4, 250, 10))
        u.Run.Start()
        TestPinger.Pump(u, 11500)                      ; 46 attempts
        txt := u.Run.StatusText()
        T.Contains(txt, " " Chr(0xB7) " 00:11 / 10:00 " Chr(0xB7) " Waiting for a reply" Chr(0x2026), "until status line (time / cap)")
        T.True(RegExMatch(txt, "^Attempt \d+ "), "until status starts with the attempt number")
        T.NotContains(txt, "last:", "until status has no last result")
        ; finished texts
        d := TestPinger.Make("count", [TestPinger.TO()], TestPinger.Cfg(1000, 1, 1000, 10))
        d.Run.Start()
        TestPinger.Pump(d, 1500)
        T.Contains(d.Run.StatusText(), "No reply", "failed status text")
        d2 := TestPinger.Make("count", [TestPinger.R()], TestPinger.Cfg(1000, 1, 1000, 10))
        d2.Run.Start()
        TestPinger.Pump(d2, 500)
        T.Contains(d2.Run.StatusText(), "Reply received", "succeeded status text")
        d3 := TestPinger.Make("count", [TestPinger.NEVER()])
        d3.Run.Start()
        d3.Run.Cancel()
        T.Contains(d3.Run.StatusText(), "Cancelled", "cancelled status text")
    }

    static SendThrows() {
        c := TestPinger.Make("count", [TestPinger.R()])
        c.Be.ThrowOnSend := true
        done := []
        c.Run.OnDone((res) => done.Push(res))
        c.Run.Start()
        T.Eq(c.Run.Status, "error", "Send throwing -> error")
        T.Contains(c.Run.Error, "no icmp handle", "error text kept")
        T.Eq(done.Length, 1, "OnDone fired for an error")
        T.False(done[1].AnyReply, "error: no reply")
        T.True(c.Run.Drained, "error run is drained")
        T.Contains(c.Run.StatusText(), "Could not ping", "error status text")
    }

    static WatchdogTimeout() {
        ; a backend that never answers is given up on after timeout + margin and counted as a timeout
        c := TestPinger.Make("count", [TestPinger.NEVER()], TestPinger.Cfg(1000, 1, 1000, 10))
        c.Run.Start()
        TestPinger.Pump(c, 1950)
        T.Eq(c.Run.Done, 0, "watchdog: not yet")
        TestPinger.Pump(c, 100)
        T.Eq(c.Run.Done, 1, "watchdog: counted after timeout + margin")
        T.Eq(c.Run.Status, "failed", "watchdog: failed")
        T.Eq(c.Be.Released.Length, 1, "watchdog: released")
    }

    static ElapsedFrozen() {
        c := TestPinger.Make("count", [TestPinger.R()], TestPinger.Cfg(1000, 1, 1000, 10))
        c.Run.Start()
        TestPinger.Pump(c, 100)
        e := c.Run.Elapsed()
        TestPinger.Pump(c, 5000)
        T.Eq(c.Run.Elapsed(), e, "elapsed does not grow after the run finished")
    }

    static FastReplyText() {
        c := TestPinger.Make("count", [{Delay: 1, Status: 0, Rtt: 0}], TestPinger.Cfg(1000, 1, 1000, 10))
        c.Run.Start()
        TestPinger.Pump(c, 200)
        T.Eq(c.Run.Lines[1], "Reply from 1.1.1.2: time <1 ms", "0 ms is shown as <1 ms")
    }

    ; --- the real backend, local only --------------------------------------------------------------------------------
    static LoopbackIntegration() {
        before := IcmpBackend.Outstanding
        be := IcmpBackend()
        run := PingRun({Mode: "count", Target: Ipv4.Parse("127.0.0.1").Int, Cfg: Map("timeoutMs", 1000, "attempts", 1, "intervalMs", 250, "untilSuccessMaxMin", 1), Backend: be})
        run.Start()
        stop := A_TickCount + 2500
        while (run.Running && A_TickCount < stop) {
            Sleep(10)
            run.Tick()
        }
        T.Eq(run.Status, "succeeded", "loopback: a real reply came back")
        T.Eq(run.Successes, 1, "loopback: counted once")
        T.True(IsObject(run.Last) && run.Last.Ok, "loopback: last result ok")
        T.Contains(run.Lines[1], "Reply from 127.0.0.1: time", "loopback: console line")
        T.True(run.Drained, "loopback: drained")
        T.Eq(be.Handle, 0, "loopback: ICMP handle closed")
        T.Eq(IcmpBackend.Outstanding, before, "loopback: nothing outstanding")
    }
}
