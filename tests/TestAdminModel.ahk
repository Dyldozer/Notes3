#Requires AutoHotkey v2.0

; TestAdminModel - the Admin companion's logic (src\Admin\AdminModel.ahk, AdminPreview.ahk). Headless, temp folders only:
; the real config\config.json is never touched.
class TestAdminModel {
    static Name := "AdminModel"
    static Root := ""
    static N := 0

    static Run() {
        TestAdminModel.Root := A_Temp "\NFSNotesTest_Admin_" A_TickCount
        for name in ["Slugs", "UniqueIds", "Categories", "SystemCategory", "StepsAdd", "RequiredReason", "MoveSteps", "Options",
                     "Fields", "StepReferences", "ReferenceCleaning", "CleanCondShapes", "Flags", "CondBuilder", "CondJson",
                     "ItemsEditor", "StaticEditor", "Template", "ThemesAndNumbers", "ValidationPaths", "ConflictCopies",
                     "Import", "RawRoundTrip", "SaveBasics", "SaveRefusals", "Classify", "RestoreDefaults", "DirtyTracking",
                     "PreviewBasics", "PreviewEqualsMainApp", "Chips", "StopEditing", "TypeChange"]
            T.Case(name, ObjBindMethod(TestAdminModel, name))
        try DirDelete(TestAdminModel.Root, true)
    }

    ; --- helpers --------------------------------------------------------------------------------------------------
    static Bare() => AdminModel()

    ; A model on a temp shared dir seeded with the defaults at the given revision.
    static Setup(rev := 0, user := "alice") {
        TestAdminModel.N += 1
        d := TestAdminModel.Root "\t" TestAdminModel.N
        DirCreate(d "\shared")
        cfg := Defaults.Config()
        cfg["revision"] := rev
        Util.AtomicWrite(d "\shared\config.json", ConfigJson.Stringify(cfg))
        st := ConfigStore({SharedDir: d "\shared", CacheDir: d "\cache", User: user, Machine: "PC-A"})
        m := AdminModel({Store: st})
        m.Load()
        return {M: m, Dir: d, Shared: d "\shared", Cache: d "\cache", Store: st}
    }

    static Count(pattern) {
        n := 0
        Loop Files pattern, "F"
            n += 1
        return n
    }

    static Slot(k, cat, step := "", other := "") {
        s := {K: k, Cat: cat, Step: step}
        if (k = "req")
            s.Field := other
        if (k = "flag")
            s.Flag := other
        return s
    }

    static Ok(m, name) => T.True(m.Validate().Ok, name)

    ; --- ids ------------------------------------------------------------------------------------------------------
    static Slugs() {
        T.Eq(AdminModel.Slug("My option"), "myOption", "slug: two words")
        T.Eq(AdminModel.Slug("Swapped Router"), "swappedRouter", "slug: capitalised words")
        T.Eq(AdminModel.Slug("PWO"), "pwo", "slug: all caps word is lower-cased")
        T.Eq(AdminModel.Slug("PWO order type"), "pwoOrderType", "slug: caps word then words")
        T.Eq(AdminModel.Slug("Item 1 (placeholder)"), "item1Placeholder", "slug: digits and brackets")
        T.Eq(AdminModel.Slug("  spaced   out  "), "spacedOut", "slug: extra spaces")
        T.Eq(AdminModel.Slug("under_score-dash"), "underScoreDash", "slug: _ and - split words")
        T.Eq(AdminModel.Slug(Chr(0xC9) "t" Chr(0xE9) " " Chr(0xDC) "nit"), "eteUnit", "slug: accents are reduced to ASCII")
        T.Eq(AdminModel.Slug("Caf" Chr(0xE9) " " Chr(0xDC) "nit"), "cafeUnit", "slug: Cafe Unit with accents")
        T.Eq(AdminModel.Slug(Chr(0x65E5) Chr(0x672C) Chr(0x8A9E)), "item", "slug: only non-ASCII letters -> fallback")
        T.Eq(AdminModel.Slug(Chr(0x65E5) Chr(0x672C) Chr(0x8A9E), "option"), "option", "slug: custom fallback")
        T.Eq(AdminModel.Slug(""), "item", "slug: empty label")
        T.Eq(AdminModel.Slug("   "), "item", "slug: blank label")
        T.Eq(AdminModel.Slug("!!!", "step"), "step", "slug: punctuation only")
        T.Eq(AdminModel.Slug("2nd router", "option"), "option2ndRouter", "slug: starting with a digit gets the fallback in front")
        T.Eq(AdminModel.Slug("5"), "item5", "slug: a lone number")
        long := AdminModel.Slug("this is a very long label that goes on and on and on forever")
        T.True(StrLen(long) <= 32, "slug: at most 32 characters")
        T.True(RegExMatch(long, Schema.ID_RE), "slug: a long one is still a valid id")
        ; every slug is a valid id for the validator
        for lab in ["Hello world", "x", "A", "1 2 3", "Zed & Co.", Chr(0xE9) Chr(0xE9), "Q?", "a-b", "-a"]
            T.True(RegExMatch(AdminModel.Slug(lab), Schema.ID_RE), "slug is a valid id: [" lab "]")
    }

    static UniqueIds() {
        T.Eq(AdminModel.UniqueId("myOption", []), "myOption", "unique: free id is kept")
        T.Eq(AdminModel.UniqueId("myOption", ["myOption"]), "myOption2", "unique: second")
        T.Eq(AdminModel.UniqueId("myOption", ["myOption", "myOption2"]), "myOption3", "unique: third")
        T.Eq(AdminModel.UniqueId("myOption", ["MYOPTION"]), "myOption2", "unique: compared without case")
        T.Eq(AdminModel.UniqueId("r", ["r1", "r2"]), "r", "unique: r is free next to r1, r2")
        T.Eq(AdminModel.UniqueId("address", []), "address2", "unique: reserved placeholder names are never used")
        T.Eq(AdminModel.UniqueId("notes", []), "notes2", "unique: notes is reserved")
        T.Eq(AdminModel.NewId("My option", ["myOption"]), "myOption2", "NewId combines slug and unique")
        T.Eq(AdminModel.NewId("", ["item"]), "item2", "NewId: empty label with the fallback taken")
        m := TestAdminModel.Bare()
        r1 := m.AddStep("notDone", "Callback", "choice")
        r2 := m.AddStep("notDone", "Callback", "choice")
        T.Eq(r1.Id "|" r2.Id, "callback|callback2", "two steps with the same label get different ids")
        ; a step id never equals a field id of the category (one namespace)
        r3 := m.AddField("notDone", "callback", "Supervisor Name")
        T.Eq(r3.Id, "supervisorName2", "a field id avoids existing field ids")
        r4 := m.AddStep("notDone", "Supervisor Name 2", "choice")
        T.Eq(r4.Id, "supervisorName22", "a step id avoids field ids (supervisorName2 is taken)")
        T.True(m.Validate().Ok, "all of that validates")
        ; ids do not change when the label changes
        m.SetStepProp("notDone", "callback", "label", "Something else")
        T.True(m.Step("notDone", "callback") is Map, "renaming a step keeps its id")
    }

    ; --- categories -------------------------------------------------------------------------------------------------
    static Categories() {
        m := TestAdminModel.Bare()
        n0 := m.Work["categories"].Length
        r := m.AddCategory("steps", "Warranty check")
        T.True(r.Ok, "add a steps category")
        T.Eq(r.Id, "warrantyCheck", "its id is a slug of the label")
        T.Eq(m.Work["categories"].Length, n0 + 1, "it is at the end")
        TestAdminModel.Ok(m, "the new steps category validates")
        c := m.Cat("warrantyCheck")
        T.Eq(c["system"] "|" c["enabled"] "|" c["kind"] "|" c["icon"] "|" c["notePrefix"], "0|1|steps|E8A5|", "defaults of a new category")
        r := m.AddCategory("items", "Parts used")
        T.True(r.Ok && r.Id = "partsUsed", "add an items category")
        TestAdminModel.Ok(m, "the new items category validates")
        r := m.AddCategory("static", "Another static")
        T.False(r.Ok, "a new static category is refused")
        T.Contains(r.Error, "Static", "and the reason names it")
        T.Eq(m.Work["categories"].Length, n0 + 2, "nothing was added")
        T.False(m.AddCategory("steps", "   ").Ok, "an empty name is refused")
        T.False(m.AddCategory("other", "Zed").Ok, "an unknown kind is refused")
        r := m.AddCategory("steps", "Warranty check")
        T.Eq(r.Id, "warrantyCheck2", "same label: unique id")
        TestAdminModel.Ok(m, "still valid")
        ; order
        ids0 := ""
        for id in m.CatIds()
            ids0 .= id ","
        T.True(m.MoveCategory("partsUsed", -1).Ok, "move up")
        ids := ""
        for id in m.CatIds()
            ids .= id ","
        T.Eq(ids, StrReplace(ids0, "warrantyCheck,partsUsed,", "partsUsed,warrantyCheck,"), "partsUsed is now above warrantyCheck")
        T.False(m.MoveCategory(m.CatIds()[1], -1).Ok, "the first can't move up")
        T.False(m.MoveCategory(m.CatIds()[m.CatIds().Length], 1).Ok, "the last can't move down")
        T.True(m.MoveCategory("notDone", 1).Ok, "move a system category down")
        T.Eq(m.CatIds()[2], "notDone", "it moved")
        T.True(m.MoveCategory("notDone", -1).Ok, "and back")
        ; properties
        T.True(m.SetCatProp("partsUsed", "label", "Parts").Ok, "rename")
        T.Eq(m.Cat("partsUsed")["label"], "Parts", "label changed, id kept")
        T.True(m.SetCatProp("partsUsed", "enabled", false).Ok, "disable")
        T.Eq(m.Cat("partsUsed")["enabled"], 0, "disabled")
        T.True(m.SetCatProp("partsUsed", "icon", "e711").Ok, "icon accepted")
        T.Eq(m.Cat("partsUsed")["icon"], "E711", "icon stored in upper case")
        for bad in ["", "E7", "ZZZZ", "E7110011", "E 711", "#E711"]
            T.False(m.SetCatProp("partsUsed", "icon", bad).Ok, "icon refused: [" bad "]")
        T.Eq(m.Cat("partsUsed")["icon"], "E711", "refused icons change nothing")
        T.True(m.SetCatProp("partsUsed", "notePrefix", "Parts: ").Ok, "note prefix")
        T.False(m.SetCatProp("partsUsed", "notePrefix", "0123456789012345678901234567890123456789X").Ok, "41 characters refused")
        T.Eq(m.Cat("partsUsed")["notePrefix"], "Parts: ", "prefix unchanged after the refusal")
        T.False(m.SetCatProp("partsUsed", "kind", "steps").Ok, "kind can't be changed")
        T.False(m.SetCatProp("nope", "label", "x").Ok, "unknown category")
        ; remove a non-system category
        r := m.RemoveCategory("partsUsed")
        T.True(r.Ok && !r.System, "remove a custom category")
        T.True(m.Cat("partsUsed") = "", "it is gone")
        TestAdminModel.Ok(m, "valid again")
        T.False(m.RemoveCategory("partsUsed").Ok, "removing it twice fails")
    }

    static SystemCategory() {
        m := TestAdminModel.Bare()
        T.True(m.IsSystem("billing") && m.IsSystem("notDone") && !m.IsSystem("warranty"), "IsSystem")
        T.Eq(m.MissingSystem().Length, 0, "nothing missing at first")
        idx := m.CatIndex("billing")
        r := m.RemoveCategory("billing")
        T.True(r.Ok && r.System, "a system category can be removed (the UI asks first), the result says so")
        v := m.Validate()
        T.False(v.Ok, "removing a system category makes validation fail")
        T.Contains(v.Errors[1], 'required system category "billing" is missing', "the error names it")
        T.Eq(m.MissingSystem().Length "|" m.MissingSystem()[1], "1|billing", "MissingSystem lists it")
        T.Eq(v.Items[1].Nav.Page, "categories", "and the error leads to the categories page")
        r := m.RestoreSystemCategory("billing")
        T.True(r.Ok, "re-adding from the defaults")
        T.Eq(m.CatIndex("billing"), idx, "at its old position")
        TestAdminModel.Ok(m, "validation is fixed")
        T.Eq(ConfigJson.Canon(m.Cat("billing")), ConfigJson.Canon(Defaults.Billing()), "it is the built-in billing")
        T.False(m.RestoreSystemCategory("billing").Ok, "restoring an existing one fails")
        T.False(m.RestoreSystemCategory("warranty").Ok, "only system categories can be restored")
        ; remove two, restore both in the wrong order: positions still follow the defaults
        m.RemoveCategory("equipment"), m.RemoveCategory("static")
        m.RestoreSystemCategory("static")
        m.RestoreSystemCategory("equipment")
        ids := ""
        for id in m.CatIds()
            ids .= id ","
        T.Eq(ids, "notDone,equipment,billing,static,closeJob,", "restored in default order")
        ; removing every system category and the whole list restored from the defaults
        for sc in Schema.SYSTEM_CATS
            m.RemoveCategory(sc[1])
        T.Eq(m.MissingSystem().Length, 5, "all five missing")
        for sc in Schema.SYSTEM_CATS
            m.RestoreSystemCategory(sc[1])
        TestAdminModel.Ok(m, "all five restored")
    }

    ; --- steps --------------------------------------------------------------------------------------------------------
    static StepsAdd() {
        m := TestAdminModel.Bare()
        for type in ["choice", "yesno", "text", "group"] {
            r := m.AddStep("closeJob", "New " type, type)
            T.True(r.Ok, "add a " type " step")
            TestAdminModel.Ok(m, "a new " type " step validates")
        }
        T.False(m.AddStep("closeJob", "x", "bogus").Ok, "unknown type refused")
        T.False(m.AddStep("closeJob", "  ", "choice").Ok, "empty label refused")
        T.False(m.AddStep("billing", "x", "choice").Ok, "steps can't be added to an items category")
        s := m.Step("closeJob", "newYesno")
        T.Eq(s["options"][1]["id"] "|" s["options"][2]["id"], "yes|no", "a yesno step has yes and no")
        T.Eq(m.Step("closeJob", "newGroup")["fields"].Length, 1, "a group step starts with one field")
        T.True(m.SetStepProp("closeJob", "newChoice", "label", "Renamed").Ok, "rename")
        T.True(m.SetStepProp("closeJob", "newChoice", "required", true).Ok, "required")
        T.True(m.SetStepProp("closeJob", "newChoice", "fragment", "Text {tech.firstName}").Ok, "fragment")
        T.Eq(m.Step("closeJob", "newChoice")["required"], 1, "required stored as 1")
        T.False(m.SetStepProp("closeJob", "newChoice", "type", "text").Ok, "type goes through ChangeStepType")
        TestAdminModel.Ok(m, "still valid")
        ; remove a step nobody uses
        r := m.RemoveStep("closeJob", "newText")
        T.True(r.Ok && r.Removed = 0, "remove an unused step")
        TestAdminModel.Ok(m, "valid")
        ; the only step of a category can't be removed
        m.AddCategory("steps", "Solo")
        r := m.RemoveStep("solo", "step1")
        T.False(r.Ok, "the only step can't be removed")
    }

    static RequiredReason() {
        m := TestAdminModel.Bare()
        T.True(m.IsRequiredStep("notDone", "reason"), "reason in notDone is the required step")
        T.False(m.IsRequiredStep("closeJob", "reason"), "but not in other categories")
        r := m.RemoveStep("notDone", "reason")
        T.False(r.Ok, "the reason step can't be removed")
        T.True(r.HasOwnProp("Locked") && r.Locked, "and it is reported as locked")
        T.Contains(r.Error, "required", "with an explanation")
        r := m.RemoveStep("notDone", "reason", true)
        T.False(r.Ok, "not even with clean := true")
        T.True(m.Step("notDone", "reason") is Map, "still there")
        T.False(m.ChangeStepType("notDone", "reason", "text").Ok, "and its type can't be changed to text")
        T.False(m.ChangeStepType("notDone", "reason", "yesno").Ok, "or to yesno")
        TestAdminModel.Ok(m, "config still valid")
        ; a copy of the config without `reason` fails validation (the validator enforces it too)
        m.Step("notDone", "orderType")                   ; (just a lookup)
        steps := m.Work["categories"][1]["steps"]
        steps.RemoveAt(1)
        v := m.Validate()
        T.False(v.Ok, "if it were gone the config would be invalid")
        allErr := ""
        for e in v.Errors
            allErr .= e "|"
        T.Contains(allErr, 'required step "reason" is missing', "the validator says so")
    }

    static MoveSteps() {
        m := TestAdminModel.Bare()
        ord := () => (m.Steps("notDone").Length ? TestAdminModel.Order(m, "notDone") : "")
        T.Eq(ord(), "reason,orderType,supervisorPwo,supervisorTc,contact,outcome", "default order")
        r := m.MoveStep("notDone", "supervisorPwo", -1)
        T.False(r.Ok, "supervisorPwo above orderType would break its when")
        T.True(r.HasOwnProp("Blocked") && r.Blocked, "it is reported as blocked")
        T.Contains(r.Error, "Supervisor contact (PWO)", "the message names the step")
        T.Contains(r.Error, "Order type", "and the step it depends on")
        T.Eq(ord(), "reason,orderType,supervisorPwo,supervisorTc,contact,outcome", "nothing moved")
        r := m.MoveStep("notDone", "orderType", 1)
        T.False(r.Ok, "orderType below supervisorPwo is blocked too")
        T.True(r.Problems.Length >= 1, "with a list of problems")
        T.True(m.MoveStep("notDone", "contact", -1).Ok, "contact above supervisorTc is fine")
        T.Eq(ord(), "reason,orderType,supervisorPwo,contact,supervisorTc,outcome", "contact moved")
        T.True(m.MoveStep("notDone", "contact", 1).Ok, "and back")
        T.False(m.MoveStep("notDone", "reason", -1).Ok, "the first step can't move up")
        T.False(m.MoveStep("notDone", "outcome", 1).Ok, "the last step can't move down")
        T.False(m.MoveStep("notDone", "nope", 1).Ok, "unknown step")
        ; keepSteps: moving `reason` below the step that stops would keep a step that is no longer above it
        T.True(m.MoveStep("notDone", "reason", 1).Ok, "reason down once")
        T.True(m.MoveStep("notDone", "reason", 1).Ok, "twice")
        r := m.MoveStep("notDone", "reason", 1)
        T.False(r.Ok, "reason below supervisorTc is blocked (the stop keeps it)")
        T.Contains(r.Error, "keeps", "the message says the stop keeps it")
        TestAdminModel.Ok(m, "the config is still valid after all that")
        ; a step that already has a problem can still be moved (only NEW problems block)
        m2 := TestAdminModel.Bare()
        m2.Step("notDone", "orderType")["when"] := Map("step", "contact", "in", ["c1"])
        T.False(m2.Validate().Ok, "(setup) an order problem exists")
        T.True(m2.MoveStep("notDone", "outcome", -1).Ok, "moving something unrelated is allowed")
    }

    static Order(m, catId) {
        s := ""
        for st in m.Steps(catId)
            s .= (s = "" ? "" : ",") st["id"]
        return s
    }

    ; --- options --------------------------------------------------------------------------------------------------
    static Options() {
        m := TestAdminModel.Bare()
        r := m.AddOption("notDone", "reason", "Billing question")
        T.True(r.Ok && r.Id = "billingQuestion", "add an option, id from the label")
        T.Eq(m.Options("notDone", "reason").Length, 5, "five options")
        r := m.AddOption("notDone", "reason", "Billing question")
        T.Eq(r.Id, "billingQuestion2", "same label: unique id")
        T.False(m.AddOption("notDone", "supervisorTc", "Maybe").Ok, "yes/no steps have exactly two options")
        T.False(m.AddOption("notDone", "supervisorPwo", "x").Ok, "a group step has no options")
        T.False(m.AddOption("notDone", "reason", " ").Ok, "empty label refused")
        T.True(m.MoveOption("notDone", "reason", "billingQuestion", -1).Ok, "move up")
        T.Eq(m.Options("notDone", "reason")[4]["id"], "billingQuestion", "moved above r4")
        T.False(m.MoveOption("notDone", "reason", "r1", -1).Ok, "first can't move up")
        T.True(m.SetOptionProp("notDone", "reason", "r1", "label", "Customer not home").Ok, "label")
        T.True(m.SetOptionProp("notDone", "reason", "r1", "fragment", "Customer was not home.").Ok, "fragment")
        T.Eq(m.Options("notDone", "reason")[1]["id"], "r1", "the id did not change")
        T.False(m.SetOptionProp("notDone", "reason", "r1", "id", "zzz").Ok, "ids can't be edited")
        T.True(m.RemoveOption("notDone", "reason", "billingQuestion2").Ok, "remove an unused option")
        T.False(m.RemoveOption("notDone", "supervisorTc", "yes").Ok, "yes/no options can't be removed")
        TestAdminModel.Ok(m, "valid")
        ; the last option of a choice can't go
        m.AddCategory("steps", "Solo")
        T.False(m.RemoveOption("solo", "step1", "option1").Ok, "a choice needs at least one option")
        ; references are listed first
        refs := m.FindReferences({Kind: "option", Cat: "notDone", Step: "reason", Option: "r4"})
        T.Eq(refs.Length, 1, "r4 is used by one flag")
        T.Eq(refs[1].Kind, "flag", "kind flag")
        T.Contains(refs[1].Text, "Reason 4", "the text names the option label")
        T.Contains(refs[1].Text, "Flag", "and says it is a flag")
        r := m.RemoveOption("notDone", "reason", "r4")
        T.False(r.Ok, "removing a referenced option asks first")
        T.True(r.HasOwnProp("NeedConfirm") && r.NeedConfirm && r.Refs.Length = 1, "NeedConfirm with the references")
        T.True(m.Options("notDone", "reason").Length = 5, "nothing was removed")
        r := m.RemoveOption("notDone", "reason", "r4", true)
        T.True(r.Ok && r.Removed = 1, "removed with clean")
        fl := m.Flags("notDone")[1]
        T.Eq(ConfigJson.Canon(fl["when"]), '{"all":[{"in":["sro"],"step":"orderType"}]}', "the flag lost that clause only")
        TestAdminModel.Ok(m, "valid after cleaning")
        ; pwo is used by supervisorPwo.when -> when is removed (empty condition)
        refs := m.FindReferences({Kind: "option", Cat: "notDone", Step: "orderType", Option: "pwo"})
        T.Eq(refs.Length "|" refs[1].Kind, "1|when", "pwo is used by one when")
        T.Contains(refs[1].Text, "Supervisor contact (PWO)", "names the step")
        T.Contains(refs[1].Text, "Order type is PWO", "and the condition in words")
        m.RemoveOption("notDone", "orderType", "pwo", true)
        T.False(m.Step("notDone", "supervisorPwo").Has("when"), "the step's empty when was deleted")
        TestAdminModel.Ok(m, "valid")
        ; requiredWhen
        refs := m.FindReferences({Kind: "option", Cat: "notDone", Step: "supervisorTc", Option: "yes"})
        T.Eq(refs.Length "|" refs[1].Kind, "1|requiredWhen", "yes is used by a requiredWhen")
    }

    ; --- fields ------------------------------------------------------------------------------------------------------
    static Fields() {
        m := TestAdminModel.Bare()
        r := m.AddField("notDone", "supervisorPwo", "Phone number")
        T.True(r.Ok && r.Id = "phoneNumber", "add a field")
        T.Eq(m.Fields("notDone", "supervisorPwo").Length, 3, "three fields")
        r := m.AddField("notDone", "supervisorPwo", "Address")
        T.Eq(r.Id, "address2", "a field called Address doesn't shadow the {address} placeholder")
        T.True(m.SetFieldProp("notDone", "supervisorPwo", "phoneNumber", "required", true).Ok, "required")
        T.True(m.SetFieldProp("notDone", "supervisorPwo", "phoneNumber", "multiline", true).Ok, "multiline")
        T.True(m.SetFieldProp("notDone", "supervisorPwo", "phoneNumber", "label", "Phone").Ok, "label")
        f := AdminModel.Find(m.Fields("notDone", "supervisorPwo"), "phoneNumber")
        T.Eq(f["required"] "|" f["multiline"] "|" f["label"], "1|1|Phone", "stored")
        T.True(m.MoveField("notDone", "supervisorPwo", "phoneNumber", -1).Ok, "move")
        T.Eq(m.Fields("notDone", "supervisorPwo")[2]["id"], "phoneNumber", "moved up one")
        TestAdminModel.Ok(m, "valid")
        ; remove: unused
        T.True(m.RemoveField("notDone", "supervisorPwo", "address2").Ok, "remove an unused field")
        ; a group's last field can't go
        m.RemoveField("notDone", "supervisorPwo", "phoneNumber")
        m.RemoveField("notDone", "supervisorPwo", "rescheduleReason", true)
        r := m.RemoveField("notDone", "supervisorPwo", "supervisorName", true)
        T.False(r.Ok, "the last field of a group is kept")
        ; references: {supervisorName} in the step fragment
        m2 := TestAdminModel.Bare()
        refs := m2.FindReferences({Kind: "field", Cat: "notDone", Field: "supervisorName"})
        T.Eq(refs.Length "|" refs[1].Kind, "1|placeholder", "supervisorName is used in a fragment")
        T.Contains(refs[1].Text, "{supervisorName}", "the text shows the placeholder")
        r := m2.RemoveField("notDone", "supervisorPwo", "supervisorName")
        T.True(!r.Ok && r.NeedConfirm, "removing a used field asks first")
        r := m2.RemoveField("notDone", "supervisorPwo", "supervisorName", true)
        T.True(r.Ok, "removed with clean")
        T.Eq(m2.Step("notDone", "supervisorPwo")["fragment"], "Supervisor placeholder note. Reschedule reason {rescheduleReason} placeholder note.",
            "the placeholder was taken out of the fragment (spaces squeezed)")
        TestAdminModel.Ok(m2, "valid, no unknown placeholders left behind")
        T.Eq(m2.Validate().Warnings.Length, 0, "and no warnings")
        ; a field used by several option fragments
        refs := m2.FindReferences({Kind: "field", Cat: "notDone", Field: "contactDetails"})
        T.Eq(refs.Length, 4, "contactDetails is used by the four contact options")
        m2.RemoveField("notDone", "contact", "contactDetails", true)
        T.Eq(m2.Options("notDone", "contact")[1]["fragment"], "Contact 1 placeholder note.", "removed from every option")
        T.Eq(m2.Fields("notDone", "contact").Length, 0, "the field is gone")
        ; the stop fragment is covered too
        m3 := TestAdminModel.Bare()
        m3.Stop("notDone", "supervisorTc", "no")["fragment"] := "Stopped. {supervisorNameTc}"
        refs := m3.FindReferences({Kind: "field", Cat: "notDone", Field: "supervisorNameTc"})
        T.Eq(refs.Length, 2, "supervisorNameTc: the yes option fragment and the stop note")
        T.Contains(refs[2].Text, "stop note", "the text says where")
    }

    ; --- steps referenced elsewhere --------------------------------------------------------------------------------
    static StepReferences() {
        m := TestAdminModel.Bare()
        refs := m.FindReferences({Kind: "step", Cat: "notDone", Step: "orderType"})
        kinds := ""
        for r in refs
            kinds .= r.Kind ","
        T.Eq(refs.Length, 4, "orderType: two whens, a flag and a keepSteps")
        T.Contains(kinds, "when,when", "two whens")
        T.Contains(kinds, "flag", "a flag")
        T.Contains(kinds, "keepSteps", "a keepSteps")
        r := m.RemoveStep("notDone", "orderType")
        T.True(!r.Ok && r.NeedConfirm && r.Refs.Length = 4, "asks first, with the four references")
        T.True(m.Step("notDone", "orderType") is Map, "still there")
        r := m.RemoveStep("notDone", "orderType", true)
        T.True(r.Ok && r.Removed = 4, "removed with clean")
        T.False(m.Step("notDone", "supervisorPwo").Has("when"), "supervisorPwo lost its when")
        T.False(m.Step("notDone", "supervisorTc").Has("when"), "supervisorTc lost its when")
        T.Eq(ConfigJson.Canon(m.Flags("notDone")[1]["when"]), '{"all":[{"in":["r4"],"step":"reason"}]}', "the flag keeps its other clause")
        T.Eq(ConfigJson.Canon(m.Stop("notDone", "supervisorTc", "no")["keepSteps"]), '["reason"]', "keepSteps lost orderType")
        TestAdminModel.Ok(m, "valid after cleaning")
        ; a step nobody refers to
        m2 := TestAdminModel.Bare()
        T.Eq(m2.FindReferences({Kind: "step", Cat: "notDone", Step: "supervisorTc"}).Length, 0, "supervisorTc is not referenced from outside")
        T.True(m2.RemoveStep("notDone", "supervisorTc").Ok, "removed at once")
        TestAdminModel.Ok(m2, "valid")
        ; {stepId} placeholders: a fragment that uses the option label of a step
        m3 := TestAdminModel.Bare()
        m3.SetStepProp("notDone", "outcome", "fragment", "Outcome was {contact} again")
        refs := m3.FindReferences({Kind: "step", Cat: "notDone", Step: "contact"})
        T.Eq(refs.Length "|" refs[1].Kind, "1|placeholder", "a {contact} placeholder counts as a reference to the step")
        m3.RemoveStep("notDone", "contact", true)
        T.Eq(m3.Step("notDone", "outcome")["fragment"], "Outcome was again", "and is removed")
        TestAdminModel.Ok(m3, "valid")
        ; requiredWhen of ANOTHER step's field
        m4 := TestAdminModel.Bare()
        m4.SetCond(TestAdminModel.Slot("req", "notDone", "contact", "contactDetails"), Map("step", "reason", "in", ["r1", "r2"]))
        refs := m4.FindReferences({Kind: "step", Cat: "notDone", Step: "reason"})
        T.True(refs.Length >= 2, "requiredWhen and the flag refer to reason")
        m4.RemoveStep("notDone", "reason", false)
        T.False(m4.RemoveStep("notDone", "reason", true).Ok, "(reason itself is protected)")
        m4.RemoveStep("notDone", "orderType", true)
        TestAdminModel.Ok(m4, "still valid")
    }

    ; --- cleaning conditions ---------------------------------------------------------------------------------------
    static ReferenceCleaning() {
        ; a clause that loses its last option is removed; one that keeps another option stays
        m := TestAdminModel.Bare()
        slot := TestAdminModel.Slot("req", "notDone", "contact", "contactDetails")
        m.SetCond(slot, Map("all", [Map("step", "reason", "in", ["r1", "r2"]), Map("step", "orderType", "in", ["sro"])]))
        m.RemoveOption("notDone", "reason", "r1", true)
        T.Eq(ConfigJson.Canon(m.GetCond(slot)), '{"all":[{"in":["r2"],"step":"reason"},{"in":["sro"],"step":"orderType"}]}', "r1 taken out of the clause, r2 stays")
        m.RemoveOption("notDone", "reason", "r2", true)
        T.Eq(ConfigJson.Canon(m.GetCond(slot)), '{"all":[{"in":["sro"],"step":"orderType"}]}', "the clause that lost its last option is removed")
        m.RemoveOption("notDone", "orderType", "sro", true)
        T.False(m.Fields("notDone", "contact")[1].Has("requiredWhen"), "an all that became empty is removed, and so is the requiredWhen")
        TestAdminModel.Ok(m, "valid")
        ; flags: a flag that loses its condition is removed
        m2 := TestAdminModel.Bare()
        m2.RemoveOption("notDone", "reason", "r4", true)
        m2.RemoveOption("notDone", "orderType", "sro", true)
        T.Eq(m2.Flags("notDone").Length, 0, "the flag is gone when nothing is left of its condition")
        T.False(m2.Cat("notDone").Has("flags"), "and the empty flags list is dropped")
        TestAdminModel.Ok(m2, "valid")
        ; any
        m3 := TestAdminModel.Bare()
        s3 := TestAdminModel.Slot("when", "notDone", "contact")
        m3.SetCond(s3, Map("any", [Map("step", "reason", "in", ["r1"]), Map("step", "orderType", "in", ["tc", "pwo"])]))
        m3.RemoveOption("notDone", "orderType", "tc", true)
        T.Eq(ConfigJson.Canon(m3.GetCond(s3)), '{"any":[{"in":["r1"],"step":"reason"},{"in":["pwo"],"step":"orderType"}]}', "any: one option out")
        m3.RemoveOption("notDone", "reason", "r1", true)
        m3.RemoveOption("notDone", "orderType", "pwo", true)
        T.False(m3.Step("notDone", "contact").Has("when"), "any: everything removed -> the when is deleted")
        ; nested conditions are cleaned too
        m4 := TestAdminModel.Bare()
        s4 := TestAdminModel.Slot("when", "notDone", "contact")
        m4.SetCond(s4, Map("any", [Map("all", [Map("step", "reason", "in", ["r1"]), Map("step", "orderType", "in", ["pwo"])]), Map("step", "reason", "in", ["r2"])]))
        m4.RemoveOption("notDone", "reason", "r1", true)
        T.Eq(ConfigJson.Canon(m4.GetCond(s4)), '{"any":[{"all":[{"in":["pwo"],"step":"orderType"}]},{"in":["r2"],"step":"reason"}]}', "nested: the clause is removed from the inner all")
        m4.RemoveOption("notDone", "orderType", "pwo", true)
        T.Eq(ConfigJson.Canon(m4.GetCond(s4)), '{"any":[{"in":["r2"],"step":"reason"}]}', "nested: the empty inner all disappears from the any")
        ; a direct unit test of CondClean
        c := Map("step", "a", "in", ["x"])
        T.Eq(AdminModel.CondClean(c, "a", "x"), "", "leaf with its last option -> removed")
        c := Map("step", "a", "in", ["x", "y"])
        T.Eq(ConfigJson.Canon(AdminModel.CondClean(c, "a", "x")), '{"in":["y"],"step":"a"}', "leaf keeps the other option")
        c := Map("step", "a", "in", ["x"])
        T.Eq(ConfigJson.Canon(AdminModel.CondClean(c, "b", "x")), '{"in":["x"],"step":"a"}', "other step: untouched")
        c := Map("step", "a", "in", ["x"])
        T.Eq(AdminModel.CondClean(c, "a", ""), "", "whole step removed")
    }

    static CleanCondShapes() {
        ; removal of a step takes its clauses out of all/any shapes as well
        m := TestAdminModel.Bare()
        slot := TestAdminModel.Slot("flag", "notDone", "", "reason4Sro")
        m.SetCond(slot, Map("any", [Map("step", "reason", "in", ["r1"]), Map("step", "contact", "in", ["c1"])]))
        m.RemoveStep("notDone", "contact", true)
        T.Eq(ConfigJson.Canon(m.GetCond(slot)), '{"any":[{"in":["r1"],"step":"reason"}]}', "removing a step drops its clauses")
        TestAdminModel.Ok(m, "valid")
        ; placeholders in the stop message are not touched (not expanded by the app)
        m.Stop("notDone", "supervisorTc", "no")["message"] := "Call {reason}"
        T.Eq(m.FindReferences({Kind: "step", Cat: "notDone", Step: "reason"}).Length, 2, "the message isn't a fragment: only the flag and the keepSteps count")
    }

    ; --- flags ------------------------------------------------------------------------------------------------------
    static Flags() {
        m := TestAdminModel.Bare()
        r := m.AddFlag("notDone", "Check the schedule")
        T.True(r.Ok && r.Id = "checkTheSchedule", "add a flag")
        f := AdminModel.Find(m.Flags("notDone"), "checkTheSchedule")
        T.Eq(ConfigJson.Canon(f["when"]), '{"in":["r1"],"step":"reason"}', "its starting condition is the first option of the first step")
        TestAdminModel.Ok(m, "valid")
        T.True(m.SetFlagMessage("notDone", "checkTheSchedule", "New text").Ok, "message")
        T.Eq(AdminModel.Find(m.Flags("notDone"), "checkTheSchedule")["message"], "New text", "stored")
        T.True(m.MoveFlag("notDone", "checkTheSchedule", -1).Ok, "move")
        T.Eq(m.Flags("notDone")[1]["id"], "checkTheSchedule", "now first")
        T.False(m.AddFlag("notDone", " ").Ok, "empty message refused")
        T.False(m.AddFlag("billing", "x").Ok, "flags belong to steps categories")
        T.True(m.RemoveFlag("notDone", "reason4Sro").Ok, "remove")
        T.True(m.RemoveFlag("notDone", "checkTheSchedule").Ok, "remove the last one")
        T.False(m.Cat("notDone").Has("flags"), "the list key is dropped when empty")
        T.False(m.RemoveFlag("notDone", "x").Ok, "unknown flag")
        TestAdminModel.Ok(m, "valid without flags")
        r := m.AddFlag("notDone", "Again")
        T.True(r.Ok, "adding to a category without flags works")
    }

    ; --- condition builder -------------------------------------------------------------------------------------------
    static CondBuilder() {
        leaf := Map("step", "reason", "in", ["r1", "r2"])
        f := AdminModel.CondFlat(leaf)
        T.True(f.Simple && f.Mode = "all" && f.Clauses.Length = 1 && f.Clauses[1].Step = "reason" && f.Clauses[1].Ins.Length = 2, "flat: a leaf")
        f := AdminModel.CondFlat(Map("all", [leaf, Map("step", "orderType", "in", ["pwo"])]))
        T.True(f.Simple && f.Mode = "all" && f.Clauses.Length = 2, "flat: all of two")
        f := AdminModel.CondFlat(Map("any", [leaf, Map("step", "orderType", "in", ["pwo"])]))
        T.True(f.Simple && f.Mode = "any" && f.Clauses.Length = 2, "flat: any of two")
        f := AdminModel.CondFlat(Map("any", [Map("all", [leaf])]))
        T.False(f.Simple, "flat: nested is not simple")
        f := AdminModel.CondFlat(Map("all", [leaf, Map("any", [leaf, leaf])]))
        T.False(f.Simple, "flat: nested later in the list is not simple")
        T.False(AdminModel.CondFlat(Map("step", "x")).Simple, "flat: step without in is not simple")
        T.True(AdminModel.CondFlat("").Simple && AdminModel.CondFlat("").Clauses.Length = 0, "flat: no condition")
        ; round trip
        for c in [leaf, Map("all", [leaf, Map("step", "orderType", "in", ["pwo"])]), Map("any", [leaf, Map("step", "orderType", "in", ["pwo"])])]
            T.Eq(ConfigJson.Canon(AdminModel.FlatCond(AdminModel.CondFlat(c))), ConfigJson.Canon(c), "flat round trip: " ConfigJson.Canon(c))
        ; editing on a real slot
        m := TestAdminModel.Bare()
        slot := TestAdminModel.Slot("req", "notDone", "supervisorTc", "supervisorNameTc")
        T.Eq(m.CondText("notDone", m.GetCond(slot)), "Has the tech spoken with their supervisor? is Yes", "text of the starting condition")
        T.Eq(m.CondChoices(slot).Length, 5, "a requiredWhen may look at any step with options")
        T.True(m.CondEdit(slot, "add").Ok, "add a clause")
        c := m.GetCond(slot)
        T.Eq(ConfigJson.Canon(c), '{"all":[{"in":["yes"],"step":"supervisorTc"},{"in":["r1"],"step":"reason"}]}', "the new clause uses the first unused step")
        T.True(m.CondEdit(slot, "mode", "any").Ok, "any of")
        T.True(c.Has("any") || m.GetCond(slot).Has("any"), "mode is any")
        T.True(m.CondEdit(slot, "opt", 2, "r3").Ok, "tick another option")
        T.Eq(ConfigJson.Canon(m.GetCond(slot)), '{"any":[{"in":["yes"],"step":"supervisorTc"},{"in":["r1","r3"],"step":"reason"}]}', "options added in tick order")
        T.True(m.CondEdit(slot, "opt", 2, "r1").Ok, "untick one")
        T.Eq(ConfigJson.Canon(m.GetCond(slot)["any"][2]), '{"in":["r3"],"step":"reason"}', "r1 gone")
        T.True(m.CondEdit(slot, "step", 2, "outcome").Ok, "change the step of a clause")
        T.Eq(ConfigJson.Canon(m.GetCond(slot)["any"][2]), '{"in":["o1"],"step":"outcome"}', "the options reset to the new step's first option")
        T.True(m.CondEdit(slot, "del", 2).Ok, "delete a clause")
        T.Eq(ConfigJson.Canon(m.GetCond(slot)), '{"in":["yes"],"step":"supervisorTc"}', "one clause is a plain leaf")
        T.True(m.CondEdit(slot, "clear").Ok, "clear")
        T.False(m.Fields("notDone", "supervisorTc")[1].Has("requiredWhen"), "no condition for a requiredWhen = key removed")
        T.False(m.CondEdit(slot, "del", 3).Ok, "deleting a clause that isn't there")
        ; unticking the last option leaves an invalid condition that the validator reports
        m.CondEdit(slot, "add")
        m.CondEdit(slot, "opt", 1, "r1")
        v := m.Validate()
        T.False(v.Ok, "a clause with no option is an error")
        T.Contains(v.Items[1].Text, "Required when", "(the readable path)" )
        ; a `when` may only look at earlier steps
        w := TestAdminModel.Slot("when", "notDone", "supervisorTc")
        names := ""
        for s in m.CondChoices(w)
            names .= s["id"] ","
        T.Eq(names, "reason,orderType,", "when: only steps above, only steps with options")
        w1 := TestAdminModel.Slot("when", "notDone", "reason")
        T.Eq(m.CondChoices(w1).Length, 0, "the first step has nothing above it")
        r := m.CondEdit(w1, "add")
        T.False(r.Ok, "so no clause can be added to it")
        T.Contains(r.Error, "above", "the reason is explained")
        ; flags can't lose their condition
        fs := TestAdminModel.Slot("flag", "notDone", "", "reason4Sro")
        T.False(m.CondEdit(fs, "clear").Ok, "a flag can't be cleared")
        T.False(m.CondEdit(fs, "del", 1).Ok && m.CondEdit(fs, "del", 1).Ok, "nor emptied by deleting its clauses")
        T.False(m.SetCond(fs, "").Ok, "SetCond empty on a flag refused")
        ; a nested condition is refused by the clause editor
        n := TestAdminModel.Slot("when", "notDone", "contact")
        m.SetCond(n, Map("any", [Map("all", [Map("step", "reason", "in", ["r1"])])]))
        r := m.CondEdit(n, "add")
        T.False(r.Ok, "the builder refuses a nested condition")
        T.Contains(r.Error, "JSON", "and points to Edit as JSON")
        T.Contains(m.CondJson(n), "all", "the JSON view shows it")
        T.Eq(m.CondText("notDone", m.GetCond(n)), "(a nested condition)", "described as nested")
    }

    static CondJson() {
        m := TestAdminModel.Bare()
        n := TestAdminModel.Slot("when", "notDone", "contact")
        r := m.SetCondJson(n, "{not json")
        T.False(r.Ok, "invalid JSON is refused")
        T.Contains(r.Error, "JSON", "with a message")
        T.False(m.Step("notDone", "contact").Has("when"), "nothing changed")
        r := m.SetCondJson(n, '{"step":"nope","in":["a"]}')
        T.False(r.Ok, "unknown step refused")
        r := m.SetCondJson(n, '{"step":"outcome","in":["o1"]}')
        T.False(r.Ok, "a later step is refused for a when")
        T.Contains(r.Error, "before", "(explained)")
        r := m.SetCondJson(n, '{"step":"reason","in":[]}')
        T.False(r.Ok, "empty in refused")
        r := m.SetCondJson(n, '{"foo":1}')
        T.False(r.Ok, "unknown keys refused")
        r := m.SetCondJson(n, '{"any":[{"all":[{"step":"reason","in":["r1"]},{"step":"orderType","in":["pwo"]}]},{"step":"reason","in":["r2"]}]}')
        T.True(r.Ok, "a nested condition is accepted")
        T.False(AdminModel.CondFlat(m.GetCond(n)).Simple, "and is shown as complex")
        TestAdminModel.Ok(m, "valid")
        T.True(m.SetCondJson(n, "").Ok, "empty text removes the condition")
        T.False(m.Step("notDone", "contact").Has("when"), "removed")
        ; a flag may use a later step (flags look at any step)
        f := TestAdminModel.Slot("flag", "notDone", "", "reason4Sro")
        T.True(m.SetCondJson(f, '{"step":"outcome","in":["o1"]}').Ok, "flags may look at any step")
        T.False(m.SetCondJson(f, "").Ok, "but need a condition")
    }

    ; --- items ------------------------------------------------------------------------------------------------------
    static ItemsEditor() {
        m := TestAdminModel.Bare()
        r := m.AddListItem("equipment", "actions", "Replaced")
        T.True(r.Ok && r.Id = "replaced", "add an action")
        a := AdminModel.Find(m.List("equipment", "actions"), "replaced")
        T.Eq(a["fragment"], "{action} {qty} {item}. {details}", "it starts with the first action's fragment")
        r := m.AddListItem("equipment", "items", "Router")
        T.True(r.Ok && r.Id = "router", "add an item")
        T.False(AdminModel.Find(m.List("equipment", "items"), "router").Has("fragment"), "items have no fragment")
        r := m.AddListItem("billing", "outcomes", "Pending")
        T.True(r.Ok, "add an outcome")
        T.Eq(AdminModel.Find(m.List("billing", "outcomes"), "pending")["fragment"], "", "outcome fragment starts empty")
        T.False(m.AddListItem("equipment", "bogus", "x").Ok, "unknown list")
        T.False(m.AddListItem("notDone", "items", "x").Ok, "not an items category")
        T.False(m.AddListItem("equipment", "items", " ").Ok, "empty label")
        T.True(m.SetListItemProp("equipment", "actions", "replaced", "label", "Swapped out").Ok, "label")
        T.True(m.SetListItemProp("equipment", "actions", "replaced", "fragment", "{action} {item}.").Ok, "fragment")
        T.False(m.SetListItemProp("equipment", "items", "router", "fragment", "x").Ok, "no fragment on items")
        T.False(m.SetListItemProp("equipment", "items", "router", "id", "x").Ok, "no id edits")
        T.True(m.MoveListItem("equipment", "items", "router", -1).Ok, "move")
        T.Eq(m.List("equipment", "items")[5]["id"], "router", "moved up (it was 6th)")
        TestAdminModel.Ok(m, "valid")
        ; removing
        T.True(m.RemoveListItem("equipment", "items", "router").Ok, "remove an item")
        T.True(m.RemoveListItem("equipment", "actions", "replaced").Ok, "remove an action")
        T.True(m.RemoveListItem("equipment", "actions", "removed").Ok, "another")
        T.True(m.RemoveListItem("equipment", "actions", "swapped").Ok, "another")
        T.False(m.RemoveListItem("equipment", "actions", "added").Ok, "the last action is kept")
        T.Eq(m.List("equipment", "actions").Length, 1, "one left")
        for id in ["item2", "item3", "item4", "item5"]
            m.RemoveListItem("equipment", "items", id)
        T.False(m.RemoveListItem("equipment", "items", "item1").Ok, "the last item is kept")
        T.False(m.RemoveListItem("equipment", "items", "ghost").Ok, "unknown id")
        TestAdminModel.Ok(m, "valid")
        ; outcomes and outcomeRequired
        T.False(m.SetEntryFlag("equipment", "outcomeRequired", true).Ok, "outcome can't be required without outcomes")
        T.True(m.RemoveListItem("billing", "outcomes", "pending").Ok, "remove one")
        T.True(m.RemoveListItem("billing", "outcomes", "completed").Ok, "and another")
        r := m.RemoveListItem("billing", "outcomes", "requested")
        T.True(r.Ok, "(two left was fine, one left)")
        r := m.RemoveListItem("billing", "outcomes", "unable")
        T.False(r.Ok, "the last outcome can't go while an outcome is required")
        T.True(m.SetEntryFlag("billing", "outcomeRequired", false).Ok, "switch the requirement off")
        T.True(m.RemoveListItem("billing", "outcomes", "unable").Ok, "now it can go")
        T.Eq(m.List("billing", "outcomes").Length, 0, "no outcomes")
        T.True(m.SetEntryFlag("billing", "qty", true).Ok && m.SetEntryFlag("billing", "details", false).Ok, "qty and details switches")
        e := m.EntryOf("billing")
        T.Eq(e["qty"] "|" e["details"], "1|0", "stored as 1/0")
        T.False(m.SetEntryFlag("billing", "bogus", true).Ok, "unknown switch")
        TestAdminModel.Ok(m, "valid")
    }

    static StaticEditor() {
        m := TestAdminModel.Bare()
        T.True(m.SetStaticProp("static", "pingTargets", "gateway", "label", "Default gateway").Ok, "ping target label")
        T.True(m.SetStaticProp("static", "pingOutcomes", "reply", "label", "Got a reply").Ok, "outcome label")
        T.True(m.SetStaticProp("static", "pingOutcomes", "reply", "fragment", "Ping to {pingTarget} worked.").Ok, "outcome fragment")
        T.False(m.SetStaticProp("static", "pingTargets", "gateway", "fragment", "x").Ok, "targets have no fragment")
        T.False(m.SetStaticProp("static", "pingOutcomes", "reply", "id", "x").Ok, "ids are fixed")
        T.False(m.SetStaticProp("static", "pingOutcomes", "zzz", "label", "x").Ok, "no such outcome")
        T.False(m.SetStaticProp("equipment", "pingOutcomes", "reply", "label", "x").Ok, "not a static category")
        ids := ""
        for o in m.StaticOf("static")["pingOutcomes"]
            ids .= o["id"] ","
        T.Eq(ids, "reply,noReply,", "the fixed ids are unchanged")
        T.True(m.AddCategory("steps", "x").Ok && !m.HasOwnProp("AddPingOutcome"), "(no add/remove for the static lists exists)")
        TestAdminModel.Ok(m, "valid")
        m.SetStaticProp("static", "pingOutcomes", "reply", "fragment", "Ping {nope} worked.")
        v := m.Validate()
        T.True(v.Ok && v.Warnings.Length = 1, "an unknown placeholder is a warning")
        T.Contains(v.Items[1].Text, "Static", "with a readable path")
    }

    ; --- template ---------------------------------------------------------------------------------------------------
    static Template() {
        m := TestAdminModel.Bare()
        n0 := m.Tpl["lines"].Length
        T.True(m.AddTemplateLine("Callback: {tech.firstName}").Ok, "add a line")
        T.Eq(m.Tpl["lines"].Length, n0 + 1, "five lines")
        T.True(m.MoveTemplateLine(n0 + 1, -1).Ok, "move up")
        T.Eq(m.Tpl["lines"][n0], "Callback: {tech.firstName}", "it moved")
        T.False(m.MoveTemplateLine(1, -1).Ok, "first can't move up")
        T.True(m.SetTemplateLine(1, "Name: {tech.name}").Ok, "edit")
        T.Eq(m.Tpl["lines"][1], "Name: {tech.name}", "stored")
        T.False(m.SetTemplateLine(99, "x").Ok, "bad index")
        T.True(m.RemoveTemplateLine(n0).Ok, "remove")
        while m.Tpl["lines"].Length > 1
            m.RemoveTemplateLine(1)
        T.False(m.RemoveTemplateLine(1).Ok, "the last line is kept")
        T.True(m.SetTemplateProp("unavailableText", "n/a").Ok, "unavailable text")
        T.True(m.SetTemplateProp("fragmentJoiner", " | ").Ok, "joiner")
        T.True(m.SetTemplateProp("categoryJoiner", "`n`n").Ok, "category joiner")
        T.True(m.SetTemplateProp("sentenceCase", false).Ok, "sentence case off")
        T.True(m.SetTemplateProp("endPunctuation", "").Ok, "empty end punctuation is allowed")
        T.Eq(m.Tpl["sentenceCase"] "|" m.Tpl["fragmentJoiner"] "|" m.Tpl["endPunctuation"], "0| | |", "stored")
        T.False(m.SetTemplateProp("bogus", "x").Ok, "unknown setting")
        TestAdminModel.Ok(m, "valid")
        ; the preview follows the joiners
        pv := AdminPreview(m)
        pv.Choose("notDone", "reason", "r1")
        pv.Choose("notDone", "orderType", "sro")
        txt0 := pv.Compose().Text
        T.Contains(txt0, "Notes: Reason 1 placeholder note. | Order type SRO placeholder note.", "the fragment joiner shows in the preview")
    }

    ; --- themes, numbers -----------------------------------------------------------------------------------------
    static ThemesAndNumbers() {
        m := TestAdminModel.Bare()
        r := m.AddPreset("Night shift", "win365", "dark", "#112233")
        T.True(r.Ok && r.Id = "nightShift", "add a look")
        TestAdminModel.Ok(m, "valid")
        T.Eq(AdminModel.Find(m.Presets, "nightShift")["accent"], "#112233", "stored")
        for bad in ["blue", "#12345", "#1234567", "112233", "#GG0000", "", "#12 345"]
            T.False(m.AddPreset("Bad", "win365", "dark", bad).Ok, "accent refused: [" bad "]")
        T.False(m.AddPreset("Bad", "nonexistent", "dark", "#112233").Ok, "unknown look refused")
        T.False(m.AddPreset("Bad", "win365", "grey", "#112233").Ok, "mode refused")
        T.False(m.AddPreset("", "win365", "dark", "#112233").Ok, "empty label refused")
        T.True(m.AddPreset("Spec", "spectrum", "light", "#0099d8").Ok, "spectrum sheet accepted, lower-case accent")
        T.Eq(AdminModel.Find(m.Presets, "spec")["accent"], "#0099D8", "accent stored upper case")
        T.True(m.SetPresetProp("nightShift", "accent", "#abcdef").Ok, "change accent")
        T.Eq(AdminModel.Find(m.Presets, "nightShift")["accent"], "#ABCDEF", "upper case")
        T.False(m.SetPresetProp("nightShift", "accent", "nope").Ok, "invalid accent refused")
        T.Eq(AdminModel.Find(m.Presets, "nightShift")["accent"], "#ABCDEF", "and unchanged")
        T.True(m.SetPresetProp("nightShift", "mode", "light").Ok, "mode")
        T.False(m.SetPresetProp("nightShift", "mode", "x").Ok, "bad mode")
        T.True(m.SetPresetProp("nightShift", "sheet", "cyber").Ok, "sheet")
        T.False(m.SetPresetProp("nightShift", "sheet", "x").Ok, "bad sheet")
        T.True(m.SetPresetProp("nightShift", "label", "Late shift").Ok, "label")
        T.True(m.SetDefaultPreset("nightShift").Ok, "default look")
        T.False(m.SetDefaultPreset("ghost").Ok, "unknown default")
        T.False(m.RemovePreset("nightShift").Ok, "the default look can't be removed")
        T.True(m.SetDefaultPreset("spectrum-light").Ok, "back")
        T.True(m.RemovePreset("nightShift").Ok, "remove")
        TestAdminModel.Ok(m, "valid")
        while m.Presets.Length > 1
            m.RemovePreset(m.Presets[m.Presets.Length]["id"] = m.Work["themes"]["default"] ? m.Presets[1]["id"] : m.Presets[m.Presets.Length]["id"])
        T.False(m.RemovePreset(m.Presets[1]["id"]).Ok, "the last look is kept")
        ; numbers: bounds equal the validator's
        for path, b in AdminModel.BOUNDS {
            parts := StrSplit(path, ".")
            for v in [b[1] - 1, b[1], b[1] + 1, b[2] - 1, b[2], b[2] + 1] {
                m2 := TestAdminModel.Bare()
                m2.Work[parts[1]][parts[2]] := v
                inRange := (v >= b[1] && v <= b[2])
                T.Eq(m2.Validate().Ok ? 1 : 0, inRange ? 1 : 0, "validator agrees with the bound: " path " = " v)
                m3 := TestAdminModel.Bare()
                r := m3.SetNumber(path, v)
                T.Eq(r.Ok ? 1 : 0, inRange ? 1 : 0, "SetNumber agrees: " path " = " v)
                if !inRange
                    T.Eq(m3.GetNumber(path), Defaults.Config()[parts[1]][parts[2]], "refused value changes nothing: " path " " v)
            }
            for bad in ["", "abc", "1.5", "-1", "1e3", "99999999999999999999", " "]
                T.False(TestAdminModel.Bare().SetNumber(path, bad).Ok, "SetNumber refuses [" bad "] for " path)
        }
        T.False(TestAdminModel.Bare().SetNumber("ping.nope", 1).Ok, "unknown number")
        r := TestAdminModel.Bare().SetNumber("history.retentionDays", 91)
        T.True(r.Min = 1 && r.Max = 90, "the refusal carries the bounds")
        m4 := TestAdminModel.Bare()
        m4.SetNumber("history.retentionDays", " 30 ")
        T.Eq(m4.GetNumber("history.retentionDays"), 30, "spaces are trimmed")
        T.True(m4.GetNumber("history.retentionDays") is Integer, "stored as a number")
    }

    ; --- validation with readable paths --------------------------------------------------------------------------
    static ValidationPaths() {
        m := TestAdminModel.Bare()
        m.Step("notDone", "orderType")["options"].Push(Map("id", "pwo", "label", "Dup", "fragment", ""))
        v := m.Validate()
        T.False(v.Ok, "a duplicate id fails")
        it := v.Items[1]
        T.Eq(it.Level, "error", "level")
        T.Contains(it.Text, "Not Done > Order type", "readable path: category and step labels")
        T.Contains(it.Text, "duplicate id", "and the message")
        T.Eq(it.Nav.Page "|" it.Nav.Cat "|" it.Nav.Step, "edit|notDone|orderType", "navigation to the step")
        m := TestAdminModel.Bare()
        m.Work["categories"][2]["entry"]["actions"].Push(Map("id", "added", "label", "Dup", "fragment", ""))
        it := m.Validate().Items[1]
        T.Contains(it.Text, "Equipment > Entries > Actions", "items path (keys are named)")
        T.Eq(it.Nav.Page "|" it.Nav.Cat, "edit|equipment", "navigates to the category")
        m := TestAdminModel.Bare()
        m.Work["noteTemplate"]["lines"] := []
        it := m.Validate().Items[1]
        T.Eq(it.Nav.Page, "template", "template errors go to the template page")
        T.Contains(it.Text, "Note template", "named")
        m := TestAdminModel.Bare()
        m.Work["themes"]["presets"][1]["accent"] := "blue"
        it := m.Validate().Items[1]
        T.Eq(it.Nav.Page, "settings", "theme errors go to the settings page")
        T.Contains(it.Text, "Spectrum - light", "the preset is named")
        m := TestAdminModel.Bare()
        m.Work["ping"]["attempts"] := 99
        T.Eq(m.Validate().Items[1].Nav.Page, "settings", "ping errors go to settings")
        m := TestAdminModel.Bare()
        m.Work["categories"][1]["label"] := ""
        it := m.Validate().Items[1]
        T.Eq(it.Nav.Page "|" it.Nav.Cat, "categories|notDone", "a category-level error goes to the categories page")
        m := TestAdminModel.Bare()
        m.Work["categories"].RemoveAt(1)
        it := m.Validate().Items
        T.True(it.Length >= 1, "removing notDone gives errors")
        found := false
        for x in it
            if InStr(x.Raw, 'system category "notDone" is missing')
                found := true
        T.True(found, "the missing reason step is described")
        ; warnings are items too
        m := TestAdminModel.Bare()
        m.Step("notDone", "supervisorPwo")["when"]["in"].Push("zzz")
        v := m.Validate()
        T.True(v.Ok && v.Warnings.Length = 1, "an unknown option is a warning")
        T.Eq(v.Items[1].Level, "warning", "level warning")
        T.Contains(v.Items[1].Text, "Supervisor contact (PWO)", "readable")
        ; defaults: nothing at all
        v := TestAdminModel.Bare().Validate()
        T.True(v.Ok && v.Warnings.Length = 0 && v.Items.Length = 0, "defaults: no errors, no warnings")
        ; unparsable path
        it := TestAdminModel.Bare().Describe("error", "something odd without a path")
        T.Eq(it.Nav.Page, "check", "no path: stay on the check page")
    }

    ; --- OneDrive conflict copies ----------------------------------------------------------------------------------
    static ConflictCopies() {
        TestAdminModel.N += 1
        d := TestAdminModel.Root "\c" TestAdminModel.N
        DirCreate(d "\backups")
        bad := ["config (1).json", "config (12).json", "CONFIG (2).JSON", "config-DESKTOP-ABC123.json", "config-MYPC.json",
            "config-LAPTOP-X7.json", "config.old-MYPC.json", "config - Copy.json", "config conflicted copy.json",
            "config-backup.json", "config-20261010.json", "config-20261010-12000.json"]
        good := ["config.json", "config.default.json", "config.cache.json", "config-20261010-120000.json",
            "config-20261010-120000_02.json", "notes.json", "configuration.json", "settings.json", "config.lock", "config.json.tmp",
            "myconfig-copy.json"]
        for n in bad
            FileAppend("{}", d "\" n, "UTF-8-RAW")
        for n in good
            FileAppend("{}", d "\" n, "UTF-8-RAW")
        ; our own backups folder, even with conflict-looking names, is not scanned
        FileAppend("{}", d "\backups\config-20261010-120000.json", "UTF-8-RAW")
        FileAppend("{}", d "\backups\config (1).json", "UTF-8-RAW")
        DirCreate(d "\config-dir.json")                 ; a folder is not a file
        found := AdminModel.FindConflictCopies(d, "MYPC")
        got := Map()
        for n in found
            got[StrLower(n)] := true
        for n in bad
            T.True(got.Has(StrLower(n)), "flagged: " n)
        for n in good
            T.False(got.Has(StrLower(n)), "not flagged: " n)
        T.False(got.Has("config-dir.json"), "a folder is not flagged")
        T.Eq(found.Length, bad.Length, "exactly the bad ones")
        T.Eq(AdminModel.FindConflictCopies(d "\nope", "MYPC").Length, 0, "a missing folder gives an empty list")
        T.Eq(AdminModel.FindConflictCopies("", "MYPC").Length, 0, "an empty path gives an empty list")
        ; a machine name with regex characters doesn't break anything
        T.False(AdminModel.IsConflictName("config.json", "A(B"), "machine with brackets: config.json is fine")
        T.True(AdminModel.IsConflictName("config.x-A(B.json", "A(B"), "machine with brackets matches literally")
        ; model integration: scanned on load and rescanned on demand
        s := TestAdminModel.Setup()
        T.Eq(s.M.Conflicts.Length, 0, "no conflicts on a clean folder")
        FileAppend("{}", s.Shared "\config-DESKTOP-ZZ.json", "UTF-8-RAW")
        T.Eq(s.M.ScanConflicts().Length, 1, "found after a rescan")
        T.Eq(s.M.Conflicts[1], "config-DESKTOP-ZZ.json", "the name")
        T.True(FileExist(s.Shared "\config-DESKTOP-ZZ.json") != "", "never deleted")
        s.M.Load()
        T.Eq(s.M.Conflicts.Length, 1, "found on load too")
        r := s.M.Save()
        T.True(r.Ok, "the model's Save itself doesn't refuse (the window asks the admin)")
        T.True(FileExist(s.Shared "\config-DESKTOP-ZZ.json") != "", "and still not deleted after a save")
        T.True(FileExist(s.Shared "\backups") != "", "(the backups folder exists)")
        T.Eq(s.M.ScanConflicts().Length, 1, "our backups are not conflict copies")
    }

    ; --- import ------------------------------------------------------------------------------------------------------
    static Import() {
        m := TestAdminModel.Bare()
        r := m.ImportText("{not json")
        T.False(r.Ok, "invalid JSON refused")
        T.Contains(r.Error, "valid JSON", "says so")
        T.False(m.ImportText("").Ok, "empty file refused")
        r := m.ImportText("[1,2,3]")
        T.False(r.Ok, "a JSON array refused")
        T.Contains(r.Error, "object", "says it isn't an object")
        T.False(m.ImportText('"hello"').Ok, "a string refused")
        ; too new
        newer := Defaults.Config()
        newer["schemaVersion"] := 99
        r := m.ImportText(ConfigJson.Stringify(newer))
        T.False(r.Ok, "a too-new file is refused")
        T.Contains(r.Error, "newer", "and says why")
        ; old schema: migrated, validated
        old := Map("historyDays", 21)
        r := m.ImportText(ConfigJson.Stringify(old))
        T.True(r.Ok, "an old-schema file is migrated and accepted")
        T.True(r.Summary.Migrated, "the summary says it was migrated")
        T.Eq(r.Summary.From "|" r.Summary.To, "0|1", "from v0 to v1")
        T.Eq(r.Cfg["history"]["retentionDays"], 21, "its value is carried over")
        T.Eq(r.Summary.Categories.Length, 5, "five categories in the summary")
        ; invalid content: summary has the errors, Ok is false
        bad := Defaults.Config()
        bad["themes"]["presets"][1]["accent"] := "blue"
        r := m.ImportText(ConfigJson.Stringify(bad))
        T.False(r.Ok, "a file with validation errors is refused")
        T.True(r.Summary.Errors.Length >= 1, "but the summary lists them")
        T.Contains(r.Error, "accent", "and the error names the problem")
        ; FillMissing: an older config without newer sections still imports
        partial := Defaults.Config()
        partial["categories"][4]["static"].Delete("pingTargets")
        r := m.ImportText(ConfigJson.Stringify(partial))
        T.True(r.Ok, "a config missing a section a later version added is filled and accepted")
        ; valid current file
        good := Defaults.Config()
        good["revision"] := 7
        good["categories"][1]["label"] := "Not Done (imported)"
        r := m.ImportText(ConfigJson.Stringify(good))
        T.True(r.Ok, "a valid file is accepted")
        T.Eq(r.Summary.Revision, 7, "the summary shows its revision")
        T.False(r.Summary.Migrated, "not migrated")
        ; ApplyConfig keeps the store's revision and replaces the working copy
        s := TestAdminModel.Setup(3)
        r := s.M.ImportText(ConfigJson.Stringify(good))
        s.M.ApplyConfig(r.Cfg)
        T.Eq(s.M.Work["revision"], 3, "the revision stays the one we loaded")
        T.Eq(s.M.Cat("notDone")["label"], "Not Done (imported)", "the working copy is replaced")
        T.True(s.M.Dirty, "and it is not saved yet")
        T.Eq(ConfigJson.Parse(FileRead(s.Shared "\config.json", "UTF-8"))["categories"][1]["label"], "Not Done", "the file on disk is untouched")
        r := s.M.Save()
        T.True(r.Ok && r.Revision = 4, "saving it works against revision 3 -> 4")
    }

    static RawRoundTrip() {
        m := TestAdminModel.Bare()
        txt := m.RawText()
        T.Contains(txt, '"categories"', "the raw text is the config")
        T.Contains(txt, "`n", "pretty printed")
        s := TestAdminModel.Setup()
        before := ConfigJson.Canon(s.M.Work)
        r := s.M.ApplyRaw(s.M.RawText())
        T.True(r.Ok, "the raw text applies")
        T.Eq(ConfigJson.Canon(s.M.Work), before, "a round trip changes nothing")
        T.False(s.M.Dirty, "so it is not dirty")
        edited := StrReplace(s.M.RawText(), '"label": "Not Done"', '"label": "Not Done (raw)"')
        r := s.M.ApplyRaw(edited)
        T.True(r.Ok, "an edited text applies")
        T.Eq(s.M.Cat("notDone")["label"], "Not Done (raw)", "and shows")
        T.True(s.M.Dirty, "dirty")
        keep := ConfigJson.Canon(s.M.Work)
        r := s.M.ApplyRaw("{ broken")
        T.False(r.Ok, "broken JSON is refused")
        T.Eq(ConfigJson.Canon(s.M.Work), keep, "the working copy is untouched")
        bad := Defaults.Config()
        bad["ping"]["attempts"] := 500
        r := s.M.ApplyRaw(ConfigJson.Stringify(bad))
        T.False(r.Ok, "valid JSON that fails validation is refused")
        T.Eq(ConfigJson.Canon(s.M.Work), keep, "also untouched")
        ; booleans are written as true/false
        T.Contains(txt, '"enabled": true', "booleans are true/false in the text")
        ; the raw text of a model with an edit parses back to the same canonical form
        m.SetCatProp("notDone", "label", "Changed")
        t2 := m.RawText()
        T.Eq(ConfigJson.Canon(ConfigJson.Parse(t2)), ConfigJson.Canon(m.Work), "the text parses back to the working copy")
    }

    ; --- saving through ConfigStore ------------------------------------------------------------------------------
    static SaveBasics() {
        s := TestAdminModel.Setup()
        m := s.M
        T.Eq(m.Store.Source, "shared", "loaded from the shared folder")
        T.False(m.Dirty, "clean after load")
        T.True(m.SetCatProp("notDone", "label", "Not Done (edited)").Ok, "edit a label")
        T.True(m.Dirty, "dirty")
        r := m.Save()
        T.True(r.Ok, "save")
        T.Eq(r.Kind "|" r.Revision, "ok|1", "revision 1")
        T.False(m.Dirty, "clean after save")
        T.Eq(m.Work["revision"], 1, "the working copy has the new revision")
        T.Eq(m.Work["updatedBy"], "alice", "updatedBy is the saving user")
        on := ConfigJson.Parse(FileRead(s.Shared "\config.json", "UTF-8"))
        T.Eq(on["revision"] "|" on["categories"][1]["label"], "1|Not Done (edited)", "the file on disk")
        T.Eq(TestAdminModel.Count(s.Shared "\backups\config-*.json"), 1, "one backup was written")
        T.False(FileExist(s.Shared "\config.lock") != "", "the lock was released")
        T.False(FileExist(s.Shared "\config.json.tmp") != "", "no tmp left")
        ; the main app's store loads it as "shared r1"
        main := ConfigStore({SharedDir: s.Shared, CacheDir: s.Dir "\maincache", User: "agent", Machine: "PC-Z"}).Load()
        T.Eq(main.Source "|" main.Revision, "shared|1", "the main app loads shared r1")
        T.Eq(main.ChipText(), "config: shared r1", "chip text")
        T.Eq(main.Config["categories"][1]["label"], "Not Done (edited)", "with the edit")
        T.Eq(main.Warnings.Length, 0, "no warnings")
        ; a second save bumps again
        m.SetCatProp("notDone", "label", "Not Done 2")
        r := m.Save()
        T.Eq(r.Revision, 2, "revision 2")
        T.Eq(TestAdminModel.Count(s.Shared "\backups\config-*.json"), 2, "two backups")
        ; the main app notices the newer revision at the next call boundary
        T.True(main.CheckForUpdate(), "the main app sees an update")
        T.True(main.ApplyPending() && main.Revision = 2, "and applies it")
        ; saving without changes still works (bumps)
        r := m.Save()
        T.True(r.Ok && r.Revision = 3, "saving an unchanged copy bumps the revision")
    }

    static SaveRefusals() {
        ; invalid: errors block the save, the file is untouched
        s := TestAdminModel.Setup()
        m := s.M
        raw0 := FileRead(s.Shared "\config.json", "UTF-8-RAW")
        m.Work["themes"]["presets"][1]["accent"] := "blue"
        r := m.Save()
        T.False(r.Ok, "an invalid config is not saved")
        T.Eq(r.Kind, "invalid", "kind invalid")
        T.True(r.Errors.Length >= 1 && r.Items.Length >= 1, "with the errors listed")
        T.True(FileRead(s.Shared "\config.json", "UTF-8-RAW") == raw0, "the file is unchanged")
        T.Eq(TestAdminModel.Count(s.Shared "\backups\*.json"), 0, "no backup either")
        ; foreign lock
        s := TestAdminModel.Setup()
        m := s.M
        m.SetCatProp("notDone", "label", "X")
        Util.AtomicWrite(s.Shared "\config.lock", ConfigJson.Stringify(Map("user", "bob", "machine", "PC-B", "time", Util.IsoNow())))
        r := m.Save()
        T.False(r.Ok, "a foreign lock refuses the save")
        T.Eq(r.Kind "|" r.Holder "|" r.Machine, "locked|bob|PC-B", "the holder is named")
        msg := m.SaveMessage(r)
        T.Contains(msg.Text, "bob on PC-B", "the dialog names the holder")
        T.Contains(msg.Text, r.Since, "and the time")
        T.True(FileExist(s.Shared "\config.lock") != "", "the foreign lock is left alone")
        T.True(m.Dirty, "the edits are kept")
        T.Eq(ConfigJson.Parse(FileRead(s.Shared "\config.json", "UTF-8"))["revision"], 0, "nothing was written")
        ; stale lock is taken over
        Util.AtomicWrite(s.Shared "\config.lock", ConfigJson.Stringify(Map("user", "bob", "machine", "PC-B", "time", "2020-01-01T00:00:00")))
        r := m.Save()
        T.True(r.Ok, "a stale lock (older than 30 minutes) is taken over")
        ; another writer bumped the revision
        s := TestAdminModel.Setup()
        m := s.M
        other := ConfigStore({SharedDir: s.Shared, CacheDir: s.Dir "\othercache", User: "carol", Machine: "PC-C"}).Load()
        oc := Util.Clone(other.Config)
        oc["categories"][1]["label"] := "Carol's label"
        T.True(other.Save(oc).Ok, "(setup) carol saved r1")
        m.SetCatProp("notDone", "label", "Alice's label")
        r := m.Save()
        T.False(r.Ok, "saving over a newer revision is refused")
        T.Eq(r.Kind "|" r.By "|" r.Rev, "conflict|carol|1", "names who and which revision")
        msg := m.SaveMessage(r)
        T.Contains(msg.Text, "carol", "the dialog names the writer")
        T.Contains(msg.Text, "unsaved edits will be lost", "and the cost of reloading")
        T.True(m.Dirty, "edits kept")
        m.Load()
        T.Eq(m.Cat("notDone")["label"], "Carol's label", "Reload picks up the newer version")
        T.Eq(m.Store.Revision, 1, "revision 1")
        T.False(m.Dirty, "and is clean")
        m.SetCatProp("notDone", "label", "Alice again")
        T.True(m.Save().Ok, "now alice can save (r2)")
        ; folder not reachable
        s := TestAdminModel.Setup()
        m := s.M
        m.SetCatProp("notDone", "label", "X")
        DirDelete(s.Shared, true)
        r := m.Save()
        T.False(r.Ok, "an unreachable folder")
        T.Eq(r.Kind, "unreachable", "kind unreachable")
        T.Contains(m.SaveMessage(r).Text, "not reachable", "dialog text")
        T.True(m.Dirty, "edits kept")
        ; injected failure inside the store: original stays, kind failed
        s := TestAdminModel.Setup()
        m := s.M
        raw0 := FileRead(s.Shared "\config.json", "UTF-8-RAW")
        m.SetCatProp("notDone", "label", "X")
        s.Store.FailAt := "afterTmp"
        r := m.Save()
        T.False(r.Ok, "an interrupted save fails")
        T.Eq(r.Kind, "failed", "kind failed")
        T.True(FileRead(s.Shared "\config.json", "UTF-8-RAW") == raw0, "the original is untouched")
        T.False(FileExist(s.Shared "\config.lock") != "", "the lock is released")
        T.True(m.Dirty, "edits kept")
        s.Store.FailAt := ""
        T.True(m.Save().Ok, "and a retry works")
    }

    static Classify() {
        m := TestAdminModel.Bare()
        r := m.Classify("Config is locked by bob on PC-B since 2026-10-10T12:00:00. Try again later.")
        T.Eq(r.Kind "|" r.Holder "|" r.Machine "|" r.Since, "locked|bob|PC-B|2026-10-10T12:00:00", "locked with machine")
        r := m.Classify("Config is locked by bob since 2026-10-10T12:00:00. Try again later.")
        T.Eq(r.Kind "|" r.Holder "|" r.Machine "|" r.Since, "locked|bob||2026-10-10T12:00:00", "locked without machine")
        r := m.Classify("Config was changed by carol at 2026-10-10T12:00:00 (r5; you have r4). Reload first.")
        T.Eq(r.Kind "|" r.By "|" r.At "|" r.Rev, "conflict|carol|2026-10-10T12:00:00|5", "changed by")
        T.Eq(m.Classify("The shared config folder is not reachable.").Kind, "unreachable", "unreachable")
        T.Eq(m.Classify("No shared config folder is set.").Kind, "unreachable", "no folder")
        T.Eq(m.Classify("Save failed, the existing config was not changed (Verification of the temporary file failed)").Kind, "verify", "verification")
        T.Eq(m.Classify("Save failed, the existing config was not changed (disk full)").Kind, "failed", "other failure")
        T.Eq(m.Classify("Config is not valid: x").Kind, "invalid", "invalid")
        T.Contains(m.SaveMessage(m.Classify("Save failed, the existing config was not changed (Verification of the temporary file failed)")).Text, "did not read back", "verify dialog")
        T.Contains(m.SaveMessage(m.Classify("Save failed (disk full)")).Text, "disk full", "unknown failures show the message")
    }

    static RestoreDefaults() {
        s := TestAdminModel.Setup(5)
        m := s.M
        m.SetCatProp("notDone", "label", "Changed")
        m.RemoveCategory("billing")
        r := m.RestoreDefaults()
        T.True(r.Ok, "restore defaults")
        T.Eq(m.Work["revision"], 5, "the current revision number is kept")
        d := Defaults.Config()
        d["revision"] := 5
        d["updatedAt"] := m.Work["updatedAt"], d["updatedBy"] := m.Work["updatedBy"]
        T.Eq(ConfigJson.Canon(m.Work), ConfigJson.Canon(d), "everything else is the built-in default")
        TestAdminModel.Ok(m, "valid")
        T.False(m.Dirty, "restoring the defaults over a saved default config leaves nothing to save")
        ; restoring defaults on an unedited default config isn't dirty; on top of an edited saved config it is
        s2 := TestAdminModel.Setup(2)
        s2.M.RestoreDefaults()
        T.False(s2.M.Dirty, "defaults over the same defaults: nothing to save")
        s2.M.SetCatProp("notDone", "label", "Custom")
        s2.M.Save()
        s2.M.RestoreDefaults()
        T.True(s2.M.Dirty, "defaults over an edited saved config: dirty")
        r := s2.M.Save()
        T.True(r.Ok && r.Revision = 4, "and saving works against the store's revision (3 -> 4)")
        T.Eq(ConfigJson.Parse(FileRead(s2.Shared "\config.json", "UTF-8"))["categories"][1]["label"], "Not Done", "the default label is on disk")
    }

    static DirtyTracking() {
        s := TestAdminModel.Setup()
        m := s.M
        T.False(m.Dirty, "clean after load")
        m.SetCatProp("notDone", "label", "Other")
        T.True(m.Dirty, "dirty after an edit")
        m.SetCatProp("notDone", "label", "Not Done")
        T.False(m.Dirty, "editing back to the original is clean again")
        m.SetStepProp("notDone", "reason", "required", false)
        T.True(m.Dirty, "a boolean edit")
        m.Load()
        T.False(m.Dirty, "reload drops the edits")
        T.Eq(m.Cat("notDone")["steps"][1]["required"], 1, "back to the saved value")
        n := 0
        m.OnChanged((mm, what) => (n += 1))
        m.SetCatProp("notDone", "label", "Q")
        T.True(n >= 1, "subscribers hear about changes")
        st := m.Status()
        T.Eq(st.Source "|" st.Revision "|" st.UpdatedBy, "shared|0|built-in", "status line values")
        T.True(st.Dir = s.Shared, "and the folder")
    }

    ; --- preview -----------------------------------------------------------------------------------------------------
    static PreviewBasics() {
        m := TestAdminModel.Bare()
        pv := AdminPreview(m)
        T.Eq(pv.Ctx.Value("techName") "|" pv.Ctx.Value("techId") "|" pv.Ctx.Value("jobNumber") "|" pv.Ctx.Value("workOrder") "|" pv.Ctx.Value("address"),
            "Sample Tech|T00000|00000|WO-0000|1 Sample St", "the sample call")
        T.Eq(pv.Ctx.Status("techName"), "mock", "marked as mock data")
        res := pv.Compose()
        T.Eq(res.Text, "Tech name: Sample`r`nTech ID: T00000`r`nJob Number: 00000`r`nNotes:", "nothing chosen: only the template")
        T.Eq(res.Warnings.Length, 0, "no warnings")
        pv.SetUnavailable(true)
        T.Contains(pv.Compose().Text, "Tech name: [not available]", "unavailable fields print the configured text")
        pv.SetUnavailable(false)
        T.Contains(pv.Compose().Text, "Tech name: Sample", "and back")
        ; steps
        T.True(pv.Choose("notDone", "reason", "r2"), "choose an option")
        T.Contains(pv.Compose().Text, "Notes: Reason 2 placeholder note.", "the note follows")
        pv.Choose("notDone", "orderType", "pwo")
        pv.Type("notDone", "supervisorPwo", "supervisorName", "Pat")
        pv.Type("notDone", "supervisorPwo", "rescheduleReason", "Moved")
        T.Contains(pv.Compose().Text, "Supervisor Pat placeholder note. Reschedule reason Moved placeholder note.", "typed fields fill the placeholders")
        ; an edit shows at once, answers stay
        m.SetOptionProp("notDone", "reason", "r2", "fragment", "Edited fragment text.")
        T.Contains(pv.Compose().Text, "Notes: Edited fragment text.", "an edited fragment shows without choosing again")
        ; a new option
        r := m.AddOption("notDone", "reason", "Brand new")
        m.SetOptionProp("notDone", "reason", r.Id, "fragment", "Brand new reason.")
        pv.Choose("notDone", "reason", r.Id)
        T.Contains(pv.Compose().Text, "Brand new reason.", "an option added in the editor can be chosen in the preview")
        ; unknown placeholder -> composer warning
        m.SetOptionProp("notDone", "reason", r.Id, "fragment", "See {nope}.")
        res := pv.Compose()
        found := false
        for w in res.Warnings
            if InStr(w, "Unknown placeholder {nope}")
                found := true
        T.True(found, "unknown placeholders are reported as composer warnings")
        T.Contains(res.Text, "See {nope}.", "and stay in the text as in the app")
        ; removing the chosen option: the answer is ignored with a note, no crash
        m.RemoveOption("notDone", "reason", r.Id)
        res := pv.Compose()
        T.NotContains(res.Text, "Brand new", "a removed option no longer shows")
        T.True(res.Extra.Length >= 1, "the engine's unknown-option note is available")
        ; a stop
        pv.Choose("notDone", "orderType", "tc")
        pv.Choose("notDone", "supervisorTc", "no")
        T.Contains(pv.Compose().Text, "Tech has not contacted supervisor", "the stop note")
        a := pv.Analyse("notDone")
        T.True(a.A.Stop.Stopped, "the engine reports the stop")
        ; items
        r := pv.AddSampleEntry("equipment")
        T.True(r.Ok, "a sample entry")
        T.Contains(pv.Compose().Text, "Added 1 Item 1 (placeholder). Sample details.", "the equipment line")
        r := pv.AddSampleEntry("equipment")
        T.True(r.Ok, "a second sample entry is a different one")
        T.Contains(pv.Compose().Text, "Removed 2 Item 2 (placeholder). Sample details.", "the second line")
        pv.AddSampleEntry("billing")
        T.Contains(pv.Compose().Text, "Added Item 1 (placeholder) Sample details - completed.", "billing with its outcome")
        pv.ClearEntries("equipment")
        T.NotContains(pv.Compose().Text, "Item 2 (placeholder). Sample", "entries cleared")
        ; static
        T.True(pv.PickPing("static", "reply", "gateway"), "pick a ping outcome")
        T.Contains(pv.Compose().Text, "Ping to Gateway 10.0.0.2: reply received (placeholder wording).", "the ping line")
        pv.PickPing("static", "")
        T.NotContains(pv.Compose().Text, "Ping to", "cleared")
        ; a disabled category is dropped
        m.SetCatProp("billing", "enabled", false)
        T.NotContains(pv.Compose().Text, "Item 1 (placeholder) Sample details - completed.", "a disabled category is left out of the preview")
        T.Eq(pv.Categories().Length, 4, "and not offered")
        m.SetCatProp("billing", "enabled", true)
        ; a category removed in the editor
        m.RemoveCategory("closeJob")
        T.Eq(pv.Compose().Warnings.Length, 0, "no warnings about a removed category")
        pv.Clear()
        T.Eq(pv.Compose().Text, "Tech name: Sample`r`nTech ID: T00000`r`nJob Number: 00000`r`nNotes:", "Clear forgets the sample answers")
    }

    ; The preview must give the text the main app gives for the same answers.
    static PreviewEqualsMainApp() {
        cfg := Defaults.Config()
        cfg["categories"][1]["steps"][1]["options"][2]["fragment"] := "Edited {tech.firstName} said {reason}."
        cfg["noteTemplate"]["categoryJoiner"] := " // "
        cfg["noteTemplate"]["lines"].Push("Address: {address}")
        pv := AdminPreview()
        pv.Cfg := cfg
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSAdminCmpLog_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: cfg}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        for id, v in AdminPreview.SAMPLE
            c.Set(id, v, "mock", "mock")
        app.Session.BeginCall(c)
        steps := [["notDone", "reason", "r2"], ["notDone", "orderType", "pwo"], ["notDone", "contact", "c3"], ["notDone", "outcome", "o1"],
            ["closeJob", "closeChoice", "k2"], ["closeJob", "closeFollowUp", "yes"]]
        for st in steps {
            pv.Choose(st[1], st[2], st[3])
            app.SetOption(st[1], st[2], st[3])
        }
        for f in [["notDone", "supervisorPwo", "supervisorName", "Pat"], ["notDone", "supervisorPwo", "rescheduleReason", "Moved {x}"],
                  ["notDone", "contact", "contactDetails", "left a message"], ["closeJob", "closeText", "closeNote", "all good"]] {
            pv.Type(f[1], f[2], f[3], f[4])
            app.SetField(f[1], f[2], f[3], f[4])
        }
        e := {action: "swapped", item: "item2", qty: "2", outcome: "", details: "Needs cable {a}"}
        pv.Session.AddEntry("equipment", e, pv.ItemsModel("equipment"))
        pv.Session.UseCategory("equipment")
        app.AddEntry("equipment", e)
        e2 := {action: "added", item: "item3", qty: "", outcome: "unable", details: ""}
        pv.Session.AddEntry("billing", e2, pv.ItemsModel("billing"))
        pv.Session.UseCategory("billing")
        app.AddEntry("billing", e2)
        pv.PickPing("static", "noReply", "ip")
        app.StaticSet("static", {ipText: "10.0.0.1/30", pingTarget: "ip", pingOutcome: "noReply"})
        mine := pv.Compose().Text
        theirs := Composer.Compose(app.Session.Context, app.Session, cfg).Text
        T.True(mine == theirs, "the preview composes exactly the main app's note")
        T.Contains(mine, "Edited Sample said Reason 2 (placeholder).", "(the edited fragment with placeholders is in it)")
        T.Contains(mine, " // ", "(and the category joiner)")
        T.Contains(mine, "Needs cable {a}", "(and braces typed by the agent stay)")
        ; unavailable context too
        pv.SetUnavailable(true)
        c2 := CallContext()
        for id, v in AdminPreview.SAMPLE
            c2.Set(id, "", "unavailable", "mock")
        app.Session.Context := c2
        T.True(pv.Compose().Text == Composer.Compose(c2, app.Session, cfg).Text, "same with unavailable fields")
        try FileDelete(app.Logger.Path)
    }

    static Chips() {
        m := TestAdminModel.Bare()
        txt := ""
        for c in m.Chips("steps", "notDone")
            txt .= c.Text " "
        T.Contains(txt, "{reason}", "step ids with options")
        T.Contains(txt, "{supervisorName}", "field ids")
        T.Contains(txt, "{tech.firstName}", "context placeholders")
        T.NotContains(txt, "{supervisorPwo}", "a group step has no option label to insert")
        T.NotContains(txt, "{notes}", "{notes} is for the template only")
        txt := ""
        for c in m.Chips("template")
            txt .= c.Text " "
        T.Contains(txt, "{notes}", "template: {notes}")
        T.Contains(txt, "{job.number}", "template: job number")
        txt := ""
        for c in m.Chips("items")
            txt .= c.Text " "
        T.Contains(txt, "{qty}", "items: qty")
        T.Contains(txt, "{outcome}", "items: outcome")
        txt := ""
        for c in m.Chips("ping")
            txt .= c.Text " "
        T.Contains(txt, "{pingAddress}", "ping: address")
        ; every chip is a placeholder the composer / models know (no warnings when used)
        m2 := TestAdminModel.Bare()
        all := ""
        for c in m2.Chips("template")
            all .= c.Text " "
        m2.SetTemplateLine(1, all)
        pv := AdminPreview(m2)
        T.Eq(pv.Compose().Warnings.Length, 0, "all template chips are known to the composer")
    }

    static StopEditing() {
        m := TestAdminModel.Bare()
        T.True(m.SetStopEnabled("notDone", "reason", "r1", true).Ok, "stop on an option")
        st := m.Stop("notDone", "reason", "r1")
        T.True(st is Map && st["message"] != "", "it starts with a message")
        T.False(m.SetStopKeep("notDone", "reason", "r1", "reason", true).Ok, "a first step has no earlier step to keep")
        T.True(m.SetStopProp("notDone", "reason", "r1", "message", "Hold on").Ok, "message")
        T.True(m.SetStopProp("notDone", "reason", "r1", "fragment", "Stopped.").Ok, "fragment")
        T.True(m.SetStopEnabled("notDone", "contact", "c1", true).Ok, "a stop on a later step")
        T.True(m.SetStopKeep("notDone", "contact", "c1", "orderType", true).Ok, "keep an earlier step")
        T.True(m.SetStopKeep("notDone", "contact", "c1", "reason", true).Ok, "and another")
        T.Eq(ConfigJson.Canon(m.Stop("notDone", "contact", "c1")["keepSteps"]), '["reason","orderType"]', "kept in step order")
        T.False(m.SetStopKeep("notDone", "contact", "c1", "outcome", true).Ok, "a later step can't be kept")
        T.False(m.SetStopKeep("notDone", "contact", "c1", "contact", true).Ok, "nor the step itself")
        T.True(m.SetStopKeep("notDone", "contact", "c1", "orderType", false).Ok, "untick")
        T.Eq(ConfigJson.Canon(m.Stop("notDone", "contact", "c1")["keepSteps"]), '["reason"]', "removed")
        TestAdminModel.Ok(m, "valid")
        T.True(m.SetStopEnabled("notDone", "contact", "c1", false).Ok, "switch the stop off")
        T.False(m.Stop("notDone", "contact", "c1") is Map, "it is gone")
        T.False(m.SetStopProp("notDone", "contact", "c1", "message", "x").Ok, "no stop to edit")
        T.False(m.SetStopEnabled("notDone", "contact", "zzz", true).Ok, "unknown option")
    }

    static TypeChange() {
        m := TestAdminModel.Bare()
        ; choice -> yesno keeps nothing that isn't yes/no and reports references
        m.AddStep("closeJob", "Extra", "choice")
        m.SetCond(TestAdminModel.Slot("when", "closeJob", "closeFollowUp"), Map("step", "closeChoice", "in", ["k1"]))
        r := m.ChangeStepType("closeJob", "closeChoice", "text")
        T.True(!r.Ok && r.NeedConfirm, "changing a referenced choice to text asks first")
        r := m.ChangeStepType("closeJob", "closeChoice", "text", true)
        T.True(r.Ok, "with clean it goes through")
        T.False(m.Step("closeJob", "closeFollowUp").Has("when"), "the reference was cleaned")
        s := m.Step("closeJob", "closeChoice")
        T.True(!s.Has("options") && s["fields"].Length = 1, "text: no options, one field")
        TestAdminModel.Ok(m, "valid")
        T.True(m.ChangeStepType("closeJob", "closeChoice", "choice").Ok, "back to choice")
        T.Eq(m.Options("closeJob", "closeChoice").Length, 1, "with a starter option")
        T.True(m.ChangeStepType("closeJob", "closeChoice", "yesno").Ok, "to yesno")
        T.Eq(m.Options("closeJob", "closeChoice")[1]["id"] "|" m.Options("closeJob", "closeChoice")[2]["id"], "yes|no", "yes and no")
        TestAdminModel.Ok(m, "valid")
        T.True(m.ChangeStepType("closeJob", "closeChoice", "group").Ok, "to group")
        TestAdminModel.Ok(m, "valid")
        T.True(m.ChangeStepType("closeJob", "closeChoice", "group").Ok, "same type: no-op")
        T.False(m.ChangeStepType("closeJob", "closeChoice", "bogus").Ok, "unknown type")
    }
}
