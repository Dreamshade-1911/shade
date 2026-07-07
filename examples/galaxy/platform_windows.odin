package main;

import "core:os";
import win32 "core:sys/windows";


@(init) windows_init :: proc "contextless" () {
    win32.timeBeginPeriod(1);
}

@(fini) windows_fini :: proc "contextless" () {
    win32.timeEndPeriod(1);
}

// Just so you can see any errors on the console.
attach_parent_console :: proc() {
    ATTACH_PARENT_PROCESS :: ~win32.DWORD(0);
    if !win32.AttachConsole(ATTACH_PARENT_PROCESS) {
        return; // No parent console.
    }

    reopen :: proc(std_handle: win32.DWORD, device: string, name: string) -> ^os.File {
        h := win32.GetStdHandle(std_handle);
        if h == nil || h == win32.INVALID_HANDLE_VALUE {
            access: win32.DWORD = win32.GENERIC_READ | win32.GENERIC_WRITE;
            share:  win32.DWORD = win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE;
            h = win32.CreateFileW(
                win32.utf8_to_wstring(device),
                access, share, nil, win32.OPEN_EXISTING, 0, nil,
            );
            if h == win32.INVALID_HANDLE_VALUE do return nil;
        }
        return os.new_file(uintptr(h), name);
    }

    if f := reopen(win32.STD_OUTPUT_HANDLE, "CONOUT$", "<stdout>"); f != nil do os.stdout = f;
    if f := reopen(win32.STD_ERROR_HANDLE,  "CONOUT$", "<stderr>"); f != nil do os.stderr = f;
    if f := reopen(win32.STD_INPUT_HANDLE,  "CONIN$",  "<stdin>");  f != nil do os.stdin  = f;
}
