//! Liquid Glass through the Tester: a bar of glass over colored stripes
//! and text, a tinted button and a clear pane. The CPU renderer must draw
//! what Metal draws, and the glass must frost what shows through.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const gpu = @import("gpu.zig");

pub const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        // Stripes and text for the glass to show through.
        const colors = [_]u24{ 0xe8453c, 0xf2a93b, 0x3fae5a, 0x2f6fd0, 0x8e44ad, 0x222222 };
        for (0..12) |k| {
            const stripe = ui.div(c).row().wFull().h(24).px(14).itemsCenter().bg(.hex(colors[k % colors.len]));
            defer stripe.end();
            ui.text(c, "Content scrolls under the glass", .{ .size = 13, .color = .{ .r = 1, .g = 1, .b = 1 } });
        }
        {
            const bar = ui.div(c).absolute().offset(16, 20).w(300).h(52).row().itemsCenter().gap(10).px(14).rounded(26).glass(.{});
            defer bar.end();
            ui.text(c, "On glass", .{ .size = 14, .weight = .semibold });
            ui.spacer(c);
            const done = ui.div(c).px(14).py(6).rounded(14).glass(.{ .tint = c.theme.accent });
            defer done.end();
            ui.text(c, "Done", .{ .size = 12, .weight = .semibold, .color = c.theme.accent_text });
        }
        const pane = ui.div(c).absolute().offset(220, 120).w(110).h(110).rounded(30).glass(.{ .style = .clear });
        pane.end();
    }
};

fn render(gpa: std.mem.Allocator, theme: ui.Theme) !struct { metal: gpu.Pixels, cpu: gpu.Pixels, scale: f32 } {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 290, .theme = theme });
    defer t.deinit();
    t.settle(1);
    var panes: usize = 0;
    for (t.instances.items) |i| {
        if (i.kind == gpu.Kind.glass) panes += 1;
    }
    try testing.expectEqual(@as(usize, 3), panes);
    const metal = try t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
    errdefer metal.deinit(gpa);
    const texels = try t.text.atlas.read(gpa);
    defer gpa.free(texels);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, metal.bytes.len), .width = metal.width, .height = metal.height };
    raster.draw(cpu, t.instances.items, .{ .pixels = texels, .size = t.text.atlas.size }, t.text.images.pictures(), t.scale, t.theme.background);
    return .{ .metal = metal, .cpu = cpu, .scale = t.scale };
}

fn at(p: gpu.Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

fn lightness(c: [4]u8) f32 {
    return (0.0722 * @as(f32, @floatFromInt(c[0])) + 0.7152 * @as(f32, @floatFromInt(c[1])) + 0.2126 * @as(f32, @floatFromInt(c[2]))) / 255;
}

test "glass: the CPU draws what Metal draws, and it frosts" {
    if (@import("text.zig").portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_]ui.Theme{ .light, .dark_theme }, [_][]const u8{ "/tmp/nanoui-glass-light.png", "/tmp/nanoui-glass-dark.png" }) |theme, path| {
        const r = try render(gpa, theme);
        defer r.metal.deinit(gpa);
        defer gpa.free(r.cpu.bytes);
        try @import("image.zig").writePng(path, r.metal);

        var total: u64 = 0;
        var worst: u8 = 0;
        var off: usize = 0;
        for (r.metal.bytes, r.cpu.bytes) |a, b| {
            const d = if (a > b) a - b else b - a;
            total += d;
            worst = @max(worst, d);
            if (d > 8) off += 1;
        }
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(r.metal.bytes.len));
        // Measured: a mean of 0.0002 and at worst 1 level apart.
        try testing.expect(mean < 0.1);
        try testing.expect(worst <= 24);
        try testing.expect(off * 500 < r.metal.bytes.len);

        // The bar's middle, over red stripes and white text, is frosted: a
        // lighter, flatter color than the stripe beside the bar.
        const beside = at(r.metal, r.scale, 340, 34);
        const under = at(r.metal, r.scale, 120, 46);
        if (!theme.dark) try testing.expect(lightness(under) > lightness(beside));
        try testing.expect(!std.mem.eql(u8, &under, &beside));
    }
}

test "glass frosts what's under it with whichever renderer draws" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 290 });
    defer t.deinit();
    t.settle(1);
    const p = try t.render(gpa);
    defer p.deinit(gpa);
    // Under the bar, the red stripe is lighter than beside it.
    try testing.expect(lightness(at(p, t.scale, 120, 46)) > lightness(at(p, t.scale, 340, 34)));
}

test "drawn on many threads, glass and all, the pixels are those of one" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 290 });
    defer t.deinit();
    t.settle(1);
    const many = try t.render(gpa);
    defer many.deinit(gpa);
    const before = raster.threads;
    defer raster.threads = before;
    raster.threads = 1;
    const one = try t.render(gpa);
    defer one.deinit(gpa);
    try testing.expectEqualSlices(u8, one.bytes, many.bytes);
}

// A native under-window material can show through only if clearing the UI
// preserves alpha. An empty scene must not become an opaque black sheet.
test "transparent window clears retain premultiplied alpha on CPU and GPU" {
    const Empty = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            // Test the clear itself, not a second background quad.
            c.node(0).style.background = null;
        }
    };
    var empty: Empty = .{};
    var theme: ui.Theme = .light;
    for ([_]ui.Color{ .transparent, .{ .r = 0.8, .g = 0.4, .b = 0.2, .a = 0.5 } }) |clear| {
        theme.background = clear;
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&empty, Empty.view), .{ .width = 24, .height = 24, .theme = theme });
        defer t.deinit();
        t.frame();
        const pixels = try t.render(testing.allocator);
        defer pixels.deinit(testing.allocator);
        const expected = [_]f32{ clear.b * clear.a, clear.g * clear.a, clear.r * clear.a, clear.a };
        for (pixels.bytes, 0..) |v, at_| {
            try testing.expectApproxEqAbs(expected[at_ % 4] * 255, @as(f32, @floatFromInt(v)), 1);
        }
        const bytes = try testing.allocator.alloc(u8, pixels.bytes.len);
        defer testing.allocator.free(bytes);
        raster.draw(.{ .bytes = bytes, .width = pixels.width, .height = pixels.height }, &.{}, .{ .pixels = &.{}, .size = 0 }, .{}, t.scale, clear);
        for (bytes, 0..) |v, at_| {
            try testing.expectApproxEqAbs(expected[at_ % 4] * 255, @as(f32, @floatFromInt(v)), 1);
        }
    }
}

test "knockout shadows retain their halo without darkening translucent fills" {
    const Scene_ = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const box = ui.div(c).absolute().offset(30, 20).size(100, 70).rounded(12).bg(.{ .r = 0.8, .g = 0.4, .b = 0.2, .a = 0.25 });
            c.node(box.index).style.shadow = .{ .blur = 8, .y = 8, .spread = -4, .color = .{ .a = 0.3 }, .knockout = true };
            box.end();
        }
    };
    var scene: Scene_ = .{};
    var theme: ui.Theme = .light;
    theme.background = .white;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&scene, Scene_.view), .{ .width = 180, .height = 130, .theme = theme });
    defer t.deinit();
    const p = try t.render(testing.allocator);
    defer p.deinit(testing.allocator);
    const center = at(p, t.scale, 80, 55);
    const expected = [_]u8{ 204, 217, 242, 255 };
    for (center, expected) |v, e| try testing.expectApproxEqAbs(@as(f32, @floatFromInt(e)), @as(f32, @floatFromInt(v)), 1);
    // The shadow is excluded by the ORIGINAL box, not its shrunken,
    // offset spread rect. The outside halo is kept.
    try testing.expectEqualSlices(u8, &center, &at(p, t.scale, 80, 24));
    try testing.expect(at(p, t.scale, 80, 94)[0] < 255);
    const bytes = try testing.allocator.alloc(u8, p.bytes.len);
    defer testing.allocator.free(bytes);
    raster.draw(.{ .bytes = bytes, .width = p.width, .height = p.height }, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, t.scale, .white);
    var total: u64 = 0;
    var worst: u8 = 0;
    for (bytes, p.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
    }
    try testing.expect(@as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(bytes.len)) < 0.15);
    try testing.expect(worst <= 8);
}
