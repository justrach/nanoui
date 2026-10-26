//! The macOS display link's rate and visibility, outside the surface lifecycle.
const std = @import("std");
const objc = @import("../objc.zig");
const pacing = @import("pacing.zig");

/// The display link's pace: the display's (null), or one frame every
/// `seconds`.
pub fn setRate(self: anytype, seconds: ?f32) void {
    const link = self.display_link orelse return;
    const fps: f32 = if (seconds) |s| std.math.clamp(1 / @max(s, 0.001), 1, 60) else 0;
    if (fps == self.link_fps) return;
    self.link_fps = fps;
    // The display's own pace is the screen's fastest: 120 on ProMotion.
    const screen = objc.msg(?objc.Object, self.window.nswindow, "screen", .{});
    const max: f32 = if (screen) |sc| @floatFromInt(objc.msg(isize, sc, "maximumFramesPerSecond", .{})) else 0;
    objc.msg(void, link, "setPreferredFrameRateRange:", .{pacing.range(fps, max)});
}

pub fn visible(self: anytype) bool {
    return objc.msg(objc.NSUInteger, self.window.nswindow, "occlusionState", .{}) & 2 != 0;
}
