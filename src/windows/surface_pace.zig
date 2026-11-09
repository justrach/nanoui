//! A Windows surface's frames on the display's beat (`vblank.zig`): an
//! animation is built once a refresh, and pointer moves and wheel turns
//! between refreshes are gathered into the next one (`ui/frame_pace.zig`
//! says when). Where the clock's thread can't be had, the surface's 16 ms
//! timer stands in, as it did before. And `NANOUI_FRAMES=<path>` (or
//! `Surface.recordFrames`): every frame's timings, as macOS logs them
//! (`ui/frame_log.zig`) — build, layout, paint, after_frame, the GPU draw
//! (`encode_ms`) and `Present` (`drawable_wait_ms`).
const std = @import("std");
const w = @import("win32.zig");
const clock = @import("../ui/clock.zig");
const vblank = @import("vblank.zig");
const frame_log = @import("../ui/frame_log.zig");
const Surface = @import("surface.zig").Surface;

pub const tick_timer: usize = 1;

/// The clock, made the first time it is needed; null where its thread
/// can't be had.
fn clockOf(s: *Surface) ?*vblank.Clock {
    if (s.vclock) |c| return c;
    if (s.no_vclock) return null;
    const h = s.window.hwnd orelse return null;
    s.vclock = vblank.Clock.create(s.gpa, h);
    if (s.vclock == null) s.no_vclock = true;
    updateOutput(s);
    return s.vclock;
}

/// Frames on every beat from now: an animation began, or input did.
pub fn startTicking(s: *Surface) void {
    if (s.ticking) return;
    s.ticking = true;
    if (clockOf(s)) |c| {
        s.pace.start();
        c.run(true);
        s.trace("vblank clock on", .{});
        return;
    }
    if (s.window.hwnd) |h| _ = w.SetTimer(h, tick_timer, 16, null);
    s.trace("tick timer on", .{});
}

pub fn stopTicking(s: *Surface) void {
    if (!s.ticking) return;
    s.ticking = false;
    s.pace.stop();
    if (s.vclock) |c| {
        c.run(false);
        s.trace("vblank clock off", .{});
        return;
    }
    if (s.window.hwnd) |h| _ = w.KillTimer(h, tick_timer);
    s.trace("tick timer off", .{});
}

/// A pointer move or a wheel turn: built now, or on the next beat.
pub fn onInput(s: *Surface) void {
    // The fallback timer gathers nothing: each input is its own frame.
    if (clockOf(s) == null) return s.frame();
    switch (s.pace.input(clock.now())) {
        .now => {
            s.frame_kind = .input;
            s.frame();
            startTicking(s);
        },
        .next_beat => {},
    }
}

/// `WM_VBLANK`: the beat's frame, when it has one, and the clock stopped
/// when nothing more is coming.
pub fn onBeat(s: *Surface) void {
    const c = s.vclock orelse return;
    c.consumed();
    if (!s.ticking) return;
    const now = clock.now();
    if (s.pace.beat(now, s.ctx.animating or s.hot_moving)) {
        s.frame_kind = .link;
        s.frame();
        s.frame_kind = .input;
    }
    if (!s.pace.keep(now, s.ctx.animating or s.hot_moving)) stopTicking(s);
}

/// The fallback timer's tick, as it always was.
pub fn onTimer(s: *Surface) void {
    s.frame_kind = .link;
    s.frame();
    s.frame_kind = .input;
    if (!s.ctx.animating) stopTicking(s);
}

/// The monitor the swap chain is on is the one whose blanks are waited
/// for: read again when the window moves or the displays change.
pub fn updateOutput(s: *Surface) void {
    const c = s.vclock orelse return;
    const p = if (s.presenter) |*p| p else return c.setOutput(null);
    c.setOutput(vblank.outputOf(@ptrCast(p.swap)));
}

pub fn deinit(s: *Surface) void {
    if (s.vclock) |c| c.destroy();
    s.vclock = null;
    if (s.frame_log) |*fl| fl.deinit();
    s.frame_log = null;
}

/// `NANOUI_FRAMES=<path>`: the frame log, written to that file.
pub fn openLog(s: *Surface) void {
    var key = std.unicode.utf8ToUtf16LeStringLiteral("NANOUI_FRAMES").*;
    var value: [512]u16 = undefined;
    const n = w.GetEnvironmentVariableW(&key, &value, value.len);
    if (n == 0 or n >= value.len) return;
    var path: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&path, value[0..n]) catch return;
    s.frame_log = frame_log.FrameLog.init(s.gpa, path[0..len]) catch null;
}

/// One frame's record (`frame_log.zig`), when the log is on: its timings
/// from the context, its kind (a beat's, or an input's), the refresh period.
pub fn logFrame(s: *Surface, now: f64, dt: f32, after_frame_ms: f64) void {
    const fl = if (s.frame_log) |*fl| fl else return;
    const c = &s.ctx;
    const interval = if (fl.last_t > 0) @max(0, (now - fl.last_t) * 1000) else 0;
    s.log_index = fl.append(.{
        .t = now,
        .kind = s.frame_kind,
        .interval_ms = interval,
        .duration = s.pace.period,
        .dt = dt,
        .build_ms = c.stats.build_ms,
        .layout_ms = c.stats.layout_ms,
        .paint_ms = c.stats.paint_ms,
        .after_frame_ms = after_frame_ms,
        .drawable_wait_ms = 0,
        .encode_ms = 0,
        .sync = false,
        .nodes = c.stats.nodes,
        .instances = c.stats.instances,
        .atlas_reset = false,
        .animating = c.animating,
    });
    if (!c.animating and !s.ticking) fl.last_t = 0;
}

/// The paint's part of the last record: the GPU's draw and the present.
pub fn logDraw(s: *Surface, draw_ms: f64, present_ms: f64, vsync: bool) void {
    const fl = if (s.frame_log) |*fl| fl else return;
    const idx = s.log_index orelse return;
    fl.setDraw(idx, present_ms, draw_ms, vsync, 0);
    s.log_index = null;
}
