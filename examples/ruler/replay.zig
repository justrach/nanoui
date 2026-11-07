//! Scripted native render, NOT a real-time screen recording. Uses the same
//! Demo.draw, ui.Tester input, text shaper and CPU rasterizer as the app.
//! stdout: 960x960 BGRA, 60 samples/second, 8 seconds (no FPS claim).
//! Pass --stills=DIR to write comparison frames instead of raw video.
const std = @import("std");
const ui = @import("nanoui").ui;
const Audit = @import("audit.zig").Audit;
const Demo = @import("view.zig").Demo;

const Gesture = struct { start: f32, end: f32, from: f32, to: f32 };
const gestures = [_]Gesture{
    .{ .start = 0.20, .end = 0.95, .from = 780, .to = 220 },
    // Grab an in-flight release, then quickly reverse under the finger.
    .{ .start = 1.05, .end = 1.80, .from = 190, .to = 710 },
    .{ .start = 2.40, .end = 3.15, .from = 790, .to = 210 },
    .{ .start = 3.25, .end = 4.00, .from = 180, .to = 670 },
    .{ .start = 4.60, .end = 5.20, .from = 770, .to = 350 },
    .{ .start = 5.30, .end = 6.00, .from = 320, .to = 823 },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var audit = false;
    var clip_audit: Audit = .{};
    var stills: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--audit-clip")) {
            audit = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--stills=")) return error.UnknownArgument;
        stills = arg[9..];
    }
    var demo: Demo = .{};
    var t: ui.Tester = undefined;
    try t.init(init.gpa, .init(&demo, Demo.draw), .{ .width = 960, .height = 960, .scale = 1 });
    defer t.deinit();
    t.dt = 1.0 / 60.0;
    t.time = 0;
    var next: usize = 0;
    var held = false;
    for (0..480) |frame| {
        const now = @as(f32, @floatFromInt(frame)) / 60;
        if (next < gestures.len) {
            const g = gestures[next];
            if (now >= g.start) {
                const p = std.math.clamp((now - g.start) / (g.end - g.start), 0, 1);
                const ease = p * p * (3 - 2 * p);
                t.ctx.input.mouse = .{ .x = g.from + (g.to - g.from) * ease, .y = 536 };
                t.ctx.updateHot();
                if (!held) {
                    t.ctx.pointerDown();
                    held = true;
                }
                if (now >= g.end) {
                    t.ctx.pointerUp();
                    held = false;
                    next += 1;
                }
            }
        }
        t.frame();
        if (audit) try clip_audit.frame(&t);
        if (stills) |dir| {
            if (frame == 48 or frame == 57 or frame == 60 or frame == 63 or frame == 132 or frame == 180 or frame == 264 or frame == 297 or frame == 300 or frame == 303 or frame == 450) {
                const path = try std.fmt.allocPrint(init.gpa, "{s}/native-v2-{d:0>3}.png", .{ dir, frame });
                defer init.gpa.free(path);
                try t.screenshot(path);
                std.debug.print("frame {d}: value={d}, position={d:.4}, moving={}\n", .{ frame, demo.ruler.value(), demo.ruler.model.position, demo.ruler.model.moving() });
            }
        } else {
            const pixels = try t.render(init.gpa);
            defer pixels.deinit(init.gpa);
            try std.Io.File.stdout().writeStreamingAll(init.io, pixels.bytes);
        }
    }
    if (audit) try clip_audit.report();
}
