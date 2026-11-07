//! The native caption's colors, following the system's light or dark mode:
//! DWM draws the title bar dark when asked to, and leaves it light otherwise.
const w = @import("win32.zig");

/// The attribute, Windows 10 1903's number for it; 1809 knows the same one as
/// 19, so that is tried where this one isn't taken.
const immersive_dark_mode: u32 = 20;
const immersive_dark_mode_1809: u32 = 19;

/// Makes the window's title bar follow the system's appearance.
pub fn followSystem(hwnd: w.HWND) void {
    var dark: w.BOOL = @intFromBool(@import("desktop.zig").isDark());
    if (w.DwmSetWindowAttribute(hwnd, immersive_dark_mode, &dark, @sizeOf(w.BOOL)) == 0) return;
    _ = w.DwmSetWindowAttribute(hwnd, immersive_dark_mode_1809, &dark, @sizeOf(w.BOOL));
}
