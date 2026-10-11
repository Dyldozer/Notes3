#Requires AutoHotkey v2.0
#NoTrayIcon
; ExportDefaults.ahk - writes config\config.default.json from Defaults.Config().
; Run: AutoHotkey64.exe tools\ExportDefaults.ahk   (the TestDefaults suite fails if the file drifts)

#Include %A_ScriptDir%\..\src\Core\Util.ahk
#Include %A_ScriptDir%\..\src\Config\ConfigJson.ahk
#Include %A_ScriptDir%\..\src\Config\Defaults.ahk
#Include %A_ScriptDir%\..\src\Config\Schema.ahk

target := A_ScriptDir "\..\config\config.default.json"
cfg := Defaults.Config()
v := Schema.Validate(cfg)
if !v.Ok {
    FileAppend("Built-in defaults are invalid: " Schema.Summary(v) "`n", "*")
    ExitApp(1)
}
Util.AtomicWrite(target, ConfigJson.Stringify(cfg) "`n")
FileAppend("Wrote " target "`n", "*")
