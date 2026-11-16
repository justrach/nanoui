//! Frames on the display's beat (`surface_pace.zig`, `vblank.zig`): moves
//! between two beats are one frame, an animation is built on the beats
//! until it ends and the clock then stops, and the frame log records each
//! frame's kind and timings. Real hidden windows, messages pumped by
//! `runFor`, as `tests_window.zig` does.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;
const loop = @import("loop.zig");
const pace_side = @import("surface_pace.zig");

test "a beat stays outstanding throughout a slow frame so input can run next" {
    const Slow = struct {
        surface: ?*@import("surface.zig").Surface = null,
        observed: bool = false,
        outstanding: bool = false,
        fn view(p: *@This(), c: *ui.Context) void {
            if (p.surface) |s| {
                p.observed = true;
                p.outstanding = s.vclock.?.posted.load(.acquire);
                std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(40), .awake) catch {};
            }
            ui.text(c, "slow animation", .{});
            c.animating = true;
        }
    };
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var p: Slow = .{};
    const win = try app.newWindow(.{ .title = "slow beat", .width = 200, .height = 100, .visible = false, .content = .{ .view = .init(&p, Slow.view) } });
    const s = win.surface.?;
    const clock = s.vclock orelse return error.SkipZigTest;
    // Pause the producer: the test controls the outstanding message without
    // depending on where a real monitor happens to be in its refresh.
    clock.run(false);
    clock.posted.store(true, .release);
    p.surface = s;
    pace_side.onBeat(s);
    try testing.expect(p.observed);
    try testing.expect(p.outstanding);
    try testing.expect(!clock.posted.load(.acquire));
}

const Counter = struct {
    builds: usize = 0,
    animate: bool = false,
    fn view(p: *Counter, c: *ui.Context) void {
        p.builds += 1;
        const root = ui.div(c).p(10);
        defer root.end();
        ui.text(c, "paced", .{});
        if (p.animate) c.animating = true;
    }
};

fn makeApp(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    return app;
}

test "moves between two beats are one frame, and the clock stops once they do" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Counter = .{};
    const win = try app.newWindow(.{ .title = "pace", .width = 200, .height = 100, .visible = false, .content = .{ .view = .init(&p, Counter.view) } });
    const s = win.surface orelse return error.SkipZigTest;
    // What the window's making queued (its first frame) is handled first:
    // only the moves' frames are counted.
    loop.runFor(0.1);
    const log = try s.recordFrames(gpa);
    const frames0 = s.frames;
    // The first move is built at once and starts the clock.
    pace_side.onInput(s);
    try testing.expectEqual(frames0 + 1, s.frames);
    if (s.vclock == null) return error.SkipZigTest; // no thread: the timer's path
    try testing.expect(s.ticking);
    // The next ones wait for the beat.
    for (0..5) |_| pace_side.onInput(s);
    try testing.expectEqual(frames0 + 1, s.frames);
    loop.runFor(0.4);
    // One frame for the five, on a beat; then nothing, and the clock stops.
    try testing.expectEqual(frames0 + 2, s.frames);
    try testing.expect(!s.ticking);
    try testing.expect(s.vclock.?.beats.load(.monotonic) >= 1);
    const recs = log.spanFrom(0);
    try testing.expect(recs.len >= 2);
    try testing.expectEqual(@import("../ui/frame_log.zig").Kind.link, recs[recs.len - 1].kind);
}

test "an animation is built on the beats until it ends" {
    const gpa = testing.allocator;
    const app = try makeApp(gpa);
    defer app.destroy();
    var p: Counter = .{ .animate = true };
    const win = try app.newWindow(.{ .title = "pace", .width = 200, .height = 100, .visible = false, .content = .{ .view = .init(&p, Counter.view) } });
    const s = win.surface orelse return error.SkipZigTest;
    loop.runFor(0.05);
    s.frame();
    if (s.vclock == null) return error.SkipZigTest;
    try testing.expect(s.ticking);
    const before = s.frames;
    loop.runFor(0.25);
    const during = s.frames - before;
    // At least a handful of beats in a quarter of a second, at most one a
    // millisecond (a clock that spun).
    try testing.expect(during >= 4 and during < 250);
    p.animate = false;
    loop.runFor(0.2);
    try testing.expect(!s.ticking);
    const after = s.frames;
    loop.runFor(0.1);
    try testing.expectEqual(after, s.frames);
}
