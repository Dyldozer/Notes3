#Requires AutoHotkey v2.0

class TestSchema {
    static Name := "Schema"

    static Run() {
        T.Case("defaults", () => TestSchema.DefaultsClean())
        T.Case("required keys", () => TestSchema.RequiredKeys())
        T.Case("system categories", () => TestSchema.SystemCats())
        T.Case("duplicates", () => TestSchema.Duplicates())
        T.Case("conditions", () => TestSchema.Conditions())
        T.Case("themes", () => TestSchema.Themes())
        T.Case("bounds", () => TestSchema.Bounds())
        T.Case("template", () => TestSchema.Template())
        T.Case("misc rules", () => TestSchema.Misc())
        T.Case("migrate", () => TestSchema.Migration())
        T.Case("notePrefix", () => TestSchema.NotePrefix())
        T.Case("stop", () => TestSchema.Stops())
        T.Case("flags", () => TestSchema.Flags())
        T.Case("step shapes", () => TestSchema.StepShapes())
        T.Case("items entry", () => TestSchema.ItemsEntry())
        T.Case("static", () => TestSchema.StaticCat())
        T.Case("fill missing", () => TestSchema.FillMissingKeys())
        T.Case("fill missing no fragments", () => TestSchema.FillMissingNoFragments())
    }

    ; Static is categories[4]: static.{pingTargets[], pingOutcomes[]} (a leftover static.fragments from older configs is ignored).
    static StaticCat() {
        r := TestSchema.With((c) => 0)
        T.True(r.Ok && r.Warnings.Length = 0, "defaults are clean")
        ; the whole section
        r := TestSchema.With((c) => c["categories"][4].Delete("static"))
        T.True(TestSchema.Has(r, "categories[4].static: required for kind static"), "static section missing")
        r := TestSchema.With((c) => c["categories"][4]["static"] := "x")
        T.True(TestSchema.Has(r, "categories[4].static: must be an object"), "static must be an object")
        r := TestSchema.With((c) => c["categories"][4]["static"]["extra"] := 1)
        T.True(r.Ok && TestSchema.WarnHas(r, 'static: unknown key "extra"'), "unknown static key is a warning")
        ; ping outcomes: both ids must exist
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"].RemoveAt(1))
        T.False(r.Ok, "missing outcome id reply rejected")
        T.True(TestSchema.Has(r, 'categories[4].static.pingOutcomes: required id "reply" is missing'), "message names the missing outcome id")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"].RemoveAt(2))
        T.True(TestSchema.Has(r, 'required id "noReply" is missing'), "missing outcome id noReply rejected")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][2]["id"] := "other")
        T.True(TestSchema.Has(r, 'required id "noReply" is missing'), "renamed outcome id rejected")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"] := [])
        T.True(TestSchema.Has(r, "pingOutcomes: must contain at least one entry"), "empty outcomes rejected")
        r := TestSchema.With((c) => c["categories"][4]["static"].Delete("pingOutcomes"))
        T.True(TestSchema.Has(r, "categories[4].static.pingOutcomes: required key is missing"), "outcomes key missing")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"] := "x")
        T.True(TestSchema.Has(r, "pingOutcomes: must be a list"), "outcomes must be a list")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1].Delete("fragment"))
        T.True(TestSchema.Has(r, "pingOutcomes[1].fragment: required key is missing"), "outcome without fragment rejected")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1]["fragment"] := "")
        T.True(r.Ok, "an empty outcome fragment is allowed")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1]["fragment"] := 5)
        T.True(TestSchema.Has(r, "pingOutcomes[1].fragment: must be text"), "numeric outcome fragment")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1]["label"] := "")
        T.True(TestSchema.Has(r, "pingOutcomes[1].label: must not be empty"), "empty outcome label")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][2]["id"] := "reply")
        T.True(TestSchema.Has(r, 'pingOutcomes: duplicate id "reply"'), "duplicate outcome id")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1]["fragment"] := "Ping {nope} {pingAddress}")
        T.True(r.Ok && TestSchema.WarnHas(r, "unknown placeholder {nope}"), "unknown placeholder in an outcome is a warning")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingOutcomes"][1]["fragment"] := "{ip} {tech.firstName} {job.number}")
        T.True(TestSchema.WarnHas(r, "unknown placeholder {ip}") && r.Warnings.Length = 1, "{ip} is not a ping placeholder; context placeholders are")
        ; ping targets: both ids must exist, labels are wording
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"].RemoveAt(1))
        T.True(TestSchema.Has(r, 'categories[4].static.pingTargets: required id "gateway" is missing'), "missing target id gateway")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"].RemoveAt(2))
        T.True(TestSchema.Has(r, 'pingTargets: required id "ip" is missing'), "missing target id ip")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"] := [])
        T.True(TestSchema.Has(r, "pingTargets: must contain at least one entry"), "empty targets")
        r := TestSchema.With((c) => c["categories"][4]["static"].Delete("pingTargets"))
        T.True(TestSchema.Has(r, "categories[4].static.pingTargets: required key is missing"), "targets key missing")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"][1]["label"] := "Default gateway")
        T.True(r.Ok && r.Warnings.Length = 0, "target labels are free wording")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"][1]["label"] := "")
        T.True(TestSchema.Has(r, "pingTargets[1].label: must not be empty"), "empty target label")
        r := TestSchema.With((c) => c["categories"][4]["static"]["pingTargets"].Push(Map("id", "gateway", "label", "Again")))
        T.True(TestSchema.Has(r, 'pingTargets: duplicate id "gateway"'), "duplicate target id")
        ; the removed scripted note: a leftover "fragments" (any shape) is ignored, never an error and not even a warning
        r := TestSchema.With((c) => c["categories"][4]["static"]["fragments"] := Map("scripted", "Static IP details: {ip}/{prefix}", "gatewayManual", "By hand."))
        T.True(r.Ok && r.Warnings.Length = 0, "a leftover static.fragments still validates, with no warning " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][4]["static"]["fragments"] := Map("scripted", 5, "extra", "x"))
        T.True(r.Ok, "even a malformed leftover fragments object is ignored " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][4]["static"]["fragments"] := "x")
        T.True(r.Ok, "even a leftover fragments that is not an object is ignored " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][4]["static"]["unknownThing"] := "x")
        T.True(r.Ok && TestSchema.WarnHas(r, 'unknown key "unknownThing"'), "other unknown static keys are still warnings")
        ; JSON round trip keeps the section valid
        c := Defaults.Config()
        back := ConfigJson.Parse(ConfigJson.Stringify(c))
        T.True(Schema.Validate(back).Ok, "the static section survives JSON")
        T.Eq(ConfigJson.Canon(back["categories"][4]), ConfigJson.Canon(c["categories"][4]), "unchanged by JSON")
    }

    static WarnHas(r, text) {
        for w in r.Warnings
            if InStr(w, text, true)
                return true
        return false
    }

    ; The Trouble Call stop: steps[4] (supervisorTc) option 2 (No).
    static Stops() {
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := ["reason", "orderType"])
        T.True(r.Ok, "keepSteps reason+orderType accepted " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"].Delete("keepSteps"))
        T.True(r.Ok, "keepSteps is optional")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := [])
        T.True(r.Ok, "empty keepSteps accepted (the note is then the stop fragment alone)")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := ["reason", "ghost"])
        T.False(r.Ok, "keepSteps with an unknown step rejected")
        T.True(TestSchema.Has(r, 'steps[4].options[2].stop.keepSteps: references unknown step "ghost"'), "message names path and step")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := ["contact"])
        T.False(r.Ok, "keepSteps with a LATER step rejected")
        T.True(TestSchema.Has(r, 'step "contact" must come before the step that stops'), "message says before")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := ["supervisorTc"])
        T.False(r.Ok, "keepSteps naming the stop step itself rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := "reason")
        T.True(TestSchema.Has(r, "stop.keepSteps: must be a list"), "keepSteps must be a list")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := [5])
        T.False(r.Ok, "keepSteps entries must be step ids")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["keepSteps"] := ["reason", "reason"])
        T.True(r.Ok && r.Warnings.Length = 1, "a step listed twice is a warning")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["extra"] := 1)
        T.True(TestSchema.Has(r, 'unknown key "extra"'), "unknown stop key rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"] := "stop")
        T.True(TestSchema.Has(r, "stop: must be an object"), "stop must be an object")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["message"] := "")
        T.True(TestSchema.Has(r, "stop.message: must not be empty"), "stop message must not be empty")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"]["fragment"] := 5)
        T.True(TestSchema.Has(r, "stop.fragment: must be text"), "stop fragment must be text")
        r := TestSchema.With((c) => c["categories"][1]["steps"][1]["options"][1]["stop"] := Map("message", "m", "keepSteps", ["reason"]))
        T.False(r.Ok, "the first step cannot keep itself")
        r := TestSchema.With((c) => c["categories"][1]["steps"][1]["options"][1]["stop"] := Map("message", "m"))
        T.True(r.Ok, "a stop with just a message is accepted")
    }

    ; Equipment is categories[2], Billing categories[3]: entry.{actions, items, outcomes, outcomeRequired, qty, details}.
    static ItemsEntry() {
        r := TestSchema.With((c) => 0)
        T.True(r.Ok && r.Warnings.Length = 0, "defaults are clean")
        ; ids
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"][2]["id"] := "item1")
        T.True(TestSchema.Has(r, 'categories[2].entry.items: duplicate id "item1"'), "duplicate item id")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["outcomes"][2]["id"] := "completed")
        T.True(TestSchema.Has(r, 'categories[3].entry.outcomes: duplicate id "completed"'), "duplicate outcome id")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["actions"][3]["id"] := "added")
        T.True(TestSchema.Has(r, 'categories[3].entry.actions: duplicate id "added"'), "duplicate action id")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"][1]["id"] := "1 bad")
        T.True(TestSchema.Has(r, "invalid id"), "bad id characters")
        ; at least one action and one item
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"] := [])
        T.True(TestSchema.Has(r, "categories[2].entry.actions: must contain at least one entry"), "no actions")
        r := TestSchema.With((c) => c["categories"][2]["entry"].Delete("actions"))
        T.True(TestSchema.Has(r, "categories[2].entry.actions: required key is missing"), "actions key missing")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["items"] := [])
        T.True(TestSchema.Has(r, "categories[3].entry.items: must contain at least one entry"), "no items")
        r := TestSchema.With((c) => c["categories"][3]["entry"].Delete("items"))
        T.True(TestSchema.Has(r, "categories[3].entry.items: required key is missing"), "items key missing")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"] := "Router")
        T.True(TestSchema.Has(r, "entry.items: must be a list"), "items must be a list")
        r := TestSchema.With((c) => c["categories"][2]["entry"] := "x")
        T.True(TestSchema.Has(r, "categories[2].entry: required for kind items"), "entry must be an object")
        ; labels and fragments are text
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"][1]["label"] := "")
        T.True(TestSchema.Has(r, "entry.items[1].label: must not be empty"), "empty item label")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"][1]["label"] := 5)
        T.True(TestSchema.Has(r, "entry.items[1].label: must be text"), "numeric item label")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["items"][1].Delete("label"))
        T.True(TestSchema.Has(r, "entry.items[1].label: required key is missing"), "missing item label")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"][1]["fragment"] := 5)
        T.True(TestSchema.Has(r, "entry.actions[1].fragment: must be text"), "numeric action fragment")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"][1].Delete("fragment"))
        T.True(TestSchema.Has(r, "entry.actions[1].fragment: required key is missing"), "action without fragment")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"][1]["fragment"] := "")
        T.True(r.Ok, "an empty fragment is allowed (the action adds nothing)")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["outcomes"][1].Delete("fragment"))
        T.True(TestSchema.Has(r, "entry.outcomes[1].fragment: required key is missing"), "outcome without fragment")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["outcomes"][1]["label"] := "")
        T.True(TestSchema.Has(r, "entry.outcomes[1].label: must not be empty"), "empty outcome label")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["outcomes"][1] := "Completed")
        T.True(TestSchema.Has(r, "entry.outcomes[1]: must be an object"), "outcome must be an object")
        ; outcomes
        r := TestSchema.With((c) => c["categories"][3]["entry"]["outcomes"] := [])
        T.True(TestSchema.Has(r, "categories[3].entry.outcomes: must contain at least one entry when outcomeRequired is true"), "outcomeRequired with no outcomes")
        r := TestSchema.With((c) => c["categories"][3]["entry"].Delete("outcomes"))
        T.True(TestSchema.Has(r, "outcomes: must contain at least one entry when outcomeRequired is true"), "outcomeRequired with no outcomes key")
        r := TestSchema.With((c) => (c["categories"][3]["entry"]["outcomes"] := [], c["categories"][3]["entry"]["outcomeRequired"] := false))
        T.True(r.Ok, "no outcomes is fine when they are not required")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["outcomeRequired"] := true)
        T.True(TestSchema.Has(r, "categories[2].entry.outcomes: must contain at least one entry when outcomeRequired"), "Equipment cannot require outcomes it does not have")
        r := TestSchema.With((c) => c["categories"][2]["entry"].Delete("outcomes"))
        T.True(r.Ok, "the outcomes key is optional")
        ; flags are booleans
        for k in ["qty", "details", "outcomeRequired"] {
            r := TestSchema.With((c, k) => c["categories"][3]["entry"][k] := "yes", k)
            T.True(TestSchema.Has(r, "categories[3].entry." k ": must be true or false"), k " rejects text")
            r := TestSchema.With((c, k) => c["categories"][3]["entry"][k] := 2, k)
            T.True(TestSchema.Has(r, "categories[3].entry." k ": must be true or false"), k " rejects 2")
            r := TestSchema.With((c, k) => c["categories"][3]["entry"][k] := Map(), k)
            T.True(TestSchema.Has(r, "entry." k ": must be true or false"), k " rejects an object")
            r := TestSchema.With((c, k) => c["categories"][3]["entry"][k] := 0, k)
            T.False(TestSchema.Has(r, "entry." k ": must be"), k " accepts 0")
            r := TestSchema.With((c, k) => c["categories"][3]["entry"].Delete(k), k)
            T.True(r.Ok || TestSchema.Has(r, "outcomes"), k " is optional")
        }
        ; warnings only
        r := TestSchema.With((c) => c["categories"][2]["entry"]["qtyy"] := true)
        T.True(r.Ok && r.Warnings.Length = 1, "an unknown key is a warning, not an error")
        T.Contains(r.Warnings[1], 'unknown key "qtyy"', "naming the key")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"][1]["fragment"] := "{action} {detials}")
        T.True(r.Ok && r.Warnings.Length = 1, "an unknown placeholder is a warning")
        T.Contains(r.Warnings[1], "{detials}", "naming the placeholder")
        r := TestSchema.With((c) => c["categories"][2]["entry"]["actions"][1]["fragment"] := "{tech.firstName} {job.number} {address} {outcome} {item} {qty} {details} {action}")
        T.True(r.Ok && r.Warnings.Length = 0, "every supported placeholder is accepted")
        ; JSON: the new flag is written and read as true / false
        txt := ConfigJson.Stringify(Defaults.Config())
        T.Contains(txt, '"outcomeRequired": true', "outcomeRequired is written as true")
        T.Contains(txt, '"outcomeRequired": false', "and false")
        back := ConfigJson.Parse(txt)
        T.Eq(back["categories"][3]["entry"]["outcomeRequired"], 1, "read back as 1")
        T.True(Schema.Validate(back).Ok, "and valid")
        ; a new items category made by an admin is validated by the same rules
        cfg := Defaults.Config()
        cfg["categories"].Push(Map("id", "parts", "label", "Parts", "icon", "E772", "enabled", true, "system", false, "kind", "items",
            "entry", Map("actions", [Map("id", "a", "label", "A", "fragment", "{action} {item}")], "items", [Map("id", "i", "label", "I")])))
        T.True(Schema.Validate(cfg).Ok, "an admin-made items category validates")
        cfg["categories"][6]["entry"]["items"] := []
        T.False(Schema.Validate(cfg).Ok, "and needs an item")
    }

    static Flags() {
        T.True(TestSchema.With((c) => 0).Ok, "defaults (with a flag) are valid")
        r := TestSchema.With((c) => c["categories"][1].Delete("flags"))
        T.True(r.Ok, "flags are optional")
        r := TestSchema.With((c) => c["categories"][1]["flags"] := [])
        T.True(r.Ok, "empty flags list accepted")
        r := TestSchema.With((c) => c["categories"][1]["flags"] := "x")
        T.True(TestSchema.Has(r, "categories[1].flags: must be a list"), "flags must be a list")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1].Delete("message"))
        T.True(TestSchema.Has(r, "flags[1].message: required key is missing"), "flag needs a message")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1]["message"] := " ")
        T.True(TestSchema.Has(r, "flags[1].message: must not be empty"), "flag message not blank")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1].Delete("when"))
        T.True(TestSchema.Has(r, "flags[1].when: required key is missing"), "flag needs a condition")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1].Delete("id"))
        T.True(TestSchema.Has(r, "flags[1].id"), "flag needs an id")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1]["when"] := Map("step", "ghost", "in", ["a"]))
        T.True(TestSchema.Has(r, "flags[1].when.step: references unknown step"), "flag condition references are checked")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1]["when"] := Map("expr", "a"))
        T.True(TestSchema.Has(r, 'unknown key "expr"'), "flag conditions stay simple")
        r := TestSchema.With((c) => c["categories"][1]["flags"].Push(Map("id", "reason4Sro", "message", "again",
            "when", Map("step", "reason", "in", ["r1"]))))
        T.True(TestSchema.Has(r, 'flags: duplicate id "reason4Sro"'), "duplicate flag id")
        r := TestSchema.With((c) => c["categories"][1]["flags"][1]["blocks"] := 1)
        T.True(TestSchema.Has(r, 'unknown key "blocks"'), "a flag cannot carry a blocking switch")
        r := TestSchema.With((c) => c["categories"][1]["flags"].Push(Map("id", "later", "message", "m",
            "when", Map("step", "outcome", "in", ["o1"]))))
        T.True(r.Ok, "a flag may refer to any step " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][5]["flags"] := [Map("id", "f", "message", "m", "when", Map("step", "closeChoice", "in", ["k1"]))])
        T.True(r.Ok, "flags work on any steps category " TestSchema.Show(r))
    }

    static StepShapes() {
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"].Push(Map("id", "maybe", "label", "Maybe")))
        T.True(TestSchema.Has(r, '"yes" and "no"'), "a yesno step takes only yes and no")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["options"] := [Map("id", "a", "label", "A")])
        T.True(TestSchema.Has(r, "a group step has only fields"), "a group has no options")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["fields"] := [])
        T.True(TestSchema.Has(r, "a group step needs at least one field"), "a group needs fields")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3].Delete("fields"))
        T.True(TestSchema.Has(r, "a group step needs at least one field"), "a group without a fields key is rejected")
        r := TestSchema.With((c) => c["categories"][5]["steps"][3].Delete("fields"))
        T.True(r.Ok && r.Warnings.Length = 1, "a text step without fields is a warning")
        r := TestSchema.With((c) => c["categories"][5]["steps"][3]["options"] := [Map("id", "a", "label", "A")])
        T.True(TestSchema.Has(r, "a text step has only fields"), "a text step has no options")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["fields"][1]["id"] := "supervisorName")
        T.True(TestSchema.Has(r, 'field id "supervisorName" is used by steps "supervisorPwo" and "supervisorTc"'), "field id reused in another step")
        r := TestSchema.With((c) => c["categories"][1]["steps"][5]["fields"][1]["id"] := "reason")
        T.True(TestSchema.Has(r, 'field id "reason" is also a step id'), "field id equal to a step id")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["fields"][1]["multiline"] := 1)
        T.True(r.Ok, "multiline accepted")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["fields"][1]["multiline"] := "yes")
        T.True(TestSchema.Has(r, "fields[1].multiline: must be true or false"), "multiline must be a bool")
        r := TestSchema.With((c) => c["categories"][1]["steps"][1]["required"] := "yes")
        T.True(TestSchema.Has(r, "steps[1].required: must be true or false"), "step required must be a bool")
        r := TestSchema.With((c) => c["categories"][1]["steps"][1].Delete("required"))
        T.True(r.Ok, "step required is optional")
        r := TestSchema.With((c) => c["categories"][1]["steps"][2]["when"] := Map("step", "contact", "in", ["c1"]))
        T.True(TestSchema.Has(r, 'steps[2].when.step: step "contact" must come before'), "when referring to a later step rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][2]["when"] := Map("step", "orderType", "in", ["pwo"]))
        T.True(TestSchema.Has(r, 'steps[2].when.step: step "orderType" must come before'), "when referring to itself rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("any", [Map("step", "orderType", "in", ["pwo"]),
            Map("step", "outcome", "in", ["o1"])]))
        T.True(TestSchema.Has(r, 'when.any[2].step: step "outcome" must come before'), "nested later reference rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["fields"][1]["requiredWhen"] := Map("step", "outcome", "in", ["o1"]))
        T.True(r.Ok, "requiredWhen may refer to any step " TestSchema.Show(r))
        T.Eq(Schema.Validate(Defaults.Config()).Warnings.Length, 0, "no warnings on the defaults")
    }

    static NotePrefix() {
        r := TestSchema.With((c) => c["categories"][1]["notePrefix"] := "Not Done - ")
        T.True(r.Ok, "notePrefix text accepted " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][1]["notePrefix"] := "")
        T.True(r.Ok, "empty notePrefix accepted")
        r := TestSchema.With((c) => c["categories"][1].Delete("notePrefix"))
        T.True(r.Ok, "notePrefix is optional")
        r := TestSchema.With((c) => c["categories"][1]["notePrefix"] := "0123456789012345678901234567890123456789")
        T.True(r.Ok, "40 characters accepted")
        r := TestSchema.With((c) => c["categories"][1]["notePrefix"] := "01234567890123456789012345678901234567890")
        T.False(r.Ok, "41 characters rejected")
        T.True(TestSchema.Has(r, "categories[1].notePrefix"), "message names the path")
        for bad in [5, Map(), ["x"]] {
            r := TestSchema.With((c, v) => c["categories"][2]["notePrefix"] := v, bad)
            T.False(r.Ok, "non-text notePrefix rejected: " Type(bad))
            T.True(TestSchema.Has(r, "categories[2].notePrefix: must be text"), "message says text: " Type(bad))
        }
    }

    ; Validate a mutated copy of the defaults.
    static With(fn, args*) {
        c := Defaults.Config()
        fn(c, args*)
        return Schema.Validate(c)
    }

    static Has(r, text) {
        for e in r.Errors
            if InStr(e, text, true)
                return true
        return false
    }

    static Show(r) => Schema.Summary(r, 4)

    static DefaultsClean() {
        r := Schema.Validate(Defaults.Config())
        T.True(r.Ok, "defaults validate")
        T.Eq(r.Errors.Length, 0, "defaults: no errors " (r.Ok ? "" : TestSchema.Show(r)))
        T.Eq(r.Warnings.Length, 0, "defaults: no warnings")
        T.False(Schema.Validate("not a map").Ok, "non-object config rejected")
    }

    static RequiredKeys() {
        for k in Schema.TOP_KEYS {
            r := TestSchema.With((c, k) => c.Delete(k), k)
            T.False(r.Ok, "missing top-level key rejected: " k)
            T.True(TestSchema.Has(r, k ": required key is missing"), "message names key: " k)
        }
        r := TestSchema.With((c) => c["ping"] := "fast")
        T.True(TestSchema.Has(r, "ping: must be an object"), "ping wrong type")
        r := TestSchema.With((c) => c["revision"] := "x")
        T.True(TestSchema.Has(r, "revision:"), "revision wrong type")
        r := TestSchema.With((c) => c["extra"] := 1)
        T.True(r.Ok && r.Warnings.Length = 1, "unknown top-level key is a warning only")
    }

    static SystemCats() {
        r := TestSchema.With((c) => c["categories"].RemoveAt(2))
        T.False(r.Ok, "missing system category rejected")
        T.True(TestSchema.Has(r, 'required system category "equipment" is missing'), "message names the category")
        r := TestSchema.With((c) => c["categories"][2]["enabled"] := false)
        T.True(r.Ok, "disabled system category is fine")
        r := TestSchema.With((c) => c["categories"][1]["steps"].RemoveAt(1))
        T.False(r.Ok, "notDone without reason rejected")
        T.True(TestSchema.Has(r, 'required step "reason" is missing'), "message names the reason step")
        r := TestSchema.With((c) => c["categories"][1]["kind"] := "items")
        T.False(r.Ok, "system category with wrong kind rejected")
        r := TestSchema.With((c) => c["categories"][1]["kind"] := "bogus")
        T.True(TestSchema.Has(r, "categories[1].kind"), "bad kind names path")
        r := TestSchema.With((c) => c["categories"].Push(Map("id", "extra", "label", "Extra", "icon", "E713",
            "enabled", true, "system", false, "kind", "steps",
            "steps", [Map("id", "s1", "label", "S", "type", "text")])))
        T.True(r.Ok, "extra custom category accepted " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][1]["icon"] := "zz")
        T.True(TestSchema.Has(r, "categories[1].icon"), "bad icon code rejected")
    }

    static Duplicates() {
        r := TestSchema.With((c) => c["categories"][2]["id"] := "notDone")
        T.True(TestSchema.Has(r, 'categories: duplicate id "notDone"'), "duplicate category id")
        r := TestSchema.With((c) => c["categories"][1]["steps"][2]["id"] := "reason")
        T.True(TestSchema.Has(r, 'categories[1].steps: duplicate id "reason"'), "duplicate step id")
        r := TestSchema.With((c) => c["categories"][1]["steps"][2]["options"][2]["id"] := "pwo")
        T.True(TestSchema.Has(r, 'categories[1].steps[2].options: duplicate id "pwo"'), "duplicate option id")
        r := TestSchema.With((c) => c["categories"][3]["entry"]["actions"][2]["id"] := "added")
        T.True(TestSchema.Has(r, 'categories[3].entry.actions: duplicate id "added"'), "duplicate action id")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["fields"][2]["id"] := "supervisorName")
        T.True(TestSchema.Has(r, 'fields: duplicate id "supervisorName"'), "duplicate field id")
        r := TestSchema.With((c) => c["categories"][1]["steps"][2]["options"][1]["id"] := "bad id")
        T.True(TestSchema.Has(r, "options[1].id"), "invalid id characters rejected")
    }

    static Conditions() {
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "nope", "in", ["x"]))
        T.True(TestSchema.Has(r, 'categories[1].steps[3].when.step: references unknown step "nope"'), "bad condition reference")
        ; reference to a step in ANOTHER category is unknown here
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "closeStep1", "in", ["opt1"]))
        T.False(r.Ok, "cross-category reference rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("expr", "a == b"))
        T.True(TestSchema.Has(r, 'unknown key "expr"'), "expression key rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "orderType", "in", ["pwo"], "all", []))
        T.False(r.Ok, "mixed condition forms rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "orderType"))
        T.False(r.Ok, "step without in rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("in", ["pwo"]))
        T.False(r.Ok, "in without step rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "orderType", "in", []))
        T.False(r.Ok, "empty in rejected")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("any", [
            Map("step", "orderType", "in", ["pwo"]),
            Map("all", [Map("step", "reason", "in", ["reason1"]), Map("step", "orderType", "in", ["tc", "sro"])])]))
        T.True(r.Ok, "nested all/any accepted " TestSchema.Show(r))
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("all", [Map("step", "ghost", "in", ["a"])]))
        T.True(TestSchema.Has(r, "when.all[1].step"), "nested bad reference names the path")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["fields"][1]["requiredWhen"] := Map("step", "ghost", "in", ["a"]))
        T.True(TestSchema.Has(r, "requiredWhen.step"), "requiredWhen reference checked")
        r := TestSchema.With((c) => c["categories"][1]["steps"][3]["when"] := Map("step", "orderType", "in", ["zzz"]))
        T.True(r.Ok && r.Warnings.Length = 1, "unknown option in condition is a warning")
    }

    static Themes() {
        for bad in ["blue", "#12345", "#GGGGGG", "0099D8", "#0099D8F", ""] {
            r := TestSchema.With((c, v) => c["themes"]["presets"][1]["accent"] := v, bad)
            T.False(r.Ok, 'accent rejected: "' bad '"')
        }
        r := TestSchema.With((c) => c["themes"]["presets"][1]["accent"] := "#abcdef")
        T.True(r.Ok, "lowercase hex accent accepted")
        r := TestSchema.With((c) => c["themes"]["default"] := "missing")
        T.True(TestSchema.Has(r, "themes.default"), "default theme must exist")
        r := TestSchema.With((c) => c["themes"]["presets"][1]["mode"] := "sepia")
        T.True(TestSchema.Has(r, "themes.presets[1].mode"), "theme mode checked")
        r := TestSchema.With((c) => c["themes"]["presets"][1]["sheet"] := "nosuchlook")
        T.True(r.Ok && r.Warnings.Length = 1 && InStr(r.Warnings[1], "unknown look"), "unknown look is a warning, not an error")
        r := TestSchema.With((c) => c["themes"]["presets"][1]["sheet"] := "WIN98")
        T.True(r.Ok && r.Warnings.Length = 0, "library look names are accepted (any case)")
    }

    static Bounds() {
        cases := [
            ["ping", "timeoutMs", 199, 5001, 200, 5000],
            ["ping", "attempts", 0, 21, 1, 20],
            ["ping", "intervalMs", 249, 10001, 250, 10000],
            ["ping", "untilSuccessMaxMin", 0, 31, 1, 30],
            ["callTracking", "newCallDebounceMs", -1, 60001, 0, 60000],
            ["history", "retentionDays", 0, 91, 1, 90]]
        for cs in cases {
            sec := cs[1], key := cs[2], path := sec "." key
            for v in [cs[3], cs[4]] {
                r := TestSchema.With((c, sec, key, v) => c[sec][key] := v, sec, key, v)
                T.False(r.Ok, path " rejects " v)
                T.True(TestSchema.Has(r, path ": must be between"), path " message for " v)
            }
            for v in [cs[5], cs[6]] {
                r := TestSchema.With((c, sec, key, v) => c[sec][key] := v, sec, key, v)
                T.True(r.Ok, path " accepts " v)
            }
            r := TestSchema.With((c, sec, key) => c[sec][key] := "10", sec, key)
            T.False(r.Ok, path " rejects text")
            r := TestSchema.With((c, sec, key) => c[sec][key] := 2.5, sec, key)
            T.False(r.Ok, path " rejects fractions")
        }
    }

    static Template() {
        r := TestSchema.With((c) => c["noteTemplate"]["lines"] := [])
        T.True(TestSchema.Has(r, "noteTemplate.lines"), "empty template lines rejected")
        r := TestSchema.With((c) => c["noteTemplate"]["lines"] := "one line")
        T.False(r.Ok, "template lines must be an array")
        r := TestSchema.With((c) => c["noteTemplate"]["lines"] := ["ok", 5])
        T.True(TestSchema.Has(r, "noteTemplate.lines[2]"), "non-text template line rejected")
        r := TestSchema.With((c) => c["noteTemplate"].Delete("sentenceCase"))
        T.False(r.Ok, "template flag required")
    }

    static Misc() {
        r := TestSchema.With((c) => c["contextFields"].RemoveAt(1))
        T.True(TestSchema.Has(r, 'required field "techName"'), "required context field")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"].RemoveAt(2))
        T.True(TestSchema.Has(r, '"yes" and "no"'), "yesno needs yes and no")
        r := TestSchema.With((c) => c["categories"][1]["steps"][4]["options"][2]["stop"] := Map())
        T.True(TestSchema.Has(r, "stop.message"), "stop needs a message")
        r := TestSchema.With((c) => c["categories"][3]["entry"].Delete("actions"))
        T.False(r.Ok, "items category needs actions")
        r := TestSchema.With((c) => c["categories"][1]["enabled"] := 5)
        T.True(TestSchema.Has(r, "categories[1].enabled"), "bool field checked")
    }

    static Migration() {
        legacy := Map("historyDays", 30, "noteTemplate", Defaults.Config()["noteTemplate"])
        m := Schema.Migrate(legacy)
        T.Eq(m.From, 0, "legacy without schemaVersion is v0")
        T.Eq(m.To, 1, "migrates to v1")
        T.True(m.Changed, "Changed flag set")
        T.Eq(m.Error, "", "no error")
        T.Eq(m.Cfg["schemaVersion"], 1, "schemaVersion written")
        T.Eq(m.Cfg["history"]["retentionDays"], 30, "historyDays moved to history.retentionDays")
        T.False(m.Cfg.Has("historyDays"), "historyDays removed")
        T.True(m.Cfg.Has("categories") && m.Cfg.Has("ping") && m.Cfg.Has("themes"), "missing sections filled from defaults")
        r := Schema.Validate(m.Cfg)
        T.True(r.Ok, "migrated config validates " TestSchema.Show(r))

        m := Schema.Migrate(Map("schemaVersion", 0))
        T.True(m.Changed && m.Cfg["history"]["retentionDays"] = 14, "explicit v0 migrates with default retention")
        T.True(Schema.Validate(m.Cfg).Ok, "explicit v0 result validates")

        m := Schema.Migrate(Map("schemaVersion", "", "historyDays", 7))
        T.True(m.Changed && m.Cfg["history"]["retentionDays"] = 7, "empty schemaVersion treated as v0")

        m := Schema.Migrate(Map("historyDays", 500))
        T.False(Schema.Validate(m.Cfg).Ok, "out-of-range legacy value is carried over, then rejected by Validate")

        cur := Defaults.Config()
        m := Schema.Migrate(cur)
        T.False(m.Changed, "current version is not changed")
        T.Eq(m.From, 1, "current From")

        newer := Defaults.Config()
        newer["schemaVersion"] := 2
        m := Schema.Migrate(newer)
        T.Contains(m.Error, "newer version", "newer version rejected by Migrate")
        r := Schema.Validate(newer)
        T.False(r.Ok, "newer version rejected by Validate")
        T.Contains(r.Errors[1], "made by a newer version", "Validate message")
        T.Contains(Schema.Migrate("junk").Error, "not a JSON object", "non-object migrate error")
    }
    ; FillMissing must not bring back the removed static.fragments (Defaults no longer has it).
    static FillMissingNoFragments() {
        cfg := Defaults.Config()
        for c in cfg["categories"]
            if (c["id"] = "static") {
                c["static"].Delete("pingTargets")
                c["static"].Delete("pingOutcomes")
            }
        T.True(Schema.FillMissing(cfg), "the two lists are filled")
        for c in cfg["categories"]
            if (c["id"] = "static") {
                T.False(c["static"].Has("fragments"), "FillMissing does not add static.fragments")
                T.True(c["static"].Has("pingTargets") && c["static"].Has("pingOutcomes"), "but the ping lists are back")
            }
        T.False(Schema.InList(Schema.FILL_LISTS, "static.fragments"), "static.fragments is not a fill list")
        ; migrate a config that has no fragments: still none afterwards
        m := Schema.Migrate(Defaults.Config())
        for c in m.Cfg["categories"]
            if (c["id"] = "static")
                T.False(c["static"].Has("fragments"), "Migrate does not add static.fragments")
        T.False(Schema.FillMissing(m.Cfg), "and a current config needs nothing")
        T.True(Schema.Validate(m.Cfg).Ok, "it validates")
    }

    ; An admin-edited config from before a milestone added sections keeps validating; nothing edited or deleted changes.
    static FillMissingKeys() {
        cur := Defaults.Config()
        T.False(Schema.FillMissing(cur), "a current defaults config needs nothing")
        old := Defaults.Config()
        for c in old["categories"] {
            if (c["id"] = "static") {
                c["static"]["fragments"] := Map("scripted", "Admin's own static line {ip}.", "gatewayManual", "By hand.")   ; the removed feature
                c["static"].Delete("pingTargets")
            }
            if (c["id"] = "notDone") {
                c["label"] := "My Not Done"
                c.Delete("notePrefix")
                c.Delete("flags")
                c["steps"][1]["options"].RemoveAt(4)
            }
            if (c["id"] = "billing")
                c["entry"].Delete("outcomeRequired")
        }
        old["categories"].Push(Map("id", "extraCat", "label", "Extra", "icon", "E700", "enabled", true, "system", false,
            "kind", "items", "entry", Map("actions", [Map("id", "a", "label", "A", "fragment", "{action} {item}")],
            "items", [Map("id", "i", "label", "I")], "outcomes", [], "qty", false, "details", false, "outcomeRequired", false)))
        T.False(Schema.Validate(old).Ok, "the old config does not validate before migration")
        m := Schema.Migrate(old)
        T.True(m.Changed, "migration reports the filled keys")
        r := Schema.Validate(m.Cfg)
        T.True(r.Ok, "old config validates after filling " TestSchema.Show(r))
        nd := "", st := "", bl := ""
        for c in m.Cfg["categories"] {
            if (c["id"] = "notDone")
                nd := c
            if (c["id"] = "static")
                st := c
            if (c["id"] = "billing")
                bl := c
        }
        T.Eq(nd["label"], "My Not Done", "edited label kept")
        T.Eq(nd["steps"][1]["options"].Length, 3, "deleted option not brought back")
        T.False(nd.Has("flags"), "deleted flags list not brought back")
        T.True(nd.Has("notePrefix") && nd["notePrefix"] = "", "missing notePrefix filled with the default")
        T.True(st["static"].Has("pingTargets"), "missing static sections filled")
        T.Eq(st["static"]["fragments"]["scripted"], "Admin's own static line {ip}.", "a leftover static.fragments is neither changed nor removed")
        T.True(bl["entry"].Has("outcomeRequired"), "missing entry flag filled")
        T.Eq(m.Cfg["categories"].Length, 6, "no category added or removed")
        gone := Defaults.Config()
        for i, c in gone["categories"]
            if (c["id"] = "closeJob") {
                gone["categories"].RemoveAt(i)
                break
            }
        Schema.FillMissing(gone)
        has := false
        for c in gone["categories"]
            has := has || c["id"] = "closeJob"
        T.False(has, "a deleted category is not brought back")
    }
}
