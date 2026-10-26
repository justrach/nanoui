//! Frames on the display's beat (macOS, iOS): what scrolling gathers between
//! refreshes, how fast to ask the display link to run, and a log of when
//! frames ran (`NANOUI_FRAME_LOG=FILE`) to check a real scroll's pace.
const std = @import("std");
const builtin = @import("builtin");

/// How long the link keeps running after the last scroll event: a
/// trackpad's events come unevenly, and a link started cold misses a beat.
pub const linger: f64 = 0.15;

/// Scrolling gathered since the last frame: every event's delta, applied
/// at once by the next frame on the display link.
pub const Scroll = struct {
    dy: f32 = 0,
    until: f64 = 0,

    pub fn add(s: *Scroll, dy: f32, now: f64) void {
        s.dy += dy;
        s.until = now + linger;
    }

    /// What the frame applies: all of it, once.
    pub fn take(s: *Scroll) f32 {
        const d = s.dy;
        s.dy = 0;
        return d;
    }

    /// Still scrolling: keep the link running.
    pub fn active(s: Scroll, now: f64) bool {
        return now < s.until;
    }
};

/// `CAFrameRateRange`.
pub const Range = extern struct { minimum: f32, maximum: f32, preferred: f32 };

/// The pace to ask the link for: `fps` frames a second (a slow, steady
/// change), or, with 0, the screen's fastest (a ProMotion display's 120),
/// down to half of it when the system needs to save power. 0 for a screen
/// that doesn't say leaves the system's default.
pub fn range(fps: f32, screen_max: f32) Range {
    if (fps > 0) return .{ .minimum = fps, .maximum = fps, .preferred = fps };
    if (screen_max <= 0) return .{ .minimum = 0, .maximum = 0, .preferred = 0 };
    return .{ .minimum = screen_max / 2, .maximum = screen_max, .preferred = screen_max };
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// When each frame ran, one time in seconds a line, to the file
/// `NANOUI_FRAME_LOG` names: a scroll's intervals can be read afterwards.
pub const FrameLog = struct {
    file: ?std.Io.File = null,

    pub fn open() FrameLog {
        if (builtin.os.tag == .windows) return .{};
        const path = getenv("NANOUI_FRAME_LOG") orelse return .{};
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = std.Io.Dir.cwd().createFile(io, std.mem.span(path), .{}) catch return .{};
        return .{ .file = f };
    }

    pub fn note(l: *FrameLog, now: f64) void {
        const f = l.file orelse return;
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d:.6}\n", .{now}) catch return;
        f.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch {};
    }

    pub fn close(l: *FrameLog) void {
        if (l.file) |f| f.close(std.Io.Threaded.global_single_threaded.io());
        l.file = null;
    }
};

test "scrolling between refreshes adds up, is applied once, and keeps the link a while" {
    var s: Scroll = .{};
    s.add(3, 10.0);
    s.add(-1, 10.004);
    s.add(4.5, 10.007);
    try std.testing.expect(s.active(10.1));
    try std.testing.expectEqual(@as(f32, 6.5), s.take());
    try std.testing.expectEqual(@as(f32, 0), s.take());
    try std.testing.expect(!s.active(10.007 + linger + 0.001));
}

test "the link asks for the screen's fastest, or a steady pace" {
    try std.testing.expectEqual(Range{ .minimum = 60, .maximum = 120, .preferred = 120 }, range(0, 120));
    try std.testing.expectEqual(Range{ .minimum = 2, .maximum = 2, .preferred = 2 }, range(2, 120));
    try std.testing.expectEqual(Range{ .minimum = 0, .maximum = 0, .preferred = 0 }, range(0, 0));
}

test "display-paced scroll coalesces burst work by at least fivefold without losing movement" {
    var scroll: Scroll = .{};
    var eager_frames: usize = 0;
    var paced_frames: usize = 0;
    var eager_delta: f32 = 0;
    var paced_delta: f32 = 0;
    for (0..120) |refresh| {
        for (0..8) |event| {
            const delta: f32 = if (event % 2 == 0) 1.25 else -0.25;
            const now = @as(f64, @floatFromInt(refresh)) / 120 + @as(f64, @floatFromInt(event)) / 960;
            scroll.add(delta, now);
            eager_delta += delta;
            eager_frames += 1;
        }
        paced_delta += scroll.take();
        paced_frames += 1;
        try std.testing.expectEqual(@as(f32, 0), scroll.take());
    }
    try std.testing.expectEqual(eager_delta, paced_delta);
    try std.testing.expect(eager_frames >= 5 * paced_frames);
    try std.testing.expect(!scroll.active(2));
}
