//! Direct3D 11 against the CPU renderer: the same instances must come out as
//! the same pixels.
//!
//! Two things made these tests weaker than they looked, and both are fixed here:
//!
//! 1. **A broken renderer was reported as a missing one.** `Renderer.init()`
//!    returned `error.Direct3D` whether the machine had no GPU or a shader would
//!    not compile, and every test skipped on that error. A shader with the wrong
//!    struct size skipped four parity tests on a machine with Direct3D 11 and
//!    printed numbers from an earlier, working build. Now only `error.NoDevice`
//!    skips; anything else fails.
//!
//! 2. **`Renderer.draw` returns `void`, so a frame that failed to draw is a
//!    blank frame, not an error.** A test comparing two blank frames passes. So
//!    `drawThenRead` checks that something was actually drawn before comparing:
//!    a clear-only frame is a failure, not a match.
//!
//! The struct-size test at the end is the one that catches the Direct3D/CPU
//! layout drift directly, without needing a device at all.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const d3d11 = @import("d3d11.zig");

const Limits = struct { mean: f64, worst: u8, off_in: usize };

/// A renderer for a parity test, or `null` when this machine has no Direct3D 11
/// at all.
///
/// The distinction is the point: `error.NoDevice` means there is no device to
/// test with, and a skip is honest. Every other error — a shader that will not
/// compile, a buffer that will not be made — is a bug in this repository and
/// must fail the test. Sharing one error name between the two is what let a
/// broken shader look like a machine without a GPU.
fn renderer() !?d3d11.Renderer {
    return d3d11.Renderer.init() catch |e| {
        if (e == error.NoDevice) {
            std.debug.print("no Direct3D 11 here: {t} ", .{e});
            return null;
        }
        std.debug.print("[d3d11] Renderer.init failed: {t}\n", .{e});
        return e;
    };
}

/// How many pixels differ from the clear colour: a frame that drew nothing is
/// the same colour everywhere.
fn drawnPixels(px: gpu.Pixels, clear: ui.Color) usize {
    const c: [4]u8 = .{
        @intFromFloat(clear.b * 255),
        @intFromFloat(clear.g * 255),
        @intFromFloat(clear.r * 255),
        @intFromFloat(clear.a * 255),
    };
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= px.bytes.len) : (i += 4) {
        // BGRA, premultiplied: a differing pixel is one where any channel is off
        // by more than rounding.
        var off = false;
        for (0..4) |k| {
            const a = px.bytes[i + k];
            const b = c[k];
            if ((if (a > b) a - b else b - a) > 2) off = true;
        }
        if (off) n += 1;
    }
    return n;
}

/// Draws with Direct3D 11 and reads the result back, failing if the frame is
/// nothing but the clear colour.
///
/// `Renderer.draw` returns `void`: a draw that fails part way leaves a cleared
/// target, which is indistinguishable from a correct frame that happened to be
/// empty. Comparing that against the CPU renderer would fail — but comparing it
/// against a CPU frame that is also mostly background can pass while the GPU
/// drew nothing at all, which is exactly what a wrong `Instance` stride does.
/// So the frame has to have content before it is compared.
fn drawThenRead(r: *d3d11.Renderer, t: *ui.Tester, clear: ui.Color) !gpu.Pixels {
    const gpa = testing.allocator;
    r.sync(t.text.atlas.mask(), t.text.atlas.generation, t.text.images.pictures(), t.text.images.generation);
    r.draw(t.instances.items, t.size, t.scale, clear, null);
    const px = try r.read(gpa);
    if (drawnPixels(px, clear) == 0) {
        px.deinit(gpa);
        std.debug.print("[d3d11] the frame is the clear colour: nothing was drawn. ", .{});
        return error.NothingDrawn;
    }
    return px;
}

/// Draws the Tester's last frame with Direct3D 11 and with the CPU renderer, and
/// expects them within `limits`.
fn compare(t: *ui.Tester, limits: Limits) !void {
    const gpa = testing.allocator;
    var maybe = try renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();

    const ours = try drawThenRead(r, t, t.theme.background);
    defer ours.deinit(gpa);
    const cpu = try t.render(gpa);
    defer cpu.deinit(gpa);

    try testing.expectEqual(cpu.width, ours.width);
    try testing.expectEqual(cpu.height, ours.height);

    var total: u64 = 0;
    var worst: u8 = 0;
    var off: usize = 0;
    for (ours.bytes, cpu.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ours.bytes.len));
    std.debug.print("d3d11 vs cpu: mean {d:.4}, worst {d}, {d} of {d} off ", .{ mean, worst, off, ours.bytes.len });
    try testing.expect(mean <= limits.mean);
    try testing.expect(worst <= limits.worst);
    // `off_in` is "one differing pixel per this many are allowed", not a count:
    // ClearType's colour fringes on text differ by design, and how many is the
    // text's business, not the renderer's.
    try testing.expect(off * limits.off_in < ours.bytes.len);
}

test "d3d11: shapes match the CPU renderer" {
    const Scene = @import("tests_raster.zig").Scene;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    try compare(&t, .{ .mean = 1.0, .worst = 240, .off_in = 20 });
}

test "d3d11: glass matches the CPU renderer" {
    const Scene = @import("tests_glass.zig").Scene;
    for ([_]ui.Theme{ .light, .dark_theme }) |theme| {
        var s: Scene = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 360, .height = 290, .theme = theme });
        defer t.deinit();
        t.settle(1);
        try compare(&t, .{ .mean = 2.0, .worst = 240, .off_in = 20 });
    }
}

test "d3d11: a canvas matches the CPU renderer" {
    const Scene = @import("tests_canvas.zig").Scene;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
    defer t.deinit();
    t.settle(0.1);
    try compare(&t, .{ .mean = 0.5, .worst = 240, .off_in = 20 });
}

test "d3d11: a coloured quad keeps its channels" {
    const gpa = testing.allocator;
    var maybe = try renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();

    // Three quads side by side: this is the test that notices a wrong
    // `Instance` stride, because only the first is at offset 0.
    const clear: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const quads = [3]gpu.Instance{
        .{ .rect = .{ 0, 0, 10, 30 }, .color = .{ 1, 0, 0, 1 } },
        .{ .rect = .{ 10, 0, 10, 30 }, .color = .{ 0, 1, 0, 1 } },
        .{ .rect = .{ 20, 0, 10, 30 }, .color = .{ 0, 0, 1, 1 } },
    };
    r.draw(&quads, .{ .w = 30, .h = 30 }, 1, clear, null);
    const px = try r.read(gpa);
    defer px.deinit(gpa);

    const at = struct {
        fn f(p2: gpu.Pixels, x: usize, y: usize) [4]u8 {
            const i = (y * p2.width + x) * 4;
            return .{ p2.bytes[i], p2.bytes[i + 1], p2.bytes[i + 2], p2.bytes[i + 3] };
        }
    }.f;
    // BGRA in memory: red is B=0 G=0 R=255.
    const red = at(px, 5, 15);
    const green = at(px, 15, 15);
    const blue = at(px, 25, 15);
    std.debug.print("[quads] red {any} green {any} blue {any} ", .{ red, green, blue });
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, red);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, green);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, blue);
}

// `shader.hlsl`'s `Instance` must be the same size as `gpu.zig`'s, because the
// vertex shader walks the structured buffer by that stride: a shader struct that
// is smaller steps too little and every instance after the first reads another's
// fields. That is not a misdraw that looks wrong, it is a misdraw that looks
// plausible — the parity tests above only caught it as a number, and only once
// they were taught to fail. This needs no device: it reads the shader source.
test "d3d11: shader.hlsl's Instance is the same size gpu.zig's is" {
    const source = @embedFile("shader.hlsl");
    const start = std.mem.indexOf(u8, source, "struct Instance {") orelse return error.NoInstanceStruct;
    const end = std.mem.indexOfPos(u8, source, start, "};") orelse return error.NoInstanceStruct;
    const body = source[start..end];

    var bytes: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '/' or std.mem.startsWith(u8, t, "struct")) continue;
        if (std.mem.startsWith(u8, t, "float4")) bytes += 16 else if (std.mem.startsWith(u8, t, "float ")) bytes += 4;
    }
    try testing.expectEqual(@sizeOf(gpu.Instance), bytes);
}

// The same for the Metal shader: it is the other implementation of the same
// struct, and it is not exercised by this machine's tests at all.
test "d3d11: shader.metal's Instance is the same size gpu.zig's is" {
    const source = @embedFile("shader.metal");
    const start = std.mem.indexOf(u8, source, "struct Instance {") orelse return error.NoInstanceStruct;
    const end = std.mem.indexOfPos(u8, source, start, "};") orelse return error.NoInstanceStruct;
    const body = source[start..end];

    var bytes: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '/' or std.mem.startsWith(u8, t, "struct")) continue;
        if (std.mem.startsWith(u8, t, "float4")) bytes += 16 else if (std.mem.startsWith(u8, t, "float ")) bytes += 4;
    }
    try testing.expectEqual(@sizeOf(gpu.Instance), bytes);
}

test "d3d11: the sizes a drag passes through keep every glass target alive" {
    const gpa = testing.allocator;
    var maybe = try renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();
    const clear: ui.Color = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 };
    // The Glass page's shape — boxes and a glass bar over them — drawn at
    // the pixel sizes a 2x window drag passes through, down and up again.
    // A CreateTexture2D that fails leaves its target null, and the pane
    // path then retries (and fails) every frame: the window turns to a
    // per-second error spill and the page crawls. Every draw below must
    // leave all four targets made.
    var instances: std.ArrayList(gpu.Instance) = .empty;
    defer instances.deinit(gpa);
    for ([_][2]f32{ .{ 900, 640 }, .{ 700, 500 }, .{ 400, 300 }, .{ 1000, 700 }, .{ 320, 200 }, .{ 200, 150 }, .{ 900, 640 } }) |s| {
        instances.clearRetainingCapacity();
        instances.append(gpa, .{ .rect = .{ 0, 0, s[0], 48 }, .color = .{ 1, 1, 1, 1 } }) catch return;
        instances.append(gpa, .{ .rect = .{ 16, 64, s[0] - 32, s[1] - 80 }, .color = .{ 0.2, 0.4, 0.9, 1 } }) catch return;
        // The glass bar: over the middle, rounded, the way the page draws it.
        instances.append(gpa, .{
            .rect = .{ 16, 64, @max(8, s[0] - 32), 64 },
            .color = .{ 1, 1, 1, 0.6 },
            .radius = 26,
            .border_width = 1,
            .kind = gpu.Kind.glass,
        }) catch return;
        // A pane against the window's corner, where the backdrop meets the
        // frame's edge.
        instances.append(gpa, .{
            .rect = .{ 0, s[1] - 40, @max(8, s[0] / 2), 40 },
            .color = .{ 1, 1, 1, 0.5 },
            .radius = 12,
            .border_width = 1,
            .kind = gpu.Kind.glass,
        }) catch return;
        r.draw(instances.items, .{ .w = s[0], .h = s[1] }, 2, clear, null);
        try testing.expect(r.frame.texture != null and r.frame.rtv != null and r.frame.srv != null);
        try testing.expect(r.a.texture != null and r.a.rtv != null and r.a.srv != null);
        try testing.expect(r.b.texture != null and r.b.rtv != null and r.b.srv != null);
        try testing.expect(r.snap.texture != null and r.snap.rtv != null and r.snap.srv != null);
    }
}
