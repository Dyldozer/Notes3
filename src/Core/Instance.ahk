#Requires AutoHotkey v2.0
; Instance.ahk - one normal copy per user, without ever closing a running window.
;
; The entry scripts use #SingleInstance Off and call Instance.Claim instead. A second normal launch brings the running
; window to the front and exits (the agent's call in progress is never lost, which #SingleInstance Force would do). A
; --selftest run never takes the lock and never touches a running copy: it runs alongside it on its own temp folders.

class Instance {
    static _mutex := 0

    ; True when this process may run. name: the mutex name; winTitle: the start of the main window's title.
    static Claim(name, winTitle) {
        for a in A_Args
            if (a = "--selftest")
                return true
        h := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", 0, "str", "Local\" name "_" A_UserName, "ptr")
        if (h && A_LastError != 183)                  ; 183 = ERROR_ALREADY_EXISTS
            return (Instance._mutex := h) != 0
        if h
            DllCall("kernel32\CloseHandle", "ptr", h)
        Instance.ActivateOther(winTitle)
        return false
    }

    ; Bring the other process's window with this title to the front (restoring it if minimised).
    static ActivateOther(winTitle) {
        prev := A_TitleMatchMode, prevHidden := A_DetectHiddenWindows
        SetTitleMatchMode(1)
        try {
            for hwnd in WinGetList(winTitle " ahk_exe AutoHotkey64.exe") {
                if (WinGetPID(hwnd) = DllCall("kernel32\GetCurrentProcessId"))
                    continue
                if (WinGetMinMax(hwnd) = -1)
                    WinRestore(hwnd)
                WinActivate(hwnd)
                break
            }
        }
        SetTitleMatchMode(prev)
        DetectHiddenWindows(prevHidden)
    }
}
