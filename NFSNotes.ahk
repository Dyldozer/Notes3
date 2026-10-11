#Requires AutoHotkey v2.0
#SingleInstance Off          ; Instance.Claim below: a second launch focuses the running window, never replaces it

#Include %A_ScriptDir%\Gui visual Library\lib\AxGui.ahk
#Include %A_ScriptDir%\src\Core\Util.ahk
#Include %A_ScriptDir%\src\Core\Instance.ahk
#Include %A_ScriptDir%\src\Core\Log.ahk
#Include %A_ScriptDir%\src\Config\ConfigJson.ahk
#Include %A_ScriptDir%\src\Config\Defaults.ahk
#Include %A_ScriptDir%\src\Config\Schema.ahk
#Include %A_ScriptDir%\src\Config\ConfigStore.ahk
#Include %A_ScriptDir%\src\Config\Settings.ahk
#Include %A_ScriptDir%\src\Context\CallContext.ahk
#Include %A_ScriptDir%\src\Context\Provider.ahk
#Include %A_ScriptDir%\src\Context\MockProvider.ahk
#Include %A_ScriptDir%\src\Call\CallSession.ahk
#Include %A_ScriptDir%\src\Call\CallStats.ahk
#Include %A_ScriptDir%\src\Workflow\Engine.ahk
#Include %A_ScriptDir%\src\Workflow\Items.ahk
#Include %A_ScriptDir%\src\Net\Ipv4.ahk
#Include %A_ScriptDir%\src\Net\StaticModel.ahk
#Include %A_ScriptDir%\src\Net\Pinger.ahk
#Include %A_ScriptDir%\src\Notes\Composer.ahk
#Include %A_ScriptDir%\src\Notes\Clipboard.ahk
#Include %A_ScriptDir%\src\Call\History.ahk
#Include %A_ScriptDir%\src\UI\Theme.ahk
#Include %A_ScriptDir%\src\UI\Views\DevPanel.ahk
#Include %A_ScriptDir%\src\UI\Views\HistoryPanel.ahk
#Include %A_ScriptDir%\src\UI\Views\StepsView.ahk
#Include %A_ScriptDir%\src\UI\Views\ItemsView.ahk
#Include %A_ScriptDir%\src\UI\Views\StaticView.ahk
#Include %A_ScriptDir%\src\UI\Views\SettingsView.ahk
#Include %A_ScriptDir%\src\UI\ThemeSelfTest.ahk
#Include %A_ScriptDir%\src\UI\MainWindow.ahk
#Include %A_ScriptDir%\src\Core\App.ahk

if !Instance.Claim("NFSNotes", "NFS Notes - Tech Assist")
    ExitApp()

app := NFSApp()
app.Run()
