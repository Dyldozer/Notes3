#Requires AutoHotkey v2.0

class TestComposer {
    static Name := "Composer"

    static Run() {
        for name in ["Exact", "ConfigOrder", "Duplicates", "SentenceCase", "Punctuation", "Statuses", "Unknown",
                "NoRecursion", "Prefix", "Disabled", "Values", "EmptyNotes", "Joiners", "NoUsed", "FirstNames", "Crlf"]
            T.Case(name, ObjBindMethod(TestComposer, name))
    }

    static Ctx() {
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        c.Set("techId", "T12345", "mock")
        c.Set("jobNumber", "88412", "mock")
        c.Set("workOrder", "55-2231", "mock")
        c.Set("address", "123 Example St", "mock")
        return c
    }

    ; session with the given categories used (in the order given) and fragments {cat: [texts]}
    static Ses(used, frags := "") {
        s := CallSession()
        for id in used
            s.UseCategory(id)
        if IsObject(frags)
            for id, arr in frags
                for f in arr
                    s.AddFragment(id, f)
        return s
    }

    static Run1(ses, cfg := "", ctx := "") {
        return Composer.Compose(IsObject(ctx) ? ctx : TestComposer.Ctx(), ses, IsObject(cfg) ? cfg : Defaults.Config())
    }

    static Exact() {
        ses := TestComposer.Ses(["billing", "notDone"], Map("notDone", ["sample fragment for {tech.firstName}", "added router"],
            "billing", ["removed modem."]))
        r := TestComposer.Run1(ses)
        exp := "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes: Sample fragment for Jordan. Added router.`r`nRemoved modem."
        T.Eq(r.Text, exp, "exact template output for two categories")
        T.Eq(r.Warnings.Length, 0, "no warnings")
    }

    static ConfigOrder() {
        frags := Map("notDone", ["a one"], "equipment", ["b two"], "billing", ["c three"])
        for order in [["billing", "equipment", "notDone"], ["notDone", "billing", "equipment"], ["equipment", "notDone", "billing"]] {
            r := TestComposer.Run1(TestComposer.Ses(order, frags))
            T.Contains(r.Text, "Notes: A one.`r`nB two.`r`nC three.", "config order (notDone, equipment, billing) whatever the use order: " order[1])
        }
    }

    static Duplicates() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["Added router", "  added   ROUTER. ", "added router", "Removed modem", "removed modem."]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Notes: Added router. Removed modem.", "case/space/punctuation variants dropped")
        T.Eq(StrSplit(r.Text, "Added router").Length, 2, "first occurrence kept once")
        ; same text in two different categories is NOT a duplicate (dedupe is per category)
        ses := TestComposer.Ses(["notDone", "billing"], Map("notDone", ["same text"], "billing", ["same text"]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Same text.`r`nSame text.", "duplicates are only dropped within a category")
    }

    static SentenceCase() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["lower start", "ALREADY Upper", "mcKenzie case kept", "5 ports"]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Lower start. ALREADY Upper. McKenzie case kept. 5 ports.", "first letter capitalised, rest untouched")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["sentenceCase"] := false
        r := TestComposer.Run1(ses, cfg)
        T.Contains(r.Text, "lower start. ALREADY Upper.", "sentenceCase off keeps the text")
    }

    static Punctuation() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["ends with period.", "ends with bang!", "ends with question?", "no punctuation", "ends with comma,"]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Ends with period. Ends with bang! Ends with question? No punctuation. Ends with comma,.", "punctuation added only when missing")
        T.NotContains(r.Text, "..", "no doubled period")
        T.NotContains(r.Text, "!.", "no period after !")
        T.NotContains(r.Text, "?.", "no period after ?")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["endPunctuation"] := ""
        r := TestComposer.Run1(TestComposer.Ses(["notDone"], Map("notDone", ["plain"])), cfg)
        T.Contains(r.Text, "Notes: Plain", "empty endPunctuation adds nothing")
        T.NotContains(r.Text, "Plain.", "empty endPunctuation: no period")
    }

    static Statuses() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["name {tech.name} id {tech.id} job {job.number} wo {job.workOrder} addr {address}"]))
        c := TestComposer.Ctx()
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Name Jordan Smith id T12345 job 88412 wo 55-2231 addr 123 Example St.", "all context placeholders (mock)")
        c.Set("techName", "Jordan Smith", "manual")
        c.Set("techId", "T12345", "history")
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Tech name: Jordan`r`n", "manual value rendered")
        T.Contains(r.Text, "Tech ID: T12345`r`n", "history value rendered")
        for st in ["live", "stale"] {
            c.Set("jobNumber", "777", st)
            r := TestComposer.Run1(ses, "", c)
            T.Contains(r.Text, "Job Number: 777`r`n", st " value rendered")
        }
        c.Set("techId", "", "unavailable")
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Tech ID: [not available]`r`n", "unavailable renders unavailableText")
        T.Contains(r.Text, "id [not available] job", "unavailable inside a fragment too")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["unavailableText"] := "N/A"
        r := TestComposer.Run1(ses, cfg, c)
        T.Contains(r.Text, "Tech ID: N/A`r`n", "unavailableText comes from config")
        c.Set("techId", "", "empty")
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Tech ID:`r`n", "empty renders nothing (trailing space trimmed)")
        T.Contains(r.Text, "id job 777", "empty inside a fragment is nothing (whitespace collapsed)")
        c.Set("techName", "", "unavailable")
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Tech name: [not available]`r`n", "unavailable first name")
        c.Set("techName", "  JORDAN SMITH  ", "mock")
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Tech name: Jordan`r`n", "first name rule applies through the placeholder")
    }

    static Unknown() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["see {nope} and {tech.nope}", "notes {notes} here"]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "See {nope} and {tech.nope}.", "unknown placeholder kept as typed")
        T.Contains(r.Text, "Notes {notes} here.", "{notes} is template-only: kept in a fragment")
        T.True(r.Warnings.Length >= 3, "warnings for unknown placeholders")
        T.Contains(r.Warnings[1], "{nope}", "warning names the placeholder")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["lines"] := ["X {bogus} {supervisorName}"]
        r := TestComposer.Run1(TestComposer.Ses(["notDone"], Map("notDone", ["a"])), cfg)
        T.Eq(r.Text, "X {bogus} {supervisorName}", "unknown placeholders in the template kept")
        T.Contains(r.Warnings[1], "template", "template warning says where")
    }

    static NoRecursion() {
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["value is {supervisorName}"]))
        ses.SetValue("notDone", "supervisorName", "{tech.id} and {notes}")
        c := TestComposer.Ctx()
        r := TestComposer.Run1(ses, "", c)
        T.Contains(r.Text, "Value is {tech.id} and {notes}.", "a value that looks like a placeholder is inserted literally")
        T.NotContains(r.Text, "Value is T12345", "not expanded")
        c.Set("address", "{job.number} Main St", "manual")
        ses2 := TestComposer.Ses(["notDone"], Map("notDone", ["at {address}"]))
        r := TestComposer.Run1(ses2, "", c)
        T.Contains(r.Text, "At {job.number} Main St.", "context value is not expanded again")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["lines"] := ["{notes}"]
        r := TestComposer.Run1(ses2, cfg, c)
        T.Eq(r.Text, "At {job.number} Main St.", "notes text is not expanded again in the template")
    }

    static Prefix() {
        cfg := Defaults.Config()
        cfg["categories"][1]["notePrefix"] := "Not Done - "
        ses := TestComposer.Ses(["notDone", "billing"], Map("notDone", ["no access", "tech left"], "billing", ["changed plan"]))
        r := TestComposer.Run1(ses, cfg)
        T.Contains(r.Text, "Notes: Not Done - No access. Tech left.`r`nChanged plan.", "prefix on the configured category only")
        r := TestComposer.Run1(ses)
        T.NotContains(r.Text, "Not Done -", "no prefix by default")
        cfg["categories"][1].Delete("notePrefix")
        r := TestComposer.Run1(ses, cfg)
        T.Contains(r.Text, "Notes: No access.", "missing notePrefix key is fine")
    }

    static Disabled() {
        cfg := Defaults.Config()
        cfg["categories"][3]["enabled"] := false
        ses := TestComposer.Ses(["billing"], Map("billing", ["added plan"]))
        r := TestComposer.Run1(ses, cfg)
        T.Contains(r.Text, "Notes: Added plan.", "used but disabled category is still included")
        T.Eq(r.Warnings.Length, 1, "one warning")
        T.Contains(r.Warnings[1], "billing", "warning names the category")
        T.Contains(r.Warnings[1], "disabled", "warning says disabled")
        ses.UseCategory("ghost")
        r := TestComposer.Run1(ses, cfg)
        T.Eq(r.Warnings.Length, 2, "unknown used category warns")
    }

    static Values() {
        ses := TestComposer.Ses(["notDone", "billing"], Map("notDone", ["spoke with {supervisorName}"], "billing", ["supervisor {supervisorName}"]))
        ses.SetValue("notDone", "supervisorName", "  Pat Lee  ")
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Spoke with Pat Lee.", "value inserted, surrounding whitespace trimmed")
        T.Contains(r.Text, "Supervisor {supervisorName}.", "values are per category")
        T.True(r.Warnings.Length = 1, "other category's missing value is an unknown placeholder warning")
    }

    static EmptyNotes() {
        ses2 := TestComposer.Ses(["notDone"])
        r := TestComposer.Run1(ses2)
        T.Eq(r.Text, "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes:", "empty {notes}: the line still renders, trailing space trimmed")
    }

    static Joiners() {
        cfg := Defaults.Config()
        cfg["noteTemplate"]["fragmentJoiner"] := " | "
        cfg["noteTemplate"]["categoryJoiner"] := " // "
        ses := TestComposer.Ses(["notDone", "equipment"], Map("notDone", ["a", "b"], "equipment", ["c"]))
        r := TestComposer.Run1(ses, cfg)
        T.Contains(r.Text, "Notes: A. | B. // C.", "custom joiners")
    }

    static NoUsed() {
        ses := TestComposer.Ses([], Map("notDone", ["fragment but unused"]))
        r := TestComposer.Run1(ses)
        T.NotContains(r.Text, "Fragment", "fragments of an unused category are not in the note")
        ses := TestComposer.Ses(["notDone"], Map("notDone", ["   ", "{tech.nope}"]))
        r := TestComposer.Run1(ses)
        T.Contains(r.Text, "Notes: {tech.nope}.", "blank fragment skipped, unknown kept")
    }

    static FirstNames() {
        cases := [["  JORDAN SMITH ", "Jordan"], ["jordan smith", "Jordan"], ["Jordan", "Jordan"], ["McKenzie Lee", "McKenzie"],
            ["DeShawn", "DeShawn"], ["MARY-JANE WATSON", "Mary-Jane"], ["o'neil", "O'Neil"], ["D'ANGELO", "D'Angelo"],
            ["", ""], ["   ", ""], ["Jos" Chr(0xE9) " ALVAREZ", "Jos" Chr(0xE9)], ["JOS" Chr(0xC9), "Jos" Chr(0xE9)],
            ["mary-jane", "Mary-Jane"], ["Morgan LEE", "Morgan"], ["alex nguyen", "Alex"], ["`tCASEY`tRIVERA", "Casey"],
            ["J.R. SMITH", "J.R."], ["al-FATAH x", "al-FATAH"], ["X", "X"], ["o" Chr(0x2019) "brien", "O" Chr(0x2019) "Brien"]]
        for c in cases
            T.Eq(Composer.FirstName(c[1]), c[2], "FirstName [" StrReplace(c[1], "`t", "<tab>") "]")
    }

    static Crlf() {
        T.Eq(Composer.Crlf("a`nb`r`nc`rd"), "a`r`nb`r`nc`r`nd", "line breaks normalised to CRLF")
        cfg := Defaults.Config()
        cfg["noteTemplate"]["lines"] := ["one", "two"]
        r := TestComposer.Run1(TestComposer.Ses(["notDone"]), cfg)
        T.Eq(r.Text, "one`r`ntwo", "template lines joined with CRLF")
    }
}
