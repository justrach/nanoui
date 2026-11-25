//! The display under a Windows window (`Surface.displayInfo`,
//! `Surface.on_display_change`) and what its swap chain shows its pixels as
//! (`Surface.setColour`: BGRA8 sRGB, or half-float scRGB on an HDR output,
//! `d3d.zig`'s `setExtended`). The switch is made where a frame is painted,
//! before it takes a back buffer (`surface_gpu.zig`).
const std = @import("std");
const w = @import("win32.zig");
const gpu = @import("../ui/gpu.zig");
const Surface = @import("surface.zig").Surface;

pub const SyncAction = enum { none, set_extended, set_sdr };

/// Swap-chain format adjustment needed for a pending colour/display transition.
pub fn syncAction(requested: gpu.SurfaceColour, extended: bool, dirty: bool, hdr_output: bool) SyncAction {
    if (!dirty) return .none;
    const want = requested == .extended_linear;
    if (want and !extended) return .set_extended;
    if (!want and extended) return .set_sdr;
    if (extended and !hdr_output) return .set_sdr;
    return .none;
}

/// Shows the window's pixels as `c` (`ui.SurfaceColour`) from the next
/// painted frame: `.extended_linear` only where the output is HDR and the
/// window draws with Direct3D 11 (an opaque window); elsewhere it stays
/// SDR, as `Context.surface_colour` then says.
pub fn setColour(self: *Surface, c: gpu.SurfaceColour) !void {
    if (self.colour == c) return;
    self.colour = c;
    self.colour_dirty = true;
    self.ctx.changed = true;
    self.requestFrame();
}

/// What the display under the window can show, read now (an SDR display's
/// defaults before the window has a swap chain).
pub fn displayInfo(self: *Surface) gpu.DisplayInfo {
    if (self.presenter) |*p| self.display_info = p.displayInfo();
    return self.display_info;
}

/// What the surface shows as of now: the swap chain's format.
pub fn shownColour(self: *const Surface) gpu.SurfaceColour {
    if (self.presenter) |p| if (p.extended) return .extended_linear;
    return .sdr_srgb;
}

/// The display changed (`WM_DISPLAYCHANGE`), or the window may be on
/// another monitor (`WM_MOVE`: only when `MonitorFromWindow` says so):
/// read it again and tell the app.
pub fn displayChanged(self: *Surface, h: w.HWND, moved: bool) void {
    const mon = w.MonitorFromWindow(h, 2);
    if (moved and mon == self.monitor) return;
    self.monitor = mon;
    self.colour_dirty = true;
    _ = displayInfo(self);
    if (self.on_display_change) |cb| cb.func(cb.ctx, self);
    self.requestFrame();
}

test "syncAction gates setExtended retries until colour or display changes" {
    const testing = std.testing;
    // Steady state on an SDR monitor after a failed attempt (`dirty = false`): no retry.
    try testing.expectEqual(SyncAction.none, syncAction(.extended_linear, false, false, false));
    try testing.expectEqual(SyncAction.none, syncAction(.sdr_srgb, false, false, false));
    // Initial request / monitor change onto HDR asks to enable extended scRGB.
    try testing.expectEqual(SyncAction.set_extended, syncAction(.extended_linear, false, true, false));
    try testing.expectEqual(SyncAction.set_extended, syncAction(.extended_linear, false, true, true));
    // Extended surface moved to an SDR monitor (or HDR disabled) steps back to sRGB.
    try testing.expectEqual(SyncAction.set_sdr, syncAction(.extended_linear, true, true, false));
    // Staying extended on an HDR monitor needs no switch.
    try testing.expectEqual(SyncAction.none, syncAction(.extended_linear, true, true, true));
    // Explicit switch back to SDR steps down.
    try testing.expectEqual(SyncAction.set_sdr, syncAction(.sdr_srgb, true, true, true));
}
