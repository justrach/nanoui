//! The display under a macOS window (`Surface.displayInfo`,
//! `Surface.on_display_change`) and what its surface shows its pixels as
//! (`Surface.setColour`: SDR, or extended linear light for EDR).
const std = @import("std");
const gpu = @import("gpu.zig");
const screens = @import("../screens.zig");
const Surface = @import("surface.zig").Surface;

/// Shows the window's pixels as `c` (`ui.SurfaceColour`). With
/// `.extended_linear` the layer becomes RGBA16Float and extended-linear
/// sRGB and wants EDR; the UI is still drawn in 8-bit sRGB and composed,
/// decoded, with the `.surface_linear` textures the frame shows, which
/// keep values above SDR white. The switch lands at a frame boundary: a
/// frame already given a drawable is drawn for the format it has. A
/// frame is asked for. On any screen (an SDR one shows extended content
/// clipped at white), so an app checks `displayInfo` first.
pub fn setColour(self: *Surface, c: gpu.SurfaceColour) !void {
    if (self.renderer.colour == c) return;
    try self.renderer.setColour(c);
    // EDR asked for: the screen's headroom now is what it gives.
    self.readDisplay();
    self.ctx.changed = true;
    self.requestFrame();
}

/// What the display under the window can show, read now.
pub fn displayInfo(self: *Surface) gpu.DisplayInfo {
    self.readDisplay();
    return self.display_info;
}

/// `display_info` from the window's screen (unchanged when it is on
/// none).
pub fn readDisplay(self: *Surface) void {
    const sc = screens.ofWindow(self.window.nswindow) orelse return;
    self.display_info = displayInfoOf(sc);
}

/// The display under a window (`screens.Screen`) as `DisplayInfo`: EDR's
/// 1.0 is SDR white, taken as 100 nits (macOS does not say).
pub fn displayInfoOf(sc: screens.Screen) gpu.DisplayInfo {
    const potential: f32 = @floatCast(@max(1, sc.edr_potential));
    return .{
        .headroom_now = @floatCast(@max(1, sc.edr_now)),
        .headroom_potential = potential,
        .sdr_white_nits = 100,
        .max_nits = 100 * potential,
        .hdr_output = potential > 1,
        .wide_gamut = sc.p3,
        .sdr_white_scale = 1,
    };
}

/// The display under the window changed (`nanouiDisplayChanged:`).
pub fn displayChanged(self: *Surface) void {
    self.readDisplay();
    if (self.on_display_change) |cb| cb.func(cb.ctx, self);
    self.ctx.changed = true;
    self.requestFrame();
}
