//! `Style.transform`: a subtree moved by any plane transform, drawn the same by
//! Metal and on the CPU, clipped where it lands, composing with boxes around it,
//! with the pointer finding things where they landed; a frosted pane; and a
//! knocked out shadow whose spread leaves it showing outside the box.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");

const red: ui.Color = .{ .r = 1 };
const blue: ui.Color = .{ .b = 1 };
const white: ui.Color = .{ .r = 1, .g = 1, .b = 1 };

/// Turned by `angle` about (cx, cy).
fn turned(angle: f32, cx: f32, cy: f32) ui.Affine {
    const ca = @cos(angle);
    const sa = @sin(angle);
    return .{ .a = ca, .b = sa, .c = -sa, .d = ca, .e = cx - ca * cx + sa * cy, .f = cy - sa * cx - ca * cy };
}

const Scene = struct {
    clicks: u32 = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = white }, null);
        defer c.end();
        // A rounded box, its border and a triangle, turned a quarter about its middle.
        _ = c.open(.{ .absolute = true, .transform = turned(std.math.pi / 2.0, 100, 50) }, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 50, .y = 20 }, .width = .{ .px = 100 }, .height = .{ .px = 60 }, .background = red, .radius = 10, .corner_circular = true }, .none, null);
        c.end();
        // Skewed: a parallelogram.
        _ = c.open(.{ .absolute = true, .transform = .{ .c = 1, .e = -200 } }, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 200, .y = 200 }, .width = .{ .px = 60 }, .height = .{ .px = 60 }, .background = blue }, .none, null);
        c.end();
        // A clip outside a moved box cuts it where it lands, and a transform
        // inside another composes with it.
        _ = c.open(.{ .absolute = true, .offset = .{ .x = 300, .y = 0 }, .width = .{ .px = 50 }, .height = .{ .px = 50 }, .clip = true }, null);
        _ = c.open(.{ .absolute = true, .transform = .{ .e = 10 } }, null);
        _ = c.open(.{ .absolute = true, .transform = .{ .a = 2, .d = 2, .e = -300 } }, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 5 }, .width = .{ .px = 40 }, .height = .{ .px = 10 }, .background = red }, .none, null);
        c.end();
        c.end();
        c.end();
        // Pressed where it lands.
        _ = c.open(.{ .absolute = true, .transform = .{ .e = 0, .f = 200 } }, null);
        const b = ui.pressable(c, .{ .absolute = true, .offset = .{ .x = 20, .y = 50 }, .width = .{ .px = 40 }, .height = .{ .px = 40 }, .background = blue }, red);
        c.end();
        if (b.clicked) s.clicks += 1;
        c.end();
    }
};

fn at(p: gpu.Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const px: usize = @intFromFloat(x * scale);
    const py: usize = @intFromFloat(y * scale);
    return p.bytes[(py * p.width + px) * 4 ..][0..4].*;
}

fn isRed(px: [4]u8) bool {
    return px[2] > 200 and px[1] < 40 and px[0] < 40;
}
fn isBlue(px: [4]u8) bool {
    return px[0] > 200 and px[1] < 40 and px[2] < 40;
}
fn isWhite(px: [4]u8) bool {
    return px[0] > 240 and px[1] > 240 and px[2] > 240;
}

test "a transform moves all of a subtree, composes, and clips where it lands" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 400, .height = 340 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // Turned a quarter about (100, 50): tall now, x 70 to 130, y 0 to 100.
    try testing.expect(isRed(at(shown, t.scale, 100, 5)));
    try testing.expect(isRed(at(shown, t.scale, 100, 95)));
    try testing.expect(isWhite(at(shown, t.scale, 60, 50)));
    try testing.expect(isWhite(at(shown, t.scale, 140, 50)));
    // Its corner stays round.
    try testing.expect(isWhite(at(shown, t.scale, 71, 1)));
    // Skewed about y = 0: at y 205 it starts at 205, at y 255 at 255.
    try testing.expect(isBlue(at(shown, t.scale, 210, 205)));
    try testing.expect(isWhite(at(shown, t.scale, 210, 255)));
    try testing.expect(isBlue(at(shown, t.scale, 262, 255)));
    // Doubled then moved: x 300 + 10 to ..., y 10 to 30, cut at the clip's x 350.
    try testing.expect(isRed(at(shown, t.scale, 315, 20)));
    try testing.expect(isRed(at(shown, t.scale, 348, 20)));
    try testing.expect(isWhite(at(shown, t.scale, 352, 20)));
    try testing.expect(isWhite(at(shown, t.scale, 305, 20)));
    // Metal or not, the same picture.
    if (!text.portable) {
        const cpu_bytes = try gpa.alloc(u8, shown.bytes.len);
        defer gpa.free(cpu_bytes);
        const cpu: gpu.Pixels = .{ .bytes = cpu_bytes, .width = shown.width, .height = shown.height };
        raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, t.text.images.pictures(), t.scale, t.theme.background);
        var off: usize = 0;
        for (shown.bytes, cpu.bytes) |a, b| {
            if ((if (a > b) a - b else b - a) > 40) off += 1;
        }
        try testing.expect(off * 200 < shown.bytes.len);
    }
    // The pointer finds it where it landed, not where it was laid out.
    t.click(40, 270);
    try testing.expectEqual(@as(u32, 1), s.clicks);
    t.click(40, 70);
    try testing.expectEqual(@as(u32, 1), s.clicks);
}

const Flat = struct {
    fn view(_: *Flat, c: *ui.Context) void {
        _ = c.open(.{ .absolute = true, .transform = .{ .a = 0 } }, null);
        _ = c.leaf(.{ .width = .{ .px = 50 }, .height = .{ .px = 50 }, .background = red }, .none, null);
        c.end();
    }
};

test "a transform flattening the plane draws nothing" {
    var s: Flat = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Flat.view), .{});
    defer t.deinit();
    for (t.instances.items) |i| try testing.expect(i.color[0] != 1 or i.color[1] != 0);
}

test "affine: times, inverse, bounds" {
    const m = turned(0.5, 10, 20);
    const inv = m.inverse().?;
    const p = inv.apply(m.apply(3, 4).x, m.apply(3, 4).y);
    try testing.expectApproxEqAbs(@as(f32, 3), p.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 4), p.y, 1e-3);
    const both = (ui.Affine{ .e = 5 }).times(.{ .a = 2, .d = 2 });
    try testing.expectEqual(@as(f32, 11), both.apply(3, 0).x);
    const b = (ui.Affine{ .a = -1 }).bounds(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try testing.expectEqual(@as(f32, -4), b.x);
    try testing.expectEqual(@as(f32, 3), b.w);
    try testing.expect((ui.Affine{ .a = 0 }).inverse() == null);
}

const Ringed = struct {
    fn view(_: *Ringed, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(40), .background = white, .width = .fill, .height = .fill });
        defer ui.end(c);
        _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .radius = 10, .corner_circular = true, .shadow = .{ .color = blue, .blur = 0, .y = 0, .spread = 3, .knockout = true } }, .none, null);
    }
};

test "a knocked out shadow's spread shows as a ring outside its box" {
    const gpa = testing.allocator;
    var s: Ringed = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Ringed.view), .{ .width = 200, .height = 160 });
    defer t.deinit();
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    try testing.expect(isBlue(at(shown, t.scale, 38.5, 70)));
    try testing.expect(isWhite(at(shown, t.scale, 42, 70)));
    try testing.expect(isWhite(at(shown, t.scale, 34, 70)));
    // A round corner stays round: the box's corner point isn't filled.
    try testing.expect(isWhite(at(shown, t.scale, 37.5, 37.5)));
    const cpu_bytes = try gpa.alloc(u8, shown.bytes.len);
    defer gpa.free(cpu_bytes);
    const cpu: gpu.Pixels = .{ .bytes = cpu_bytes, .width = shown.width, .height = shown.height };
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, t.text.images.pictures(), t.scale, t.theme.background);
    try testing.expect(isBlue(at(cpu, t.scale, 38.5, 70)));
    try testing.expect(isWhite(at(cpu, t.scale, 42, 70)));
}

const Frost = struct {
    fn view(_: *Frost, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = white }, null);
        defer c.end();
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 0 }, .width = .{ .px = 100 }, .height = .{ .px = 200 }, .background = .{} }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 50, .y = 50 }, .width = .{ .px = 100 }, .height = .{ .px = 100 }, .glass = .{ .style = .frost, .blur = 12 } }, .none, null);
    }
};

test "a frosted pane only blurs: its middle stays as it was" {
    const gpa = testing.allocator;
    var s: Frost = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Frost.view), .{ .width = 200, .height = 200, .scale = 1 });
    defer t.deinit();
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    // Well within each side, black and white.
    try testing.expect(at(shown, 1, 60, 100)[1] < 50);
    try testing.expect(at(shown, 1, 145, 100)[1] > 200);
    // Across the edge, gray.
    const mid = at(shown, 1, 100, 100)[1];
    try testing.expect(mid > 60 and mid < 200);
}
