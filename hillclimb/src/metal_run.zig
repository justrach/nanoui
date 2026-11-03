//! macOS hill-climb: Tester frames drawn by Metal into an offscreen target.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const scenes = @import("scenes.zig");
const main = @import("main.zig");

pub fn run(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize) !main.Result {
    var state: scenes.State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, scenes.State.view), .{ .width = main.width, .height = main.height, .scale = main.scale });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    const target = t.renderer.newTarget(t.size, t.scale);
    defer nanoui.objc.release(target);

    const frame_ms = try gpa.alloc(f64, frames);
    defer gpa.free(frame_ms);
    const encode_ms = try gpa.alloc(f64, frames);
    defer gpa.free(encode_ms);
    const gpu_ms = try gpa.alloc(f64, frames);
    defer gpa.free(gpu_ms);
    var phases: [3][]f64 = undefined;
    for (&phases) |*ph| ph.* = try gpa.alloc(f64, frames);
    defer for (phases) |ph| gpa.free(ph);
    var cpu0: f64 = 0;
    for (0..main.warmup + frames) |i| {
        if (i == main.warmup) cpu0 = main.cpuSeconds();
        state.frame = i;
        state.time = @as(f32, @floatFromInt(i)) / 120;
        t.time = state.time;
        const t0 = ui.clock.now();
        t.frame();
        const ft = (ui.clock.now() - t0) * 1000;
        const timing = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, t.theme.background);
        if (i >= main.warmup) {
            frame_ms[i - main.warmup] = ft;
            encode_ms[i - main.warmup] = timing.encode_ms;
            gpu_ms[i - main.warmup] = timing.gpu_ms;
            phases[0][i - main.warmup] = t.ctx.stats.build_ms;
            phases[1][i - main.warmup] = t.ctx.stats.layout_ms;
            phases[2][i - main.warmup] = t.ctx.stats.paint_ms;
        }
    }
    const cpu = (main.cpuSeconds() - cpu0) * 1000 / @as(f64, @floatFromInt(frames));
    return .{
        .fw = "nanoui",
        .scene = @tagName(scene),
        .frames = frames,
        .frame_ms = main.medianOf(frame_ms),
        .frame_p95 = main.p95Of(frame_ms),
        .frame_p99 = main.p99Of(frame_ms),
        .renderer = "metal",
        .encode_ms = main.medianOf(encode_ms),
        .gpu_ms = main.medianOf(gpu_ms),
        .cpu_ms = cpu,
        .ops = t.instances.items.len,
        .build_ms = main.medianOf(phases[0]),
        .layout_ms = main.medianOf(phases[1]),
        .paint_ms = main.medianOf(phases[2]),
    };
}
