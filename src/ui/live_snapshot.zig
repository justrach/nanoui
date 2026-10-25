//! A running window's frame written to a PNG when asked: with
//! NANOUI_LIVE_SNAPSHOT=PATH set, creating PATH.request makes the next
//! check (each second) draw the window's frame offscreen, from the GPU
//! state the window draws with (its glyph atlas, its pictures), to PATH.
//! For seeing a running app without capturing the screen. What the request
//! file says, if anything, the view gets as `Context.snapshot_request` for
//! that frame alone, which is drawn offscreen and not shown.
const std = @import("std");
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;
const cf = @import("cf.zig");
const frame_mod = @import("frame.zig");

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
    // What it asks for, if anything: the view shows that in the frame drawn
    // here, which isn't put on screen.
    var asked: [256]u8 = undefined;
    const n = readAll(request, &asked);
    _ = std.c.unlink(request);
    const what = std.mem.trim(u8, asked[0..n], " \n\r\t");
    if (what.len == 0) {
        s.frame();
    } else {
        s.ctx.snapshot_request = what;
        defer s.ctx.snapshot_request = "";
        const t = cf.CACurrentMediaTime();
        _ = frame_mod.run(&s.ctx, s.view, &s.text, &s.instances, s.size, s.scale, s.theme(), 1.0 / 60.0, t - s.start_time);
        s.renderer.syncImages(&s.text.images);
        s.renderer.textures = s.ctx.textures.items;
    }
    const pixels = s.renderer.drawOffscreen(s.gpa, s.instances.items, s.atlasTexture(), s.size, s.scale, s.ctx.theme.background) catch return;
    defer pixels.deinit(s.gpa);
    @import("image.zig").writePng(path, pixels) catch {};
    // Back to what the window shows.
    if (what.len > 0) s.frame();
}

fn readAll(path: [*:0]const u8, buf: []u8) usize {
    const fd = std.c.open(path, .{}, @as(std.c.mode_t, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    return if (n > 0) @intCast(n) else 0;
}
