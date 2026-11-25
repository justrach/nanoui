//! The display under an iOS/iPadOS surface (`Surface.displayInfo`,
//! `Surface.on_display_change`) and what its Metal layer shows its pixels as
//! (`Surface.setColour`: SDR, or extended linear light for EDR).
const std = @import("std");
const objc = @import("../objc.zig");
const gpu = @import("../ui/gpu.zig");
const Surface = @import("surface.zig").Surface;

/// Shows the layer's pixels as `c` (`ui.SurfaceColour`): `.extended_linear`
/// switches the Metal layer to RGBA16Float extended-linear sRGB and enables EDR.
pub fn setColour(self: *Surface, c: gpu.SurfaceColour) !void {
    if (self.renderer.colour == c) return;
    try self.renderer.setColour(c);
    self.readDisplay();
    self.ctx.changed = true;
    self.requestFrame();
}

/// What the display under the view can show, read now.
pub fn displayInfo(self: *Surface) gpu.DisplayInfo {
    self.readDisplay();
    return self.display_info;
}

/// Pure conversion from `UIScreen` headroom and P3 gamut support to `DisplayInfo`.
/// UIKit defines 1.0 as SDR white, matching macOS's 100-nit baseline.
pub fn displayInfoOf(edr_now: f64, edr_potential: f64, p3: bool) gpu.DisplayInfo {
    const potential: f32 = @floatCast(@max(1, edr_potential));
    return .{
        .headroom_now = @floatCast(@max(1, edr_now)),
        .headroom_potential = potential,
        .sdr_white_nits = 100,
        .max_nits = 100 * potential,
        .hdr_output = potential > 1,
        .wide_gamut = p3,
        .sdr_white_scale = 1,
    };
}

fn screenOf(self: *const Surface) ?objc.Object {
    if (objc.msg(?objc.Object, self.uiview, "window", .{})) |win| {
        if (objc.msg(?objc.Object, win, "screen", .{})) |sc| return sc;
    }
    return objc.msg(?objc.Object, objc.class("UIScreen"), "mainScreen", .{});
}

/// Updates `display_info` from the view's `UIScreen` and trait gamut.
pub fn readDisplay(self: *Surface) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const sc = screenOf(self) orelse return;
    var edr_now: f64 = 1;
    var edr_potential: f64 = 1;
    if (objc.msg(objc.BOOL, sc, "respondsToSelector:", .{objc.sel("currentEDRHeadroom")}))
        edr_now = @max(1, objc.msg(f64, sc, "currentEDRHeadroom", .{}));
    if (objc.msg(objc.BOOL, sc, "respondsToSelector:", .{objc.sel("potentialEDRHeadroom")}))
        edr_potential = @max(1, objc.msg(f64, sc, "potentialEDRHeadroom", .{}));
    const traits = objc.msg(objc.Object, self.uiview, "traitCollection", .{});
    // UIDisplayGamutP3 == 1.
    const p3 = objc.msg(objc.NSInteger, traits, "displayGamut", .{}) == 1;
    self.display_info = displayInfoOf(edr_now, edr_potential, p3);
}

/// Refreshes display info after screen, trait, or foreground changes and notifies `on_display_change`.
pub fn displayChanged(self: *Surface) void {
    const prev = self.display_info;
    readDisplay(self);
    if (!std.meta.eql(prev, self.display_info)) {
        if (self.on_display_change) |cb| cb.func(cb.ctx, self);
        self.ctx.changed = true;
    }
}

test "iOS EDR DisplayInfo derives hdr_output and max_nits from headroom and P3" {
    const testing = std.testing;
    const hdr = displayInfoOf(2.5, 8.0, true);
    try testing.expect(hdr.hdr_output);
    try testing.expect(hdr.wide_gamut);
    try testing.expect(hdr.hasHeadroom());
    try testing.expectEqual(@as(f32, 2.5), hdr.headroom_now);
    try testing.expectEqual(@as(f32, 8.0), hdr.headroom_potential);
    try testing.expectEqual(@as(f32, 800), hdr.max_nits);
    try testing.expectEqual(@as(f32, 1), hdr.sdr_white_scale);

    const sdr = displayInfoOf(1.0, 1.0, false);
    try testing.expect(!sdr.hdr_output);
    try testing.expect(!sdr.wide_gamut);
    try testing.expect(!sdr.hasHeadroom());
    try testing.expectEqual(@as(f32, 100), sdr.max_nits);
}
