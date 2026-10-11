#Requires AutoHotkey v2.0
#SingleInstance Off          ; Instance.Claim below: a second launch focuses the running window, never replaces it

; NFSAdmin.ahk - the Admin companion (PLAN M10). Edits the shared config (config\config.json beside the program, or the
; folder named in nfsnotes.ini [Config] SharedPath) and saves it through ConfigStore. The main app picks a new revision up at the next
; call boundary. `NFSAdmin.ahk --selftest` drives the window against a throw-away copy of the defaults and exits.

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
#Include %A_ScriptDir%\src\Call\CallSession.ahk
#Include %A_ScriptDir%\src\Workflow\Engine.ahk
#Include %A_ScriptDir%\src\Workflow\Items.ahk
#Include %A_ScriptDir%\src\Net\Ipv4.ahk
#Include %A_ScriptDir%\src\Net\StaticModel.ahk
#Include %A_ScriptDir%\src\Notes\Composer.ahk
#Include %A_ScriptDir%\src\UI\Theme.ahk
#Include %A_ScriptDir%\src\Admin\AdminModel.ahk
#Include %A_ScriptDir%\src\Admin\AdminPreview.ahk
#Include %A_ScriptDir%\src\Admin\AdminUi.ahk
#Include %A_ScriptDir%\src\Admin\AdminPages.ahk
#Include %A_ScriptDir%\src\Admin\AdminSelfTest.ahk
#Include %A_ScriptDir%\src\Admin\AdminWindow.ahk

if !Instance.Claim("NFSAdmin", "NFS Notes - Admin")
    ExitApp()

admin := AdminApp()
admin.Run()