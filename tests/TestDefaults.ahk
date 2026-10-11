#Requires AutoHotkey v2.0

class TestDefaults {
    static Name := "Defaults"

    static Run() {
        T.Case("shape", () => TestDefaults.Shape())
        T.Case("fresh", () => TestDefaults.Fresh())
        T.Case("export", () => TestDefaults.Export())
        T.Case("workflow", () => TestDefaults.Workflow())
        T.Case("static", () => TestDefaults.StaticShape())
        T.Case("config.json", () => TestDefaults.ShippedConfig())
    }

    ; The M5 shape: Not Done steps, stop, flags, Close Job.
    static Workflow() {
        c := Defaults.Config()
        nd := c["categories"][1]
        st := nd["steps"]
        T.Eq(st[1]["type"] "," st[1]["required"], "choice,1", "reason: required choice")
        T.Eq(st[1]["options"].Length, 4, "reason: 4 options")
        T.Eq(st[1]["options"][1]["id"] "," st[1]["options"][4]["id"], "r1,r4", "reason option ids")
        T.Eq(st[1]["options"][1]["label"], "Reason 1 (placeholder)", "reason option label is a marked placeholder")
        T.Eq(st[1]["options"][1]["fragment"], "Reason 1 placeholder note.", "reason option fragment is a marked placeholder")
        T.Eq(st[2]["options"][1]["label"] "," st[2]["options"][2]["label"] "," st[2]["options"][3]["label"], "PWO,TC,SRO", "order types")
        T.Eq(st[3]["type"], "group", "supervisorPwo is a group")
        T.False(st[3].Has("options"), "a group has only fields")
        T.Eq(st[3]["fields"][1]["id"] "," st[3]["fields"][1]["required"], "supervisorName,1", "PWO supervisor name required")
        T.Eq(st[3]["fields"][2]["id"] "," st[3]["fields"][2]["required"] "," st[3]["fields"][2]["multiline"], "rescheduleReason,1,1", "PWO reschedule reason required + multiline")
        T.Eq(st[4]["type"], "yesno", "supervisorTc is yes/no")
        T.Eq(st[4]["label"], "Has the tech spoken with their supervisor?", "supervisor question wording")
        T.Eq(st[4]["fields"][1]["id"], "supervisorNameTc", "TC supervisor field has its own id")
        T.Eq(st[4]["fields"][1]["requiredWhen"]["in"][1], "yes", "TC name required when Yes")
        stop := st[4]["options"][2]["stop"]
        T.Eq(st[4]["options"][2]["id"], "no", "the stop is on No")
        T.Eq(stop["message"], "The tech must contact their supervisor before calling back.", "stop banner message")
        T.Eq(stop["fragment"], "Tech has not contacted supervisor; advised tech to contact supervisor before calling back.", "stop note (PLAN 3.6)")
        T.Eq(stop["keepSteps"][1] "," stop["keepSteps"][2], "reason,orderType", "stop keeps reason and order type")
        T.Eq(st[5]["options"].Length "," st[5]["fields"][1]["id"], "4,contactDetails", "contact: 4 options + optional details")
        T.Eq(st[6]["options"].Length, 4, "outcome: 4 options")
        T.Eq(nd["flags"].Length, 1, "one placeholder flag")
        T.Contains(nd["flags"][1]["message"], "Placeholder flag", "flag text is a marked placeholder")
        cj := c["categories"][5]["steps"]
        T.Eq(cj[1]["type"] "," cj[1]["required"] "," cj[1]["options"].Length, "choice,1,3", "Close Job: required choice with 3 options")
        T.Eq(cj[2]["type"] "," cj[2]["required"], "yesno,0", "Close Job: optional yes/no")
        T.Eq(cj[3]["type"] "," cj[3]["required"] "," cj[3]["fields"].Length, "text,0,1", "Close Job: optional text with one field")
        ; no business wording outside the allowed list: every option label/fragment of the placeholder steps says placeholder
        for sid in [1, 5, 6]
            for o in st[sid]["options"]
                T.Contains(o["fragment"], "placeholder", "placeholder fragment: " o["id"])
    }

    ; The M7 shape of the Static category: wording only (the IPv4 maths is code), obviously placeholder text.
    static StaticShape() {
        c := Defaults.Config()
        st := c["categories"][4]
        T.Eq(st["id"] "," st["kind"], "static,static", "category 4 is Static")
        s := st["static"]
        T.False(s.Has("fragments"), "no static.fragments (the scripted note and the manual-gateway sentence were removed)")
        T.Eq(s.Count, 2, "static holds only pingTargets and pingOutcomes")
        T.Eq(s["pingTargets"][1]["id"] "|" s["pingTargets"][1]["label"] "|" s["pingTargets"][2]["id"] "|" s["pingTargets"][2]["label"], "gateway|Gateway|ip|IP", "ping targets")
        T.Eq(s["pingOutcomes"][1]["label"] "|" s["pingOutcomes"][2]["label"], "Reply received|No reply", "ping outcome labels (PLAN 3.7)")
        T.Eq(s["pingOutcomes"][1]["fragment"], "Ping to {pingTarget} {pingAddress}: reply received (placeholder wording).", "reply wording")
        T.Eq(s["pingOutcomes"][2]["fragment"], "Ping to {pingTarget} {pingAddress}: no reply (placeholder wording).", "no reply wording")
        ; the exported file and config.json carry it
        for f in ["config.default.json", "config.json"] {
            cfg := ConfigJson.Parse(FileRead(A_ScriptDir "\..\config\" f, "UTF-8"))
            sc := ""
            for cat in cfg["categories"]
                if (cat["id"] = "static")
                    sc := cat
            T.True(IsObject(sc) && sc["static"] is Map && !sc["static"].Has("fragments") && sc["static"].Has("pingTargets") && sc["static"].Has("pingOutcomes"), f ": has the static section")
            if IsObject(sc) {
                T.Eq(sc["static"]["pingOutcomes"][1]["label"] "|" sc["static"]["pingOutcomes"][2]["id"], "Reply received|noReply", f ": ping outcomes")
                T.Eq(sc["static"]["pingTargets"].Length, 2, f ": ping targets")
            }
        }
    }

    ; config\config.json is the file the user edits: it must always validate (it starts as a copy of the defaults).
    static ShippedConfig() {
        path := A_ScriptDir "\..\config\config.json"
        T.True(FileExist(path), "config\config.json exists")
        if !FileExist(path)
            return
        cfg := ConfigJson.Parse(FileRead(path, "UTF-8"))
        r := Schema.Validate(cfg)
        T.True(r.Ok, "config.json validates " Schema.Summary(r))
        T.Eq(Schema.Migrate(cfg).Changed ? 1 : 0, 0, "config.json is the current schema version")
    }

    static Shape() {
        c := Defaults.Config()
        T.Eq(c["schemaVersion"], Schema.CURRENT, "schemaVersion is current")
        T.Eq(c["revision"], 0, "revision 0")
        T.Eq(c["updatedBy"], "built-in", "updatedBy built-in")
        ids := ""
        for cat in c["categories"]
            ids .= cat["id"] ","
        T.Eq(ids, "notDone,equipment,billing,static,closeJob,", "five system categories in order")
        kinds := ""
        for cat in c["categories"]
            kinds .= cat["kind"] ","
        T.Eq(kinds, "steps,items,items,static,steps,", "category kinds")
        for cat in c["categories"]
            T.True(cat["system"] = 1 && cat["enabled"] = 1, cat["id"] ": system and enabled")
        eq := ""
        for a in c["categories"][2]["entry"]["actions"]
            eq .= a["label"] ","
        T.Eq(eq, "Added,Removed,Swapped,", "equipment actions")
        bl := ""
        for a in c["categories"][3]["entry"]["actions"]
            bl .= a["label"] ","
        T.Eq(bl, "Added,Removed,Changed,", "billing actions")
        T.Eq(c["categories"][3]["entry"]["outcomes"].Length, 3, "billing has 3 outcomes")
        T.Eq(c["categories"][3]["entry"]["outcomes"][1]["label"], "Completed", "billing outcome Completed")
        T.Eq(c["categories"][2]["entry"]["actions"][3]["fragment"], "{action} {qty} {item}. {details}", "equipment fragment shape (PLAN 3.5)")
        T.Eq(c["categories"][2]["entry"]["items"].Length, 5, "equipment has five placeholder items")
        T.Eq(c["categories"][3]["entry"]["items"][5]["label"], "Item 5 (placeholder)", "billing items are placeholders")
        T.Eq(c["categories"][3]["entry"]["outcomes"][2]["label"], "Requested " Chr(0x2014) " not yet completed", "billing outcome 2")
        T.Eq(c["categories"][3]["entry"]["outcomes"][3]["label"], "Unable to complete", "billing outcome 3")
        T.True(c["categories"][3]["entry"]["outcomeRequired"] = 1 && c["categories"][2]["entry"]["outcomeRequired"] = 0, "outcomeRequired: billing yes, equipment no")
        T.True(c["categories"][3]["entry"]["qty"] = 0 && c["categories"][3]["entry"]["details"] = 1, "billing: qty off, details on")
        T.True(c["categories"][2]["entry"]["qty"] = 1 && c["categories"][2]["entry"]["details"] = 1, "equipment: qty on, details on")
        steps := c["categories"][1]["steps"]
        sid := ""
        for s in steps
            sid .= s["id"] ","
        T.Eq(sid, "reason,orderType,supervisorPwo,supervisorTc,contact,outcome,", "Not Done step skeleton")
        T.Eq(steps[1]["options"].Length, 4, "4 placeholder reasons")
        opt := ""
        for o in steps[2]["options"]
            opt .= o["id"] ","
        T.Eq(opt, "pwo,tc,sro,", "order types")
        T.Eq(steps[3]["when"]["in"][1], "pwo", "supervisorPwo only for pwo")
        T.True(steps[4]["options"][2].Has("stop"), "supervisorTc No has a stop")
        T.Contains(steps[1]["options"][1]["label"], "placeholder", "reason options are marked placeholders")
        T.Contains(steps[5]["options"][1]["label"], "placeholder", "contact options are marked placeholders")
        T.Contains(steps[6]["options"][1]["label"], "placeholder", "outcome options are marked placeholders")
        T.Eq(c["categories"][5]["steps"].Length, 3, "closeJob has 3 placeholder steps")
        T.Eq(c["ping"]["timeoutMs"], 1000, "ping timeout")
        T.Eq(c["ping"]["attempts"], 4, "ping attempts")
        T.Eq(c["ping"]["intervalMs"], 1000, "ping interval")
        T.Eq(c["ping"]["untilSuccessMaxMin"], 10, "ping cap")
        T.Eq(c["callTracking"]["newCallDebounceMs"], 3000, "debounce")
        T.Eq(c["history"]["retentionDays"], 14, "retention")
        T.Eq(c["themes"]["default"], "spectrum-light", "default theme")
        T.Eq(c["themes"]["presets"][1]["accent"], "#0099D8", "spectrum accent")
        ids := ""
        for p in c["themes"]["presets"]
            ids .= (ids = "" ? "" : ",") p["id"]
        T.Eq(ids, "spectrum-light,spectrum-dark,win365", "three presets: Spectrum light, Spectrum dark, plain win365")
        T.Eq(c["themes"]["presets"][2]["mode"], "dark", "spectrum-dark is dark")
        T.Eq(c["themes"]["presets"][2]["sheet"], "spectrum", "spectrum-dark uses the spectrum look")
        T.Eq(c["themes"]["presets"][3]["sheet"], "win365", "plain preset is win365")
        T.Eq(c["noteTemplate"]["lines"].Length, 4, "template has 4 lines")
        T.Eq(c["noteTemplate"]["lines"][4], "Notes: {notes}", "template last line")
        T.Eq(c["noteTemplate"]["unavailableText"], "[not available]", "unavailable text")
        for cat in c["categories"]
            T.True(cat.Has("notePrefix") && cat["notePrefix"] == "", cat["id"] ": notePrefix defaults to empty text")
    }

    static Fresh() {
        a := Defaults.Config()
        a["ping"]["attempts"] := 99
        a["categories"].RemoveAt(1)
        b := Defaults.Config()
        T.Eq(b["ping"]["attempts"], 4, "each call returns a fresh tree (ping)")
        T.Eq(b["categories"].Length, 5, "each call returns a fresh tree (categories)")
        T.Eq(ConfigJson.Canon(Defaults.Config()), ConfigJson.Canon(Defaults.Config()), "deterministic")
    }

    static Export() {
        path := A_ScriptDir "\..\config\config.default.json"
        T.True(FileExist(path), "config\config.default.json exists (run tools\ExportDefaults.ahk)")
        if !FileExist(path)
            return
        text := FileRead(path, "UTF-8")
        cfg := ConfigJson.Parse(text)
        r := Schema.Validate(cfg)
        T.True(r.Ok, "exported file validates " Schema.Summary(r))
        T.Eq(ConfigJson.Canon(cfg), ConfigJson.Canon(Defaults.Config()), "exported file equals Defaults.Config()")
        T.Contains(text, '"enabled": true', "exported file uses true/false")
        T.True(InStr(text, "`n  ") > 0, "exported file is pretty-printed")
        ; migration is a no-op on the export
        T.False(Schema.Migrate(cfg).Changed, "export is already the current schema")
    }
}
