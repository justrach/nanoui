//! The Win32 functions nanoui calls, declared directly (no headers): user32
//! for windows, input, timers and the clipboard, gdi32 to show frames,
//! kernel32, shell32 and comdlg32. Zig's own import libraries link them.
const std = @import("std");

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HDC = *opaque {};
pub const HCURSOR = *opaque {};
pub const BOOL = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const WNDPROC = *const fn (hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
pub const TIMERPROC = *const fn (hwnd: ?HWND, msg: u32, id: usize, time: u32) callconv(.winapi) void;

pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
pub const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT, private: u32 = 0 };
pub const PAINTSTRUCT = extern struct { hdc: HDC, erase: BOOL, rc: RECT, restore: BOOL, inc_update: BOOL, reserved: [32]u8 };
pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
pub const TRACKMOUSEEVENT = extern struct { cbSize: u32 = @sizeOf(TRACKMOUSEEVENT), dwFlags: u32, hwndTrack: HWND, dwHoverTime: u32 = 0 };
pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

pub extern "user32" fn RegisterClassExW(wc: *const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn SetFocus(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: u32, max: u32, remove: u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, w: i32, h: i32, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
pub extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: u32, menu: BOOL, ex: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(e: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, p: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(vk: i32) callconv(.winapi) i16;
pub extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?TIMERPROC) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
pub extern "user32" fn OpenClipboard(hwnd: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(format: u32, mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn SetDIBitsToDevice(hdc: HDC, x: i32, y: i32, w: u32, h: u32, sx: i32, sy: i32, start: u32, lines: u32, bits: *const anyopaque, info: *const BITMAPINFOHEADER, usage: u32) callconv(.winapi) i32;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(mem: *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: *anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, op: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: i32) callconv(.winapi) ?*anyopaque;
pub extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
/// Reads a value from the registry: the system's light/dark preference lives
/// under HKCU. `HKEY_CURRENT_USER` is 0x80000001; the rest are constants
/// `RegGetValueW` needs.
pub extern "advapi32" fn RegGetValueW(hkey: usize, sub_key: [*:0]const u16, value: ?[*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, bytes: ?*u32) callconv(.winapi) i32;
pub const HKEY_CURRENT_USER: usize = 0x80000001;
/// RRF_RT_REG_DWORD: the value is read as a DWORD, whatever else the key holds.
pub const RRF_RT_REG_DWORD = 0x00000010;

// Messages.
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
/// A system setting changed: the appearance, among others.
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_SETFOCUS = 0x0007;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_KEYDOWN = 0x0100;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_TIMER = 0x0113;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const CS_DBLCLKS = 0x0008;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const GWLP_USERDATA = -21;

/// UTF-16 of `s`, null-terminated, in `buf` (truncated to fit).
pub fn wide(buf: []u16, s: []const u8) [*:0]const u16 {
    // A UTF-8 byte makes at most one UTF-16 unit.
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s[0..@min(s.len, buf.len - 1)]) catch 0;
    buf[@min(n, buf.len - 1)] = 0;
    return @ptrCast(buf.ptr);
}
