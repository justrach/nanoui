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
    for ([_]ui.Theme{ .light, .dark_theme }, 0..) |theme, i| {
        var path_buf: [256]u8 = undefined;
        const path = try @import("../temp_path.zig").tempPath(&path_buf, if (i == 0) "nanoui-glass-light.png" else "nanoui-glass-dark.png");
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
