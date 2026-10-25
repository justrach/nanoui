//! A running window's frame written to a PNG when asked: with
//! NANOUI_LIVE_SNAPSHOT=PATH set, creating PATH.request makes the next
//! check (each second) draw the window's frame offscreen, from the GPU
//! state the window draws with (its glyph atlas, its pictures), to PATH.
//! For seeing a running app without capturing the screen.
const std = @import("std");
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;

/// The checking timer, when asked for (it retains the view: invalidate it).
pub fn start(nsview: objc.Object) ?objc.Object {
    if (std.c.getenv("NANOUI_LIVE_SNAPSHOT") == null) return null;
    return objc.retain(objc.msg(objc.Object, objc.class("NSTimer"), "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{
        @as(f64, 1.0), nsview, objc.sel("liveSnapshotTick:"), @as(?objc.Object, null), objc.YES,
    }));
}

pub fn tick(s: *Surface) void {
    const path = std.mem.span(std.c.getenv("NANOUI_LIVE_SNAPSHOT") orelse return);
    var buf: [1024]u8 = undefined;
    const request = std.fmt.bufPrintSentinel(&buf, "{s}.request", .{path}, 0) catch return;
    if (std.c.access(request, 0) != 0) return;
    _ = std.c.unlink(request);
    s.frame();
    const pixels = s.renderer.drawOffscreen(s.gpa, s.instances.items, s.atlasTexture(), s.size, s.scale, s.ctx.theme.background) catch return;
    defer pixels.deinit(s.gpa);
    @import("image.zig").writePng(path, pixels) catch {};
}
