#requires AutoHotkey v2.1-alpha.8

; WinRT library is required. 
#Include <windows>

/** Switching between all the installed keyboard layouts. */
class KeyboardLayout
{
    /** @typedef GUITHREADINFO */
    class GUITHREADINFO {
        cbSize       : u32 := ObjGetDataSize(this)
        flags        : u32
        hwndActive   : uptr
        hwndFocus    : uptr
        hwndCapture  : uptr
        hwndMenuOwner: uptr
        hwndMoveSize : uptr
        hwndCaret    : uptr
        rcCaret      : KeyboardLayout.RECT 
    }
    
    /** @typedef RECT */
    class RECT {
        Left  : i32
        Top   : i32
        Right : i32
        Bottom: i32
    }

    /** @prop {array} KeyboardLayoutList List of current installed keyboard layout(s). */
    static KeyboardLayoutList := []

    /** @prop {Map} KeyboardLayoutList This object stores the next keyboard layout for each keyboard layout. */
    static SwitchTo := Map()

    /** @prop {string} CurrentKeyboardLayout Get the current selected keyboard layout. */
    static CurrentKeyboardLayout => Windows.Globalization.Language.CurrentInputMethodLanguageTag

    /** Retrieve the names of all the installed keyboard layouts. */
    static __New()
    {
        temp := A_Temp "\myTemp.txt"

        if !FileExist(A_ProgramFiles "\PowerShell\7\pwsh.exe")
            RunWait(Format('powershell.exe /C CD {1} `; Get-WinUserLanguageList > {2}', A_Temp, temp),, "Hide")
        else
            RunWait(Format('pwsh /C CD {1} && Get-WinUserLanguageList > {2}', A_Temp, temp),, "Hide")

        output := Trim(FileRead(temp, "`n"), "`n`r ")
        FileDelete(temp)
        RegExReplace(output, "imS)LanguageTag\h*:\h*\K\N+", m => this.KeyboardLayoutList.Push(m[]))

        for i, lp in this.KeyboardLayoutList
            this.SwitchTo[lp] := this.KeyboardLayoutList[i = this.KeyboardLayoutList.Length ? 1 : i+1]
    }

    /**
     * Switching between all the installed keyboard layouts.
     * @param {array} [lanList] The keyboard layout(s) to cycle through. If omitted, it will switch between the currently installed keyboard layouts. 
     * @example
     * RShift::KeyboardLayout()
     * ~RCtrl Up::KeyboardLayout("sr-Cyrl-RS", "en-GB", "es-ES", "zh-Hant-TW")
     * @returns {void} 
     */
    static Call(lanList*)
    {
        static cSwitchList := Map()
        if !cSwitchList.Count && lanList.Length {
            for i, lp in lanList
                cSwitchList[lp] := lanList[i = lanList.Length ? 1 : i+1]
        }

        idThread := DllCall("GetWindowThreadProcessId", "ptr", DllCall("GetForegroundWindow"), "uptr*", &pid := 0)
        lpgui    := this.GetGUIThreadInfo(idThread)
        lpName   := this.CurrentKeyboardLayout
        
        if !lanList.Length {
            if this.SwitchTo.Has(lpName)
                lpNameTo := this.SwitchTo[lpName]
            else if !this.SwitchTo.Has(lpName := this._ResolveLocaleName(this.CurrentKeyboardLayout))
                return MsgBox("Language Name Not Match: " lpName, A_ThisFunc)
        } else {
            for i, lp in lanList {
                if (lpName = lp) {
                    lpNameTo := lanList[i = lanList.Length ? 1 : i+1]
                    break
                }
            }
        }
        
        LCID := DllCall("LocaleNameToLCID", "ptr", StrPtr(lpNameTo), "uint", 0, "uint")

        DetectHiddenWindows(true)
        for hwnd in [0xFFFF, lpgui.hwndCaret, lpgui.hwndFocus, "ahk_pid" idThread]
            try PostMessage(0x50,, LCID,, hwnd)
    }

    static LCIDToLocaleName(Locale, lpName := 0, cchName := 0, dwFlags := 0) => DllCall("LCIDToLocaleName", "UInt", Locale >> 16, "Ptr", lpName, "UInt", cchName, "UInt", dwFlags)

    static GetGUIThreadInfo(idThread) => (DllCall("GetGUIThreadInfo", "uint", idThread, this.GUITHREADINFO, lpgui := this.GUITHREADINFO()), lpgui)

    static _ResolveLocaleName(lpNameToResolve) {
        static len := 85
        DllCall("ResolveLocaleName", "ptr", StrPtr(lpNameToResolve), "ptr", lpLocaleName := Buffer(len, 0), "int", len, "int")
        return StrGet(lpLocaleName)
    }
}
