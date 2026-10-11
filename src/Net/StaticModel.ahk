#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
#Include %A_LineFile%\..\Ipv4.ahk
; StaticModel.ahk - the model of the "static" category (PLAN section 7): the IP utility state and the manual ping
; outcome. Pure logic: no GUI, no files, no clock, no network. The IP utility never writes to the note; only a confirmed
; ping outcome does. Every calculation is in Ipv4 (code-only); the config only supplies wording (category.static):
;   pingTargets[]           {id: "gateway"|"ip", label}                 ids are fixed, labels are wording
;   pingOutcomes[]          {id: "reply"|"noReply", label, fragment}   fragment uses {pingTarget} (label) and {pingAddress}
;
; STATE  (a plain object; the session keeps one per static category; Apply() returns a new one, never changes the old)
;   inputs   ipInput prefixInput manualInput            the text in the three boxes (IP, prefix/mask, manual gateway)
;            pingTarget ("gateway"|"ip")  pingOutcome ("" | "reply" | "noReply")  pingConfirmed (bool)
;   derived  ip prefix mask network broadcast gateway   "" when not (yet) valid; prefix is the number as text ("30")
;            gatewayManual (bool)                         the gateway in use was typed by the agent
;            autoGateway                                  the IP+1 gateway when the rule allows it (even if a manual one is in use)
;            ipError prefixError gatewayError             specific messages; gatewayErrorKind is "auto" | "host" | "manual"
;            canManual (bool)                             the auto rule failed in a way a typed gateway can fix (IP+1 = broadcast, /31, /32)
;            ready (bool)                                 ip, prefix and gateway are all valid
;   Recalc() derives everything from the inputs, so a restored or hand-edited state can never disagree with itself.
;
; Rules
;   - Never write a note line from an invalid IP / gateway: Fragments() returns a warning instead.
;   - Network and broadcast are internal maths (validation and error messages); the page does not show them as results.
;   - Old snapshots that still carry includeScripted (a removed feature) restore fine: the key is ignored.
;   - The ping line when an outcome is chosen AND pingConfirmed AND the target's address is valid. (M7: the agent's own
;     choice counts as confirmed. M8's pinger prefills the outcome with SetPingResult(state, id, false); the agent then
;     confirms it and only then does it reach the note.)
;   - Typed text is inserted literally (values never contain "{" except an admin label, which goes through Values).

class StaticModel {
    static DEFAULT_TARGET := "gateway"

    __New(category) {
        this.Category := category
        this.SentenceCase := true            ; the Composer's note-template switches (App.StaticModelFor copies them from the config)
        this.EndPunct := "."
        s := (category is Map && category.Has("static") && category["static"] is Map) ? category["static"] : Map()
        this.Targets := [], this.TargetById := Map()
        this.Outcomes := [], this.OutcomeById := Map()
        StaticModel._Load(s, "pingTargets", this.Targets, this.TargetById)
        StaticModel._Load(s, "pingOutcomes", this.Outcomes, this.OutcomeById)
    }

    static _Load(s, key, list, byId) {
        if (s.Has(key) && s[key] is Array)
            for o in s[key]
                if (o is Map && o.Has("id") && o["id"] is String && !byId.Has(o["id"])) {
                    list.Push(o)
                    byId[o["id"]] := o
                }
    }

    static Label(o) => (o is Map && o.Has("label")) ? String(o["label"]) : (o is Map && o.Has("id") ? String(o["id"]) : "")

    TargetLabel(id) => this.TargetById.Has(id) ? StaticModel.Label(this.TargetById[id]) : ""
    OutcomeLabel(id) => this.OutcomeById.Has(id) ? StaticModel.Label(this.OutcomeById[id]) : ""

    ; --- state ----------------------------------------------------------------------------------------------------
    static NewState() => StaticModel.Recalc({ipInput: "", prefixInput: "", manualInput: "",
        pingTarget: StaticModel.DEFAULT_TARGET, pingOutcome: "", pingConfirmed: false})

    static Copy(s) {
        n := {}
        if IsObject(s)
            for k in s.OwnProps()
                n.%k% := s.%k%
        return n
    }

    static _Str(s, k) => (IsObject(s) && s.HasOwnProp(k)) ? String(s.%k%) : ""
    static _Bool(s, k) => (IsObject(s) && s.HasOwnProp(k) && !IsObject(s.%k%) && (s.%k% = 1 || s.%k% = "1" || s.%k% = "true")) ? true : false

    ; Derive everything from the inputs. Returns a new state.
    static Recalc(s) {
        n := {ipInput: Util.Trim(StaticModel._Str(s, "ipInput")), prefixInput: Util.Trim(StaticModel._Str(s, "prefixInput")),
            manualInput: Util.Trim(StaticModel._Str(s, "manualInput")),
            pingTarget: StaticModel._Str(s, "pingTarget"), pingOutcome: Util.Trim(StaticModel._Str(s, "pingOutcome")),
            pingConfirmed: StaticModel._Bool(s, "pingConfirmed")}
        if (n.pingTarget = "")
            n.pingTarget := StaticModel.DEFAULT_TARGET
        if (n.pingOutcome = "")
            n.pingConfirmed := false
        n.ip := "", n.prefix := "", n.mask := "", n.network := "", n.broadcast := "", n.gateway := "", n.autoGateway := ""
        n.gatewayManual := false, n.ipError := "", n.prefixError := "", n.gatewayError := "", n.gatewayErrorKind := ""
        n.canManual := false, n.ready := false
        ipInt := "", pre := ""
        if (n.ipInput != "") {
            r := Ipv4.Parse(n.ipInput)
            if !r.Ok
                n.ipError := r.Error
            else {
                u := Ipv4.IsUsableHostRange(r.Int)
                if u.Ok
                    n.ip := r.Text, ipInt := r.Int
                else
                    n.ipError := u.Error
            }
        }
        if (n.prefixInput != "") {
            p := Ipv4.ParsePrefix(n.prefixInput)
            if p.Ok
                n.prefix := String(p.Prefix), n.mask := p.Mask, pre := p.Prefix
            else
                n.prefixError := p.Error
        } else if (ipInt != "")
            n.prefixError := "Enter a prefix (like /30) or a mask (like 255.255.255.252) to calculate the gateway."
        if (ipInt != "" && pre != "") {
            n.network := Ipv4.ToText(Ipv4.Network(ipInt, pre))
            n.broadcast := Ipv4.ToText(Ipv4.Broadcast(ipInt, pre))
            auto := Ipv4.Gateway(ipInt, pre)
            if auto.Ok
                n.autoGateway := auto.Gateway
            n.canManual := auto.CanManual
            if (n.manualInput != "" && (auto.Ok || auto.CanManual)) {
                host := Ipv4.CheckHost(ipInt, pre)
                if !host.Ok
                    n.gatewayError := host.Error, n.gatewayErrorKind := "host"
                else {
                    chk := Ipv4.CheckManualGateway(n.manualInput, ipInt, pre)
                    if chk.Ok
                        n.gateway := chk.Text, n.gatewayManual := true
                    else
                        n.gatewayError := chk.Error, n.gatewayErrorKind := "manual"
                }
            } else if auto.Ok
                n.gateway := auto.Gateway
            else
                n.gatewayError := auto.Error, n.gatewayErrorKind := "auto"
        }
        n.ready := (n.ip != "" && n.prefix != "" && n.gateway != "")
        return n
    }

    ; Apply a change and return the new state. patch: an object with any of
    ;   ipText      the whole IP box ("1.1.1.1", "1.1.1.1/30", "1.1.1.1 255.255.255.252"): split into IP and prefix
    ;   prefixText  the prefix / mask box          manualText  the manual gateway box
    ;   pingTarget  pingOutcome (a manual choice is confirmed)  pingConfirmed
    Apply(state, patch) {
        s := StaticModel.Copy(state)
        has := (k) => patch.HasOwnProp(k)
        if has("ipText") {
            sp := Ipv4.SplitInput(patch.ipText)
            s.ipInput := sp.IpText
            if sp.HasPrefix
                s.prefixInput := sp.PrefixText
        }
        if has("prefixText")
            s.prefixInput := String(patch.prefixText)
        if has("manualText")
            s.manualInput := String(patch.manualText)
        if has("pingTarget")
            s.pingTarget := String(patch.pingTarget)
        if has("pingOutcome") {
            s.pingOutcome := String(patch.pingOutcome)
            s.pingConfirmed := s.pingOutcome != ""
        }
        if has("pingConfirmed")
            s.pingConfirmed := patch.pingConfirmed ? true : false
        n := StaticModel.Recalc(s)
        if (n.ip != "")
            n.ipInput := n.ip                    ; show what was understood: "1.1.1.1/30" becomes "1.1.1.1" + "/30"
        if (n.prefix != "")
            n.prefixInput := "/" n.prefix
        return n
    }

    ; The seam for M8's pinger: record a ping result. confirmed false = prefilled, not yet agreed by the agent
    ; (it stays out of the note and does not mark the category used until the agent confirms it).
    SetPingResult(state, outcomeId, confirmed := false) => this.Apply(state, {pingOutcome: outcomeId, pingConfirmed: confirmed})

    ; True when this state puts something in the note: a confirmed ping outcome. Only then does the category count as used.
    static AddsToNote(s) => StaticModel._Str(s, "pingOutcome") != "" && StaticModel._Bool(s, "pingConfirmed")

    ; The address the chosen ping target points at ("" when it is not valid yet).
    static PingAddress(s) => StaticModel._Str(s, "pingTarget") = "ip" ? StaticModel._Str(s, "ip") : (StaticModel._Str(s, "pingTarget") = "gateway" ? StaticModel._Str(s, "gateway") : "")

    ; --- snapshot form ----------------------------------------------------------------------------------------------
    ; Plain Map (inputs, flags and the values that matter in the saved note; the rest is derived again on restore).
    static ToMap(s) => Map("ipInput", StaticModel._Str(s, "ipInput"), "prefixInput", StaticModel._Str(s, "prefixInput"),
        "manualInput", StaticModel._Str(s, "manualInput"),
        "pingTarget", StaticModel._Str(s, "pingTarget"), "pingOutcome", StaticModel._Str(s, "pingOutcome"),
        "pingConfirmed", StaticModel._Bool(s, "pingConfirmed") ? 1 : 0,
        "ip", StaticModel._Str(s, "ip"), "prefix", StaticModel._Str(s, "prefix"), "mask", StaticModel._Str(s, "mask"),
        "gateway", StaticModel._Str(s, "gateway"), "gatewayManual", StaticModel._Bool(s, "gatewayManual") ? 1 : 0)

    ; A state from a snapshot Map (a damaged one gives whatever is usable); "" when m is not a Map.
    static FromMap(m) {
        if !(m is Map)
            return ""
        g := (k) => (m.Has(k) && !IsObject(m[k])) ? String(m[k]) : ""
        return StaticModel.Recalc({ipInput: g("ipInput"), prefixInput: g("prefixInput"), manualInput: g("manualInput"),
            pingTarget: g("pingTarget"), pingOutcome: g("pingOutcome"), pingConfirmed: g("pingConfirmed") = "1" || g("pingConfirmed") = "true"})
    }

    ; Nothing entered: no need to keep it in a snapshot.
    static IsDefault(s) => StaticModel._Str(s, "ipInput") = "" && StaticModel._Str(s, "prefixInput") = "" && StaticModel._Str(s, "manualInput") = ""
        && StaticModel._Str(s, "pingOutcome") = ""
        && (StaticModel._Str(s, "pingTarget") = "" || StaticModel._Str(s, "pingTarget") = StaticModel.DEFAULT_TARGET)

    ; Same inputs and flags (the derived values follow from them).
    static Same(a, b) {
        ma := StaticModel.ToMap(a), mb := StaticModel.ToMap(b)
        for k, v in ma
            if !(v == mb[k])
                return false
        return true
    }

    ; --- note fragments ---------------------------------------------------------------------------------------------
    ; {Fragments: [text...], Values: Map, Warnings: [text...]}. config (optional): a category Map to take the wording
    ; from instead of the one this model was made with.
    Fragments(state, config := "") {
        m := (IsObject(config) && config is Map) ? StaticModel(config) : this
        s := StaticModel.Recalc(state)
        frags := [], values := Map(), warns := []
        if (s.pingOutcome != "") {
            if !m.OutcomeById.Has(s.pingOutcome)
                warns.Push('Ping outcome "' s.pingOutcome '" is not in the config; the ping line was not added.')
            else if !s.pingConfirmed
                warns.Push("The ping outcome is not confirmed yet; the ping line was not added.")
            else if !m.TargetById.Has(s.pingTarget)
                warns.Push('Ping target "' s.pingTarget '" is not in the config; the ping line was not added.')
            else {
                addr := StaticModel.PingAddress(s)
                if (addr = "")
                    warns.Push("The ping target has no valid address yet; the ping line was not added.")
                else {
                    o := m.OutcomeById[s.pingOutcome]
                    tpl := o.Has("fragment") ? String(o["fragment"]) : ""
                    if (Util.Trim(tpl) != "")
                        frags.Push(StaticModel._Fill(tpl, Map("pingTarget", m.TargetLabel(s.pingTarget), "pingAddress", addr), values))
                }
            }
        }
        return {Fragments: frags, Values: values, Warnings: warns}
    }

    ; One pass over the template: {pingTarget} {pingAddress} are replaced when vals has
    ; them (anything else is left for the Composer). A value that contains "{" goes into Values under a private name.
    static _Fill(tpl, vals, holder) {
        out := "", pos := 1
        while RegExMatch(tpl, "\{([A-Za-z]+)\}", &m, pos) {
            out .= SubStr(tpl, pos, m.Pos - pos)
            if vals.Has(m[1]) {
                txt := vals[m[1]]
                if (IsObject(holder) && InStr(txt, "{")) {
                    key := "static" StrUpper(SubStr(m[1], 1, 1)) SubStr(m[1], 2)
                    holder[key] := txt
                    out .= "{" key "}"
                } else
                    out .= txt
            } else
                out .= m[0]
            pos := m.Pos + m.Len
        }
        return out SubStr(tpl, pos)
    }

}
