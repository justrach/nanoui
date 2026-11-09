//! The macOS surface's pace: the display link's frame-rate cap, an app's
//! (`Surface.setFpsCap`) under the screen's own maximum.
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;

pub fn updateMaxFps(self: *Surface) void {
    const screen = objc.msg(?objc.Object, self.window.nswindow, "screen", .{});
    const screen_fps: f32 = if (screen) |sc| @floatFromInt(@max(60, objc.msg(objc.NSInteger, sc, "maximumFramesPerSecond", .{}))) else 60;
    const fps = if (self.fps_cap > 0) @min(self.fps_cap, screen_fps) else screen_fps;
    if (fps != self.max_fps) {
        self.max_fps = fps;
        const cur = self.link_fps;
        self.link_fps = -1;
        if (cur >= 0) self.setRate(if (cur == 0) null else 1 / cur);
    }
}

/// Caps the display link's pace at `fps` (0 lifts the cap).
pub fn setFpsCap(self: *Surface, fps: f32) void {
    self.fps_cap = fps;
    self.updateMaxFps();
}
