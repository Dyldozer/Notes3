#Requires AutoHotkey v2.0
; TestIpv4.ahk - the IPv4 library (PLAN section 7): parsing, usable range, mask <-> prefix, network / broadcast, the IP box
; input forms, the gateway rule and the manual gateway check. Table driven. Headless.

class TestIpv4 {
    static Name := "Ipv4"

    static Run() {
        for name in ["ParseTable", "ParseEdges", "UsableRange", "ToTextRoundTrip", "MaskPrefixAll", "MaskHelpers", "NonContiguous", "NetworkBroadcast",
                "SplitAndParseInput", "ValidTable", "ErrorTable", "ErrorFields", "GatewayApi", "CheckHost", "ManualGateway", "ManualGatewayEdge", "NoThrow"]
            T.Case(name, ObjBindMethod(TestIpv4, name))
    }

    ; The whole pipeline the IP box uses: ParseInput, then the gateway rule when a prefix was given.
    static Eval(text) {
        r := Ipv4.ParseInput(text)
        out := {Ok: false, Ip: r.Ip, Prefix: r.Prefix, Mask: r.Mask, Gateway: "", Network: "", Broadcast: "", Error: r.Error}
        if !r.Ok
            return out
        if (r.Prefix = "") {
            out.Error := "No prefix: enter a prefix or mask"
            return out
        }
        g := Ipv4.Gateway(r.IpInt, r.Prefix)
        out.Ok := g.Ok, out.Gateway := g.Gateway, out.Network := g.Network, out.Broadcast := g.Broadcast, out.Error := g.Error
        return out
    }

    ; --- Parse ----------------------------------------------------------------------------------------------------
    static ParseTable() {
        good := [["1.1.1.1", 16843009], ["0.0.0.0", 0], ["255.255.255.255", 4294967295], ["10.0.0.1", 167772161], ["192.168.1.254", 3232236030],
            ["1.2.3.4", 16909060], ["0.0.0.1", 1], ["0.0.1.0", 256], ["1.0.0.0", 16777216], ["100.64.0.1", 1681915905], ["172.16.5.1", 2886731009]]
        for g in good {
            r := Ipv4.Parse(g[1])
            T.True(r.Ok && r.Int = g[2] && r.Text = g[1] && r.Error = "", "valid: " g[1])
        }
        ; surrounding whitespace is trimmed (a tab, CR/LF and a non-breaking space too)
        for w in [" 1.1.1.1", "1.1.1.1 ", "  1.1.1.1  ", "`t1.1.1.1`t", "1.1.1.1`r`n", "`n1.1.1.1", Chr(0xA0) "1.1.1.1" Chr(0xA0)]
            T.True(Ipv4.Parse(w).Ok && Ipv4.Parse(w).Text = "1.1.1.1", "whitespace trimmed: " StrReplace(StrReplace(StrReplace(w, "`t", "\t"), "`r", "\r"), "`n", "\n"))
        ; {text, text the message must name}
        bad := [["", ""], ["   ", ""], ["1", '"1"'], ["1.1", '"1.1"'], ["1.1.1", '"1.1.1"'], ["1.1.1.1.1", '"1.1.1.1.1"'], ["1.1.1.1.1.1", '"1.1.1.1.1.1"'],
            ["256.1.1.1", '"256"'], ["1.256.1.1", '"256"'], ["1.1.256.1", '"256"'], ["1.1.1.256", '"256"'], ["999.999.999.999", '"999"'],
            ["1000.1.1.1", '"1000"'], ["99999999999999999999.1.1.1", "99999999999999999999"],
            ["01.1.1.1", '"01"'], ["1.01.1.1", '"01"'], ["1.1.01.1", '"01"'], ["1.1.1.01", '"01"'], ["00.1.1.1", '"00"'], ["000.1.1.1", '"000"'],
            ["001.1.1.1", '"001"'], ["1.1.1.00", '"00"'], ["010.0.0.1", '"010"'],
            ["a.b.c.d", '"a"'], ["1.1.1.x", '"x"'], ["1.1.1.1a", '"1a"'], ["1.1.1.0x1", '"0x1"'], ["-1.1.1.1", '"-1"'], ["+1.1.1.1", '"+1"'], ["1.1.1.1e1", '"1e1"'],
            ["1..1.1", "empty number"], [".1.1.1", "empty number"], ["1.1.1.", "empty number"], ["1.1.1.1.", '"1.1.1.1."'], ["...", "empty number"],
            ["1. 1.1.1", '" 1"'], ["1 .1.1.1", '"1 "'], ["1.1.1.1 1", '"1 1"'], ["1,1,1,1", '"1,1,1,1"'], ["1.1.1,1", '"1.1.1,1"'],
            [Chr(0xFF11) ".1.1.1", Chr(0xFF11)], ["1.1.1.1/30", '"1/30"']]
        for b in bad {
            r := Ipv4.Parse(b[1])
            T.False(r.Ok, "invalid: [" b[1] "]")
            T.True(r.Error != "", "invalid has a message: [" b[1] "]")
            if (b[2] != "")
                T.Contains(r.Error, b[2], "message names the value: [" b[1] "]")
            T.True(r.Int = 0 && r.Text = "", "invalid result is empty: [" b[1] "]")
        }
        T.Contains(Ipv4.Parse("").Error, "Enter an IP address", "empty input says what to do")
        T.Contains(Ipv4.Parse("01.1.1.1").Error, "leading zero", "leading zero is named")
        T.Contains(Ipv4.Parse("01.1.1.1").Error, "write 1 instead of 01", "and the fix given")
        T.Contains(Ipv4.Parse("256.1.1.1").Error, "above 255", "range is named")
        T.Contains(Ipv4.Parse("1.1.1").Error, "needs 4 numbers", "count is named")
        T.Contains(Ipv4.Parse("1.1.1").Error, "has 3", "and what was found")
    }

    static ParseEdges() {
        T.Eq(Ipv4.Parse(0).Ok ? 1 : 0, 0, "a number 0 is not an address")
        T.Eq(Ipv4.Parse("0.0.0.0").Int, 0, "0.0.0.0 parses (the range check rejects it separately)")
        T.Eq(Ipv4.Parse("255.255.255.255").Int, 4294967295, "255.255.255.255 parses")
        T.True(Ipv4.Parse("1.1.1.1").Ok, "plain")
        ; each octet position
        T.Eq(Ipv4.Parse("1.2.3.4").Int, 1 * 16777216 + 2 * 65536 + 3 * 256 + 4, "octet weights")
        T.True(Ipv4.Parse("128.0.0.0").Int = 2147483648, "no sign problems at 2^31")
        T.True(Ipv4.Parse("255.0.0.0").Int = 4278190080, "no sign problems above 2^31")
    }

    ; --- usable range ------------------------------------------------------------------------------------------------
    static UsableRange() {
        for tx in ["0.0.0.0", "0.0.0.1", "0.1.2.3", "0.255.255.255", "127.0.0.1", "127.0.0.0", "127.255.255.255", "127.1.2.3",
                "224.0.0.0", "224.0.0.1", "239.255.255.255", "240.0.0.0", "250.1.1.1", "255.255.255.255", "255.255.255.254"] {
            r := Ipv4.IsUsableHostRange(Ipv4.Parse(tx).Int)
            T.False(r.Ok, "not usable: " tx)
            T.Contains(r.Error, tx, "message names the address: " tx)
        }
        T.Contains(Ipv4.IsUsableHostRange(Ipv4.Parse("0.1.2.3").Int).Error, "0.x.x.x", "0.x message")
        T.Contains(Ipv4.IsUsableHostRange(Ipv4.Parse("127.0.0.1").Int).Error, "loopback", "127.x message")
        T.Contains(Ipv4.IsUsableHostRange(Ipv4.Parse("224.0.0.1").Int).Error, "multicast / reserved", "224+ message")
        for tx in ["1.0.0.0", "1.1.1.1", "10.0.0.1", "126.255.255.255", "128.0.0.0", "172.16.0.1", "192.168.1.1", "223.255.255.255", "169.254.1.1", "100.64.0.1"] {
            r := Ipv4.IsUsableHostRange(Ipv4.Parse(tx).Int)
            T.True(r.Ok && r.Error = "", "usable: " tx)
        }
        for junk in ["x", -1, 4294967296, 1.5, ""]
            T.False(Ipv4.IsUsableHostRange(junk).Ok, "junk argument refused: [" junk "]")
    }

    static ToTextRoundTrip() {
        for n in [0, 1, 255, 256, 65535, 65536, 16777215, 16777216, 2147483647, 2147483648, 3232235777, 4294967294, 4294967295] {
            txt := Ipv4.ToText(n)
            T.Eq(Ipv4.Parse(txt).Int, n, "Parse(ToText(" n ")) = " n " (" txt ")")
        }
        T.Eq(Ipv4.ToText(0), "0.0.0.0", "ToText 0")
        T.Eq(Ipv4.ToText(4294967295), "255.255.255.255", "ToText max")
        T.Eq(Ipv4.ToText(3232235777), "192.168.1.1", "ToText 192.168.1.1")
        loop 50 {
            n := Random(0, 4294967295)
            T.Eq(Ipv4.Parse(Ipv4.ToText(n)).Int, n, "random round trip " n)
        }
    }

    ; --- masks ---------------------------------------------------------------------------------------------------------
    ; Round trip for every prefix (the helpers cover /0../32; the gateway rule only /8../30).
    static MaskPrefixAll() {
        loop 33 {
            p := A_Index - 1
            m := Ipv4.MaskFromPrefix(p)
            txt := Ipv4.ToText(m)
            r := Ipv4.PrefixFromMask(txt)
            T.True(r.Ok && r.Prefix = p && r.Mask = txt && r.MaskInt = m, "mask <-> prefix /" p " (" txt ")")
            pp := Ipv4.ParsePrefix("/" p)
            T.True(pp.Ok && pp.Prefix = p && pp.Mask = txt, "ParsePrefix /" p)
            pp := Ipv4.ParsePrefix(String(p))
            T.True(pp.Ok && pp.Prefix = p && pp.Mask = txt, "ParsePrefix " p)
            pp := Ipv4.ParsePrefix(txt)
            T.True(pp.Ok && pp.Prefix = p && pp.Mask = txt, "ParsePrefix " txt)
            pp := Ipv4.ParsePrefix("/" txt)
            T.True(pp.Ok && pp.Prefix = p, "ParsePrefix /" txt)
            pp := Ipv4.ParsePrefix("  /" p "  ")
            T.True(pp.Ok && pp.Prefix = p, "ParsePrefix with spaces /" p)
            ; block size
            T.Eq(Ipv4.Broadcast(3232235776, p) - Ipv4.Network(3232235776, p) + 1, 2 ** (32 - p), "block size /" p)
            ; mask has exactly p leading ones
            T.Eq(m & 0xFFFFFFFF, m, "mask is 32 bits /" p)
        }
        for p, txt in Map(8, "255.0.0.0", 16, "255.255.0.0", 24, "255.255.255.0", 25, "255.255.255.128", 28, "255.255.255.240", 29, "255.255.255.248",
                30, "255.255.255.252", 31, "255.255.255.254", 32, "255.255.255.255", 0, "0.0.0.0", 1, "128.0.0.0", 7, "254.0.0.0")
            T.Eq(Ipv4.ToText(Ipv4.MaskFromPrefix(p)), txt, "known mask /" p)
    }

    static MaskHelpers() {
        for bad in [-1, 33, 100, "a", "", 1.5, "30"]
            T.Eq(Ipv4.MaskFromPrefix(bad), "", "MaskFromPrefix refuses [" bad "]")
        T.Eq(Ipv4.MaskFromPrefix(0), 0, "/0 is mask 0 (no shift past the width)")
        T.Eq(Ipv4.MaskFromPrefix(32), 4294967295, "/32")
        ; prefix texts
        for tx in ["/33", "33", "/99", "99", "/-1", "-1", "/", "", "  ", "/abc", "abc", "30/2", "/30/", "3.0", "030", "/030", "1e1", "0x1e", "30 1", "/ ", "٣٠"]
            T.False(Ipv4.ParsePrefix(tx).Ok, "ParsePrefix refuses [" tx "]")
        T.Contains(Ipv4.ParsePrefix("/33").Error, "/33", "the bad prefix is named")
        T.Contains(Ipv4.ParsePrefix("abc").Error, '"abc"', "the bad text is named")
        T.Contains(Ipv4.ParsePrefix("").Error, "Enter a prefix", "empty says what to do")
        T.Contains(Ipv4.ParsePrefix("/").Error, '"/"', "a lone slash is named")
        T.True(Ipv4.ParsePrefix("08").Ok && Ipv4.ParsePrefix("08").Prefix = 8, "08 is /8")
        T.True(Ipv4.ParsePrefix("/0").Ok && Ipv4.ParsePrefix("/0").Prefix = 0, "/0 parses (the gateway rule refuses it)")
        T.Eq(Ipv4.ParsePrefix("/ 30").Prefix, 30, "slash space number")
    }

    static NonContiguous() {
        for m in ["255.0.255.0", "0.255.255.255", "255.255.0.255", "128.0.0.1", "255.255.255.253", "1.1.1.1", "255.255.255.250", "127.0.0.0",
                "255.255.254.1", "0.0.0.1", "255.1.0.0", "192.0.0.1", "10.0.0.0", "255.255.255.7"] {
            r := Ipv4.PrefixFromMask(m)
            T.False(r.Ok, "non-contiguous refused: " m)
            T.Contains(r.Error, m, "message names the mask: " m)
            T.Contains(r.Error, "not a valid subnet mask", "message says what is wrong: " m)
            T.False(Ipv4.ParsePrefix(m).Ok, "ParsePrefix refuses it too: " m)
        }
        for m in ["255.255.255", "255.255.255.256", "a.b.c.d", "", "255.255.255.0.0", "255.255.255.00", "255..255.0"] {
            r := Ipv4.PrefixFromMask(m)
            T.False(r.Ok, "bad mask text refused: [" m "]")
            T.True(r.Error != "", "bad mask text has a message: [" m "]")
        }
        T.Contains(Ipv4.PrefixFromMask("255.255.255.256").Error, "256", "bad octet in a mask is named")
    }

    static NetworkBroadcast() {
        a := Ipv4.Parse("1.1.1.9").Int
        T.Eq(Ipv4.ToText(Ipv4.Network(a, 29)), "1.1.1.8", "network of 1.1.1.9/29")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(a, 29)), "1.1.1.15", "broadcast of 1.1.1.9/29")
        T.Eq(Ipv4.ToText(Ipv4.Network(a, 30)), "1.1.1.8", "network of 1.1.1.9/30")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(a, 30)), "1.1.1.11", "broadcast of 1.1.1.9/30")
        T.Eq(Ipv4.ToText(Ipv4.Network(a, 32)), "1.1.1.9", "network of /32")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(a, 32)), "1.1.1.9", "broadcast of /32")
        T.Eq(Ipv4.ToText(Ipv4.Network(a, 31)), "1.1.1.8", "network of /31")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(a, 31)), "1.1.1.9", "broadcast of /31")
        T.Eq(Ipv4.ToText(Ipv4.Network(a, 0)), "0.0.0.0", "network of /0")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(a, 0)), "255.255.255.255", "broadcast of /0")
        b := Ipv4.Parse("10.0.255.255").Int
        T.Eq(Ipv4.ToText(Ipv4.Network(b, 8)), "10.0.0.0", "network of 10.0.255.255/8")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(b, 8)), "10.255.255.255", "broadcast of 10.0.255.255/8")
        c := Ipv4.Parse("192.168.1.130").Int
        T.Eq(Ipv4.ToText(Ipv4.Network(c, 25)), "192.168.1.128", "/25 network")
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(c, 25)), "192.168.1.255", "/25 broadcast")
        d := Ipv4.Parse("223.255.255.253").Int
        T.Eq(Ipv4.ToText(Ipv4.Broadcast(d, 30)), "223.255.255.255", "broadcast near the top of the class C range")
    }

    ; --- the IP box ------------------------------------------------------------------------------------------------------
    static SplitAndParseInput() {
        ; every accepted form gives the same IP and prefix
        forms := ["1.1.1.1/30", "1.1.1.1 / 30", "1.1.1.1 /30", "1.1.1.1/ 30", "  1.1.1.1/30  ", "1.1.1.1/255.255.255.252", "1.1.1.1 / 255.255.255.252",
            "1.1.1.1 255.255.255.252", "1.1.1.1   255.255.255.252", "1.1.1.1`t255.255.255.252", "1.1.1.1 30", "1.1.1.1/30`r`n", "1.1.1.1/030x"]
        for f in forms {
            r := Ipv4.ParseInput(f)
            if (f = "1.1.1.1/030x") {
                T.False(r.Ok, "junk after the prefix refused")
                continue
            }
            T.True(r.Ok && r.Ip = "1.1.1.1" && r.Prefix = 30 && r.Mask = "255.255.255.252" && r.Error = "", "form accepted: [" StrReplace(StrReplace(StrReplace(f, "`t", "\t"), "`r", "\r"), "`n", "\n") "]")
            T.Eq(r.IpInt, 16843009, "IpInt for [" Trim(f) "]")
        }
        ; address only
        r := Ipv4.ParseInput("8.8.8.8")
        T.True(r.Ok && r.Ip = "8.8.8.8" && r.Prefix = "" && r.Mask = "", "address only: Ok with no prefix")
        r := Ipv4.ParseInput("  8.8.8.8  ")
        T.True(r.Ok && r.Ip = "8.8.8.8" && r.Prefix = "", "address only with spaces")
        ; prefix 0 is a real value (not "no prefix")
        r := Ipv4.ParseInput("8.8.8.8/0")
        T.True(r.Ok && r.Prefix = 0 && r.Prefix != "" && r.Mask = "0.0.0.0", "/0 parses as prefix 0")
        ; a normalised IP comes back (the box shows what was understood)
        T.Eq(Ipv4.ParseInput("1.2.3.4/24").Ip, "1.2.3.4", "Ip is text")
        ; split only
        sp := Ipv4.SplitInput("1.1.1.1 / 30")
        T.True(sp.IpText = "1.1.1.1" && sp.PrefixText = "30" && sp.HasPrefix, "SplitInput slash with spaces")
        sp := Ipv4.SplitInput("1.1.1.1 255.255.255.0")
        T.True(sp.IpText = "1.1.1.1" && sp.PrefixText = "255.255.255.0" && sp.HasPrefix, "SplitInput space mask")
        sp := Ipv4.SplitInput("1.1.1.1")
        T.True(sp.IpText = "1.1.1.1" && sp.PrefixText = "" && !sp.HasPrefix, "SplitInput address only")
        sp := Ipv4.SplitInput("1.1.1.1/")
        T.True(sp.IpText = "1.1.1.1" && sp.PrefixText = "" && sp.HasPrefix, "SplitInput trailing slash")
        sp := Ipv4.SplitInput("1.1.1.1 2 3")
        T.True(sp.IpText = "1.1.1.1 2 3" && !sp.HasPrefix, "SplitInput too many parts: left whole for Parse to refuse")
        T.False(Ipv4.ParseInput("1.1.1.1 2 3").Ok, "too many parts refused")
        T.Contains(Ipv4.ParseInput("1.1.1.1 2 3").Error, "1.1.1.1 2 3", "and named")
        sp := Ipv4.SplitInput("")
        T.True(sp.IpText = "" && !sp.HasPrefix, "SplitInput empty")
    }

    ; --- the PLAN section 7 table ----------------------------------------------------------------------------------------
    static ValidTable() {
        ; input, ip, prefix, mask, gateway, network, broadcast
        rows := [
            ["1.1.1.1/30", "1.1.1.1", 30, "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"],             ; the required case
            ["1.1.1.9/29", "1.1.1.9", 29, "255.255.255.248", "1.1.1.10", "1.1.1.8", "1.1.1.15"],
            ["10.0.0.1/8", "10.0.0.1", 8, "255.0.0.0", "10.0.0.2", "10.0.0.0", "10.255.255.255"],
            ["10.0.255.255/8", "10.0.255.255", 8, "255.0.0.0", "10.1.0.0", "10.0.0.0", "10.255.255.255"],  ; crosses octets
            ["10.255.255.254/8", "10.255.255.254", 8, "255.0.0.0", "", "", ""],                            ; IP+1 = broadcast (error row, see ErrorTable)
            ["192.168.1.253/24", "192.168.1.253", 24, "255.255.255.0", "192.168.1.254", "192.168.1.0", "192.168.1.255"],
            ["172.16.5.1/255.255.0.0", "172.16.5.1", 16, "255.255.0.0", "172.16.5.2", "172.16.0.0", "172.16.255.255"],
            ["8.8.8.8 255.255.255.0", "8.8.8.8", 24, "255.255.255.0", "8.8.8.9", "8.8.8.0", "8.8.8.255"],
            ["  1.1.1.1/30  ", "1.1.1.1", 30, "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"],
            ["1.1.1.1 / 30", "1.1.1.1", 30, "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"],
            ["1.1.1.1/255.255.255.252", "1.1.1.1", 30, "255.255.255.252", "1.1.1.2", "1.1.1.0", "1.1.1.3"],
            ["1.1.1.2/29", "1.1.1.2", 29, "255.255.255.248", "1.1.1.3", "1.1.1.0", "1.1.1.7"],
            ["1.1.1.6/29", "1.1.1.6", 29, "255.255.255.248", "", "", ""],                                  ; IP+1 = broadcast
            ["1.0.0.1/8", "1.0.0.1", 8, "255.0.0.0", "1.0.0.2", "1.0.0.0", "1.255.255.255"],
            ["100.64.0.1/10", "100.64.0.1", 10, "255.192.0.0", "100.64.0.2", "100.64.0.0", "100.127.255.255"],
            ["192.168.1.1/25", "192.168.1.1", 25, "255.255.255.128", "192.168.1.2", "192.168.1.0", "192.168.1.127"],
            ["192.168.1.129/25", "192.168.1.129", 25, "255.255.255.128", "192.168.1.130", "192.168.1.128", "192.168.1.255"],
            ["223.255.255.253/30", "223.255.255.253", 30, "255.255.255.252", "223.255.255.254", "223.255.255.252", "223.255.255.255"],
            ["126.255.255.253/8", "126.255.255.253", 8, "255.0.0.0", "126.255.255.254", "126.0.0.0", "126.255.255.255"],
            ["9.9.9.9/29", "9.9.9.9", 29, "255.255.255.248", "9.9.9.10", "9.9.9.8", "9.9.9.15"],
            ["1.1.1.4/30", "1.1.1.4", 30, "255.255.255.252", "", "", ""]]                                  ; network address
        for r in rows {
            e := TestIpv4.Eval(r[1])
            if (r[5] = "") {
                T.False(e.Ok, "this row is an error case: " r[1])
                continue
            }
            T.True(e.Ok, "valid: " r[1] " " e.Error)
            T.Eq(e.Ip, r[2], r[1] ": ip")
            T.Eq(e.Prefix, r[3], r[1] ": prefix")
            T.Eq(e.Mask, r[4], r[1] ": mask")
            T.Eq(e.Gateway, r[5], r[1] ": gateway")
            T.Eq(e.Network, r[6], r[1] ": network")
            T.Eq(e.Broadcast, r[7], r[1] ": broadcast")
            T.Eq(e.Error, "", r[1] ": no error")
        }
        ; every /8../30 has a gateway for the first host
        loop 23 {
            p := A_Index + 7
            ip := Ipv4.Parse("20.0.0.1").Int
            ip := Ipv4.Network(ip, p) + 1
            g := Ipv4.Gateway(ip, p)
            T.True(g.Ok && g.Gateway = Ipv4.ToText(ip + 1), "first host of 20.0.0.0/" p " has gateway IP+1")
        }
    }

    ; input, text the error must contain, text naming the problem value
    static ErrorTable() {
        rows := [
            ["1.1.1.2/30", "IP+1 (1.1.1.3) would be the broadcast address", "1.1.1.3"],
            ["1.1.1.3/30", "is the broadcast address for /30", "1.1.1.3"],
            ["1.1.1.0/30", "is the network address for /30", "1.1.1.0"],
            ["192.168.1.254/24", "IP+1 (192.168.1.255) would be the broadcast address", "192.168.1.255"],
            ["192.168.1.255/24", "is the broadcast address for /24", "192.168.1.255"],
            ["192.168.1.0/24", "is the network address for /24", "192.168.1.0"],
            ["1.1.1.1/31", "Unsupported for auto-gateway (/31, /32)", "/31"],
            ["1.1.1.1/32", "Unsupported for auto-gateway (/31, /32)", "/32"],
            ["1.1.1.1/7", "Prefix must be /8 to /30", "/7"],
            ["1.1.1.1/0", "Prefix must be /8 to /30", "/0"],
            ["1.1.1.1/1", "Prefix must be /8 to /30", "/1"],
            ["1.1.1.1/33", "not a valid prefix", "/33"],
            ["1.1.1.1/99", "not a valid prefix", "/99"],
            ["1.1.1.1/255.0.255.0", "not a valid subnet mask", "255.0.255.0"],
            ["1.1.1.1 255.0.255.0", "not a valid subnet mask", "255.0.255.0"],
            ["1.1.1.1/255.255.255.255", "Unsupported for auto-gateway", "/32"],
            ["1.1.1.1/0.0.0.0", "Prefix must be /8 to /30", "/0"],
            ["1.1.1.1/254.0.0.0", "Prefix must be /8 to /30", "/7"],
            ["256.1.1.1/30", "above 255", '"256"'],
            ["01.1.1.1/30", "leading zero", '"01"'],
            ["1.1.1/30", "needs 4 numbers", '"1.1.1"'],
            ["1.1.1.1.1/30", "needs 4 numbers", '"1.1.1.1.1"'],
            ["a.b.c.d/30", "not a number", '"a"'],
            ["a.b.c.d", "not a number", '"a"'],
            ["1..1.1/30", "empty number", '"1..1.1"'],
            ["1.1.1.1/", "Nothing after", '"/"'],
            ["1.1.1.1/abc", "not a valid prefix or mask", '"abc"'],
            ["1.1.1.1/-1", "not a valid prefix or mask", '"-1"'],
            ["1.1.1.1/30/2", "not a valid prefix or mask", '"30/2"'],
            ["1.1.1.1/030", "not a valid prefix or mask", '"030"'],
            ["", "Enter an IP address", ""],
            ["   ", "Enter an IP address", ""],
            ["0.1.2.3/8", "0.x.x.x", "0.1.2.3"],
            ["0.0.0.0/8", "0.x.x.x", "0.0.0.0"],
            ["127.0.0.1/8", "loopback", "127.0.0.1"],
            ["127.1.1.1/30", "loopback", "127.1.1.1"],
            ["224.0.0.1/8", "multicast / reserved", "224.0.0.1"],
            ["239.1.1.1/24", "multicast / reserved", "239.1.1.1"],
            ["255.255.255.255/8", "multicast / reserved", "255.255.255.255"],
            ["255.255.255.255", "multicast / reserved", "255.255.255.255"],
            ["1.1.1.1 2 3", "not a number", "1.1.1.1 2 3"],
            ["1. 1.1.1/30", "not a number", '" 1"'],
            ["1.1.1.1", "No prefix", ""]]
        for r in rows {
            e := TestIpv4.Eval(r[1])
            T.False(e.Ok, "error: [" r[1] "]")
            T.True(e.Error != "", "error has a message: [" r[1] "]")
            T.Contains(e.Error, r[2], "message for [" r[1] "]")
            if (r[3] != "")
                T.Contains(e.Error, r[3], "message names the value for [" r[1] "]")
            T.True(e.Gateway = "", "no gateway on error: [" r[1] "]")
        }
        ; the network / broadcast are still reported when they could be worked out
        e := TestIpv4.Eval("1.1.1.2/30")
        T.True(e.Network = "1.1.1.0" && e.Broadcast = "1.1.1.3", "1.1.1.2/30 error still gives network and broadcast")
    }

    static ErrorFields() {
        T.Eq(Ipv4.ParseInput("256.1.1.1/30").ErrorField, "ip", "bad octet: ip")
        T.Eq(Ipv4.ParseInput("127.0.0.1/8").ErrorField, "ip", "loopback: ip")
        T.Eq(Ipv4.ParseInput("1.1.1.1/abc").ErrorField, "prefix", "bad prefix text: prefix")
        T.Eq(Ipv4.ParseInput("1.1.1.1/").ErrorField, "prefix", "nothing after slash: prefix")
        T.Eq(Ipv4.ParseInput("1.1.1.1/255.0.255.0").ErrorField, "prefix", "bad mask: prefix")
        T.Eq(Ipv4.ParseInput("1.1.1.1/33").ErrorField, "prefix", "/33: prefix")
        T.Eq(Ipv4.ParseInput("1.1.1.1/30").ErrorField, "", "no error: no field")
        r := Ipv4.ParseInput("1.1.1.1/abc")
        T.True(r.Ip = "1.1.1.1" && r.IpInt = 16843009, "a good IP is still reported when the prefix is bad")
        T.True(Ipv4.ParseInput("256.1.1.1/abc").Ip = "", "a bad IP is not reported")
    }

    static GatewayApi() {
        ip := Ipv4.Parse("1.1.1.1").Int
        g := Ipv4.Gateway(ip, 30)
        T.True(g.Ok && g.Gateway = "1.1.1.2" && g.Network = "1.1.1.0" && g.Broadcast = "1.1.1.3" && g.Error = "" && !g.CanManual, "1.1.1.1/30")
        ; CanManual: only for the failures a typed gateway can fix
        g := Ipv4.Gateway(Ipv4.Parse("1.1.1.2").Int, 30)
        T.True(!g.Ok && g.CanManual, "IP+1 = broadcast: manual can fix it")
        g := Ipv4.Gateway(Ipv4.Parse("1.1.1.1").Int, 31)
        T.True(!g.Ok && g.CanManual && g.Gateway = "", "/31: manual can fix it")
        g := Ipv4.Gateway(Ipv4.Parse("1.1.1.1").Int, 32)
        T.True(!g.Ok && g.CanManual, "/32: manual can fix it")
        g := Ipv4.Gateway(Ipv4.Parse("1.1.1.0").Int, 30)
        T.True(!g.Ok && !g.CanManual, "network address: fix the IP, not the gateway")
        g := Ipv4.Gateway(Ipv4.Parse("1.1.1.3").Int, 30)
        T.True(!g.Ok && !g.CanManual, "broadcast address: fix the IP")
        g := Ipv4.Gateway(ip, 7)
        T.True(!g.Ok && !g.CanManual, "/7: fix the prefix")
        ; every junk argument gives an error, never a throw
        for junk in [["x", 30], ["", 30], [-1, 30], [4294967296, 30], [1.5, 30], [ip, "x"], [ip, ""], [ip, -1], [ip, 33], [ip, 1.5], [ip, "30"]] {
            g := Ipv4.Gateway(junk[1], junk[2])
            T.False(g.Ok, "junk refused: " junk[1] " " junk[2])
            T.True(g.Error != "", "junk has a message: " junk[1] " " junk[2])
        }
        T.Contains(Ipv4.Gateway(ip, 33).Error, "/33", "bad prefix is named")
        T.Contains(Ipv4.Gateway(ip, "x").Error, '"x"', "non-number prefix is named")
        ; the 64-bit pitfalls: the highest /30 and the lowest ones
        g := Ipv4.Gateway(Ipv4.Parse("223.255.255.253").Int, 30)
        T.True(g.Ok && g.Gateway = "223.255.255.254", "highest usable /30")
        g := Ipv4.Gateway(Ipv4.Parse("1.0.0.1").Int, 8)
        T.True(g.Ok && g.Gateway = "1.0.0.2", "/8 low")
        ; the exact message strings (PLAN 7 / the milestone brief)
        T.Eq(Ipv4.Gateway(ip, 7).Error, "/7: Prefix must be /8 to /30 " Chr(0x2014) " check the prefix or mask.", "/7 message")
        T.Eq(Ipv4.Gateway(ip, 31).Error, "/31: Unsupported for auto-gateway (/31, /32) " Chr(0x2014) " enter the gateway manually.", "/31 message")
        T.Eq(Ipv4.Gateway(Ipv4.Parse("1.1.1.2").Int, 30).Error, "IP+1 (1.1.1.3) would be the broadcast address " Chr(0x2014) " enter the gateway manually.", "IP+1 message")
        T.Eq(Ipv4.Gateway(Ipv4.Parse("1.1.1.0").Int, 30).Error, "1.1.1.0 is the network address for /30 " Chr(0x2014) " check the IP or prefix.", "network message")
        T.Eq(Ipv4.Gateway(Ipv4.Parse("1.1.1.3").Int, 30).Error, "1.1.1.3 is the broadcast address for /30 " Chr(0x2014) " check the IP or prefix.", "broadcast message")
    }

    static CheckHost() {
        ip := (tx) => Ipv4.Parse(tx).Int
        T.True(Ipv4.CheckHost(ip("1.1.1.1"), 30).Ok, "host in /30")
        T.True(Ipv4.CheckHost(ip("1.1.1.2"), 30).Ok, "second host in /30 (its gateway may fail, the host does not)")
        T.False(Ipv4.CheckHost(ip("1.1.1.0"), 30).Ok, "network address")
        T.False(Ipv4.CheckHost(ip("1.1.1.3"), 30).Ok, "broadcast address")
        T.True(Ipv4.CheckHost(ip("1.1.1.0"), 31).Ok && Ipv4.CheckHost(ip("1.1.1.1"), 31).Ok, "/31 has no network or broadcast address")
        T.True(Ipv4.CheckHost(ip("1.1.1.0"), 32).Ok, "/32 neither")
        T.False(Ipv4.CheckHost("x", 30).Ok, "junk ip")
        T.False(Ipv4.CheckHost(ip("1.1.1.1"), "x").Ok, "junk prefix")
        T.False(Ipv4.CheckHost(ip("1.1.1.1"), 33).Ok, "prefix too big")
    }

    ; --- the manual gateway ---------------------------------------------------------------------------------------------
    static ManualGateway() {
        ip := Ipv4.Parse("1.1.1.2").Int
        r := Ipv4.CheckManualGateway("1.1.1.1", ip, 30)
        T.True(r.Ok && r.Text = "1.1.1.1" && r.Int = 16843009 && r.Error = "", "in the subnet, a host: accepted")
        T.True(Ipv4.CheckManualGateway("1.1.1.1", "1.1.1.2", 30).Ok, "the IP may be given as text")
        T.True(Ipv4.CheckManualGateway("  1.1.1.1  ", ip, 30).Ok, "surrounding spaces trimmed")
        ; {gateway, text the error must contain}
        bad := [["1.1.1.2", "same as the IP"], ["1.1.1.0", "network address for /30"], ["1.1.1.3", "broadcast address for /30"],
            ["1.1.2.1", "not in the same subnet"], ["2.1.1.1", "not in the same subnet"], ["1.1.1.4", "not in the same subnet"],
            ["", "Enter an IP address"], ["abc", '"abc"'], ["1.1.1", '"1.1.1"'], ["256.1.1.1", '"256"'], ["01.1.1.1", '"01"'],
            ["127.0.0.1", "loopback"], ["0.0.0.1", "0.x.x.x"], ["224.0.0.1", "multicast"], ["255.255.255.255", "multicast"], ["1.1.1.1/30", '"1/30"']]
        for b in bad {
            r := Ipv4.CheckManualGateway(b[1], ip, 30)
            T.False(r.Ok, "refused: [" b[1] "]")
            T.True(r.Error != "", "has a message: [" b[1] "]")
            T.Contains(r.Error, b[2], "message for [" b[1] "]")
            if (b[1] != "" && InStr(b[2], '"') = 0)
                T.True(InStr(r.Error, Trim(b[1])) > 0 || b[1] = "1.1.1.1/30", "message names the gateway: [" b[1] "]")
            T.True(r.Int = 0 && r.Text = "", "nothing returned for [" b[1] "]")
        }
        ; the subnet message names both sides
        r := Ipv4.CheckManualGateway("1.1.2.1", ip, 30)
        T.Contains(r.Error, "1.1.1.2/30", "names the IP and prefix")
        T.Contains(r.Error, "1.1.1.0 to 1.1.1.3", "and the subnet range")
        ; /24
        ip24 := Ipv4.Parse("192.168.1.10").Int
        T.True(Ipv4.CheckManualGateway("192.168.1.1", ip24, 24).Ok, "/24 .1")
        T.True(Ipv4.CheckManualGateway("192.168.1.254", ip24, 24).Ok, "/24 .254")
        T.False(Ipv4.CheckManualGateway("192.168.1.0", ip24, 24).Ok, "/24 network")
        T.False(Ipv4.CheckManualGateway("192.168.1.255", ip24, 24).Ok, "/24 broadcast")
        T.False(Ipv4.CheckManualGateway("192.168.2.1", ip24, 24).Ok, "/24 other subnet")
        T.False(Ipv4.CheckManualGateway("192.168.1.10", ip24, 24).Ok, "/24 same as IP")
        ; /8 crossing octets
        ip8 := Ipv4.Parse("10.0.255.255").Int
        T.True(Ipv4.CheckManualGateway("10.0.255.254", ip8, 8).Ok, "/8 neighbour")
        T.True(Ipv4.CheckManualGateway("10.1.0.0", ip8, 8).Ok, "/8 next octet")
        T.False(Ipv4.CheckManualGateway("11.0.0.1", ip8, 8).Ok, "/8 other net")
    }

    static ManualGatewayEdge() {
        ; /31: both addresses are hosts; the gateway is the other one
        ip := Ipv4.Parse("10.0.0.4").Int
        T.True(Ipv4.CheckManualGateway("10.0.0.5", ip, 31).Ok, "/31: the other address")
        T.False(Ipv4.CheckManualGateway("10.0.0.4", ip, 31).Ok, "/31: not the IP itself")
        T.False(Ipv4.CheckManualGateway("10.0.0.6", ip, 31).Ok, "/31: not outside")
        T.True(Ipv4.CheckManualGateway("10.0.0.4", Ipv4.Parse("10.0.0.5").Int, 31).Ok, "/31: the lower address is a valid gateway (no network address at /31)")
        ; /32: nothing else is in the subnet
        ip := Ipv4.Parse("10.0.0.9").Int
        T.False(Ipv4.CheckManualGateway("10.0.0.10", ip, 32).Ok, "/32: other address outside")
        T.False(Ipv4.CheckManualGateway("10.0.0.9", ip, 32).Ok, "/32: same as the IP")
        T.Contains(Ipv4.CheckManualGateway("10.0.0.10", ip, 32).Error, "not in the same subnet", "/32 message")
        ; junk context
        r := Ipv4.CheckManualGateway("1.1.1.1", "", 30)
        T.False(r.Ok, "no IP: refused")
        T.True(r.Error != "", "no IP: message")
        r := Ipv4.CheckManualGateway("1.1.1.1", 16843010, "")
        T.False(r.Ok, "no prefix: refused")
        T.Contains(r.Error, "prefix", "no prefix: says so")
        T.False(Ipv4.CheckManualGateway("1.1.1.1", 16843010, 40).Ok, "prefix 40 refused")
        T.False(Ipv4.CheckManualGateway("1.1.1.1", "x.y", 30).Ok, "text IP that does not parse refused")
    }

    ; nothing in the library throws on junk
    static NoThrow() {
        junk := ["", " ", "x", "..", "1.1.1.1/", "/", "//", "/30", "1.1.1.1//30", "1.1.1.1/30/30", "1.1.1.1 / / 30", "0", 0, -1, 1.5, "1e9", "٣.٣.٣.٣",
            "1.1.1.1/" Chr(0x2014), Chr(0x2014), "1.1.1.1" Chr(0xFEFF), "1.1.1.1 /30 ", "1.1.1.1/30 extra", "1.1.1.1 30 extra", "{ip}", "%ip%", "`"1.1.1.1`""]
        for j in junk {
            T.Case("no throw: " j, ((x) => (Ipv4.Parse(x), Ipv4.ParseInput(x), Ipv4.ParsePrefix(x), Ipv4.PrefixFromMask(x), Ipv4.SplitInput(x),
                Ipv4.CheckManualGateway(x, 16843010, 30), Ipv4.CheckManualGateway("1.1.1.1", x, 30), Ipv4.Gateway(x, 30), Ipv4.IsUsableHostRange(x),
                Ipv4.MaskFromPrefix(x), Ipv4.CheckHost(x, 30))).Bind(j))
        }
        T.True(true, "all junk handled")
    }
}
