#Requires AutoHotkey v2.0
; TestItems.ahk - the items model (Equipment, Billing), the entries inside CallSession (add / update / remove / move,
; snapshots, old snapshots), the composed notes (including the combined Not Done + Equipment + Billing note) and the
; App wiring without a window. Headless.

class TestItems {
    static Name := "Items"

    static Run() {
        for name in ["Defaults", "BillingMatrix", "BillingCompleted", "EquipmentCombos", "QtyValidation", "ValidateParts", "OutcomeRequired",
                "Duplicates", "UnknownIds", "JunkInput", "LiteralBraces", "ContextPlaceholders", "OrderKept", "UpdateRemoveMove", "OptionsOff",
                "SessionBasics", "SnapshotShape", "RoundTrip", "OldSnapshot", "HistoryEmpty", "CombinedNote", "CustomCategory", "AppWiring",
                "PreviewAndDescribe", "NoteEdgeCases"]
            T.Case(name, ObjBindMethod(TestItems, name))
    }

    ; --- helpers ----------------------------------------------------------------------------------------------
    static Cat(id) {
        for c in Defaults.Config()["categories"]
            if (c["id"] = id)
                return c
    }

    static Model(id) => ItemsModel(TestItems.Cat(id))

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

    static E(action, item, qty := "", outcome := "", details := "") => {action: action, item: item, qty: qty, outcome: outcome, details: details}

    static Note(s, cfg := "") {
        if !IsObject(cfg)
            cfg := Defaults.Config()
        return Composer.Compose(s.Context, s, cfg).Text
    }

    ; the text after "Notes: " (all categories, CRLF between them)
    static Tail(text) => SubStr(text, InStr(text, "Notes: ") + 7)

    ; a session whose one items category holds these entries
    static With(catId, entries) {
        s := TestItems.Make()
        m := TestItems.Model(catId)
        s.UseCategory(catId)
        for e in entries
            s.AddEntry(catId, e, m)
        return s
    }

    static Keys(m) {
        a := []
        for k, v in m
            a.Push(k)
        out := ""
        for k in a
            out .= (out = "" ? "" : ",") k
        return out
    }

    ; --- defaults ---------------------------------------------------------------------------------------------
    static Defaults() {
        for id in ["equipment", "billing"] {
            c := TestItems.Cat(id)
            e := c["entry"]
            T.Eq(e["items"].Length, 5, id ": five placeholder items")
            for it in e["items"] {
                T.Contains(it["label"], "(placeholder)", id " item " it["id"] " is marked placeholder")
                T.False(it.Has("fragment"), id " item " it["id"] " has no fragment")
            }
            T.True(e.Has("outcomeRequired") && e.Has("qty") && e.Has("details") && e.Has("outcomes"), id ": all entry keys present")
            T.True(Schema.Validate(Defaults.Config()).Ok, "defaults validate")
        }
        eq := TestItems.Cat("equipment")["entry"]
        T.Eq(eq["outcomes"].Length, 0, "equipment has no outcomes")
        T.True(eq["qty"] = 1 && eq["details"] = 1 && eq["outcomeRequired"] = 0, "equipment: qty on, details on, outcome not required")
        bl := TestItems.Cat("billing")["entry"]
        T.True(bl["qty"] = 0 && bl["details"] = 1 && bl["outcomeRequired"] = 1, "billing: qty off, details on, outcome required")
        ids := ""
        for o in bl["outcomes"]
            ids .= o["id"] "=" o["label"] "|" o["fragment"] ";"
        T.Eq(ids, "completed=Completed|- completed.;requested=Requested " Chr(0x2014) " not yet completed|- requested, not yet completed.;unable=Unable to complete|- unable to complete.;",
            "billing outcomes: ids, labels and fragments")
        n := 0
        for o in bl["outcomes"]
            if InStr(o["fragment"], "completed")
                n += 1
        T.Eq(n, 2, "only two outcome fragments contain the word (Completed, and 'not yet completed')")
        for a in bl["actions"]
            T.False(InStr(a["fragment"], "complete"), "billing action " a["id"] " never says completed")
        T.Eq(TestItems.Keys(Map("a", 1)), "a", "helper")
    }

    ; --- billing: every action x outcome, exact fragments and notes -------------------------------------------
    static BillingMatrix() {
        m := TestItems.Model("billing")
        actions := Map("added", "Added", "removed", "Removed", "changed", "Changed")
        outcomes := Map("completed", ["Completed", "- completed."], "requested", ["Requested", "- requested, not yet completed."],
            "unable", ["Unable", "- unable to complete."])
        n := 0
        for aid, alabel in actions
            for oid, o in outcomes {
                e := TestItems.E(aid, "item1", "", oid)
                r := m.Fragments([e])
                T.Eq(r.Fragments.Length, 1, aid "/" oid ": one fragment")
                T.Eq(r.Fragments[1], alabel "  Item 1 (placeholder)  " o[2], aid "/" oid ": exact raw fragment (empty qty and details leave only spaces)")
                T.Eq(r.Values.Count, 0, aid "/" oid ": nothing to hold back")
                T.Eq(r.Warnings.Length, 0, aid "/" oid ": no warnings")
                s := TestItems.With("billing", [e])
                T.Eq(TestItems.Tail(TestItems.Note(s)), alabel " Item 1 (placeholder) " o[2], aid "/" oid ": exact note")
                T.Eq(m.Preview(e), alabel " Item 1 (placeholder) " o[2], aid "/" oid ": exact preview")
                n += 1
            }
        T.Eq(n, 9, "nine combinations")
    }

    ; "completed" is a claim only for the Completed outcome - scanned over every rendered billing note
    static BillingCompleted() {
        m := TestItems.Model("billing")
        bad := 0, claims := 0, total := 0
        for aid in ["added", "removed", "changed"]
            for iid in ["item1", "item2", "item3", "item4", "item5"]
                for oid in ["completed", "requested", "unable"]
                    for det in ["", "Customer asked", "Needs follow up."] {
                        s := TestItems.With("billing", [TestItems.E(aid, iid, "", oid, det)])
                        txt := TestItems.Tail(TestItems.Note(s))
                        total += 1
                        stripped := StrReplace(StrReplace(txt, "not yet completed", ""), "unable to complete", "")
                        has := InStr(stripped, "completed") > 0
                        if (oid = "completed") {
                            claims += has ? 1 : 0
                            if !has
                                bad += 1
                        } else if has
                            bad += 1
                    }
        T.Eq(total, 135, "135 billing notes scanned")
        T.Eq(claims, 45, "the word is a claim in exactly the 45 Completed notes")
        T.Eq(bad, 0, "and in none of the others")
        ; without an outcome (an old entry, the config changed) the note makes no claim either
        r := m.Fragments([TestItems.E("added", "item1")])
        T.Eq(r.Fragments.Length, 1, "no outcome: still one fragment")
        T.False(InStr(r.Fragments[1], "complete"), "and it says nothing about completion")
        T.Eq(r.Warnings.Length, 1, "with a warning")
        T.NotContains(r.Warnings[1], "Item", "warning holds no call content")
        ; the user's wording in details is not an outcome
        s := TestItems.With("billing", [TestItems.E("added", "item1", "", "unable", "was completed earlier")])
        T.Contains(TestItems.Note(s), "unable to complete", "typed details do not change the outcome text")
    }

    ; --- equipment: actions with and without qty and details --------------------------------------------------
    static EquipmentCombos() {
        m := TestItems.Model("equipment")
        n := 0
        for aid, alabel in Map("added", "Added", "removed", "Removed", "swapped", "Swapped") {
            T.Eq(m.Fragments([TestItems.E(aid, "item1")]).Fragments[1], alabel "  Item 1 (placeholder). ", aid ": raw fragment, no qty no details")
            T.Eq(m.Fragments([TestItems.E(aid, "item1", "2", "", "Needs cable")]).Fragments[1], alabel " 2 Item 1 (placeholder). Needs cable", aid ": raw fragment with both")
            cases := Map(
                "", alabel " Item 1 (placeholder).",
                "q", alabel " 2 Item 1 (placeholder).",
                "d", alabel " Item 1 (placeholder). Needs cable.",
                "qd", alabel " 2 Item 1 (placeholder). Needs cable.")
            for k, want in cases {
                q := InStr(k, "q") ? "2" : ""
                d := InStr(k, "d") ? "Needs cable" : ""
                s := TestItems.With("equipment", [TestItems.E(aid, "item1", q, "", d)])
                T.Eq(TestItems.Tail(TestItems.Note(s)), want, aid " [" k "]: exact note")
                T.Eq(m.Preview(TestItems.E(aid, "item1", q, "", d)), want, aid " [" k "]: exact preview")
                n += 1
            }
        }
        T.Eq(n, 12, "twelve combinations")
        ; the PLAN 3.5 shape
        T.Eq(TestItems.Tail(TestItems.Note(TestItems.With("equipment", [TestItems.E("swapped", "item1")]))), "Swapped Item 1 (placeholder).", "Swapped + Item 1 reads like PLAN 3.5")
        ; nothing is invented: no digits, serials or models appear unless typed
        txt := TestItems.Tail(TestItems.Note(TestItems.With("equipment", [TestItems.E("added", "item3")])))
        T.False(RegExMatch(txt, "\d") && !RegExMatch(txt, "^Added Item 3 \(placeholder\)\.$"), "no invented numbers")
        ; details already ending in a full stop do not get a second one; a question mark stays
        T.Eq(TestItems.Tail(TestItems.Note(TestItems.With("equipment", [TestItems.E("added", "item1", "", "", "Ok.")]))), "Added Item 1 (placeholder). Ok.", "details with a stop")
        T.Eq(TestItems.Tail(TestItems.Note(TestItems.With("equipment", [TestItems.E("added", "item1", "", "", "Ok?")]))), "Added Item 1 (placeholder). Ok?", "details with a question mark")
        ; blanks around typed text are trimmed, and spaces inside collapse
        T.Eq(TestItems.Tail(TestItems.Note(TestItems.With("equipment", [TestItems.E("added", "item1", " 3 ", "", "  two   spaces  ")]))), "Added 3 Item 1 (placeholder). two spaces.", "trim and squeeze")
    }

    static QtyValidation() {
        m := TestItems.Model("equipment")
        for q in ["0", "100", "abc", "2.5", "-1", "+2", "1e1", "1 2", "999", "00", "0.0", "٣"]
            T.False(m.Validate(TestItems.E("added", "item1", q)).Ok, "qty [" q "] is refused")
        for q in ["", " ", "1", "99", "01", "007", "42", " 5 "]
            T.True(m.Validate(TestItems.E("added", "item1", q)).Ok, "qty [" q "] is accepted")
        v := m.Validate(TestItems.E("added", "item1", "abc"))
        T.Eq(v.Missing.Length "|" v.Missing[1].field "|" v.Missing[1].reason, "1|qty|invalid", "the bad field is named")
        T.Contains(v.Missing[1].label, "1-99", "label says the range")
        T.Eq(m.Clean(TestItems.E("added", "item1", "007")).qty, "7", "leading zeros are dropped")
        T.Eq(m.Clean(TestItems.E("added", "item1", " 05 ")).qty, "5", "blanks too")
        T.Eq(m.Clean(TestItems.E("added", "item1", "abc")).qty, "abc", "a bad qty is kept as typed (and refused), not corrected")
        T.True(ItemsModel.QtyOk("1") && ItemsModel.QtyOk("99") && !ItemsModel.QtyOk("100") && !ItemsModel.QtyOk(""), "QtyOk")
        s := TestItems.Make()
        r := s.AddEntry("equipment", TestItems.E("added", "item1", "100"), m)
        T.False(r.Ok, "the session refuses it")
        T.Eq(s.EntriesFor("equipment").Length, 0, "nothing stored")
        T.Contains(r.Error, "Quantity", "error names the quantity")
        T.False(s.Fragments("equipment").Length > 0, "no fragment")
    }

    static ValidateParts() {
        m := TestItems.Model("equipment")
        v := m.Validate(TestItems.E("", ""))
        T.Eq(v.Ok ? 1 : 0 "|" v.Missing.Length, "0|2", "nothing chosen: action and item")
        T.Eq(ItemsModel.MissingText(v), "Action, Item", "MissingText")
        v := m.Validate(TestItems.E("added", ""))
        T.Eq(v.Missing.Length "|" v.Missing[1].field, "1|item", "item missing")
        v := m.Validate(TestItems.E("", "item1"))
        T.Eq(v.Missing.Length "|" v.Missing[1].field, "1|action", "action missing")
        v := m.Validate(TestItems.E("nope", "item1"))
        T.Eq(v.Missing[1].field "|" v.Missing[1].reason, "action|unknown", "unknown action id is invalid")
        v := m.Validate(TestItems.E("added", "ghost"))
        T.Eq(v.Missing[1].field "|" v.Missing[1].reason, "item|unknown", "unknown item id is invalid")
        v := m.Validate(TestItems.E("added", "item1", "", "completed"))
        T.Eq(v.Missing[1].field "|" v.Missing[1].reason, "outcome|unknown", "an outcome the category does not have is invalid")
        T.True(m.Validate(TestItems.E("added", "item1")).Ok, "action and item are enough for Equipment")
        T.True(m.Validate(Map("action", "added", "item", "item1")).Ok, "a Map entry works")
        T.True(m.Validate("junk").Missing.Length = 2, "junk input does not throw")
        T.True(m.Validate("").Missing.Length = 2, "empty input")
        T.Eq(m.Validate(TestItems.E(" added ", " item1 ")).Ok ? 1 : 0, 1, "ids are trimmed")
    }

    static OutcomeRequired() {
        m := TestItems.Model("billing")
        v := m.Validate(TestItems.E("added", "item1"))
        T.Eq(v.Ok ? 1 : 0 "|" v.Missing[1].field "|" v.Missing[1].reason, "0|outcome|missing", "Billing needs an outcome")
        T.True(m.Validate(TestItems.E("added", "item1", "", "completed")).Ok, "with an outcome it is valid")
        T.False(m.Validate(TestItems.E("added", "item1", "", "bogus")).Ok, "unknown outcome")
        v := m.Validate(TestItems.E("", "", "", ""))
        T.Eq(ItemsModel.MissingText(v), "Action, Item, Outcome", "all three listed")
        ; the same category with outcomeRequired off: the outcome is optional
        c := TestItems.Cat("billing")
        c["entry"]["outcomeRequired"] := false
        m2 := ItemsModel(c)
        T.True(m2.Validate(TestItems.E("added", "item1")).Ok, "outcome optional when not required")
        r := m2.Fragments([TestItems.E("added", "item1")])
        T.Eq(r.Warnings.Length, 0, "and no warning")
        T.Eq(r.Fragments[1], "Added  Item 1 (placeholder) ", "the note then says nothing about an outcome")
        s := TestItems.Make()
        s.UseCategory("billing")
        res := s.AddEntry("billing", TestItems.E("added", "item1"), m)
        T.False(res.Ok, "the session refuses an entry without outcome")
        T.Eq(res.Missing[1].field, "outcome", "naming the outcome")
        T.Eq(s.Fragments("billing").Length, 0, "no fragment, so no 'completed'")
    }

    ; --- duplicates -------------------------------------------------------------------------------------------
    static Duplicates() {
        m := TestItems.Model("equipment")
        s := TestItems.Make()
        s.UseCategory("equipment")
        T.True(s.AddEntry("equipment", TestItems.E("swapped", "item1"), m).Ok, "first")
        r := s.AddEntry("equipment", TestItems.E("swapped", "item1"), m)
        T.False(r.Ok, "identical entry refused")
        T.Eq(r.Error, "That entry is already in the list " Chr(0x2014) " change the quantity instead", "exact message")
        T.Eq(r.Error, ItemsModel.DupMessage(), "same as the constant")
        T.True(r.HasOwnProp("Duplicate") && r.Duplicate, "flagged as a duplicate")
        T.Eq(s.EntriesFor("equipment").Length, 1, "still one entry")
        T.Eq(s.Fragments("equipment").Length, 1, "still one fragment")
        T.False(s.AddEntry("equipment", TestItems.E(" swapped ", "item1", "", "", "  "), m).Ok, "blanks do not make it different")
        T.True(s.AddEntry("equipment", TestItems.E("swapped", "item1", "2"), m).Ok, "a different quantity is a different entry")
        T.False(s.AddEntry("equipment", TestItems.E("swapped", "item1", "02"), m).Ok, "02 is the same quantity as 2")
        T.True(s.AddEntry("equipment", TestItems.E("swapped", "item1", "", "", "Left a note"), m).Ok, "different details are a different entry")
        T.False(s.AddEntry("equipment", TestItems.E("swapped", "item1", "", "", "left a NOTE"), m).Ok, "details that differ only in case print the same (the composer would drop one)")
        T.False(s.AddEntry("equipment", TestItems.E("swapped", "item1", "", "", "Left   a note."), m).Ok, "spacing and a final stop do not matter either")
        T.True(s.AddEntry("equipment", TestItems.E("added", "item1"), m).Ok, "another action")
        T.True(s.AddEntry("equipment", TestItems.E("swapped", "item2"), m).Ok, "another item")
        T.Eq(s.EntriesFor("equipment").Length, 5, "five entries")
        ; the note: every entry prints once
        txt := TestItems.Tail(TestItems.Note(s))
        T.Eq(txt, "Swapped Item 1 (placeholder). Swapped 2 Item 1 (placeholder). Swapped Item 1 (placeholder). Left a note. Added Item 1 (placeholder). Swapped Item 2 (placeholder).",
            "all five sentences are in the note")
        ; update: the entry is not a duplicate of itself, but of another one
        T.True(s.UpdateEntry("equipment", 1, TestItems.E("swapped", "item1"), m).Ok, "saving an entry unchanged is fine")
        r := s.UpdateEntry("equipment", 5, TestItems.E("added", "item1"), m)
        T.False(r.Ok, "changing an entry into another one is refused")
        T.True(r.Duplicate, "as a duplicate")
        T.Eq(s.EntriesFor("equipment")[5].item, "item2", "the entry is unchanged")
        T.Eq(m.FindDuplicate(s.EntriesFor("equipment"), TestItems.E("swapped", "item2")), 5, "FindDuplicate gives the index")
        T.Eq(m.FindDuplicate(s.EntriesFor("equipment"), TestItems.E("swapped", "item2"), 5), 0, "...unless it is skipped")
        T.Eq(m.FindDuplicate(s.EntriesFor("equipment"), TestItems.E("removed", "item2")), 0, "no duplicate")
        T.Eq(m.FindDuplicate("not a list", TestItems.E("removed", "item2")), 0, "junk list")
        ; Billing: qty is not used there, so a different qty is the same sentence -> refused (it would print once)
        mb := TestItems.Model("billing")
        sb := TestItems.Make()
        sb.UseCategory("billing")
        T.True(sb.AddEntry("billing", TestItems.E("added", "item1", "", "completed"), mb).Ok, "billing first")
        T.False(sb.AddEntry("billing", TestItems.E("added", "item1", "4", "completed"), mb).Ok, "qty is ignored in billing: same sentence, refused")
        T.True(sb.AddEntry("billing", TestItems.E("added", "item1", "", "unable"), mb).Ok, "another outcome is another entry")
        ; every refused add leaves the session untouched
        cnt := {n: 0}
        sb.OnChanged((*) => cnt.n += 1)
        sb.AddEntry("billing", TestItems.E("added", "item1", "", "completed"), mb)
        sb.AddEntry("billing", TestItems.E("", ""), mb)
        T.Eq(cnt.n, 0, "refused adds notify nobody")
    }

    ; --- unknown ids ------------------------------------------------------------------------------------------
    static UnknownIds() {
        m := TestItems.Model("equipment")
        list := [TestItems.E("swapped", "item1"), TestItems.E("zzz", "item1"), TestItems.E("added", "gone"), TestItems.E("added", "item2", "", "x"),
            TestItems.E("removed", "item3")]
        r := m.Fragments(list)
        T.Eq(r.Fragments.Length, 2, "only the two known entries produce fragments")
        T.Eq(r.Fragments[1], "Swapped  Item 1 (placeholder). ", "first kept")
        T.Eq(r.Fragments[2], "Removed  Item 3 (placeholder). ", "last kept, order preserved")
        T.Eq(r.Warnings.Length, 3, "three warnings")
        T.Eq(r.Warnings[1], 'Entry 2 skipped: unknown action "zzz".', "warning names position and id")
        T.Eq(r.Warnings[2], 'Entry 3 skipped: unknown item "gone".', "item")
        T.Eq(r.Warnings[3], 'Entry 4 skipped: unknown outcome "x".', "outcome")
        ; missing action / item in a stored entry
        r := m.Fragments([TestItems.E("", "item1"), TestItems.E("added", "")])
        T.Eq(r.Fragments.Length "|" r.Warnings.Length, "0|2", "no action / no item: skipped with a warning")
        ; a stored bad qty is left out, never corrected
        r := m.Fragments([TestItems.E("added", "item1", "abc")])
        T.Eq(r.Fragments.Length "|" r.Warnings.Length, "1|1", "bad qty: fragment without it, plus a warning")
        T.Eq(r.Fragments[1], "Added  Item 1 (placeholder). ", "no qty in the text")
        ; through a session: restore a call whose ids the config no longer has
        s := TestItems.Make()
        s.UseCategory("equipment")
        snap := Map("context", Map(), "categoriesUsed", ["equipment"], "categories", Map("equipment", Map("fragments", ["kept as saved"], "values", Map(),
            "entries", [Map("action", "swapped", "item", "old-item", "qty", "", "outcome", "", "details", "")])), "noteText", "", "generatedText", "", "agentEdited", 0)
        T.True(s.Restore(snap), "restores")
        T.Eq(s.Fragments("equipment")[1], "kept as saved", "stored fragments are kept as saved")
        r := s.ApplyEntries("equipment", m)
        T.Eq(r.Fragments.Length "|" r.Warnings.Length, "0|1", "re-running the model skips the unknown entry")
        T.Eq(s.Fragments("equipment").Length, 0, "and replaces the fragments")
        T.Eq(s.EntriesFor("equipment").Length, 1, "the entry itself is kept (the agent can still remove it)")
        T.Eq(m.Describe(s.EntriesFor("equipment")[1]), "", "Describe is empty for it")
        T.True(s.RemoveEntry("equipment", 1, m), "and removed")
    }

    static JunkInput() {
        m := TestItems.Model("equipment")
        T.Eq(m.Fragments("not a list").Fragments.Length, 0, "a string instead of a list")
        T.Eq(m.Fragments("").Fragments.Length, 0, "empty")
        r := m.Fragments([5, "s", Map(), Map("action", "added", "item", "item1"), {action: "removed", item: "item2"}])
        T.Eq(r.Fragments.Length, 2, "junk entries are skipped, Map and object entries work")
        T.Eq(r.Warnings.Length, 6, "an entry with neither action nor item is reported for both")
        bad := ItemsModel("not a category")
        T.Eq(bad.Actions.Length, 0, "a model of junk is empty")
        T.Eq(bad.Fragments([TestItems.E("added", "item1")]).Fragments.Length, 0, "and produces nothing")
        T.False(bad.Validate(TestItems.E("added", "item1")).Ok, "and validates nothing")
        c := Map("entry", Map("actions", [Map("id", "a", "label", "A"), 5, Map("id", "a", "label", "dup")], "items", "oops", "qty", Map()))
        m2 := ItemsModel(c)
        T.Eq(m2.Actions.Length "|" m2.Items.Length, "1|0", "bad lists are tolerated")
        T.False(m2.Qty, "junk flag is false")
        ses := CallSession()
        T.False(ses.UpdateEntry("equipment", 3, TestItems.E("added", "item1"), m).Ok, "update of a missing index")
        T.False(ses.RemoveEntry("equipment", 1, m), "remove of a missing index")
        T.False(ses.RemoveEntry("equipment", "x", m), "remove with a bad index")
        T.False(ses.MoveEntry("equipment", 1, 2, m), "move on an empty list")
    }

    ; what the agent typed is inserted literally
    static LiteralBraces() {
        m := TestItems.Model("equipment")
        det := "see {x} and {tech.id} and {notes} and {details} {"
        r := m.Fragments([TestItems.E("added", "item1", "", "", det)])
        T.NotContains(r.Fragments[1], "{x}", "the fragment does not carry the typed braces")
        T.Contains(r.Fragments[1], "{itemsDetails1}", "it carries a private placeholder instead")
        T.Eq(r.Values["itemsDetails1"], det, "the text sits in Values, unchanged")
        T.Eq(r.Values.Count, 1, "only that value")
        s := TestItems.Make()
        s.UseCategory("equipment")
        T.True(s.AddEntry("equipment", TestItems.E("added", "item1", "", "", det), m).Ok, "added through the session")
        res := Composer.Compose(s.Context, s, Defaults.Config())
        T.Eq(TestItems.Tail(res.Text), "Added Item 1 (placeholder). see {x} and {tech.id} and {notes} and {details} {.", "the note shows the braces as typed")
        T.Eq(res.Warnings.Length, 0, "and the composer found nothing unknown")
        T.NotContains(res.Text, "T12345" "}", "the tech id was not pulled in")
        T.Eq(StrSplit(res.Text, "T12345").Length, 2, "T12345 appears once (the template line only)")
        ; a second entry gets its own placeholder
        s.AddEntry("equipment", TestItems.E("removed", "item2", "", "", "{y}"), m)
        res := Composer.Compose(s.Context, s, Defaults.Config())
        T.Contains(res.Text, "Removed Item 2 (placeholder). {y}.", "second entry literal too")
        T.Eq(s.ValuesFor("equipment").Count, 2, "two private values")
        T.Eq(res.Warnings.Length, 0, "still no warnings")
        ; typed text with no brace is inserted directly (no private values)
        r := m.Fragments([TestItems.E("added", "item1", "", "", "plain")])
        T.Eq(r.Values.Count, 0, "plain text needs no value")
        T.Eq(r.Fragments[1], "Added  Item 1 (placeholder). plain", "inserted directly")
        ; the preview shows it as typed too
        T.Eq(m.Preview(TestItems.E("added", "item1", "", "", "{z}")), "Added Item 1 (placeholder). {z}.", "preview")
        ; the five names inside typed text are not replaced a second time
        r := m.Fragments([TestItems.E("added", "item1", "", "", "{item}")])
        T.Eq(r.Values["itemsDetails1"], "{item}", "{item} typed in details stays {item}")
    }

    ; context placeholders in the fragments are left for the composer
    static ContextPlaceholders() {
        c := TestItems.Cat("equipment")
        c["entry"]["actions"][1]["fragment"] := "{tech.firstName} {action} {item} {qty} for job {job.number}"
        m := ItemsModel(c)
        r := m.Fragments([TestItems.E("added", "item1", "2")])
        T.Eq(r.Fragments[1], "{tech.firstName} Added Item 1 (placeholder) 2 for job {job.number}", "tech and job placeholders untouched")
        cfg := Defaults.Config()
        cfg["categories"][2] := c
        s := TestItems.Make()
        s.UseCategory("equipment")
        s.AddEntry("equipment", TestItems.E("added", "item1", "2"), m)
        T.Eq(TestItems.Tail(TestItems.Note(s, cfg)), "Jordan Added Item 1 (placeholder) 2 for job 88412.", "the composer fills them")
        ; an unknown placeholder stays and is reported by the composer, not by the model
        c["entry"]["actions"][1]["fragment"] := "{action} {nope}"
        m := ItemsModel(c)
        r := m.Fragments([TestItems.E("added", "item1")])
        T.Eq(r.Fragments[1], "Added {nope}", "unknown placeholder kept")
        T.Eq(r.Warnings.Length, 0, "the model does not warn about it")
    }

    static OrderKept() {
        m := TestItems.Model("equipment")
        s := TestItems.Make()
        s.UseCategory("equipment")
        for e in [TestItems.E("removed", "item5"), TestItems.E("added", "item2"), TestItems.E("swapped", "item4"), TestItems.E("added", "item1")]
            s.AddEntry("equipment", e, m)
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Removed Item 5 (placeholder). Added Item 2 (placeholder). Swapped Item 4 (placeholder). Added Item 1 (placeholder).",
            "the note follows the order of the list")
        ids := ""
        for e in s.EntriesFor("equipment")
            ids .= e.item ","
        T.Eq(ids, "item5,item2,item4,item1,", "entries keep their order")
        T.Eq(s.Fragments("equipment").Length, 4, "four fragments")
    }

    static UpdateRemoveMove() {
        m := TestItems.Model("equipment")
        s := TestItems.With("equipment", [TestItems.E("added", "item1"), TestItems.E("removed", "item2"), TestItems.E("swapped", "item3")])
        cnt := {n: 0}
        s.OnChanged((*) => cnt.n += 1)
        r := s.UpdateEntry("equipment", 2, TestItems.E("removed", "item2", "4", "", "gone"), m)
        T.True(r.Ok && r.Index = 2, "update")
        T.Eq(cnt.n, 1, "one notification")
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Added Item 1 (placeholder). Removed 4 Item 2 (placeholder). gone. Swapped Item 3 (placeholder).", "the note shows the update, in place")
        T.Eq(s.Fragments("equipment").Length, 3, "fragments REPLACED, not appended")
        cnt.n := 0
        T.True(s.UpdateEntry("equipment", 2, TestItems.E("removed", "item2", "4", "", "gone"), m).Ok, "saving the same thing")
        T.Eq(cnt.n, 0, "changes nothing and notifies nobody")
        T.False(s.UpdateEntry("equipment", 2, TestItems.E("removed", "item2", "400"), m).Ok, "an invalid update is refused")
        T.Eq(s.EntriesFor("equipment")[2].qty, "4", "and the entry is as it was")
        T.False(s.UpdateEntry("equipment", 0, TestItems.E("removed", "item2"), m).Ok, "index 0")
        T.False(s.UpdateEntry("equipment", 4, TestItems.E("removed", "item2"), m).Ok, "index past the end")
        ; remove
        T.True(s.RemoveEntry("equipment", 1, m), "remove the first")
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Removed 4 Item 2 (placeholder). gone. Swapped Item 3 (placeholder).", "the others keep their order")
        T.False(s.RemoveEntry("equipment", 3, m), "past the end")
        T.False(s.RemoveEntry("equipment", 0, m), "index 0")
        T.True(s.IsUsed("equipment"), "the category stays used")
        ; move
        T.True(s.MoveEntry("equipment", 2, 1, m), "move up")
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Swapped Item 3 (placeholder). Removed 4 Item 2 (placeholder). gone.", "order changed")
        T.False(s.MoveEntry("equipment", 1, 1, m), "same place")
        T.False(s.MoveEntry("equipment", 1, 3, m), "out of range")
        T.False(s.MoveEntry("equipment", 0, 1, m), "index 0")
        T.True(s.MoveEntry("equipment", 1, 2, m), "move down")
        T.Eq(s.EntriesFor("equipment")[1].item, "item2", "back to the first order")
        ; remove the last one: fragments and values go
        s.RemoveEntry("equipment", 1, m)
        s.RemoveEntry("equipment", 1, m)
        T.Eq(s.Fragments("equipment").Length, 0, "no fragments left")
        T.Eq(s.ValuesFor("equipment").Count, 0, "no values left")
        T.False(s.HasEntries("equipment"), "no entries")
        T.False(s.HasStructured() && !s.IsUsed("equipment"), "(used only)")
        ; reset forgets the entries
        s2 := TestItems.With("equipment", [TestItems.E("added", "item1")])
        s2.ResetCategory("equipment")
        T.Eq(s2.EntriesFor("equipment").Length "|" s2.Fragments("equipment").Length, "0|0", "reset clears entries and fragments")
        T.True(s2.IsUsed("equipment"), "but the category stays used")
        s3 := TestItems.With("equipment", [TestItems.E("added", "item1")])
        s3.Reset()
        T.Eq(s3.Entries.Count, 0, "Reset() forgets all entries")
    }

    ; a category without qty / details ignores them
    static OptionsOff() {
        c := TestItems.Cat("equipment")
        c["entry"]["qty"] := false
        c["entry"]["details"] := false
        m := ItemsModel(c)
        e := m.Clean(TestItems.E("added", "item1", "3", "", "typed"))
        T.Eq(e.qty "|" e.details, "|", "qty and details are emptied")
        r := m.Fragments([TestItems.E("added", "item1", "3", "", "typed")])
        T.Eq(r.Fragments[1], "Added  Item 1 (placeholder). ", "and never reach the note")
        T.True(m.Validate(TestItems.E("added", "item1", "abc")).Ok, "a qty that is not used is not validated")
        m2 := TestItems.Model("billing")
        T.Eq(m2.Preview(TestItems.E("changed", "item2", "9", "unable")), "Changed Item 2 (placeholder) - unable to complete.", "billing never prints a qty")
        T.Eq(m2.Clean(TestItems.E("changed", "item2", "9", "unable")).qty, "", "billing entries are stored without qty")
    }

    ; --- session ----------------------------------------------------------------------------------------------
    static SessionBasics() {
        m := TestItems.Model("equipment")
        s := TestItems.Make()
        T.False(s.HasStructured(), "empty call")
        cnt := {n: 0}
        s.OnChanged((*) => cnt.n += 1)
        r := s.AddEntry("equipment", TestItems.E("swapped", "item1"), m)
        T.True(r.Ok && r.Index = 1 && r.Error = "" && r.Missing.Length = 0, "add result")
        T.Eq(cnt.n, 1, "one notification per change")
        T.True(s.HasStructured(), "entries are content")
        T.True(s.HasContent(), "so Clear All has something to save")
        T.False(s.IsUsed("equipment"), "the session alone does not mark a category used (App.AddEntry does)")
        T.Eq(s.Fragments("equipment").Length, 1, "fragments follow the entries")
        e := s.EntriesFor("equipment")[1]
        T.Eq(e.action "|" e.item "|" e.qty "|" e.outcome "|" e.details, "swapped|item1|||", "stored as plain strings")
        r := s.AddEntry("equipment", TestItems.E("", ""), m)
        T.False(r.Ok, "an incomplete entry is refused")
        T.Eq(r.Error, "Missing or invalid: Action, Item.", "with a message")
        T.Eq(r.Missing.Length, 2, "and the list of what is missing")
        ; without a model the entry is stored as given (tests / tools)
        s2 := CallSession()
        T.True(s2.AddEntry("billing", TestItems.E("a", "b", "", "c")).Ok, "no model: no checks")
        T.Eq(s2.Fragments("billing").Length, 0, "and no fragments")
        ; a dev-style AddFragment next to entries is replaced by the next entry change (items categories do not take them)
        s3 := TestItems.With("equipment", [TestItems.E("added", "item1")])
        s3.AddFragment("equipment", "stray")
        s3.AddEntry("equipment", TestItems.E("added", "item2"), m)
        T.Eq(s3.Fragments("equipment").Length, 2, "the fragments are exactly the model output")
    }

    static SnapshotShape() {
        m := TestItems.Model("equipment")
        s := TestItems.With("equipment", [TestItems.E("swapped", "item1", "2", "", "note")])
        snap := s.Snapshot()
        T.Eq(TestItems.Keys(snap["categories"]["equipment"]), "entries,fragments,values", "category keys")
        en := snap["categories"]["equipment"]["entries"]
        T.True(en is Array && en.Length = 1 && en[1] is Map, "entries is a list of objects")
        T.Eq(TestItems.Keys(en[1]), "action,details,item,outcome,qty", "entry keys")
        T.Eq(en[1]["qty"] "|" en[1]["details"], "2|note", "values")
        ; no entries -> no key
        s2 := TestItems.Make()
        s2.AddFragment("static", "x")
        T.False(s2.Snapshot()["categories"]["static"].Has("entries"), "no entries key without entries")
        s3 := TestItems.With("equipment", [TestItems.E("swapped", "item1")])
        s3.RemoveEntry("equipment", 1, m)
        T.False(s3.Snapshot()["categories"].Has("equipment"), "an emptied category leaves the snapshot")
        ; the snapshot is a copy
        en[1]["item"] := "changed"
        T.Eq(s.EntriesFor("equipment")[1].item, "item1", "changing the snapshot does not change the session")
    }

    static RoundTrip() {
        me := TestItems.Model("equipment"), mb := TestItems.Model("billing")
        s := TestItems.Make()
        s.UseCategory("billing"), s.UseCategory("equipment")
        s.AddEntry("billing", TestItems.E("added", "item2", "", "completed", "x {y}"), mb)
        s.AddEntry("billing", TestItems.E("removed", "item3", "", "requested"), mb)
        s.AddEntry("equipment", TestItems.E("swapped", "item1", "2", "", "Left at door"), me)
        s.AddEntry("equipment", TestItems.E("added", "item5"), me)
        note := TestItems.Note(s)
        s.NoteText := note, s.GeneratedText := note
        snap := s.Snapshot()
        back := ConfigJson.Parse(ConfigJson.Stringify(snap))               ; through JSON, as History does
        c := CallSession()
        T.True(c.Restore(back), "restored from JSON")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "snapshot -> JSON -> restore -> snapshot has identical categories")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categoriesUsed"]), ConfigJson.Canon(snap["categoriesUsed"]), "and used categories")
        T.Eq(c.EntriesFor("equipment").Length "|" c.EntriesFor("billing").Length, "2|2", "entries are back")
        T.Eq(c.EntriesFor("equipment")[1].qty "|" c.EntriesFor("equipment")[1].details, "2|Left at door", "values")
        T.Eq(c.EntriesFor("billing")[1].details, "x {y}", "braces survive")
        T.True(c.EntriesFor("billing")[1] is Object && !(c.EntriesFor("billing")[1] is Map), "plain objects, not Maps")
        T.Eq(ConfigJson.Canon(c.Fragments("equipment")), ConfigJson.Canon(s.Fragments("equipment")), "fragments restored as saved")
        T.Eq(TestItems.Note(c), note, "the restored session composes the same note")
        ; running the model on the restored entries gives the same fragments and values
        c.ApplyEntries("equipment", me)
        c.ApplyEntries("billing", mb)
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "the model reproduces fragments and values")
        ; and the restored call is editable
        T.True(c.RemoveEntry("billing", 1, mb), "remove after restore")
        T.True(c.UpdateEntry("equipment", 1, TestItems.E("swapped", "item1", "3", "", "Left at door"), me).Ok, "update after restore")
        T.Contains(TestItems.Note(c), "Swapped 3 Item 1 (placeholder). Left at door.", "and the note follows")
        ; History file round trip
        d := A_Temp "\NFSItemsTest_" A_TickCount "_" Random(1000, 9999)
        DirCreate(d)
        h := History({Dir: d, Agent: "tester", Now: () => "20261010120000000"})
        id := h.Save(snap, "clearAll")
        T.True(id != "", "saved to History")
        T.Contains(FileRead(h.FileFor("2026-10-10"), "UTF-8"), '"entries"', "the file holds the entries")
        c2 := CallSession()
        T.True(c2.Restore(h.Get(id)["snapshot"]), "loaded from the file")
        T.Eq(ConfigJson.Canon(c2.Snapshot()["categories"]), ConfigJson.Canon(snap["categories"]), "identical")
        try DirDelete(d, true)
    }

    static OldSnapshot() {
        s := TestItems.Make()
        s.UseCategory("equipment")
        s.AddFragment("equipment", "an old fragment")
        old := s.Snapshot()
        T.False(old["categories"]["equipment"].Has("entries"), "an M5-style snapshot has no entries")
        c := CallSession()
        T.True(c.Restore(old), "restores")
        T.Eq(c.EntriesFor("equipment").Length, 0, "no entries")
        T.Eq(c.Fragments("equipment")[1], "an old fragment", "fragments as before")
        T.Eq(ConfigJson.Canon(c.Snapshot()["categories"]), ConfigJson.Canon(old["categories"]), "and snapshots back identically")
        ; damaged entries
        snap := s.Snapshot()
        snap["categories"]["equipment"]["entries"] := [5, "x", Map("action", "added", "item", "item1"), Map()]
        c2 := CallSession()
        T.True(c2.Restore(snap), "damaged entries still restore")
        T.Eq(c2.EntriesFor("equipment").Length, 2, "Maps are kept (the empty one too, the model skips it), junk is dropped")
        snap["categories"]["equipment"]["entries"] := "nope"
        c3 := CallSession()
        T.True(c3.Restore(snap), "entries of the wrong type")
        T.Eq(c3.EntriesFor("equipment").Length, 0, "ignored")
        ; a restore replaces the entries of the previous call
        c4 := TestItems.With("billing", [TestItems.E("added", "item1", "", "completed")])
        c4.Restore(old)
        T.Eq(c4.EntriesFor("billing").Length, 0, "restore forgets the previous call's entries")
    }

    static HistoryEmpty() {
        snap := TestItems.With("equipment", [TestItems.E("added", "item1")]).Snapshot()
        T.False(History.IsEmpty(snap), "a snapshot with entries is not empty")
        only := Map("context", Map(), "categoriesUsed", [], "categories", Map("equipment", Map("fragments", [], "values", Map(),
            "entries", [Map("action", "added", "item", "item1", "qty", "", "outcome", "", "details", "")])), "noteText", "")
        T.False(History.IsEmpty(only), "entries alone are content")
        only["categories"]["equipment"]["entries"] := []
        T.True(History.IsEmpty(only), "an empty list is not")
    }

    ; --- the combined note ----------------------------------------------------------------------------------------
    static CombinedNote() {
        eng := TestStepsNotes.Eng()
        me := TestItems.Model("equipment"), mb := TestItems.Model("billing")
        want := "Tech name: Jordan`r`nTech ID: T12345`r`nJob Number: 88412`r`nNotes: Reason 1 placeholder note. Order type SRO placeholder note."
            . " Contact 1 placeholder note. Outcome 1 placeholder note.`r`nSwapped 2 Item 1 (placeholder). Left at door."
            . "`r`nAdded Item 2 (placeholder) - completed."
        ; whatever the order the agent used the categories in, the note follows the config order
        orders := [["billing", "equipment", "notDone"], ["equipment", "notDone", "billing"], ["notDone", "billing", "equipment"]]
        for order in orders {
            s := TestItems.Make()
            for id in order {
                s.UseCategory(id)
                if (id = "notDone") {
                    s.Choose("notDone", "reason", "r1", eng)
                    s.Choose("notDone", "orderType", "sro", eng)
                    s.Choose("notDone", "contact", "c1", eng)
                    s.Choose("notDone", "outcome", "o1", eng)
                } else if (id = "equipment")
                    s.AddEntry("equipment", TestItems.E("swapped", "item1", "2", "", "Left at door"), me)
                else
                    s.AddEntry("billing", TestItems.E("added", "item2", "", "completed"), mb)
            }
            T.Eq(TestItems.Note(s), want, "exact combined note, used in order " order[1] "," order[2] "," order[3])
        }
        ; the same with a Trouble Call stop in Not Done: the limited note, then Equipment and Billing as usual
        s := TestItems.Make()
        s.UseCategory("notDone"), s.UseCategory("equipment"), s.UseCategory("billing")
        s.Choose("notDone", "reason", "r2", eng)
        s.Choose("notDone", "orderType", "tc", eng)
        s.Choose("notDone", "supervisorTc", "no", eng)
        s.AddEntry("equipment", TestItems.E("removed", "item4"), me)
        s.AddEntry("billing", TestItems.E("changed", "item5", "", "requested"), mb)
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Reason 2 placeholder note. Order type TC placeholder note. Tech has not contacted supervisor; advised tech to contact supervisor before calling back."
            . "`r`nRemoved Item 4 (placeholder).`r`nChanged Item 5 (placeholder) - requested, not yet completed.", "with the Trouble Call stop")
        ; a used category with no entries (all removed) adds no line
        s.RemoveEntry("equipment", 1, me)
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Reason 2 placeholder note. Order type TC placeholder note. Tech has not contacted supervisor; advised tech to contact supervisor before calling back."
            . "`r`nChanged Item 5 (placeholder) - requested, not yet completed.", "an emptied Equipment leaves no blank line")
    }

    ; an admin-made items category works with the same model
    static CustomCategory() {
        c := Map("id", "parts", "label", "Parts", "icon", "E772", "enabled", true, "system", false, "kind", "items", "notePrefix", "",
            "entry", Map("actions", [Map("id", "ord", "label", "Ordered", "fragment", "{action}: {qty} x {item}")],
                "items", [Map("id", "cable", "label", "Cable"), Map("id", "box", "label", "Box")],
                "outcomes", [Map("id", "ok", "label", "Done", "fragment", "(done)")],
                "outcomeRequired", false, "qty", true, "details", false))
        cfg := Defaults.Config()
        cfg["categories"].InsertAt(3, c)
        T.True(Schema.Validate(cfg).Ok, "the custom category validates " Schema.Summary(Schema.Validate(cfg)))
        m := ItemsModel(c)
        s := TestItems.Make()
        s.UseCategory("parts")
        s.AddEntry("parts", TestItems.E("ord", "cable", "3"), m)
        s.AddEntry("parts", TestItems.E("ord", "box", "", "ok"), m)
        T.Eq(TestItems.Tail(TestItems.Note(s, cfg)), "Ordered: 3 x Cable. Ordered: x Box (done).", "exact note from the config alone (an empty qty leaves its own words, never a number)")
        T.Eq(m.Validate(TestItems.E("ord", "cable", "", "")).Ok ? 1 : 0, 1, "outcome optional")
    }

    ; --- App wiring (no window) -----------------------------------------------------------------------------------
    static AppWiring() {
        app := NFSApp()
        app.Logger := Log({Path: A_Temp "\NFSItemsLog_" A_TickCount ".log", Level: "debug"})
        app.Config := {Config: Defaults.Config()}
        app.Session := CallSession({Logger: app.Logger})
        app.Stats := TestStepsNotes.FakeStats()
        c := CallContext()
        c.Set("techName", "Jordan Smith", "mock")
        app.Session.BeginCall(c)
        T.True(app.IsItemsCategory("equipment") && app.IsItemsCategory("billing"), "equipment and billing are items categories")
        T.False(app.IsItemsCategory("notDone") || app.IsItemsCategory("static") || app.IsItemsCategory("nope"), "others are not")
        T.True(app.ModelFor("equipment") == app.ModelFor("equipment"), "models are cached")
        T.Eq(app.ModelFor("notDone"), "", "no model for steps categories")
        T.Eq(app.ModelFor("nope"), "", "nor for unknown ones")
        T.True(app.ModelFor("equipment").SentenceCase && app.ModelFor("equipment").EndPunct == ".", "the model copies the note template switches")
        T.False(app.AddSampleFragment("equipment") || app.AddSampleFragment("billing"), "no sample fragments for items categories")
        T.False(app.AddSampleFragment("static"), "nor static (M7)")
        T.Eq(app.Session.Fragments("equipment").Length, 0, "nothing added to equipment")
        ; a refused entry does not mark the category used
        r := app.AddEntry("equipment", TestItems.E("", ""))
        T.False(r.Ok, "refused")
        T.False(app.Session.IsUsed("equipment"), "and not used")
        T.False(app.Stats.Used.Has("equipment"), "and not credited")
        r := app.AddEntry("equipment", TestItems.E("swapped", "item1"))
        T.True(r.Ok, "added")
        T.True(app.Session.IsUsed("equipment"), "the first entry marks the category used")
        T.Eq(app.Stats.Used["equipment"], 1, "and credits it once")
        app.AddEntry("equipment", TestItems.E("added", "item2"))
        T.Eq(app.Stats.Used["equipment"], 1, "only the first entry uses the category")
        T.False(app.AddEntry("equipment", TestItems.E("added", "item2")).Ok, "a duplicate is refused")
        T.Eq(app.Stats.Used["equipment"], 1, "still once")
        T.True(app.UpdateEntry("equipment", 2, TestItems.E("added", "item3", "2")).Ok, "update")
        T.Eq(app.Session.Fragments("equipment").Length, 2, "fragments replaced")
        T.True(app.MoveEntry("equipment", 2, 1), "move")
        T.Eq(app.Session.EntriesFor("equipment")[1].item, "item3", "moved")
        T.True(app.RemoveEntry("equipment", 1), "remove")
        T.Eq(app.Session.EntriesFor("equipment").Length, 1, "one left")
        T.False(app.RemoveEntry("equipment", 5), "bad index")
        T.False(app.AddEntry("notDone", TestItems.E("a", "b")).Ok, "steps categories take no entries")
        T.False(app.AddEntry("nope", TestItems.E("a", "b")).Ok, "nor unknown ones")
        T.False(app.UpdateEntry("nope", 1, TestItems.E("a", "b")).Ok, "update on an unknown category")
        T.False(app.RemoveEntry("nope", 1), "remove on an unknown category")
        T.False(app.MoveEntry("nope", 1, 2), "move on an unknown category")
        ; MissingRequired only looks at steps categories
        T.Eq(app.MissingRequired().Length, 0, "items entries never block a copy")
        ; the model is re-run from the entries (a config change)
        app.Config.Config["categories"][2]["entry"]["actions"][3]["fragment"] := "{action} CHANGED {item}"
        T.True(app.ModelFor("equipment") == app.ModelFor("equipment"), "same config object: the cached model")
        app.Config := {Config: Util.Clone(app.Config.Config)}
        app.RefreshEntries("equipment")
        T.Contains(app.Session.Fragments("equipment")[1], "Swapped CHANGED", "RefreshEntries re-runs the model after a config change")
        ; reset
        app.ResetCategory("equipment")
        T.Eq(app.Session.EntriesFor("equipment").Length, 0, "ResetCategory clears entries")
        try FileDelete(app.Logger.Path)
    }

    static PreviewAndDescribe() {
        m := TestItems.Model("equipment")
        T.Eq(m.Preview(TestItems.E("swapped", "item1")), "Swapped Item 1 (placeholder).", "preview")
        T.Eq(m.Preview(TestItems.E("swapped", "")), "", "no item: no preview")
        T.Eq(m.Preview(TestItems.E("swapped", "item1", "abc")), "", "bad qty: no preview")
        T.Eq(m.Describe(TestItems.E("swapped", "item1", "abc")), "Swapped Item 1 (placeholder).", "Describe leaves a bad qty out, like the note")
        T.Eq(m.Describe(TestItems.E("swapped", "zzz")), "", "Describe of an unknown id")
        m.SentenceCase := false
        m.EndPunct := ""
        T.Eq(m.Preview(TestItems.E("swapped", "item1")), "Swapped Item 1 (placeholder).", "(the fragment itself ends with a stop)")
        c := TestItems.Cat("billing")
        c["entry"]["actions"][1]["fragment"] := "{action} {item}"
        mb := ItemsModel(c)
        mb.SentenceCase := false
        mb.EndPunct := ""
        T.Eq(mb.Preview(TestItems.E("added", "item1", "", "unable")), "Added Item 1 (placeholder) - unable to complete.", "switches off: text as is")
        mb.SentenceCase := true
        mb.EndPunct := "!"
        T.Eq(mb.Preview(TestItems.E("added", "item1", "", "unable")), "Added Item 1 (placeholder) - unable to complete.", "an existing stop is kept")
        c["entry"]["outcomes"][3]["fragment"] := "- unable to complete"
        mb2 := ItemsModel(c)
        mb2.EndPunct := "!"
        T.Eq(mb2.Preview(TestItems.E("added", "item1", "", "unable")), "Added Item 1 (placeholder) - unable to complete!", "configured end punctuation")
    }

    static NoteEdgeCases() {
        m := TestItems.Model("equipment")
        ; multi-line details are squeezed into one line
        s := TestItems.With("equipment", [TestItems.E("added", "item1", "", "", "line one`r`nline two`n`nline three")])
        T.Eq(TestItems.Tail(TestItems.Note(s)), "Added Item 1 (placeholder). line one line two line three.", "newlines in details")
        ; disabled category still composes what was used
        cfg := Defaults.Config()
        cfg["categories"][2]["enabled"] := false
        T.Contains(TestItems.Tail(TestItems.Note(s, cfg)), "Added Item 1", "a used but disabled category is still in the note")
        ; the ids are never printed
        txt := TestItems.Note(TestItems.With("billing", [TestItems.E("added", "item1", "", "completed")]))
        T.NotContains(txt, "item1", "ids never appear in the note")
        T.NotContains(txt, "completed|", "nor raw outcome keys")
        ; a very long detail is kept whole
        long := ""
        loop 50
            long .= "word" A_Index " "
        T.Contains(TestItems.Note(TestItems.With("equipment", [TestItems.E("added", "item1", "", "", long)])), "word50.", "long details are not cut")
    }
}
