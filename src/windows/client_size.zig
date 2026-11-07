//! The size of a window's client area, as the frame is built for it: read on
//! `WM_SIZE`, `WM_MOVE` and every paint, and worked out again when Windows
//! reports a client area that is not inside the window (a window moved to
//! another monitor can keep the one it had there).
const std = @import("std");
const w = @import("win32.zig");
const Surface = @import("surface.zig").Surface;

/// Reads the window's client size and DPI into the surface; true when
/// either changed. Called on `WM_SIZE`, and again by `paint`: a size
/// message a modal loop swallowed, or one sent while the window was
/// hidden, must not leave the frame (and the swap chain) at a size the
/// window no longer is.
pub fn updateSize(self: *Surface, h: w.HWND) bool {
    var r: w.RECT = .{};
    // A call that failed says nothing about the size: a zeroed rect would
    // become a zeroed surface, and a frame built for nothing is a window
    // that stays blank until something resizes it.
    if (w.GetClientRect(h, &r) == 0) return false;
    // Windows hands back the client area it last worked out, and a window
    // moved to another monitor can keep the one it had there — a client
    // area that is not inside the window at all. Nothing invalidates a
    // region it does not intersect: no WM_PAINT comes, the frame is never
    // built, and the window stays blank until something resizes it. The
    // client area is worked out again here instead, which is exactly the
    // `WM_NCCALCSIZE` a resize sends, with nothing moved.
    if (!clientFits(h, r)) {
        repairClient(self, h, r);
        if (w.GetClientRect(h, &r) == 0) return false;
    }
    const dpi = w.GetDpiForWindow(h);
    const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
    const w_: f32 = @as(f32, @floatFromInt(r.right - r.left)) / scale;
    const h_: f32 = @as(f32, @floatFromInt(r.bottom - r.top)) / scale;
    const changed = w_ != self.size.w or h_ != self.size.h or scale != self.scale;
    // A drag-resize sends WM_SIZE per pixel of movement, and the DPI does
    // not change with the size: only a scale that changed is worth telling
    // the text system about (it would empty the glyph atlas to re-raster
    // every glyph at the new scale).
    if (scale != self.scale) {
        self.scale = scale;
        self.text.setScale(scale);
    }
    self.size = .{ .w = w_, .h = h_ };
    return changed;
}

/// Whether the client area a window reports lies inside the window. True of
/// every window Windows has placed; false when the two disagree — a client
/// area belonging to where the window was, not to where it is.
fn clientFits(h: w.HWND, r: w.RECT) bool {
    var wr: w.RECT = .{};
    if (w.GetWindowRect(h, &wr) == 0) return true;
    // Smaller than the window's frame is all a client area can be; one
    // bigger than the frame cannot be inside it.
    if (r.right - r.left > wr.right - wr.left or r.bottom - r.top > wr.bottom - wr.top) return false;
    // And where it starts: a client area whose corner is outside the window
    // is not the window's, whatever its size.
    var origin: w.POINT = .{};
    if (w.ClientToScreen(h, &origin) == 0) return true;
    return origin.x >= wr.left and origin.x < wr.right and origin.y >= wr.top and origin.y < wr.bottom;
}

/// Has Windows work the client area out again, without moving or resizing
/// the window, and ask for the frame the window needs now. A client area
/// that has been outside the window left no update region to paint, so the
/// invalidation is what gets the first frame back.
fn repairClient(self: *Surface, h: w.HWND, stale: w.RECT) void {
    if (self.repairing) return;
    self.repairing = true;
    defer self.repairing = false;
    _ = w.SetWindowPos(h, null, 0, 0, 0, 0, w.SWP_NOSIZE | w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE | w.SWP_FRAMECHANGED);
    var fresh: w.RECT = .{};
    _ = w.GetClientRect(h, &fresh);
    std.log.warn("nanoui: the client area {d}x{d} was not the window's: worked out again as {d}x{d}", .{
        stale.right - stale.left, stale.bottom - stale.top, fresh.right - fresh.left, fresh.bottom - fresh.top,
    });
    self.size_dirty = true;
    _ = w.InvalidateRect(h, null, 0);
}
