#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; RunTests.ahk - headless logic tests. Writes tests\results.txt, exits with the fail count.
; Run: AutoHotkey64.exe /ErrorStdOut tests\RunTests.ahk

#Include %A_ScriptDir%\TestLib.ahk
#Include %A_ScriptDir%\..\src\Core\Util.ahk
#Include %A_ScriptDir%\..\src\Core\Log.ahk
#Include %A_ScriptDir%\..\src\Config\ConfigJson.ahk
#Include %A_ScriptDir%\..\src\Config\Defaults.ahk
#Include %A_ScriptDir%\..\src\Config\Schema.ahk
#Include %A_ScriptDir%\..\src\Config\ConfigStore.ahk
#Include %A_ScriptDir%\..\src\Config\Settings.ahk
#Include %A_ScriptDir%\..\src\Context\CallContext.ahk
#Include %A_ScriptDir%\..\src\Context\Provider.ahk
#Include %A_ScriptDir%\..\src\Context\MockProvider.ahk
#Include %A_ScriptDir%\..\src\Call\CallSession.ahk
#Include %A_ScriptDir%\..\src\Call\CallStats.ahk
#Include %A_ScriptDir%\..\src\Workflow\Engine.ahk
#Include %A_ScriptDir%\..\src\Workflow\Items.ahk
#Include %A_ScriptDir%\..\src\Net\Ipv4.ahk
#Include %A_ScriptDir%\..\src\Net\StaticModel.ahk
#Include %A_ScriptDir%\..\src\Net\Pinger.ahk
#Include %A_ScriptDir%\..\src\Notes\Composer.ahk
#Include %A_ScriptDir%\..\src\Notes\Clipboard.ahk
#Include %A_ScriptDir%\..\src\Call\History.ahk
#Include %A_ScriptDir%\..\src\UI\Theme.ahk
#Include %A_ScriptDir%\..\src\Core\App.ahk
#Include %A_ScriptDir%\..\src\Admin\AdminModel.ahk
#Include %A_ScriptDir%\..\src\Admin\AdminPreview.ahk
#Include %A_ScriptDir%\TestUtil.ahk
#Include %A_ScriptDir%\TestLog.ahk
#Include %A_ScriptDir%\TestDefaults.ahk
#Include %A_ScriptDir%\TestSchema.ahk
#Include %A_ScriptDir%\TestConfigStore.ahk
#Include %A_ScriptDir%\TestSettings.ahk
#Include %A_ScriptDir%\TestTheme.ahk
#Include %A_ScriptDir%\TestCallContext.ahk
#Include %A_ScriptDir%\TestMockProvider.ahk
#Include %A_ScriptDir%\TestCallSession.ahk
#Include %A_ScriptDir%\TestCallStats.ahk
#Include %A_ScriptDir%\TestComposer.ahk
#Include %A_ScriptDir%\TestClipboard.ahk
#Include %A_ScriptDir%\TestHistory.ahk
#Include %A_ScriptDir%\TestEngine.ahk
#Include %A_ScriptDir%\TestStepsNotes.ahk
#Include %A_ScriptDir%\TestItems.ahk
#Include %A_ScriptDir%\TestIpv4.ahk
#Include %A_ScriptDir%\TestStatic.ahk
#Include %A_ScriptDir%\TestPinger.ahk
#Include %A_ScriptDir%\TestAdminModel.ahk

ResultsPath := A_ScriptDir "\results.txt"

OnError(CrashHandler)
CrashHandler(e, mode) {
    T.Record(false, "unhandled error", e.Message " (line " e.Line ", " e.What ")")
    Finish()
    return 1
}

Finish() {
    global ResultsPath
    try FileDelete(ResultsPath)
    FileAppend(T.Report(), ResultsPath, "UTF-8-RAW")
    ExitApp(T.Fail)
}

for suite in [TestUtil, TestLog, TestDefaults, TestSchema, TestConfigStore, TestSettings, TestTheme,
        TestCallContext, TestMockProvider, TestCallSession, TestCallStats, TestComposer, TestClipboard, TestHistory, TestEngine, TestStepsNotes, TestItems, TestIpv4, TestStatic, TestPinger, TestAdminModel] {
    T.Suite := suite.Name
    suite.Run()
}
T.Suite := ""
Finish()
