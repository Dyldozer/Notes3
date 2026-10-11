#Requires AutoHotkey v2.0
; TestStatic.ahk - the static model (state, gateway / manual gateway, ping outcome), its place in CallSession
; (state, snapshots, old snapshots), the composed notes and the App wiring without a window. Headless.
; The page adds to the note only through a confirmed ping outcome (no scripted static line any more).

class TestStatic {
    static Name := "Static"

    static Run() {
        for name in ["Defaults", "NewState", "ApplyForms", "PrefixBox", "AddressOnly", "ErrorStates", "BoxInteraction", "ManualGateway", "ManualEdge",
                "ForgedState", "NoStaticLine", "PingOutcomes", "PingInvalid", "PingSeam", "ConfigOverride", "LiteralBraces",
                "ComposedNote", "SessionBasics", "SnapshotShape", "RoundTrip", "OldSnapshot", "OldSnapshotIncludeScripted", "DamagedSnapshot",
                "HistoryFile", "ResetAndNewCall", "HelperFunctions", "AppWiring", "TypingNeverUsesCategory", "ConfirmedPingUsesCategory", "CopyOfState"]
            T.Case(name, ObjBindMethod(TestStatic, name))
    }

    ; --- helpers ----------------------------------------------------------------------------------------------
    static Cat() {
        for c in Defaults.Config()["categories"]
            if (c["id"] = "static")
                return c
    }

    static Model() => StaticModel(TestStatic.Cat())

    static Make() {
        s := CallSession()
        c := CallContext()
        c.Set("techName", "JORDAN SMITH", "mock")
        c.Set("techId", "T12345", "mock")
        c.Set("jobNumber", "88412", "mock")
        c.Set("workOrder", "55-2231", "mock")
        c.Set("address", "123 Example St", "mock")
        s.BeginCall(c)
        return s
    }

    ; a state made by applying the patches in order
    static S(patches*) {
        m := TestStatic.Model()
        st := StaticModel.NewState()
        for p in patches
            st := m.Apply(st, p)
        return st
    }

    static Note(s, cfg := "") {
        if !IsObject(cfg)
            cfg := Defaults.Config()
        return Composer.Compose(s.Context, s, cfg).Text
    }

    static Tail(text) => SubStr(text, InStr(text, "Notes: ") + 7)

    ; a session whose static category holds the state produced by these patches (fragments from the model)
    static With(patches*) {
        s := TestStatic.Make()
        m := TestStatic.Model()
        st := StaticModel.NewState()
        for p in patches
            st := m.Apply(st, p)
        s.SetStatic("static", st, m)
        if StaticModel.AddsToNote(st)
            s.UseCategory("static")
        return s
    }

    static Pairs(m) {
        a := []
        for k, v in m
            a.Push(k)
        out := ""
        for k in a
            out .= (out = "" ? "" : ",") k
        return out
    }

    ; --- defaults -----------------------------------------------------------------------------------------------
    static Defaults() {
        c := TestStatic.Cat()
        s := c["static"]
        T.Eq(c["kind"], "static", "kind")
        T.Eq(TestStatic.Pairs(s), "pingOutcomes,pingTargets", "static keys: no fragments (the scripted note and the manual sentence are gone)")
        T.Eq(s["pingTargets"].Length, 2, "two ping targets")
        T.Eq(s["pingTargets"][1]["id"] "|" s["pingTargets"][1]["label"], "gateway|Gateway", "target 1")
        T.Eq(s["pingTargets"][2]["id"] "|" s["pingTargets"][2]["label"], "ip|IP", "target 2")
        T.Eq(s["pingOutcomes"].Length, 2, "two ping outcomes")
        T.Eq(s["pingOutcomes"][1]["id"] "|" s["pingOutcomes"][1]["label"], "reply|Reply received", "outcome 1 (PLAN 3.7 wording)")
        T.Eq(s["pingOutcomes"][2]["id"] "|" s["pingOutcomes"][2]["label"], "noReply|No reply", "outcome 2 (PLAN 3.7 wording)")
        for o in s["pingOutcomes"] {
            T.Contains(o["fragment"], "{pingTarget}", o["id"] ": uses {pingTarget}")
            T.Contains(o["fragment"], "{pingAddress}", o["id"] ": uses {pingAddress}")
            T.Contains(o["fragment"], "placeholder wording", o["id"] ": obviously placeholder")
        }
        T.NotContains(s["pingOutcomes"][1]["fragment"] s["pingOutcomes"][2]["fragment"], "M7", "no milestone leftovers in the wording")
        r := Schema.Validate(Defaults.Config())
        T.True(r.Ok && r.Warnings.Length = 0, "defaults validate cleanly " Schema.Summary(r))
    }

    static NewState() {
        s := StaticModel.NewState()
        T.Eq(s.ipInput "|" s.prefixInput "|" s.manualInput, "||", "empty boxes")
        T.True(!s.HasOwnProp("includeScripted") && s.pingOutcome = "" && !s.pingConfirmed && s.pingTarget = "gateway", "defaults: no include flag any more, target gateway, no outcome")
        T.True(s.ip = "" && s.prefix = "" && s.mask = "" && s.gateway = "" && s.network = "" && s.broadcast = "", "nothing derived")
        T.True(!s.ready && !s.gatewayManual && !s.canManual, "not ready")
        T.True(s.ipError = "" && s.prefixError = "" && s.gatewayError = "", "no errors for an empty state")
        T.True(StaticModel.IsDefault(s), "IsDefault")
        T.False(StaticModel.AddsToNote(s), "adds nothing to the note")
        T.True(StaticModel.NewState() != StaticModel.NewState(), "each call is a new object")
    }

    ; --- the IP box and the prefix box ------------------------------------------------------------------------
    static ApplyForms() {
        ; {input, ip, prefix, mask, gateway, network, broadcast}
        rows := [["1.1.1.1/30", "1.1.1.1", "30", "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"],
            ["1.1.1.9/29", "1.1.1.9", "29", "255.255.255.248", "1.1.1.10", "1.1.1.8", "1.1.1.15"],
            ["10.0.255.255/8", "10.0.255.255", "8", "255.0.0.0", "10.1.0.0", "10.0.0.0", "10.255.255.255"],
            ["192.168.1.253/24", "192.168.1.253", "24", "255.255.255.0", "192.168.1.254", "192.168.1.0", "192.168.1.255"],
            ["172.16.5.1/255.255.0.0", "172.16.5.1", "16", "255.255.0.0", "172.16.5.2", "172.16.0.0", "172.16.255.255"],
            ["8.8.8.8 255.255.255.0", "8.8.8.8", "24", "255.255.255.0", "8.8.8.9", "8.8.8.0", "8.8.8.255"],
            ["  1.1.1.1 / 30  ", "1.1.1.1", "30", "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"]]
        for r in rows {
            s := TestStatic.S({ipText: r[1]})
            T.True(s.ip = r[2] && s.prefix = r[3] && s.mask = r[4] && s.gateway = r[5] && s.network = r[6] && s.broadcast = r[7], "derived: [" r[1] "]")
            T.True(s.ready && !s.gatewayManual && s.ipError = "" && s.prefixError = "" && s.gatewayError = "" && s.gatewayErrorKind = "", "ready, no errors: [" r[1] "]")
            T.Eq(s.ipInput, r[2], "the IP box shows the IP only: [" r[1] "]")
            T.Eq(s.prefixInput, "/" r[3], "the prefix box shows /prefix: [" r[1] "]")
            T.Eq(s.autoGateway, r[5], "autoGateway: [" r[1] "]")
        }
        ; the required case, all fields
        s := TestStatic.S({ipText: "1.1.1.1/30"})
        T.Eq(s.ip "|" s.prefix "|" s.mask "|" s.gateway, "1.1.1.1|30|255.255.255.252|1.1.1.2", "1.1.1.1/30 -> IP 1.1.1.1, prefix 30, mask 255.255.255.252, gateway 1.1.1.2")
    }

    static PrefixBox() {
        for pf in ["/30", "30", "255.255.255.252", " /30 ", "/255.255.255.252"] {
            s := TestStatic.S({ipText: "1.1.1.1"}, {prefixText: pf})
            T.True(s.ready && s.prefix = "30" && s.mask = "255.255.255.252" && s.gateway = "1.1.1.2", "prefix box accepts [" pf "]")
            T.Eq(s.prefixInput, "/30", "and shows /30 for [" pf "]")
        }
        ; changing the prefix recalculates
        s := TestStatic.S({ipText: "1.1.1.10/29"})
        T.Eq(s.gateway, "1.1.1.11", "start")
        s := TestStatic.Model().Apply(s, {prefixText: "255.255.255.0"})
        T.True(s.prefix = "24" && s.gateway = "1.1.1.11" && s.network = "1.1.1.0" && s.broadcast = "1.1.1.255", "mask in the prefix box recalculates")
        s := TestStatic.Model().Apply(s, {prefixText: "30"})
        T.True(s.network = "1.1.1.8" && s.broadcast = "1.1.1.11" && s.gateway = "" && s.gatewayErrorKind = "auto", "/30 for 1.1.1.10: IP+1 is the broadcast address")
        ; bad prefix texts keep what was typed and say why
        for bad in ["abc", "33", "/33", "255.0.255.0", "/", "1.1.1"] {
            s := TestStatic.S({ipText: "1.1.1.1/30"}, {prefixText: bad})
            T.True(s.prefixError != "" && s.prefix = "" && s.gateway = "" && !s.ready, "bad prefix [" bad "]: error, nothing derived")
            T.Eq(s.ipError, "", "the IP is still fine for [" bad "]")
            T.Eq(s.ip, "1.1.1.1", "and still known for [" bad "]")
        }
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {prefixText: "abc"})
        T.Eq(s.prefixInput, "abc", "what was typed stays in the box")
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {prefixText: ""})
        T.True(s.prefix = "" && s.prefixError != "", "an emptied prefix box asks for a prefix")
    }

    static AddressOnly() {
        s := TestStatic.S({ipText: "1.1.1.1"})
        T.True(s.ip = "1.1.1.1" && s.prefix = "" && s.gateway = "" && !s.ready, "address only: no gateway yet")
        T.Contains(s.prefixError, "Enter a prefix", "and the prefix box says what to do")
        s := TestStatic.S({})
        T.Eq(s.prefixError, "", "nothing typed: nothing said")
        s := TestStatic.S({ipText: ""})
        T.Eq(s.ipError "|" s.prefixError, "|", "empty IP box: no error")
        ; the prefix survives a new address without one
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {ipText: "1.1.1.5"})
        T.True(s.ip = "1.1.1.5" && s.prefix = "30" && s.gateway = "1.1.1.6", "a new address keeps the prefix")
        ; but an address with a prefix replaces it
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {ipText: "10.0.0.1/8"})
        T.True(s.prefix = "8" && s.gateway = "10.0.0.2", "an address with a prefix replaces it")
        ; an address with "/" and nothing after it
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {ipText: "1.1.1.1/"})
        T.True(s.prefix = "" && s.prefixError != "", "'/' with nothing after it empties the prefix and asks for one")
    }

    static ErrorStates() {
        ; {input, ipError?, prefixError?, kind, canManual, ip known, prefix known}
        rows := [["1.1.1.2/30", 0, 0, "auto", 1, 1, 1], ["1.1.1.0/30", 0, 0, "auto", 0, 1, 1], ["1.1.1.3/30", 0, 0, "auto", 0, 1, 1],
            ["192.168.1.254/24", 0, 0, "auto", 1, 1, 1], ["192.168.1.255/24", 0, 0, "auto", 0, 1, 1], ["1.1.1.1/31", 0, 0, "auto", 1, 1, 1],
            ["1.1.1.1/32", 0, 0, "auto", 1, 1, 1], ["1.1.1.1/7", 0, 0, "auto", 0, 1, 1], ["1.1.1.1/0", 0, 0, "auto", 0, 1, 1],
            ["256.1.1.1/30", 1, 0, "", 0, 0, 1], ["01.1.1.1/30", 1, 0, "", 0, 0, 1], ["1.1.1/30", 1, 0, "", 0, 0, 1], ["a.b.c.d/30", 1, 0, "", 0, 0, 1],
            ["0.1.2.3/8", 1, 0, "", 0, 0, 1], ["127.0.0.1/8", 1, 0, "", 0, 0, 1], ["224.0.0.1/8", 1, 0, "", 0, 0, 1], ["255.255.255.255/8", 1, 0, "", 0, 0, 1],
            ["1.1.1.1/abc", 0, 1, "", 0, 1, 0], ["1.1.1.1/33", 0, 1, "", 0, 1, 0], ["1.1.1.1/255.0.255.0", 0, 1, "", 0, 1, 0],
            ["256.1.1.1/abc", 1, 1, "", 0, 0, 0]]
        for r in rows {
            s := TestStatic.S({ipText: r[1]})
            T.True(s.gateway = "" && !s.ready, "no gateway, not ready: [" r[1] "]")
            T.Eq((s.ipError != "" ? 1 : 0), r[2], "ipError for [" r[1] "]")
            T.Eq((s.prefixError != "" ? 1 : 0), r[3], "prefixError for [" r[1] "]")
            T.Eq(s.gatewayErrorKind, r[4], "error kind for [" r[1] "]")
            T.Eq((s.canManual ? 1 : 0), r[5], "canManual for [" r[1] "]")
            T.Eq((s.ip != "" ? 1 : 0), r[6], "ip known for [" r[1] "]")
            T.Eq((s.prefix != "" ? 1 : 0), r[7], "prefix known for [" r[1] "]")
            if (r[4] = "auto")
                T.True(s.gatewayError != "", "a gateway error message for [" r[1] "]")
        }
        s := TestStatic.S({ipText: "1.1.1.2/30"})
        T.Contains(s.gatewayError, "IP+1 (1.1.1.3)", "IP+1 error names the value")
        T.True(s.network = "1.1.1.0" && s.broadcast = "1.1.1.3", "network and broadcast are still shown")
        s := TestStatic.S({ipText: "1.1.1.0/30"})
        T.Contains(s.gatewayError, "1.1.1.0 is the network address for /30", "network error")
        ; an error state recovers when the input is fixed
        s := TestStatic.Model().Apply(TestStatic.S({ipText: "1.1.1.2/30"}), {ipText: "1.1.1.1/30"})
        T.True(s.ready && s.gateway = "1.1.1.2" && s.gatewayError = "" && s.gatewayErrorKind = "" && !s.canManual, "fixing the IP clears the error")
    }

    static BoxInteraction() {
        m := TestStatic.Model()
        s := TestStatic.S({ipText: "1.1.1.1/30"})
        s2 := m.Apply(s, {})
        T.True(StaticModel.Same(s, s2), "an empty patch changes nothing")
        s2 := m.Apply(s, {ipText: "1.1.1.1/30"})
        T.True(StaticModel.Same(s, s2), "the same text again changes nothing")
        s2 := m.Apply(s, {ipText: " 1.1.1.1 255.255.255.252 "})
        T.True(StaticModel.Same(s, s2), "the same address in another form changes nothing")
        s2 := m.Apply(s, {ipText: "1.1.1.5"})
        T.False(StaticModel.Same(s, s2), "a different address is a change")
        ; the old state is never modified
        T.Eq(s.ip, "1.1.1.1", "Apply returns a new state")
        ; unknown patch keys are ignored
        s2 := m.Apply(s, {nonsense: 5})
        T.True(StaticModel.Same(s, s2), "unknown patch keys are ignored")
    }

    ; --- manual gateway ------------------------------------------------------------------------------------------
    static ManualGateway() {
        m := TestStatic.Model()
        s := TestStatic.S({ipText: "1.1.1.2/30"})
        T.True(!s.ready && s.canManual && s.gatewayErrorKind = "auto", "IP+1 = broadcast: manual is offered")
        s1 := m.Apply(s, {manualText: "1.1.1.1"})
        T.True(s1.ready && s1.gateway = "1.1.1.1" && s1.gatewayManual && s1.gatewayError = "" && s1.gatewayErrorKind = "" && s1.autoGateway = "", "a valid manual gateway is accepted")
        T.True(s1.canManual, "and the box stays offered")
        for bad in [["1.1.1.2", "same as the IP"], ["1.1.1.3", "broadcast address for /30"], ["1.1.1.0", "network address for /30"], ["1.1.2.1", "not in the same subnet"],
                ["abc", '"abc"'], ["127.0.0.1", "loopback"], ["1.1.1", '"1.1.1"'], ["1.1.1.256", '"256"']] {
            s2 := m.Apply(s, {manualText: bad[1]})
            T.True(!s2.ready && s2.gateway = "" && !s2.gatewayManual && s2.gatewayErrorKind = "manual", "manual [" bad[1] "] refused with kind manual")
            T.Contains(s2.gatewayError, bad[2], "message for manual [" bad[1] "]")
        }
        ; clearing goes back to the auto result (here: still the auto error)
        s2 := m.Apply(s1, {manualText: ""})
        T.True(!s2.ready && s2.gatewayErrorKind = "auto" && !s2.gatewayManual, "clearing the manual box returns to the auto rule")
        ; when the auto rule works, a manual gateway overrides it
        a := TestStatic.S({ipText: "1.1.1.1/30"})
        T.Eq(a.gateway, "1.1.1.2", "auto gateway")
        a2 := m.Apply(a, {manualText: "1.1.1.2"})
        T.True(a2.ready && a2.gateway = "1.1.1.2" && a2.gatewayManual, "a manual gateway equal to the auto one still counts as manual")
        a3 := m.Apply(TestStatic.S({ipText: "192.168.1.10/24"}), {manualText: "192.168.1.1"})
        T.True(a3.ready && a3.gateway = "192.168.1.1" && a3.gatewayManual && a3.autoGateway = "192.168.1.11", "manual overrides the calculated gateway (kept in autoGateway)")
        a4 := m.Apply(a, {manualText: "1.1.1.1"})
        T.True(!a4.ready && a4.gatewayErrorKind = "manual" && a4.gateway = "", "a refused manual gateway does not fall back to the auto one")
        a5 := m.Apply(a4, {manualText: ""})
        T.True(a5.ready && a5.gateway = "1.1.1.2" && !a5.gatewayManual, "emptied: the auto gateway is back")
        ; /31 and /32 can only be manual
        for pf in [31, 32] {
            s := TestStatic.S({ipText: "10.0.0.4/" pf})
            T.True(!s.ready && s.canManual && s.gatewayErrorKind = "auto", "/" pf ": unsupported for auto, manual offered")
            T.Contains(s.gatewayError, "Unsupported for auto-gateway", "/" pf ": message")
        }
        s := TestStatic.S({ipText: "10.0.0.4/31"}, {manualText: "10.0.0.5"})
        T.True(s.ready && s.gateway = "10.0.0.5" && s.gatewayManual, "/31 with the other address")
        s := TestStatic.S({ipText: "10.0.0.4/31"}, {manualText: "10.0.0.4"})
        T.True(!s.ready && s.gatewayErrorKind = "manual", "/31 gateway equal to the IP refused")
        s := TestStatic.S({ipText: "10.0.0.4/31"}, {manualText: "10.0.0.6"})
        T.True(!s.ready && s.gatewayErrorKind = "manual", "/31 gateway outside refused")
        s := TestStatic.S({ipText: "10.0.0.9/32"}, {manualText: "10.0.0.10"})
        T.True(!s.ready, "/32 gateway outside refused")
    }

    static ManualEdge() {
        m := TestStatic.Model()
        ; a manual gateway typed before the IP is checked once there is an IP and a prefix
        s := TestStatic.S({manualText: "1.1.1.1"})
        T.True(!s.ready && s.gateway = "" && s.manualInput = "1.1.1.1", "manual text alone: nothing to check yet")
        s := m.Apply(s, {ipText: "1.1.1.2/30"})
        T.True(s.ready && s.gateway = "1.1.1.1" && s.gatewayManual, "then it is checked and accepted")
        ; a manual gateway is re-checked when the IP moves
        s := m.Apply(s, {ipText: "1.1.1.6/30"})
        T.True(!s.ready && s.gatewayErrorKind = "manual" && s.manualInput = "1.1.1.1", "IP moved to another subnet: the manual gateway is refused, text kept")
        T.Contains(s.gatewayError, "not in the same subnet", "and the reason given")
        s := m.Apply(s, {manualText: "1.1.1.5"})
        T.True(s.ready && s.gateway = "1.1.1.5", "a fitting gateway for the new subnet")
        ; the IP being the network address cannot be saved by a manual gateway
        s := TestStatic.S({ipText: "1.1.1.0/30"}, {manualText: "1.1.1.1"})
        T.True(s.gateway = "" && !s.ready, "a network-address IP has no gateway, manual or not")
        s := TestStatic.S({ipText: "1.1.1.3/30"}, {manualText: "1.1.1.1"})
        T.True(!s.ready, "nor a broadcast-address IP")
        ; /7 and below: manual is not accepted either (fix the prefix)
        s := TestStatic.S({ipText: "1.1.1.1/7"}, {manualText: "1.1.1.2"})
        T.True(!s.ready && s.gatewayErrorKind = "auto" && s.gateway = "", "/7: the prefix error, manual ignored")
        s := TestStatic.S({ipText: "1.1.1.1/33"}, {manualText: "1.1.1.2"})
        T.True(!s.ready && s.prefixError != "", "bad prefix: not ready")
        ; a bad IP
        s := TestStatic.S({ipText: "300.1.1.1/30"}, {manualText: "1.1.1.2"})
        T.True(!s.ready && s.ipError != "", "bad IP: not ready")
        ; only spaces in the manual box is empty
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {manualText: "   "})
        T.True(s.ready && s.gateway = "1.1.1.2" && !s.gatewayManual && s.manualInput = "", "blank manual box = no manual gateway")
    }

    static ForgedState() {
        ; a state object with wrong derived values can never produce a note: Fragments re-derives from the inputs
        m := TestStatic.Model()
        s := TestStatic.S({ipText: "1.1.1.0/30"}, {pingOutcome: "reply"})
        s.ready := true, s.gateway := "9.9.9.9", s.ip := "1.1.1.0", s.prefix := "30"
        r := m.Fragments(s)
        T.Eq(r.Fragments.Length, 0, "a forged 'ready' state gives no ping line to the gateway")
        T.Eq(r.Warnings.Length, 1, "but a warning")
        s2 := StaticModel.FromMap(Map("ipInput", "1.1.1.0", "prefixInput", "/30", "pingOutcome", "reply", "pingConfirmed", 1, "ip", "1.1.1.0", "gateway", "9.9.9.9", "prefix", "30", "mask", "x"))
        T.True(s2.gateway = "" && !s2.ready, "stored derived values are ignored when restoring")
        T.Eq(m.Fragments(s2).Fragments.Length, 0, "and still no fragment")
    }

    ; --- no scripted static line ----------------------------------------------------------------------------------
    static NoStaticLine() {
        m := TestStatic.Model()
        T.False(m.HasOwnProp("Scripted") || m.HasOwnProp("GatewayManual") || HasMethod(m, "ScriptedPreview"), "the model has no scripted wording and no preview")
        ; any IP, valid or not, a manual gateway, even the removed include flag: no fragment, no warning, not "adding to the note"
        for ip in ["1.1.1.1/30", "1.1.1.0/30", "1.1.1.3/30", "1.1.1.2/30", "1.1.1.1/31", "1.1.1.1/7", "256.1.1.1/30", "1.1.1.1/abc", "1.1.1.1", "127.0.0.1/8", ""] {
            s := TestStatic.S({ipText: ip}, {includeScripted: true})
            r := m.Fragments(s)
            T.True(r.Fragments.Length = 0 && r.Warnings.Length = 0 && r.Values.Count = 0, "[" ip "]: no static line and no warning")
            T.False(StaticModel.AddsToNote(s), "[" ip "]: adds nothing to the note")
            T.False(s.HasOwnProp("includeScripted"), "[" ip "]: the removed include flag is not kept in the state")
        }
        s := TestStatic.S({ipText: "1.1.1.2/30"}, {manualText: "1.1.1.1"})
        r := m.Fragments(s)
        T.True(s.gatewayManual && s.ready, "a manual gateway is still state (the gateway was typed by hand)")
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 0, "but there is no 'entered manually' sentence")
        ; the exact keys of ToMap
        T.False(StaticModel.ToMap(s).Has("includeScripted"), "new snapshots do not write includeScripted")
        ; the ping line is independent of everything else
        s := TestStatic.S({ipText: "1.1.1.2/30"}, {pingTarget: "ip"}, {pingOutcome: "reply"})
        r := m.Fragments(s)
        T.Eq(r.Fragments.Length, 1, "ping to the IP works although the gateway is missing")
        T.Eq(r.Fragments[1], "Ping to IP 1.1.1.2: reply received (placeholder wording).", "exact ping line")
        T.Eq(r.Warnings.Length, 0, "and no warning")
    }

    ; --- ping line ------------------------------------------------------------------------------------------------
    static PingOutcomes() {
        m := TestStatic.Model()
        want := Map("gateway|reply", "Ping to Gateway 1.1.1.2: reply received (placeholder wording).",
            "gateway|noReply", "Ping to Gateway 1.1.1.2: no reply (placeholder wording).",
            "ip|reply", "Ping to IP 1.1.1.1: reply received (placeholder wording).",
            "ip|noReply", "Ping to IP 1.1.1.1: no reply (placeholder wording).")
        for key, text in want {
            parts := StrSplit(key, "|")
            s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingTarget: parts[1]}, {pingOutcome: parts[2]})
            r := m.Fragments(s)
            T.Eq(r.Fragments.Length, 1, key ": one fragment")
            T.Eq(r.Fragments[1], text, key ": exact")
            T.Eq(r.Warnings.Length, 0, key ": no warnings")
            T.True(StaticModel.AddsToNote(s), key ": counts as adding to the note")
        }
        ; no outcome: nothing
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingTarget: "ip"})
        T.True(m.Fragments(s).Fragments.Length = 0 && !StaticModel.AddsToNote(s), "a target alone adds nothing")
        ; a manual choice is confirmed
        s := TestStatic.S({pingOutcome: "reply"})
        T.True(s.pingConfirmed, "M7: the agent's choice counts as confirmed")
        s := TestStatic.Model().Apply(s, {pingOutcome: ""})
        T.True(!s.pingConfirmed && s.pingOutcome = "", "clearing the outcome clears the confirmation")
        ; the ping line alone
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "noReply"})
        r := m.Fragments(s)
        T.Eq(r.Fragments.Length, 1, "only the ping line")
        T.Eq(r.Fragments[1], "Ping to Gateway 1.1.1.2: no reply (placeholder wording).", "exact")
        ; labels come from the config
        c := TestStatic.Cat()
        c["static"]["pingTargets"][1]["label"] := "Default gateway"
        c["static"]["pingOutcomes"][1]["fragment"] := "{pingTarget} answered ({pingAddress})."
        m2 := StaticModel(c)
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        T.Eq(m2.Fragments(s).Fragments[1], "Default gateway answered (1.1.1.2).", "wording is the config's")
        T.Eq(m2.TargetLabel("gateway") "|" m2.OutcomeLabel("noReply") "|" m2.TargetLabel("zz"), "Default gateway|No reply|", "label lookups")
    }

    static PingInvalid() {
        m := TestStatic.Model()
        ; target gateway but no valid gateway
        s := TestStatic.S({ipText: "1.1.1.0/30"}, {pingTarget: "gateway"}, {pingOutcome: "reply"})
        r := m.Fragments(s)
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 1, "no valid gateway: no ping line, a warning")
        T.Contains(r.Warnings[1], "no valid address", "warning says why")
        ; target ip but no ip
        s := TestStatic.S({pingTarget: "ip"}, {pingOutcome: "reply"})
        r := m.Fragments(s)
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 1, "no IP: no ping line, a warning")
        s := TestStatic.S({ipText: "256.1.1.1/30"}, {pingTarget: "ip"}, {pingOutcome: "noReply"})
        T.Eq(m.Fragments(s).Fragments.Length, 0, "an invalid IP is never printed")
        ; unknown ids
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "maybe"})
        r := m.Fragments(s)
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 1, "unknown outcome id: warning")
        T.Contains(r.Warnings[1], '"maybe"', "names the id")
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingTarget: "router"}, {pingOutcome: "reply"})
        r := m.Fragments(s)
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 1, "unknown target id: warning")
        T.Contains(r.Warnings[1], '"router"', "names the id")
        ; a manual gateway is the ping address when it is the gateway in use
        s := TestStatic.S({ipText: "1.1.1.2/30"}, {manualText: "1.1.1.1"}, {pingOutcome: "reply"})
        T.Eq(m.Fragments(s).Fragments[1], "Ping to Gateway 1.1.1.1: reply received (placeholder wording).", "ping address = the manual gateway")
        T.Eq(StaticModel.PingAddress(s), "1.1.1.1", "PingAddress")
    }

    ; The seam M8 plugs into: a prefilled result is not agreed yet.
    static PingSeam() {
        m := TestStatic.Model()
        s := TestStatic.S({ipText: "1.1.1.1/30"})
        p := m.SetPingResult(s, "noReply")
        T.True(p.pingOutcome = "noReply" && !p.pingConfirmed, "SetPingResult prefills unconfirmed by default")
        r := m.Fragments(p)
        T.True(r.Fragments.Length = 0 && r.Warnings.Length = 1, "an unconfirmed outcome stays out of the note, with a warning")
        T.Contains(r.Warnings[1], "not confirmed", "warning says so")
        T.False(StaticModel.AddsToNote(p), "and does not count as adding to the note")
        c := m.Apply(p, {pingConfirmed: true})
        T.True(c.pingConfirmed && c.pingOutcome = "noReply", "confirming keeps the outcome")
        T.Eq(m.Fragments(c).Fragments[1], "Ping to Gateway 1.1.1.2: no reply (placeholder wording).", "and now it is in the note")
        T.True(StaticModel.AddsToNote(c), "and counts")
        p2 := m.SetPingResult(s, "reply", true)
        T.True(p2.pingConfirmed, "SetPingResult can set it confirmed")
        T.True(s.pingOutcome = "", "the old state is not modified")
        ; a confirmation without an outcome is nothing
        x := m.Apply(s, {pingConfirmed: true})
        T.False(x.pingConfirmed, "no outcome: not confirmed")
        ; choosing another outcome by hand confirms it
        d := m.Apply(p, {pingOutcome: "reply"})
        T.True(d.pingConfirmed, "a hand-picked outcome is confirmed")
    }

    static ConfigOverride() {
        c := TestStatic.Cat()
        c["static"]["pingOutcomes"][1]["fragment"] := "OTHER {pingAddress}"
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        r := TestStatic.Model().Fragments(s, c)
        T.Eq(r.Fragments[1], "OTHER 1.1.1.2", "Fragments(state, config) takes the wording from the given category")
        T.Contains(TestStatic.Model().Fragments(s).Fragments[1], "placeholder wording", "and the model's own wording is untouched")
        ; a model made from junk does not throw
        for junk in [Map(), "x", 5, Map("static", "x"), Map("static", Map("fragments", 5, "pingTargets", "x", "pingOutcomes", [5, Map("id", 7)]))] {
            m := StaticModel(junk)
            r := m.Fragments(s)
            T.True(r.Fragments.Length = 0, "no wording from a junk category: " Type(junk))
        }
    }

    static LiteralBraces() {
        ; an admin label with braces is not expanded again by the Composer
        c := TestStatic.Cat()
        c["static"]["pingTargets"][1]["label"] := "GW {job.number}"
        m := StaticModel(c)
        s := TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        r := m.Fragments(s)
        T.Eq(r.Fragments[1], "Ping to {staticPingTarget} 1.1.1.2: reply received (placeholder wording).", "the label goes in through a private placeholder")
        T.Eq(r.Values["staticPingTarget"], "GW {job.number}", "and its text is in Values")
        ses := TestStatic.Make()
        ses.UseCategory("static")
        ses.SetStatic("static", s, m)
        cfg := Defaults.Config()
        cfg["categories"][4] := c
        T.Eq(TestStatic.Tail(TestStatic.Note(ses, cfg)), "Ping to GW {job.number} 1.1.1.2: reply received (placeholder wording).", "composed: the label comes out literally")
        ; context placeholders in the wording are left for the Composer
        c["static"]["pingOutcomes"][1]["fragment"] := "{tech.firstName}: {pingAddress}"
        T.Eq(StaticModel(c).Fragments(TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})).Fragments[1], "{tech.firstName}: 1.1.1.2", "{tech.firstName} untouched")
        ; unknown placeholders stay as typed
        c["static"]["pingOutcomes"][1]["fragment"] := "{pingAddress} {ip} {nope}"
        T.Eq(StaticModel(c).Fragments(TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})).Fragments[1], "1.1.1.2 {ip} {nope}", "{ip} is not a placeholder any more, unknown ones stay")
    }

    static ComposedNote() {
        ; Equipment comes before Static in the config; Close Job after
        me := ItemsModel(Defaults.Config()["categories"][2])
        s := TestStatic.Make()
        m := TestStatic.Model()
        s.UseCategory("static")
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"}), m)
        s.UseCategory("equipment")
        s.AddEntry("equipment", {action: "swapped", item: "item1", qty: "", outcome: "", details: ""}, me)
        want := "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes: Swapped Item 1 (placeholder)."
            . "`r`nPing to Gateway 1.1.1.2: reply received (placeholder wording)."
        T.Eq(TestStatic.Note(s), want, "exact combined note: Equipment, then Static (config order)")
        ; an IP alone leaves no line
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}), m)
        T.Eq(TestStatic.Note(s), "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes: Swapped Item 1 (placeholder).", "no outcome: only Equipment")
    }

    ; --- session --------------------------------------------------------------------------------------------------
    static SessionBasics() {
        m := TestStatic.Model()
        s := TestStatic.Make()
        T.True(StaticModel.IsDefault(s.StaticFor("static")), "StaticFor gives a default state")
        T.False(s.HasStatic("static") || s.HasStaticInput(), "nothing entered")
        cnt := {n: 0}
        s.OnChanged((*) => cnt.n += 1)
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}), m)
        T.Eq(cnt.n, 1, "one notification per change")
        T.True(s.HasStatic("static") && s.HasStaticInput(), "typed input is held")
        T.False(s.HasStructured() || s.HasContent(), "typing an IP is not content for the note or History")
        T.Eq(s.Fragments("static").Length, 0, "and makes no fragment")
        T.False(s.IsUsed("static"), "and does not use the category (App.StaticSet does that)")
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"}), m)
        T.Eq(s.Fragments("static").Length, 1, "outcome chosen: a fragment")
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.5/30"}, {pingOutcome: "reply"}), m)
        T.Eq(s.Fragments("static").Length, 1, "replaced, not appended")
        T.Contains(s.Fragments("static")[1], "Gateway 1.1.1.6:", "with the newest values")
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.5/30"}), m)
        T.Eq(s.Fragments("static").Length, 0, "no outcome: the fragment is gone")
        T.Eq(s.Vals.Has("static") ? 1 : 0, 0, "and no values are left behind")
        ; a dev-style AddFragment next to a state is replaced by the next state change
        s.AddFragment("static", "stray")
        s.SetStatic("static", TestStatic.S({ipText: "1.1.1.5/30"}, {pingOutcome: "reply"}), m)
        T.Eq(s.Fragments("static").Length, 1, "the fragments are exactly the model output")
        ; without a model the state is only stored
        s2 := TestStatic.Make()
        s2.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"}))
        T.Eq(s2.Fragments("static").Length, 0, "no model: no fragments")
        T.True(s2.HasStatic("static"), "but the state is held")
    }

    static SnapshotShape() {
        s := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        snap := s.Snapshot()
        c := snap["categories"]["static"]
        T.True(c.Has("fragments") && c.Has("values") && c.Has("static"), "category has fragments, values and static")
        st := c["static"]
        T.Eq(st.Count, 11, "eleven keys")
        T.False(st.Has("includeScripted"), "no includeScripted key")
        for k in ["ipInput", "prefixInput", "manualInput", "pingTarget", "pingOutcome", "pingConfirmed", "ip", "prefix", "mask", "gateway", "gatewayManual"]
            T.True(st.Has(k), "static has " k)
        T.Eq(st["ipInput"] "|" st["prefixInput"] "|" st["manualInput"], "1.1.1.1|/30|", "inputs")
        T.Eq(st["pingTarget"] "|" st["pingOutcome"] "|" st["pingConfirmed"], "gateway|reply|1", "flags")
        T.Eq(st["ip"] "|" st["prefix"] "|" st["mask"] "|" st["gateway"] "|" st["gatewayManual"], "1.1.1.1|30|255.255.255.252|1.1.1.2|0", "values")
        T.True(st["pingConfirmed"] is Integer && st["gatewayManual"] is Integer, "flags are 0 / 1")
        ; a default state leaves no key
        s2 := TestStatic.Make()
        s2.SetStatic("static", StaticModel.NewState(), TestStatic.Model())
        T.False(s2.Snapshot()["categories"].Has("static"), "an untouched state is not in the snapshot")
        ; typed input alone is in the snapshot (when something else makes the call worth saving)
        s3 := TestStatic.Make()
        s3.SetStatic("static", TestStatic.S({ipText: "1.1.1.1/30"}), TestStatic.Model())
        s3.UseCategory("billing")
        T.True(s3.Snapshot()["categories"]["static"].Has("static"), "typed input is saved with the call")
        T.True(s3.Snapshot()["categories"]["static"]["fragments"].Length = 0, "without fragments")
        ; the snapshot is a copy
        st["ipInput"] := "changed"
        T.Eq(s.StaticFor("static").ipInput, "1.1.1.1", "changing the snapshot does not change the session")
        ; a state with a manual gateway
        s4 := TestStatic.With({ipText: "1.1.1.2/30"}, {manualText: "1.1.1.1"}, {pingOutcome: "reply"})
        st4 := s4.Snapshot()["categories"]["static"]["static"]
        T.Eq(st4["manualInput"] "|" st4["gateway"] "|" st4["gatewayManual"], "1.1.1.1|1.1.1.1|1", "manual gateway saved")
    }

    static RoundTrip() {
        n := 0
        for patches in [[{ipText: "1.1.1.1/30"}, {pingTarget: "ip"}, {pingOutcome: "reply"}],
                [{ipText: "1.1.1.2/30"}, {manualText: "1.1.1.1"}, {pingOutcome: "noReply"}],
                [{ipText: "10.0.255.255/8"}, {pingOutcome: "noReply"}],
                [{ipText: "1.1.1.0/30"}, {pingTarget: "ip"}, {pingOutcome: "reply"}],
                [{ipText: "256.1.1.1/30"}, {pingOutcome: "reply"}],
                [{ipText: "1.1.1.1"}],
                [{ipText: "1.1.1.1/30"}, {pingOutcome: "reply"}, {pingConfirmed: false}]] {
            n += 1
            s := TestStatic.With(patches*)
            s.UseCategory("static")
            note := TestStatic.Note(s)
            s.NoteText := note, s.GeneratedText := note
            snap := s.Snapshot()
            back := ConfigJson.Parse(ConfigJson.Stringify(snap))               ; through JSON, as History does
            c := CallSession()
            T.True(c.Restore(back), "restored from JSON")
            T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "snapshot -> JSON -> restore -> snapshot is identical: case " n)
            T.Eq(ConfigJson.Canon(StaticModel.ToMap(c.StaticFor("static"))), ConfigJson.Canon(StaticModel.ToMap(s.StaticFor("static"))), "the state is back")
            T.Eq(TestStatic.Note(c), note, "the restored session composes the same note")
            T.Eq(ConfigJson.Canon(c.Fragments("static")), ConfigJson.Canon(s.Fragments("static")), "fragments restored as saved")
            ; running the model again gives the same fragments and values
            c.ApplyStatic("static", TestStatic.Model())
            T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "the model reproduces fragments and values")
        }
        ; the restored state is a plain object that works with the model
        s := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        c := CallSession()
        c.Restore(ConfigJson.Parse(ConfigJson.Stringify(s.Snapshot())))
        st := c.StaticFor("static")
        T.True(st.ready && st.pingConfirmed && st.gateway = "1.1.1.2" && st.ip = "1.1.1.1", "derived values are back")
        T.True(st is Object && !(st is Map), "a plain object, not a Map")
        st2 := TestStatic.Model().Apply(st, {ipText: "1.1.1.5/30"})
        c.SetStatic("static", st2, TestStatic.Model())
        T.Contains(TestStatic.Note(c), "Gateway 1.1.1.6:", "a restored call is editable")
    }

    static OldSnapshot() {
        s := TestStatic.Make()
        s.UseCategory("static")
        s.AddFragment("static", "an old sample fragment")
        old := s.Snapshot()
        T.False(old["categories"]["static"].Has("static"), "an M6-style snapshot has no static state")
        c := CallSession()
        T.True(c.Restore(old), "restores")
        T.True(StaticModel.IsDefault(c.StaticFor("static")), "default state")
        T.False(c.HasStaticInput(), "no static input")
        T.Eq(c.Fragments("static")[1], "an old sample fragment", "fragments as before")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(old["categories"]), "and snapshots back identically")
        ; a snapshot with static state replaces the previous call's state, one without clears it
        c4 := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        c4.Restore(old)
        T.False(c4.HasStaticInput(), "restore forgets the previous call's static state")
        T.Eq(c4.Fragments("static").Length, 1, "and uses the snapshot's fragments")
    }

    ; An old snapshot (made while the "Add static IP details" box existed) carries includeScripted and the scripted fragment text.
    ; It restores; the key is ignored; the static state adds no line of its own.
    static OldSnapshotIncludeScripted() {
        s := TestStatic.Make()
        s.UseCategory("static")
        snap := s.Snapshot()
        snap["categories"]["static"] := Map("fragments", [], "values", Map(), "static", Map("ipInput", "1.1.1.1", "prefixInput", "/30", "manualInput", "",
            "includeScripted", 1, "pingTarget", "gateway", "pingOutcome", "", "pingConfirmed", 0, "ip", "1.1.1.1", "prefix", "30",
            "mask", "255.255.255.252", "gateway", "1.1.1.2", "gatewayManual", 0))
        back := ConfigJson.Parse(ConfigJson.Stringify(snap))
        c := CallSession()
        T.True(c.Restore(back), "an old snapshot with includeScripted: 1 restores")
        st := c.StaticFor("static")
        T.True(st.ip = "1.1.1.1" && st.prefix = "30" && st.gateway = "1.1.1.2" && st.ready, "the IP state is back")
        T.False(st.HasOwnProp("includeScripted"), "the include flag is ignored")
        T.False(StaticModel.ToMap(st).Has("includeScripted"), "and is not written again")
        c.ApplyStatic("static", TestStatic.Model())
        T.Eq(c.Fragments("static").Length, 0, "running the model adds no static line")
        T.False(InStr(TestStatic.Note(c), "Static IP details") > 0, "and the composed note has no static line")
        T.False(c.Snapshot()["categories"]["static"]["static"].Has("includeScripted"), "a new snapshot has no includeScripted")
        ; same through the "true" spelling and with a manual gateway
        snap["categories"]["static"]["static"]["includeScripted"] := "true"
        snap["categories"]["static"]["static"]["manualInput"] := "1.1.1.2"
        c2 := CallSession()
        T.True(c2.Restore(snap), "restores with other spellings")
        T.True(c2.StaticFor("static").gatewayManual, "the manual gateway is still state")
        c2.ApplyStatic("static", TestStatic.Model())
        T.Eq(c2.Fragments("static").Length, 0, "and still no line (no manual sentence)")
        ; the old saved fragment text stays as saved when the model is not run
        snap["categories"]["static"]["fragments"] := ["Static IP details (placeholder wording): IP 1.1.1.1."]
        c3 := CallSession()
        c3.Restore(snap)
        T.Eq(c3.Fragments("static").Length, 1, "saved fragments are restored as saved (History shows the call as it was)")
    }

    static DamagedSnapshot() {
        s := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        for bad in ["nope", 5, [], Map(), Map("ipInput", 5), Map("ipInput", "1.1.1.1", "prefixInput", "/30", "pingConfirmed", "yes"),
                Map("ipInput", Map(), "prefixInput", [], "pingOutcome", 7), Map("gateway", "9.9.9.9", "includeScripted", 1)] {
            snap := s.Snapshot()
            snap["categories"]["static"]["static"] := bad
            c := CallSession()
            T.True(c.Restore(snap), "still restores with static = " Type(bad))
            st := c.StaticFor("static")
            T.True(st.gateway != "9.9.9.9", "a forged gateway never survives")
            T.Eq(c.Fragments("static").Length, 1, "the saved fragments are kept as they were")
        }
        snap := s.Snapshot()
        snap["categories"]["static"]["static"] := Map("ipInput", "1.1.1.1", "prefixInput", "/30", "includeScripted", "yes", "pingConfirmed", "true", "pingOutcome", "reply")
        c := CallSession()
        c.Restore(snap)
        st := c.StaticFor("static")
        T.True(st.ready && st.pingConfirmed && st.pingOutcome = "reply", "'true' is true, a leftover includeScripted is ignored")
    }

    static HistoryFile() {
        s := TestStatic.With({ipText: "1.1.1.2/30"}, {manualText: "1.1.1.1"}, {pingTarget: "ip"}, {pingOutcome: "noReply"})
        snap := s.Snapshot()
        d := A_Temp "\NFSStaticTest_" A_TickCount "_" Random(1000, 9999)
        DirCreate(d)
        h := History({Dir: d, Agent: "tester", Now: () => "20261010120000000"})
        id := h.Save(snap, "clearAll")
        T.True(id != "", "saved to History")
        T.Contains(FileRead(h.FileFor("2026-10-10"), "UTF-8"), '"ipInput": "1.1.1.2"', "the file holds the static state")
        c := CallSession()
        T.True(c.Restore(h.Get(id)["snapshot"]), "loaded from the file")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "identical")
        T.True(c.StaticFor("static").gatewayManual && c.StaticFor("static").pingOutcome = "noReply", "the state is back")
        ; History.IsEmpty: a snapshot holding only static input is not empty
        only := Map("context", Map(), "categoriesUsed", [], "categories", Map("static", Map("fragments", [], "values", Map(),
            "static", Map("ipInput", "1.1.1.1"))), "noteText", "")
        T.False(History.IsEmpty(only), "a static state alone counts")
        only["categories"]["static"]["static"] := Map()
        T.True(History.IsEmpty(only), "an empty static map does not")
        try DirDelete(d, true)
    }

    static ResetAndNewCall() {
        m := TestStatic.Model()
        s := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        s.ResetCategory("static")
        T.False(s.HasStatic("static"), "ResetCategory drops the static state")
        T.Eq(s.Fragments("static").Length, 0, "and the fragments")
        T.True(s.IsUsed("static"), "but the category stays used")
        s2 := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        s2.Reset()
        T.False(s2.HasStaticInput(), "Reset() forgets it")
        s3 := TestStatic.With({ipText: "1.1.1.1/30"}, {pingOutcome: "reply"})
        s3.BeginCall(CallContext())
        T.False(s3.HasStaticInput(), "BeginCall forgets it")
    }

    static HelperFunctions() {
        a := TestStatic.S({ipText: "1.1.1.1/30"})
        b := StaticModel.Copy(a)
        T.True(StaticModel.Same(a, b) && a != b, "Copy is an equal new object")
        b.ipInput := "9.9.9.9"
        T.Eq(a.ipInput, "1.1.1.1", "and independent")
        T.True(StaticModel.Same(StaticModel.NewState(), StaticModel.NewState()), "two default states are the same")
        T.False(StaticModel.Same(a, StaticModel.NewState()), "different states are not")
        T.False(StaticModel.IsDefault(a), "IsDefault false once typed")
        T.False(StaticModel.IsDefault(TestStatic.S({pingTarget: "ip"})), "a changed ping target is not default")
        T.True(StaticModel.IsDefault(TestStatic.S({pingTarget: "gateway"})), "the default target is")
        T.True(StaticModel.IsDefault({}), "an empty object is default")
        T.Eq(StaticModel.FromMap("x"), "", "FromMap of junk")
        T.False(StaticModel.AddsToNote(TestStatic.S({includeScripted: true})), "the removed include flag adds nothing")
        T.True(StaticModel.AddsToNote(TestStatic.S({pingOutcome: "reply"})), "a hand-picked outcome adds (even if its address is invalid, the agent asked)")
        T.True(StaticModel.ToMap(a).Count = 11, "ToMap has 11 keys")
        ; the state of an unknown / missing category
        T.Eq(StaticModel(Map()).Fragments(a).Fragments.Length, 0, "a model without a static section is silent")
    }

    ; --- App wiring (no window) -------------------------------------------------------------------------------------
    static AppWiring() {
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSStaticLog_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        T.True(app.IsStaticCategory("static"), "static is a static category")
        T.False(app.IsStaticCategory("notDone") || app.IsStaticCategory("equipment") || app.IsStaticCategory("nope"), "others are not")
        T.False(app.IsStepsCategory("static") || app.IsItemsCategory("static"), "and not steps / items")
        T.True(app.StaticModelFor("static") == app.StaticModelFor("static"), "models are cached")
        T.Eq(app.StaticModelFor("notDone"), "", "no model for steps categories")
        T.Eq(app.StaticModelFor("nope"), "", "nor for unknown ones")
        T.True(app.StaticModelFor("static").SentenceCase && app.StaticModelFor("static").EndPunct == ".", "the model copies the note template switches")
        T.False(app.AddSampleFragment("static") || app.AddSampleFragment("notDone") || app.AddSampleFragment("equipment"), "no category takes sample fragments any more")
        T.False(app.StaticSet("notDone", {ipText: "1.1.1.1/30"}), "steps categories take no static state")
        T.False(app.StaticSet("nope", {ipText: "1.1.1.1/30"}), "nor unknown ones")
        ; typing an IP does not use the category
        T.True(app.StaticSet("static", {ipText: "1.1.1.1/30"}), "an IP is accepted")
        T.False(app.Session.IsUsed("static"), "typing an IP does not use the category")
        T.False(app.Stats.Used.Has("static"), "and does not credit it")
        T.Eq(app.Session.StaticFor("static").gateway, "1.1.1.2", "the gateway is calculated")
        T.False(app.StaticSet("static", {ipText: "1.1.1.1/30"}), "the same input again is no change")
        T.False(app.StaticSet("static", {ipText: "1.1.1.1 255.255.255.252"}), "nor the same address in another form")
        T.True(app.StaticSet("static", {manualText: "1.1.1.2"}) && app.StaticSet("static", {manualText: ""}), "manual box changes are state changes")
        T.False(app.Session.IsUsed("static"), "still not used")
        T.True(app.StaticSet("static", {prefixText: "29"}), "prefix box")
        T.False(app.Session.IsUsed("static"), "still not used")
        ; a ping outcome uses it, once
        T.True(app.StaticSet("static", {pingOutcome: "reply"}), "outcome")
        T.True(app.Session.IsUsed("static"), "the outcome uses the category")
        T.Eq(app.Stats.Used["static"], 1, "and credits it once")
        T.Eq(app.Session.Fragments("static").Length, 1, "the ping line is there")
        app.StaticSet("static", {ipText: "1.1.1.5/29"})
        app.StaticSet("static", {pingOutcome: "noReply"})
        T.Eq(app.Stats.Used["static"], 1, "only the first thing uses the category")
        T.Eq(app.Session.Fragments("static").Length, 1, "one ping line, replaced")
        ; a refused address writes no ping line
        app.StaticSet("static", {ipText: "1.1.1.0/29"})
        T.Eq(app.Session.Fragments("static").Length, 0, "network-address IP: the gateway ping is not printed")
        try FileDelete(app.Logger.Path)
    }

    ; (d) typing a valid IP leaves the category unused and the note without a static line
    static TypingNeverUsesCategory() {
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSStaticLog3_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        T.True(app.StaticSet("static", {ipText: "1.1.1.1/30"}), "a valid IP is accepted")
        T.True(app.Session.StaticFor("static").ready, "and the gateway is worked out")
        T.False(app.Session.IsUsed("static"), "the category stays unused")
        T.False(app.Stats.Used.Has("static"), "nothing is credited")
        T.Eq(app.Session.Fragments("static").Length, 0, "no fragment")
        T.False(app.Session.HasContent(), "the call has no content")
        T.False(InStr(TestStatic.Note(app.Session), "Static") > 0 || InStr(TestStatic.Note(app.Session), "1.1.1") > 0, "and the note has no static line")
        app.StaticSet("static", {manualText: "1.1.1.2"})
        app.StaticSet("static", {prefixText: "29"})
        app.StaticSet("static", {pingTarget: "ip"})
        T.False(app.Session.IsUsed("static"), "a manual gateway, a prefix change and a target change do not use it either")
        T.False(app.Stats.Used.Has("static"), "still nothing credited")
        T.False(StaticModel.AddsToNote(app.Session.StaticFor("static")), "the state adds nothing to the note")
        try FileDelete(app.Logger.Path)
    }

    ; (e) a confirmed ping outcome adds its line and marks the category used
    static ConfirmedPingUsesCategory() {
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSStaticLog4_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        app.StaticSet("static", {ipText: "1.1.1.1/30"})
        T.True(app.StaticSet("static", {pingOutcome: "reply"}), "a hand-picked outcome (confirmed)")
        T.True(app.Session.IsUsed("static"), "the category is used")
        T.Eq(app.Stats.Used["static"], 1, "and credited once")
        T.Eq(app.Session.Fragments("static")[1], "Ping to Gateway 1.1.1.2: reply received (placeholder wording).", "the line is in the fragments")
        T.True(app.Session.HasContent(), "the call has content")
        T.Eq(TestStatic.Tail(TestStatic.Note(app.Session)), "Ping to Gateway 1.1.1.2: reply received (placeholder wording).", "and in the composed note, with no static IP line")
        ; a prefilled outcome is not enough until it is confirmed
        app.Session.BeginCall(c)
        app.Stats := TestStepsNotes.FakeStats()
        app.StaticSet("static", {ipText: "1.1.1.1/30"})
        app.StaticPrefillPing("static", "noReply")
        T.False(app.Session.IsUsed("static"), "unconfirmed: not used")
        app.StaticSet("static", {pingConfirmed: true})
        T.True(app.Session.IsUsed("static"), "confirmed: used")
        T.Eq(TestStatic.Tail(TestStatic.Note(app.Session)), "Ping to Gateway 1.1.1.2: no reply (placeholder wording).", "and in the note")
        try FileDelete(app.Logger.Path)
    }

    static CopyOfState() {
        ; a ping outcome alone uses the category; a prefilled one does not until confirmed
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSStaticLog2_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        app.StaticSet("static", {ipText: "1.1.1.1/30"})
        T.True(app.StaticPrefillPing("static", "noReply"), "prefill accepted")
        T.False(app.Session.IsUsed("static"), "a prefilled outcome does not use the category")
        T.False(app.Stats.Used.Has("static"), "and does not credit it")
        T.Eq(app.Session.Fragments("static").Length, 0, "and is not in the note")
        T.True(app.Session.StaticFor("static").pingOutcome = "noReply" && !app.Session.StaticFor("static").pingConfirmed, "but it is in the state, unconfirmed")
        T.False(app.StaticPrefillPing("static", "maybe"), "an unknown outcome id is refused")
        T.False(app.StaticPrefillPing("notDone", "reply"), "a non-static category is refused")
        T.True(app.StaticPrefillPing("static", "reply", "ip"), "prefill with a target")
        T.Eq(app.Session.StaticFor("static").pingTarget, "ip", "target set")
        T.True(app.StaticSet("static", {pingConfirmed: true}), "the agent confirms")
        T.True(app.Session.IsUsed("static"), "now the category is used")
        T.Eq(app.Stats.Used["static"], 1, "credited once")
        T.Eq(app.Session.Fragments("static")[1], "Ping to IP 1.1.1.1: reply received (placeholder wording).", "and the line is in the note")
        ; a hand-picked outcome uses it at once (new call)
        app.Session.BeginCall(c)
        app.StaticSet("static", {ipText: "1.1.1.1/30"})
        app.StaticSet("static", {pingOutcome: "reply"})
        T.True(app.Session.IsUsed("static"), "a hand-picked outcome uses the category")
        ; RefreshStatic re-runs the model after a config change
        app.Config.Config["categories"][4]["static"]["pingOutcomes"][1]["fragment"] := "CHANGED {pingTarget}"
        app.Config := {Config: Util.Clone(app.Config.Config)}
        app.RefreshStatic("static")
        T.Eq(app.Session.Fragments("static")[1], "CHANGED Gateway", "RefreshStatic uses the new wording")
        ; reset
        app.ResetCategory("static")
        T.False(app.Session.HasStaticInput(), "ResetCategory clears the state")
        ; MissingRequired only looks at steps categories
        T.Eq(app.MissingRequired().Length, 0, "static never blocks a copy through MissingRequired")
        try FileDelete(app.Logger.Path)
    }
}
