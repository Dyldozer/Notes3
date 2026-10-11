#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\Core\Util.ahk
; Ipv4.ahk - IPv4 parsing, validation, mask <-> prefix, network / broadcast and the static-IP gateway rule
; (PLAN section 2 and 7). Pure logic: no GUI, no files, no clock. All of it is code-only (not configurable).
;
; Addresses are plain integers 0..4294967295 (AHK integers are 64-bit, so no sign problems). Every mask is made with
; a shift and then masked to 32 bits; there is no bitwise NOT on a 64-bit value anywhere.
;
;   Ipv4.Parse(text)               -> {Ok, Int, Text, Error}        4 decimal octets 0-255, no leading zeros, no spaces
;   Ipv4.IsUsableHostRange(int)    -> {Ok, Error}                   rejects 0.x.x.x, 127.x.x.x and 224.0.0.0 and above
;   Ipv4.ToText(int)               -> "a.b.c.d"
;   Ipv4.MaskFromPrefix(p)         -> mask integer (0..32), "" when p is not 0..32
;   Ipv4.PrefixFromMask(text)      -> {Ok, Prefix, MaskInt, Mask, Error}   contiguous masks only
;   Ipv4.ParsePrefix(text)         -> {Ok, Prefix, Mask, Error}     "/30", "30" or "255.255.255.252"
;   Ipv4.Network(int, p) / Ipv4.Broadcast(int, p)
;   Ipv4.SplitInput(text)          -> {IpText, PrefixText, HasPrefix}      only splits; nothing is validated
;   Ipv4.ParseInput(text)          -> {Ok, Ip, IpInt, Prefix, Mask, Error, ErrorField}
;                                     a.b.c.d | a.b.c.d/p | a.b.c.d / p | a.b.c.d/mask | a.b.c.d mask
;   Ipv4.Gateway(ip, prefix)       -> {Ok, Gateway, Network, Broadcast, Error, CanManual}   supported prefixes /8-/30
;   Ipv4.CheckHost(ip, prefix)     -> {Ok, Error}                   the IP is not the network / broadcast address
;   Ipv4.CheckManualGateway(gw, ip, prefix) -> {Ok, Int, Text, Error}
;
; Every error text names the value that is wrong and says what to do about it.

class Ipv4 {
    static DASH := Chr(0x2014)
    static MAX := 4294967295
    static GW_MIN_PREFIX := 8
    static GW_MAX_PREFIX := 30

    static _Bad(msg) => {Ok: false, Int: 0, Text: "", Error: msg}

    ; --- addresses ------------------------------------------------------------------------------------------------
    static Parse(text) {
        s := Util.Trim(text)
        if (s = "")
            return Ipv4._Bad("Enter an IP address, for example 1.1.1.1/30.")
        parts := StrSplit(s, ".")
        if (parts.Length != 4)
            return Ipv4._Bad('"' s '" is not a valid IPv4 address: it needs 4 numbers separated by dots (like 1.1.1.1), but has ' parts.Length ".")
        val := 0
        for p in parts {
            if (p = "")
                return Ipv4._Bad('"' s '" has an empty number between dots ' Ipv4.DASH ' write all 4 numbers (like 1.1.1.1).')
            if !RegExMatch(p, "D)^[0-9]+$")
                return Ipv4._Bad('"' p '" in "' s '" is not a number ' Ipv4.DASH ' use digits 0-9 only.')
            if (StrLen(p) > 1 && SubStr(p, 1, 1) = "0")
                return Ipv4._Bad('"' p '" in "' s '" has a leading zero ' Ipv4.DASH ' write ' Integer(p) ' instead of ' p ".")
            if (StrLen(p) > 3 || Integer(p) > 255)
                return Ipv4._Bad('"' p '" in "' s '" is above 255 ' Ipv4.DASH ' each number must be 0 to 255.')
            val := val * 256 + Integer(p)
        }
        return {Ok: true, Int: val, Text: Ipv4.ToText(val), Error: ""}
    }

    static ToText(n) => ((n >> 24) & 255) "." ((n >> 16) & 255) "." ((n >> 8) & 255) "." (n & 255)

    ; 0.x.x.x, 127.x.x.x (loopback) and 224.0.0.0 and above (multicast / reserved) are not host addresses.
    static IsUsableHostRange(n) {
        if !(n is Integer) || n < 0 || n > Ipv4.MAX
            return {Ok: false, Error: "That is not an IPv4 address."}
        t := Ipv4.ToText(n), a := n >> 24
        if (a = 0)
            return {Ok: false, Error: t " is in 0.x.x.x, which can't be used as a host address " Ipv4.DASH " check the first number."}
        if (a = 127)
            return {Ok: false, Error: t " is in 127.x.x.x (loopback), which can't be used as a host address " Ipv4.DASH " check the first number."}
        if (a >= 224)
            return {Ok: false, Error: t " is in 224.0.0.0 and above (multicast / reserved), which can't be used as a host address " Ipv4.DASH " check the first number."}
        return {Ok: true, Error: ""}
    }

    ; --- masks ----------------------------------------------------------------------------------------------------
    static MaskFromPrefix(p) {
        if !(p is Integer) || p < 0 || p > 32
            return ""
        if (p = 0)
            return 0
        return (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF
    }

    ; A dotted mask: the 1 bits must be one block (255.255.255.0 yes, 255.0.255.0 no).
    static PrefixFromMask(text) {
        r := Ipv4.Parse(text)
        s := Util.Trim(text)
        if !r.Ok
            return {Ok: false, Prefix: "", MaskInt: 0, Mask: "", Error: "Mask: " r.Error}
        loop 33 {
            p := A_Index - 1
            if (Ipv4.MaskFromPrefix(p) = r.Int)
                return {Ok: true, Prefix: p, MaskInt: r.Int, Mask: r.Text, Error: ""}
        }
        return {Ok: false, Prefix: "", MaskInt: 0, Mask: "", Error: '"' s '" is not a valid subnet mask ' Ipv4.DASH
            . " the 1s must be one block (like 255.255.255.0 or 255.255.255.252)."}
    }

    ; "/30", "30" or "255.255.255.252" (also "/255.255.255.252").
    static ParsePrefix(text) {
        s := Util.Trim(text)
        bad := (msg) => {Ok: false, Prefix: "", Mask: "", Error: msg}
        if (s = "")
            return bad("Enter a prefix (like /30) or a mask (like 255.255.255.252).")
        raw := s
        if (SubStr(s, 1, 1) = "/") {
            s := Util.Trim(SubStr(s, 2))
            if (s = "")
                return bad('"' raw '" has no number after the "/" ' Ipv4.DASH " write a prefix like /30.")
        }
        if InStr(s, ".") {
            m := Ipv4.PrefixFromMask(s)
            return {Ok: m.Ok, Prefix: m.Prefix, Mask: m.Mask, Error: m.Error}
        }
        if !RegExMatch(s, "D)^[0-9]{1,2}$")
            return bad('"' raw '" is not a valid prefix or mask ' Ipv4.DASH " use /30, 30 or 255.255.255.252.")
        p := Integer(s)
        if (p > 32)
            return bad("/" p " is not a valid prefix " Ipv4.DASH " use a number from 0 to 32.")
        return {Ok: true, Prefix: p, Mask: Ipv4.ToText(Ipv4.MaskFromPrefix(p)), Error: ""}
    }

    static Network(n, p) => n & Ipv4.MaskFromPrefix(p)

    static Broadcast(n, p) => Ipv4.Network(n, p) + (Ipv4.MAX - Ipv4.MaskFromPrefix(p))

    ; --- the IP box -------------------------------------------------------------------------------------------------
    ; Only splits the text into the IP part and the prefix / mask part:  a.b.c.d/p   a.b.c.d / p   a.b.c.d mask
    static SplitInput(text) {
        s := Util.Trim(text)
        slash := InStr(s, "/")
        if slash
            return {IpText: Util.Trim(SubStr(s, 1, slash - 1)), PrefixText: Util.Trim(SubStr(s, slash + 1)), HasPrefix: true}
        tok := StrSplit(RegExReplace(s, "\s+", " "), " ")
        if (tok.Length = 2)
            return {IpText: tok[1], PrefixText: tok[2], HasPrefix: true}
        return {IpText: s, PrefixText: "", HasPrefix: false}       ; one part, or too many (Parse then reports it)
    }

    ; Ok with Prefix "" when only an address was typed. ErrorField is "ip" or "prefix" when Ok is false.
    static ParseInput(text) {
        sp := Ipv4.SplitInput(text)
        fail := (field, msg, ip := "", ipInt := 0) => {Ok: false, Ip: ip, IpInt: ipInt, Prefix: "", Mask: "", Error: msg, ErrorField: field}
        ip := Ipv4.Parse(sp.IpText)
        if !ip.Ok
            return fail("ip", ip.Error)
        u := Ipv4.IsUsableHostRange(ip.Int)
        if !u.Ok
            return fail("ip", u.Error)
        if !sp.HasPrefix
            return {Ok: true, Ip: ip.Text, IpInt: ip.Int, Prefix: "", Mask: "", Error: "", ErrorField: ""}
        if (sp.PrefixText = "")
            return fail("prefix", 'Nothing after the "/" ' Ipv4.DASH " enter a prefix like /30 or a mask like 255.255.255.252.", ip.Text, ip.Int)
        pr := Ipv4.ParsePrefix(sp.PrefixText)
        if !pr.Ok
            return fail("prefix", pr.Error, ip.Text, ip.Int)
        return {Ok: true, Ip: ip.Text, IpInt: ip.Int, Prefix: pr.Prefix, Mask: pr.Mask, Error: "", ErrorField: ""}
    }

    ; --- the gateway rule -------------------------------------------------------------------------------------------
    ; Gateway = IP + 1. Prefix /8 to /30 only. The IP must not be the network or the broadcast address, and IP+1 must be
    ; below the broadcast address. Network / Broadcast are filled in whenever they could be worked out.
    static Gateway(ip, prefix) {
        res := {Ok: false, Gateway: "", Network: "", Broadcast: "", Error: "", CanManual: false}
        if !(ip is Integer) || ip < 0 || ip > Ipv4.MAX {
            res.Error := "Enter a valid IP address first."
            return res
        }
        if !(prefix is Integer) || prefix < 0 || prefix > 32 {
            res.Error := "Prefix must be /8 to /30 (got " (prefix is Integer ? "/" prefix : '"' prefix '"') ")."
            return res
        }
        res.Network := Ipv4.ToText(Ipv4.Network(ip, prefix))
        res.Broadcast := Ipv4.ToText(Ipv4.Broadcast(ip, prefix))
        if (prefix < Ipv4.GW_MIN_PREFIX) {
            res.Error := "/" prefix ": Prefix must be /8 to /30 " Ipv4.DASH " check the prefix or mask."
            return res
        }
        if (prefix > Ipv4.GW_MAX_PREFIX) {
            res.Error := "/" prefix ": Unsupported for auto-gateway (/31, /32) " Ipv4.DASH " enter the gateway manually."
            res.CanManual := true
            return res
        }
        bad := Ipv4._HostProblem(ip, prefix)
        if (bad != "") {
            res.Error := bad
            return res
        }
        gw := ip + 1
        if (gw >= Ipv4.Broadcast(ip, prefix)) {
            res.Error := "IP+1 (" Ipv4.ToText(gw) ") would be the broadcast address " Ipv4.DASH " enter the gateway manually."
            res.CanManual := true
            return res
        }
        res.Ok := true
        res.Gateway := Ipv4.ToText(gw)
        return res
    }

    ; "" when the IP may be used as a host in its subnet, else the message. /31 and /32 have no network / broadcast address.
    static _HostProblem(ip, prefix) {
        if (prefix >= 31)
            return ""
        if (ip = Ipv4.Network(ip, prefix))
            return Ipv4.ToText(ip) " is the network address for /" prefix " " Ipv4.DASH " check the IP or prefix."
        if (ip = Ipv4.Broadcast(ip, prefix))
            return Ipv4.ToText(ip) " is the broadcast address for /" prefix " " Ipv4.DASH " check the IP or prefix."
        return ""
    }

    static CheckHost(ip, prefix) {
        if !(ip is Integer) || ip < 0 || ip > Ipv4.MAX || !(prefix is Integer) || prefix < 0 || prefix > 32
            return {Ok: false, Error: "Enter a valid IP address and prefix first."}
        bad := Ipv4._HostProblem(ip, prefix)
        return {Ok: bad = "", Error: bad}
    }

    ; A gateway typed by the agent: a valid host address in the same subnet as the IP; not the IP, not the network or
    ; broadcast address (/31 and /32 have none). ip may be an integer or "a.b.c.d" text.
    static CheckManualGateway(gw, ip, prefix) {
        bad := (msg) => {Ok: false, Int: 0, Text: "", Error: msg}
        if (ip is String) {
            pi := Ipv4.Parse(ip)
            if !pi.Ok
                return bad("Enter a valid IP address first.")
            ip := pi.Int
        }
        if !(ip is Integer) || ip < 0 || ip > Ipv4.MAX || !(prefix is Integer) || prefix < 0 || prefix > 32
            return bad("Enter the IP and prefix first so the gateway can be checked.")
        g := Ipv4.Parse(gw)
        if !g.Ok
            return bad("Gateway: " g.Error)
        u := Ipv4.IsUsableHostRange(g.Int)
        if !u.Ok
            return bad("Gateway: " u.Error)
        net := Ipv4.Network(ip, prefix), bc := Ipv4.Broadcast(ip, prefix)
        if (Ipv4.Network(g.Int, prefix) != net)
            return bad("Gateway " g.Text " is not in the same subnet as " Ipv4.ToText(ip) "/" prefix " (" Ipv4.ToText(net) " to " Ipv4.ToText(bc) ").")
        if (g.Int = ip)
            return bad("Gateway " g.Text " is the same as the IP " Ipv4.DASH " use a different address.")
        if (prefix < 31 && g.Int = net)
            return bad("Gateway " g.Text " is the network address for /" prefix " " Ipv4.DASH " use a host address.")
        if (prefix < 31 && g.Int = bc)
            return bad("Gateway " g.Text " is the broadcast address for /" prefix " " Ipv4.DASH " use a host address.")
        return {Ok: true, Int: g.Int, Text: g.Text, Error: ""}
    }
}
