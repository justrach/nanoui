//! The display under a Windows window (`Surface.displayInfo`,
//! `Surface.on_display_change`) and what its swap chain shows its pixels as
//! (`Surface.setColour`: BGRA8 sRGB, or half-float scRGB on an HDR output,
//! `d3d.zig`'s `setExtended`). The switch is made where a frame is painted,
//! before it takes a back buffer (`surface_gpu.zig`).
const std = @import("std");
const w = @import("win32.zig");
const gpu = @import("../ui/gpu.zig");
const Surface = @import("surface.zig").Surface;

/// Shows the window's pixels as `c` (`ui.SurfaceColour`) from the next
/// painted frame: `.extended_linear` only where the output is HDR and the
/// window draws with Direct3D 11 (an opaque window); elsewhere it stays
/// SDR, as `Context.surface_colour` then says.
pub fn setColour(self: *Surface, c: gpu.SurfaceColour) !void {
    if (self.colour == c) return;
    self.colour = c;
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
    _ = displayInfo(self);
    if (self.on_display_change) |cb| cb.func(cb.ctx, self);
    self.requestFrame();
}
