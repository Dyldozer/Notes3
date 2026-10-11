#Requires AutoHotkey v2.0
; AdminSelfTest.ahk - NFSAdmin.ahk --selftest: drives the real window (DOM clicks on the registered controls, the real
; handlers) against a throw-away shared folder seeded with a copy of the defaults. Each scenario logs a line; a failed check
; is logged at ERROR level ("selftest FAIL ..."). Questions are answered through window.AutoAsk, file pickers through
; window.FileHook. Nothing real is touched: the config folder, cache and log are all in %TEMP%.

class AdminSelfTest {
    static Win := ""
    static Passed := 0
    static Failed := 0
    static Ans := Map()
    static Asked := []
    static NextFile := ""
    static Tmp := ""

    static Run(win) {
        S := AdminSelfTest
        S.Win := win
        lg := win.Log
        S.Tmp := win.App.TempRoot
        win.AutoAsk := (kind, text, buttons) => AdminSelfTest.Answer(kind, text, buttons)
        win.FileHook := (mode, default) => AdminSelfTest.NextFile
        try {
            for name in ["Load", "EditSave", "AddOption", "DeleteReferenced", "RemoveReason", "MoveBlocked", "FragmentPreview", "Template",
                         "InvalidValues", "ForeignLock", "RevisionBump", "ConflictCopies", "Import", "RestoreDefaults", "Export", "RawJson",
                         "SystemCategory", "RealDialogs", "CheckNavigation", "CloseWithChanges", "Conditions", "StopAndFields"] {
                S.Fresh()
                S.%"T" name%()
            }
        } catch as e {
            SplitPath(e.File, &eFile)
            lg.Error("selftest failed", {error: e.Message, line: e.Line, file: eFile, what: e.What,
                stack: StrReplace(RegExReplace(e.Stack, "m)^.*\\", ""), "`n", " <- ")})
        }
        lg.Info("selftest done", {passed: S.Passed, failed: S.Failed})
        try DirDelete(win.App.TempRoot, true)
        SetTimer(() => ExitApp(), -200)
    }

    ; --- helpers ---------------------------------------------------------------------------------------------------
    static Chk(name, cond, detail := "") {
        S := AdminSelfTest
        if cond {
            S.Passed += 1
            S.Win.Log.Debug("selftest ok " name)
        } else {
            S.Failed += 1
            S.Win.Log.Error("selftest FAIL " name, detail != "" ? {detail: detail} : unset)
        }
        return cond ? true : false
    }

    static Say(kind, answer) {
        AdminSelfTest.Ans[kind] := answer
    }

    static Answer(kind, text, buttons) {
        S := AdminSelfTest
        S.Asked.Push({Kind: kind, Text: text})
        if S.Ans.Has(kind)
            return S.Ans[kind]
        S.Win.Log.Error("selftest FAIL unexpected question", {kind: kind})
        return buttons[buttons.Length]
    }

    static El(id) {
        try return AdminSelfTest.Win.G.El(id)
        return ""
    }

    static Text(id) {
        try return AdminSelfTest.El(id).innerText
        return ""
    }

    static Title() {
        try return WinGetTitle("ahk_id " AdminSelfTest.Win.G.Hwnd)
        return ""
    }

    static Id(act, args*) => AdminSelfTest.Win.H.BaseId(act, args)

    ; Click a registered control through the DOM.
    static Press(act, args*) {
        S := AdminSelfTest
        id := S.Id(act, args*)
        el := S.El(id)
        if !S.Chk("control exists: " id, IsObject(el))
            return false
        el.click()
        Sleep(100)
        return true
    }

    ; Type into a box (or pick in a select) and fire the handler the way a blur / change does.
    static SetVal(act, args, value) {
        S := AdminSelfTest
        id := S.Id(act, args*)
        el := S.El(id)
        if !S.Chk("control exists: " id, IsObject(el))
            return false
        el.value := value
        S.Win.Onchange(el)
        Sleep(60)
        return true
    }

    static Page(p) {
        AdminSelfTest.Win.ShowPage(p)
        Sleep(80)
    }

    static Count(pattern) {
        n := 0
        Loop Files pattern, "F"
            n += 1
        return n
    }

    static Order(m) {
        o := ""
        for s in m.Steps("notDone")
            o .= (o = "" ? "" : ",") s["id"]
        return o
    }

    ; How a page lays out: text boxes that collapsed to nothing, and whether the page needs a horizontal scroll bar.
    static Layout(page) {
        S := AdminSelfTest
        r := {Inputs: 0, Collapsed: 0, MinW: 99999, ScrollW: 0, ClientW: 0}
        mount := S.El("adP_" page)
        if !IsObject(mount)
            return r
        els := mount.querySelectorAll("input, textarea, select")
        loop els.length {
            e := els.item(A_Index - 1)
            ty := ""
            try ty := e.type
            if (ty = "checkbox")
                continue
            r.Inputs += 1
            w := e.offsetWidth
            if (w < 20)
                r.Collapsed += 1
            r.MinW := Min(r.MinW, w)
        }
        doc := S.Win.G.Doc.documentElement
        r.ScrollW := doc.scrollWidth, r.ClientW := doc.clientWidth
        return r
    }

    ; Click a button of the library dialog from a timer, while the dialog is open (value goes into its input first).
    static ClickDialog(n, value := "") {
        SetTimer(() => AdminSelfTest._DlgClick(n, value), -400)
    }

    static _DlgClick(n, value) {
        S := AdminSelfTest
        try {
            if (value != "")
                S.El("axDlgInput").value := value
            S.Win.LastDialog := {Title: S.Text("axDlgTitle"), Text: S.Text("axDlgText"), Buttons: S.El("axDlgBtns").querySelectorAll(".axdlg-btn").length}
            S.El("axDlgBtn" n).click()
        } catch as e
            S.Win.Log.Error("selftest FAIL dialog click", {error: e.Message})
    }

    static Disk() => ConfigJson.Parse(FileRead(AdminSelfTest.Win.App.SharedPath "\config.json", "UTF-8"))

    ; Back to the saved file, no lock, no stray files.
    static Fresh() {
        S := AdminSelfTest
        w := S.Win
        sd := w.App.SharedPath
        for n in ["config.lock", "config-DESKTOP-TEST.json"]
            if FileExist(sd "\" n)
                FileDelete(sd "\" n)
        S.Ans := Map()
        w.ReloadNow(false)
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        w.LastError := ""
        S.Page("categories")
    }

    ; --- scenarios -------------------------------------------------------------------------------------------------
    static TLoad() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Chk("loaded from the shared folder", m.Store.Source = "shared" && m.Store.Revision = 0)
        S.Chk("not dirty after load", !m.Dirty)
        S.Chk("five categories", m.Work["categories"].Length = 5)
        S.Chk("the defaults validate", m.Validate().Ok)
        S.Chk("status line shows the revision", InStr(S.Text("adStatus"), "revision 0"), S.Text("adStatus"))
        S.Chk("title has no star", !InStr(S.Title(), "*"), S.Title())
        S.Chk("the config is not the real one", InStr(w.App.SharedPath, A_Temp) = 1)
        sizes := ""
        for p in AdminWindow.PAGES {
            S.Page(p[1])
            mount := S.El("adP_" p[1])
            n := IsObject(mount) ? StrLen(mount.innerHTML) : 0
            S.Chk("page drawn: " p[1], n > 200, "html length " n)
            sizes .= p[1] "=" n " "
            ly := S.Layout(p[1])
            S.Chk("no collapsed text boxes on " p[1], ly.Collapsed = 0, ly.Collapsed " of " ly.Inputs)
            S.Chk("no horizontal scroll on " p[1], ly.ScrollW <= ly.ClientW + 2, ly.ScrollW " > " ly.ClientW)
            lg.Info("selftest layout", {page: p[1], inputs: ly.Inputs, collapsed: ly.Collapsed, minWidth: ly.MinW, scrollW: ly.ScrollW, clientW: ly.ClientW})
        }
        lg.Info("selftest load", {source: m.Store.Source, revision: m.Store.Revision, dirty: m.Dirty ? 1 : 0, categories: m.Work["categories"].Length,
            valid: m.Validate().Ok ? 1 : 0, status: S.Text("adStatus"), title: S.Title(), pages: sizes})
    }

    static TEditSave() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        sd := w.App.SharedPath
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Not Done (admin)")
        S.Chk("dirty after a label edit", m.Dirty)
        S.Chk("title shows *", InStr(S.Title(), "*"), S.Title())
        S.Chk("unsaved marker in the header", S.Text("adDirty") = "Unsaved changes", S.Text("adDirty"))
        S.Press("save")
        d := S.Disk()
        S.Chk("saved: revision 1 on disk", d["revision"] = 1, d["revision"])
        S.Chk("saved: the label is on disk", d["categories"][1]["label"] = "Not Done (admin)")
        S.Chk("saved: a backup exists", S.Count(sd "\backups\config-*.json") = 1)
        S.Chk("saved: the lock is released", !FileExist(sd "\config.lock"))
        S.Chk("saved: not dirty", !m.Dirty)
        S.Chk("saved: title has no star", !InStr(S.Title(), "*"), S.Title())
        S.Chk("saved: status shows revision 1 and my name", InStr(S.Text("adStatus"), "revision 1") && InStr(S.Text("adStatus"), A_UserName), S.Text("adStatus"))
        S.Chk("saved: toast", InStr(w.LastToast, "Saved. Revision 1"), w.LastToast)
        S.Chk("saved: no tmp file", !FileExist(sd "\config.json.tmp"))
        lg.Info("selftest save", {revision: d["revision"], backups: S.Count(sd "\backups\config-*.json"), lock: FileExist(sd "\config.lock") ? 1 : 0,
            dirty: m.Dirty ? 1 : 0, status: S.Text("adStatus")})
    }

    static TAddOption() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        S.Page("edit")
        S.SetVal("optNewName", ["notDone", "reason"], "Selftest option")
        holder := w.ScrollHolder(S.El("adP_edit"))
        scrollBefore := -1
        if IsObject(holder) {
            holder.scrollTop := 150
            scrollBefore := holder.scrollTop
        }
        S.Press("optAdd", "notDone", "reason")
        holder := w.ScrollHolder(S.El("adP_edit"))
        scrollAfter := IsObject(holder) ? holder.scrollTop : -1
        S.Chk("the scroll position survives a redraw", scrollBefore <= 0 || Abs(scrollAfter - scrollBefore) <= 2, scrollBefore " -> " scrollAfter)
        lg.Info("selftest scroll", {holder: IsObject(holder) ? 1 : 0, before: scrollBefore, after: scrollAfter})
        S.Chk("option added to the model", AdminModel.Find(m.Options("notDone", "reason"), "selftestOption") is Map)
        S.Page("edit")
        S.SetVal("optFrag", ["notDone", "reason", "selftestOption"], "Selftest reason note.")
        S.Page("preview")
        S.Press("pvChoose", "notDone", "reason", "selftestOption")
        w.RefreshNoteNow()
        S.Chk("the new option can be chosen in the preview", InStr(w.NoteText(), "Selftest reason note."), w.NoteText())
        lg.Info("selftest addOption", {options: m.Options("notDone", "reason").Length, id: "selftestOption", inNote: InStr(w.NoteText(), "Selftest reason note.") ? 1 : 0})
    }

    static TDeleteReferenced() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        S.Page("edit")
        S.Say("refs", "Cancel")
        S.Press("optDel", "notDone", "reason", "r4")
        S.Chk("cancel: the option is still there", AdminModel.Find(m.Options("notDone", "reason"), "r4") is Map)
        S.Chk("the references were listed", w.LastRefs.Length = 1 && w.LastRefs[1].Kind = "flag", w.LastRefs.Length)
        S.Chk("the list names the flag", InStr(w.LastAsked.Html, "Flag"), w.LastAsked.Html)
        S.Say("refs", "Delete and remove those references")
        S.Press("optDel", "notDone", "reason", "r4")
        S.Chk("the option is gone", !(AdminModel.Find(m.Options("notDone", "reason"), "r4") is Map))
        flagWhen := ConfigJson.Canon(m.Flags("notDone")[1]["when"])
        S.Chk("the flag lost that clause only", flagWhen = '{"all":[{"in":["sro"],"step":"orderType"}]}', flagWhen)
        S.Chk("the config is still valid", m.Validate().Ok)
        lg.Info("selftest deleteReferenced", {refs: w.LastRefs.Length, kind: w.LastRefs[1].Kind, flagWhen: flagWhen, valid: m.Validate().Ok ? 1 : 0})
    }

    static TRemoveReason() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        S.Page("edit")
        n0 := S.Asked.Length
        S.Press("stepDel", "notDone", "reason")
        S.Chk("reason is still there", m.Step("notDone", "reason") is Map)
        S.Chk("the refusal says why", InStr(w.LastError, "required"), w.LastError)
        S.Chk("no question was asked", S.Asked.Length = n0)
        lg.Info("selftest removeReason", {stillThere: m.Step("notDone", "reason") is Map ? 1 : 0, error: w.LastError})
    }

    static TMoveBlocked() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "supervisorPwo"
        S.Page("edit")
        order0 := S.Order(m)
        S.Say("moveBlocked", "OK")
        S.Press("stepUp", "notDone", "supervisorPwo")
        S.Chk("the move was blocked", S.Order(m) = order0, S.Order(m))
        S.Chk("the admin was told why", w.LastAsked.Kind = "moveBlocked" && InStr(w.LastAsked.Text, "above"), w.LastAsked.Text)
        lg.Info("selftest moveBlocked", {order: S.Order(m), asked: w.LastAsked.Kind})
    }

    static TFragmentPreview() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("preview")
        S.Press("pvChoose", "notDone", "reason", "r1")
        w.RefreshNoteNow()
        before := w.NoteText()
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        S.Page("edit")
        S.SetVal("optFrag", ["notDone", "reason", "r1"], "Edited by the selftest.")
        w.RefreshNoteNow()
        after := w.NoteText()
        S.Chk("the note changed with the fragment", before != after && InStr(after, "Edited by the selftest."), after)
        S.Chk("the old text is gone", !InStr(after, "Reason 1 placeholder note."))
        lg.Info("selftest fragment", {changed: before != after ? 1 : 0, hasNew: InStr(after, "Edited by the selftest.") ? 1 : 0})
    }

    static TTemplate() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("template")
        S.SetVal("tplLine", [1], "Tech name: {tech.firstName} (template edit)")
        w.RefreshNoteNow()
        S.Chk("template line edit shows in the note", InStr(w.NoteText(), "Tech name: Sample (template edit)"), w.NoteText())
        ; a chip inserts at the cursor
        id := S.Id("tplLine", 2)
        el := S.El(id)
        el.value := "ab"
        w.LastBox := id
        el.focus()
        el.setSelectionRange(1, 1)
        S.Press("chip", "{tech.id}")
        S.Chk("chip inserted at the cursor", m.Tpl["lines"][2] = "a{tech.id}b", m.Tpl["lines"][2])
        w.RefreshNoteNow()
        S.Chk("and the note follows", InStr(w.NoteText(), "aT00000b"), w.NoteText())
        S.Press("tplAdd")
        S.Chk("a line was added", m.Tpl["lines"].Length = 5)
        S.Page("template")
        S.Press("tplDel", 5)
        S.Chk("and removed", m.Tpl["lines"].Length = 4)
        lg.Info("selftest template", {line1: m.Tpl["lines"][1], line2: m.Tpl["lines"][2], inNote: InStr(w.NoteText(), "aT00000b") ? 1 : 0})
    }

    static TInvalidValues() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("settings")
        acc0 := AdminModel.Find(m.Presets, "spectrum-light")["accent"]
        S.SetVal("presetAccent", ["spectrum-light"], "blue")
        S.Chk("an invalid accent is refused", AdminModel.Find(m.Presets, "spectrum-light")["accent"] = acc0)
        S.Chk("with a message", InStr(w.LastError, "accent"), w.LastError)
        S.Chk("shown under the box", S.Text("adErr_preset_spectrum-light") != "", S.Text("adErr_preset_spectrum-light"))
        S.SetVal("presetAccent", ["spectrum-light"], "#112233")
        S.Chk("a valid accent is taken", AdminModel.Find(m.Presets, "spectrum-light")["accent"] = "#112233")
        S.Chk("and the message is cleared", S.Text("adErr_preset_spectrum-light") = "")
        S.SetVal("presetAccent", ["spectrum-light"], acc0)
        S.SetVal("num", ["ping.timeoutMs"], "50")
        S.Chk("a number below the bound is refused", m.GetNumber("ping.timeoutMs") = 1000 && InStr(S.Text("adErr_ping_timeoutMs"), "200"), S.Text("adErr_ping_timeoutMs"))
        S.SetVal("num", ["ping.timeoutMs"], "1500")
        S.Chk("a number inside the bounds is taken", m.GetNumber("ping.timeoutMs") = 1500 && S.Text("adErr_ping_timeoutMs") = "")
        S.SetVal("num", ["history.retentionDays"], "91")
        S.Chk("retention above 90 refused", m.GetNumber("history.retentionDays") = 14)
        S.SetVal("num", ["history.retentionDays"], "30")
        S.Chk("retention 30 taken", m.GetNumber("history.retentionDays") = 30)
        lg.Info("selftest invalid", {accent: AdminModel.Find(m.Presets, "spectrum-light")["accent"], timeout: m.GetNumber("ping.timeoutMs"), retention: m.GetNumber("history.retentionDays")})
    }

    static TForeignLock() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        sd := w.App.SharedPath
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Lock test")
        rev0 := S.Disk()["revision"]
        FileAppend(ConfigJson.Stringify(Map("user", "bob", "machine", "PC-B", "time", Util.IsoNow())), sd "\config.lock", "UTF-8-RAW")
        S.Say("savelocked", "OK")
        S.Press("save")
        S.Chk("save refused while another user holds the lock", S.Disk()["revision"] = rev0 && m.Dirty)
        S.Chk("the holder is named", InStr(w.LastAsked.Text, "bob") && InStr(w.LastAsked.Text, "PC-B"), w.LastAsked.Text)
        S.Chk("the question was the lock one", w.LastAsked.Kind = "savelocked", w.LastAsked.Kind)
        S.Chk("the foreign lock is left alone", FileExist(sd "\config.lock") != "")
        FileDelete(sd "\config.lock")
        lg.Info("selftest lock", {refused: m.Dirty ? 1 : 0, kind: w.LastAsked.Kind, namesHolder: InStr(w.LastAsked.Text, "bob") ? 1 : 0})
    }

    static TRevisionBump() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        sd := w.App.SharedPath
        other := ConfigStore({SharedDir: sd, CacheDir: S.Tmp "\othercache", User: "carol", Machine: "PC-C"}).Load()
        oc := Util.Clone(other.Config)
        oc["categories"][1]["label"] := "Carol label"
        other.Save(oc)
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Alice label")
        S.Say("saveChanged", "Keep editing")
        S.Press("save")
        S.Chk("save refused: the file changed", m.Dirty && S.Disk()["categories"][1]["label"] = "Carol label")
        S.Chk("the dialog names who", InStr(w.LastAsked.Text, "carol"), w.LastAsked.Text)
        S.Chk("and offers reload", w.LastAsked.Kind = "saveChanged" && w.LastAsked.Buttons[1] = "Reload (unsaved edits will be lost)")
        S.Chk("keep editing keeps the edits", m.Dirty && m.Cat("notDone")["label"] = "Alice label")
        S.Say("saveChanged", "Reload (unsaved edits will be lost)")
        S.Press("save")
        S.Chk("reload picked up the other version", !m.Dirty && m.Cat("notDone")["label"] = "Carol label")
        S.Chk("at its revision", m.Store.Revision = S.Disk()["revision"])
        lg.Info("selftest bump", {kind: w.LastAsked.Kind, revision: m.Store.Revision, label: m.Cat("notDone")["label"], dirty: m.Dirty ? 1 : 0})
    }

    static TConflictCopies() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        sd := w.App.SharedPath
        S.Chk("no banner on a clean folder", !w.BannerShown())
        FileAppend("{}", sd "\config-DESKTOP-TEST.json", "UTF-8-RAW")
        w.ReloadNow(false)
        S.Chk("the banner is shown", w.BannerShown())
        S.Chk("it warns", InStr(w.BannerText(), "OneDrive found conflicting copies of the config. Check them before saving."), w.BannerText())
        S.Chk("and names the file", InStr(w.BannerText(), "config-DESKTOP-TEST.json"), w.BannerText())
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Copies test")
        rev0 := S.Disk()["revision"]
        S.Say("saveCopies", "Cancel")
        S.Press("save")
        S.Chk("save asks first and Cancel saves nothing", w.LastAsked.Kind = "saveCopies" && S.Disk()["revision"] = rev0 && m.Dirty)
        S.Say("saveCopies", "Save anyway")
        S.Press("save")
        S.Chk("Save anyway saves", S.Disk()["revision"] = rev0 + 1 && !m.Dirty)
        S.Chk("the copy is never deleted", FileExist(sd "\config-DESKTOP-TEST.json") != "")
        FileDelete(sd "\config-DESKTOP-TEST.json")
        w.ReloadNow(false)
        S.Chk("banner hidden again", !w.BannerShown())
        lg.Info("selftest copies", {asked: "saveCopies", saved: S.Disk()["revision"] = rev0 + 1 ? 1 : 0})
    }

    static TImport() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        sd := w.App.SharedPath
        S.Page("files")
        bad := S.Tmp "\bad.json"
        FileAppend("{not json", bad, "UTF-8-RAW")
        S.NextFile := bad
        S.Say("importBad", "OK")
        rev0 := S.Disk()["revision"]
        S.Press("import")
        S.Chk("an invalid file is refused", w.LastAsked.Kind = "importBad" && !m.Dirty, w.LastAsked.Kind)
        S.Chk("with the reason", InStr(w.LastError, "JSON"), w.LastError)
        newer := Defaults.Config()
        newer["schemaVersion"] := 99
        tooNew := S.Tmp "\new.json"
        FileAppend(ConfigJson.Stringify(newer), tooNew, "UTF-8-RAW")
        S.NextFile := tooNew
        S.Press("import")
        S.Chk("a too-new file is refused", !m.Dirty && InStr(w.LastError, "newer"), w.LastError)
        good := Defaults.Config()
        good["revision"] := 99
        good["categories"][1]["label"] := "Imported label"
        goodPath := S.Tmp "\good.json"
        FileAppend(ConfigJson.Stringify(good), goodPath, "UTF-8-RAW")
        S.NextFile := goodPath
        S.Say("importOk", "Cancel")
        S.Press("import")
        S.Chk("declining the confirmation changes nothing", !m.Dirty)
        S.Say("importOk", "Replace")
        S.Press("import")
        S.Chk("a valid file replaces the working copy", m.Cat("notDone")["label"] = "Imported label")
        S.Chk("it is not saved", S.Disk()["revision"] = rev0 && m.Dirty)
        S.Chk("the revision is the loaded one", m.Work["revision"] = m.Store.Revision, m.Work["revision"])
        S.Chk("the confirmation described the file", InStr(w.LastAsked.Text, "5 categories") && InStr(w.LastAsked.Text, "revision 99"), w.LastAsked.Text)
        lg.Info("selftest import", {invalidRefused: 1, replaced: m.Cat("notDone")["label"] = "Imported label" ? 1 : 0, dirty: m.Dirty ? 1 : 0,
            diskRevision: S.Disk()["revision"], workRevision: m.Work["revision"]})
    }

    static TRestoreDefaults() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Not the default")
        S.Page("files")
        S.Say("restoreDefaults", "Restore defaults")
        S.Press("restoreDefaults")
        S.Chk("the default label is back", m.Cat("notDone")["label"] = "Not Done")
        S.Chk("the working copy differs from the saved file or equals it, never saved", S.Disk()["revision"] = m.Store.Revision)
        S.Chk("the revision number is kept", m.Work["revision"] = m.Store.Revision)
        ; dirty relative to an edited saved file
        m.SetCatProp("static", "label", "Static (edited)")
        S.Press("save")
        S.Chk("(setup) an edited file was saved", S.Disk()["categories"][4]["label"] = "Static (edited)")
        S.Page("files")
        S.Press("restoreDefaults")
        S.Chk("restoring defaults over an edited saved file makes the copy dirty", m.Dirty)
        S.Chk("and the file on disk is untouched", S.Disk()["categories"][4]["label"] = "Static (edited)")
        lg.Info("selftest restore", {label: m.Cat("notDone")["label"], dirty: m.Dirty ? 1 : 0, revision: m.Work["revision"]})
    }

    static TExport() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Exported label")
        S.Page("files")
        S.NextFile := S.Tmp "\export.json"
        S.Press("export")
        ok := FileExist(S.NextFile) != ""
        S.Chk("the file was written", ok)
        same := false
        if ok
            same := ConfigJson.Canon(ConfigJson.Parse(FileRead(S.NextFile, "UTF-8"))) == ConfigJson.Canon(m.Work)
        S.Chk("it holds the working copy", same)
        S.Chk("the disk copy is untouched", S.Disk()["categories"][1]["label"] != "Exported label")
        lg.Info("selftest export", {written: ok ? 1 : 0, sameAsWorking: same ? 1 : 0})
    }

    static TRawJson() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("raw")
        canon0 := ConfigJson.Canon(m.Work)
        S.SetVal("rawText", [], "{ broken")
        S.Press("rawApply")
        S.Chk("broken JSON is not applied", ConfigJson.Canon(m.Work) == canon0 && InStr(w.RawMsg, "Not applied"), w.RawMsg)
        cur := m.Cat("notDone")["label"]
        txt := StrReplace(m.RawText(), '"label": "' cur '"', '"label": "' cur ' (raw)"', true, , 1)
        S.SetVal("rawText", [], txt)
        S.Press("rawApply")
        S.Chk("valid JSON is applied to the working copy", m.Cat("notDone")["label"] = cur " (raw)", m.Cat("notDone")["label"])
        S.Chk("and is not saved", m.Store.Revision = S.Disk()["revision"] && m.Dirty)
        bad := Defaults.Config()
        bad["ping"]["attempts"] := 500
        S.SetVal("rawText", [], ConfigJson.Stringify(bad))
        S.Press("rawApply")
        S.Chk("JSON that fails validation is not applied", m.GetNumber("ping.attempts") != 500, w.RawMsg)
        lg.Info("selftest raw", {label: m.Cat("notDone")["label"], msg: w.RawMsg})
    }

    static TSystemCategory() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Page("categories")
        S.Say("delSystem", {Button: "Remove it anyway", Value: "wrong name"})
        S.Press("catDel", "billing")
        S.Chk("a wrong typed name removes nothing", m.Cat("billing") is Map)
        S.Chk("the warning is strong", InStr(w.LastAsked.Text, "History entries that used it will show its id") && InStr(w.LastAsked.Text, "NOT valid"), w.LastAsked.Text)
        S.Say("delSystem", {Button: "Cancel", Value: ""})
        S.Press("catDel", "billing")
        S.Chk("Cancel removes nothing", m.Cat("billing") is Map)
        S.Say("delSystem", {Button: "Remove it anyway", Value: "billing"})
        S.Press("catDel", "billing")
        S.Chk("the right name removes it", !(m.Cat("billing") is Map))
        S.Chk("the configuration is invalid until it is restored", !m.Validate().Ok && m.MissingSystem().Length = 1)
        S.Page("categories")
        S.Chk("the page offers to restore it", IsObject(S.El(S.Id("catRestore", "billing"))))
        rev0 := S.Disk()["revision"]
        S.Say("saveInvalid", "OK")
        S.Press("save")
        S.Chk("errors block the save", w.LastAsked.Kind = "saveInvalid" && S.Disk()["revision"] = rev0)
        S.Press("catRestore", "billing")
        S.Chk("restored from the defaults", m.Cat("billing") is Map && m.Validate().Ok)
        lg.Info("selftest system", {removedAndRestored: m.Cat("billing") is Map ? 1 : 0, valid: m.Validate().Ok ? 1 : 0})
    }

    ; The library dialog itself (the other scenarios answer through AutoAsk): the reference list with Html, and the typed
    ; confirmation with an input box. A timer presses the button while the dialog is open.
    static TRealDialogs() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        saved := w.AutoAsk
        w.AutoAsk := ""
        w.LastDialog := {Title: "", Text: "", Buttons: 0}
        w.Sel.Cat := "notDone", w.Sel.Step := "reason"
        S.Page("edit")
        S.ClickDialog(2)                                   ; Cancel
        S.Press("optDel", "notDone", "reason", "r4")
        S.Chk("real dialog: Cancel keeps the option", AdminModel.Find(m.Options("notDone", "reason"), "r4") is Map, w.LastDialog.Text)
        S.Chk("real dialog: it listed the references", InStr(w.LastDialog.Text, "Flag"), w.LastDialog.Text)
        S.Chk("real dialog: two buttons", w.LastDialog.Buttons = 2, w.LastDialog.Buttons)
        S.ClickDialog(1)                                   ; Delete and remove those references
        S.Press("optDel", "notDone", "reason", "r4")
        S.Chk("real dialog: the first button removes the option and its references", !(AdminModel.Find(m.Options("notDone", "reason"), "r4") is Map))
        S.Page("categories")
        S.ClickDialog(1, "wrong")
        S.Press("catDel", "billing")
        S.Chk("real dialog: a wrong typed name removes nothing", m.Cat("billing") is Map)
        S.ClickDialog(1, "Billing")
        S.Press("catDel", "billing")
        S.Chk("real dialog: the typed name removes the system category", !(m.Cat("billing") is Map))
        S.Chk("real dialog: the typed-confirmation text mentions History", InStr(w.LastDialog.Text, "History entries"), w.LastDialog.Text)
        S.Page("categories")
        S.Press("catRestore", "billing")
        S.Chk("real dialog: restored", m.Cat("billing") is Map && m.Validate().Ok)
        w.AutoAsk := saved
        lg.Info("selftest realDialogs", {title: w.LastDialog.Title, buttons: w.LastDialog.Buttons})
    }

    static TCheckNavigation() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        m.Step("notDone", "orderType")["options"].Push(Map("id", "pwo", "label", "Duplicate", "fragment", ""))
        w.UpdateChrome()
        S.Page("check")
        S.Chk("the check page lists the error", w.CheckItems.Length >= 1 && w.CheckItems[1].Level = "error", w.CheckItems.Length)
        S.Chk("with a readable path", InStr(w.CheckItems[1].Text, "Not Done > Order type"), w.CheckItems[1].Text)
        S.Press("go", 1)
        S.Chk("clicking it opens the step", w.Cur = "edit" && w.Sel.Cat = "notDone" && w.Sel.Step = "orderType", w.Cur "|" w.Sel.Cat "|" w.Sel.Step)
        S.Chk("the header counts the error", InStr(S.Text(w.H.BaseId("showCheck", [])), "1 error"), S.Text(w.H.BaseId("showCheck", [])))
        m.Work["themes"]["presets"][1]["accent"] := "blue"
        w.UpdateChrome()
        S.Page("check")
        found := 0
        for i, it in w.CheckItems
            if (it.Nav.Page = "settings")
                found := i
        S.Chk("a theme error leads to the settings page", found > 0)
        if found {
            S.Press("go", found)
            S.Chk("and goes there", w.Cur = "settings", w.Cur)
        }
        lg.Info("selftest check", {items: w.CheckItems.Length, page: w.Cur})
    }

    static TCloseWithChanges() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        S.Chk("closing a clean window asks nothing", w.OnClosing("selftest") = false)
        S.Page("categories")
        S.SetVal("catLabel", ["notDone"], "Close test")
        S.Say("close", "Cancel")
        r1 := w.OnClosing("selftest")
        S.Chk("Cancel keeps the window open", r1 = true && w.LastAsked.Kind = "close")
        S.Say("close", "Discard")
        r2 := w.OnClosing("selftest")
        S.Chk("Discard lets it close", r2 = false)
        S.Say("close", "Save")
        r3 := w.OnClosing("selftest")
        S.Chk("Save saves, then lets it close", r3 = false && !m.Dirty && S.Disk()["categories"][1]["label"] = "Close test")
        lg.Info("selftest close", {cancelKeepsOpen: r1 ? 1 : 0, discardCloses: r2 ? 0 : 1, saveCloses: r3 ? 0 : 1, asked: w.LastAsked.Kind})
    }

    static TConditions() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "supervisorTc"
        S.Page("edit")
        slot := ["req", "notDone", "supervisorTc", "supervisorNameTc"]
        S.Press("condAdd", slot*)
        c := ConfigJson.Canon(m.GetCond({K: "req", Cat: "notDone", Step: "supervisorTc", Field: "supervisorNameTc"}))
        S.Chk("a clause was added", InStr(c, '"all"') && InStr(c, "reason"), c)
        S.Page("edit")
        S.SetVal("condMode", slot, "any")
        c := ConfigJson.Canon(m.GetCond({K: "req", Cat: "notDone", Step: "supervisorTc", Field: "supervisorNameTc"}))
        S.Chk("the mode was changed to any", InStr(c, '"any"'), c)
        S.Page("edit")
        a2 := slot.Clone()
        a2.Push(2)
        a2.Push("r2")
        S.Press("condOpt", a2*)
        c := ConfigJson.Canon(m.GetCond({K: "req", Cat: "notDone", Step: "supervisorTc", Field: "supervisorNameTc"}))
        S.Chk("an option was ticked", InStr(c, '"r1","r2"'), c)
        ; nested JSON is shown read-only with a JSON box and validated before it is applied
        w.Sel.Step := "contact"
        wslot := ["when", "notDone", "contact", ""]
        m.SetCond({K: "when", Cat: "notDone", Step: "contact"}, Map("any", [Map("all", [Map("step", "reason", "in", ["r1"])])]))
        S.Page("edit")
        S.Chk("a nested condition shows a JSON box", IsObject(S.El(S.Id("condJson", wslot*))))
        S.SetVal("condJson", wslot, '{"step":"nope","in":["a"]}')
        S.Press("condJsonApply", wslot*)
        S.Chk("bad JSON is refused", InStr(ConfigJson.Canon(m.GetCond({K: "when", Cat: "notDone", Step: "contact"})), '"all"') && w.LastError != "", w.LastError)
        S.SetVal("condJson", wslot, '{"step":"reason","in":["r2"]}')
        S.Press("condJsonApply", wslot*)
        S.Chk("valid JSON is applied", ConfigJson.Canon(m.GetCond({K: "when", Cat: "notDone", Step: "contact"})) = '{"in":["r2"],"step":"reason"}')
        lg.Info("selftest conditions", {valid: m.Validate().Ok ? 1 : 0})
    }

    static TStopAndFields() {
        S := AdminSelfTest, w := S.Win, m := w.Model, lg := w.Log
        w.Sel.Cat := "notDone", w.Sel.Step := "supervisorTc"
        S.Page("edit")
        S.Chk("the stop of the No option is drawn", IsObject(S.El(S.Id("stopMsg", "notDone", "supervisorTc", "no"))))
        S.SetVal("stopMsg", ["notDone", "supervisorTc", "no"], "Changed stop message")
        S.Chk("stop message edit", m.Stop("notDone", "supervisorTc", "no")["message"] = "Changed stop message")
        S.Press("stopKeep", "notDone", "supervisorTc", "no", "orderType")
        S.Chk("keepSteps is edited with a check box", !InStr(ConfigJson.Canon(m.Stop("notDone", "supervisorTc", "no")["keepSteps"]), "orderType"))
        S.Page("edit")
        S.SetVal("fieldNewName", ["notDone", "supervisorTc"], "Callback number")
        S.Press("fieldAdd", "notDone", "supervisorTc")
        S.Chk("a field was added", AdminModel.Find(m.Fields("notDone", "supervisorTc"), "callbackNumber") is Map)
        S.Page("edit")
        S.Press("fieldReq", "notDone", "supervisorTc", "callbackNumber")
        S.Chk("the required box works", AdminModel.Find(m.Fields("notDone", "supervisorTc"), "callbackNumber")["required"] = 1)
        S.Page("edit")
        S.Press("fieldDel", "notDone", "supervisorTc", "callbackNumber")
        S.Chk("the field was removed", !(AdminModel.Find(m.Fields("notDone", "supervisorTc"), "callbackNumber") is Map))
        S.Page("edit")
        S.SetVal("flagNewMsg", ["notDone"], "Selftest flag")
        S.Press("flagAdd", "notDone")
        S.Chk("a flag was added", AdminModel.Find(m.Flags("notDone"), "selftestFlag") is Map)
        S.Page("edit")
        S.Press("flagDel", "notDone", "selftestFlag")
        S.Chk("and removed", !(AdminModel.Find(m.Flags("notDone"), "selftestFlag") is Map))
        S.Page("categories")
        S.SetVal("catNewName", [], "Selftest steps")
        S.Press("catAdd")
        S.Chk("a steps category was added", m.Cat("selftestSteps") is Map)
        S.Page("categories")
        S.Say("delCategory", "Remove")
        S.Press("catDel", "selftestSteps")
        S.Chk("and removed after a simple confirm", !(m.Cat("selftestSteps") is Map))
        S.Page("preview")
        S.Chk("the preview page draws", StrLen(S.El("adP_preview").innerHTML) > 500)
        S.Press("pvEntry", "equipment")
        w.RefreshNoteNow()
        S.Chk("a sample equipment entry reaches the note", InStr(w.NoteText(), "Item 1"), w.NoteText())
        S.Press("pvPing", "static", "reply")
        w.RefreshNoteNow()
        S.Chk("a sample ping outcome reaches the note", InStr(w.NoteText(), "10.0.0.2"), w.NoteText())
        cb := S.El(S.Id("unavail"))
        S.Chk("the unavailable toggle exists", IsObject(cb))
        cb.click()
        Sleep(200)
        w.RefreshNoteNow()
        S.Chk("marking the call details unavailable shows the configured text", InStr(w.NoteText(), "[not available]"), w.NoteText())
        cb.click()
        Sleep(200)
        lg.Info("selftest stopFields", {valid: m.Validate().Ok ? 1 : 0, note: StrLen(w.NoteText())})
    }
}
