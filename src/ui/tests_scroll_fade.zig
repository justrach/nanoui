//! Grouped alpha must match the CPU renderer, including nested opacity,
//! overlapping content, rounded clips, and non-overflowing scroll boxes.
const std = @import("std");
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const testing = std.testing;

// Force the platform GPU entry points through semantic analysis in compile-only
// cross-target gates. These are never called by an offscreen Tester test.
export fn nanoui_scroll_fade_check_gl(r: *@import("opengl.zig").Renderer, instances: [*]const gpu.Instance, count: usize) void {
    r.draw(instances[0..count], .{ .w = 140, .h = 110 }, 1, .black, 0, 0);
}
fn checkD3d(r: *@import("d3d11.zig").Renderer, instances: [*]const gpu.Instance, count: usize) callconv(.c) void {
    r.draw(instances[0..count], .{ .w = 140, .h = 110 }, 1, .black, null);
}
comptime {
    if (@import("builtin").os.tag == .windows) @export(&checkD3d, .{ .name = "nanoui_scroll_fade_check_d3d" });
}

/// Nested opacity + edge fade over a split background, with overlapping children.
pub const Scene = struct {
    opacity: f32 = 1,
    id: u64 = 0,

    pub fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).size(140, 110);
        defer root.end();
        ui.div(c).absolute().size(70, 110).bg(.hex(0x204060)).end();
        ui.div(c).absolute().offset(70, 0).size(70, 110).bg(.hex(0x603020)).end();
        const parent = ui.div(c).absolute().offset(10, 15).size(100, 80).opacity(s.opacity);
        c.node(parent.index).style.group = true;
        defer parent.end();
        const scroll = ui.div(c).size(100, 80).scrollY().scrollEdgeFade(16).hideScrollBar();
        s.id = scroll.id();
        defer scroll.end();
        const content = ui.div(c).size(100, 200).bg(.hex(0x00ff00));
        defer content.end();
        // Red fully covers green here. A per-primitive fade incorrectly lets
        // green show through red at the hidden edge; a grouped mask does not.
        ui.div(c).absolute().offset(20, 0).size(60, 200).bg(.hex(0xff0000)).end();
    }
};

const FitScene = struct {
    id: u64 = 0,

    fn view(s: *FitScene, c: *ui.Context) void {
        const scroll = ui.div(c).size(100, 100).scrollY().scrollEdgeFade(16).hideScrollBar();
        s.id = scroll.id();
        defer scroll.end();
        ui.div(c).size(100, 50).bg(.hex(0x336699)).end();
    }
};

const RoundedScene = struct {
    id: u64 = 0,

    fn view(s: *RoundedScene, c: *ui.Context) void {
        const root = ui.div(c).size(120, 100).bg(.hex(0x102030));
        defer root.end();
        const scroll = ui.div(c).absolute().offset(10, 10).size(100, 80).rounded(20).clip().scrollY().scrollEdgeFade(14).hideScrollBar();
        s.id = scroll.id();
        defer scroll.end();
        ui.div(c).size(100, 200).bg(.hex(0x22aaee)).end();
    }
};

fn rgb(p: gpu.Pixels, x: usize, y: usize) [3]u8 {
    const at = (y * p.width + x) * 4;
    return .{ p.bytes[at + 2], p.bytes[at + 1], p.bytes[at] };
}

test "scroll fade groups match reference pixels with overlapping content and nested opacity" {
    for ([_]f32{ 1, 0.65 }) |opacity| {
        var scene: Scene = .{ .opacity = opacity };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&scene, Scene.view), .{ .width = 140, .height = 110, .scale = 1 });
        defer t.deinit();
        t.settle(0.1);
        try testing.expectEqual(@as(f32, 120), t.ctx.scroll_max.get(scene.id).?);
        const native = try t.render(testing.allocator);
        defer native.deinit(testing.allocator);
        const cpu: gpu.Pixels = .{ .bytes = try testing.allocator.alloc(u8, native.bytes.len), .width = native.width, .height = native.height };
        defer cpu.deinit(testing.allocator);
        raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, 1, t.ctx.theme.background);
        var error_max: u32 = 0;
        for (native.bytes, cpu.bytes) |a, b| error_max = @max(error_max, @abs(@as(i32, a) - @as(i32, b)));
        try testing.expect(error_max <= 3);
        for ([_]usize{ 40, 80 }) |x| {
            const base: [3]f32 = if (x < 70) .{ 32, 64, 96 } else .{ 96, 48, 32 };
            for ([_]usize{ 16, 55, 93 }) |y| {
                const fade = @min(@as(f32, 1), (95 - (@as(f32, @floatFromInt(y)) + 0.5)) / 16);
                const alpha = fade * opacity;
                const actual = rgb(native, x, y);
                for (0..3) |channel| {
                    const foreground: f32 = if (channel == 0) 255 else 0;
                    const expected = foreground * alpha + base[channel] * (1 - alpha);
                    try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(actual[channel])), 3);
                }
            }
        }
        try testing.expect(t.ctx.hits.items.len > 0);
    }
}

test "non-overflowing scroll fade box emits no offscreen layer group" {
    var scene: FitScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&scene, FitScene.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_max.get(scene.id).?);
    for (t.instances.items) |inst| {
        try testing.expect(inst.kind != gpu.Kind.layer_begin);
        try testing.expect(inst.kind != gpu.Kind.layer_end);
    }
}

test "rounded clipped scroll fade box clips offscreen group corners" {
    var scene: RoundedScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&scene, RoundedScene.view), .{ .width = 120, .height = 100, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    t.scroll(60, 50, -40);
    t.settle(0.1);
    const native = try t.render(testing.allocator);
    defer native.deinit(testing.allocator);
    const cpu: gpu.Pixels = .{ .bytes = try testing.allocator.alloc(u8, native.bytes.len), .width = native.width, .height = native.height };
    defer cpu.deinit(testing.allocator);
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, 1, t.ctx.theme.background);
    var error_max: u32 = 0;
    for (native.bytes, cpu.bytes) |a, b| error_max = @max(error_max, @abs(@as(i32, a) - @as(i32, b)));
    try testing.expect(error_max <= 3);

    // Exterior rounded corner of the 100x80 box at (10, 10) must stay untouched background.
    const corner = rgb(native, 11, 11);
    try testing.expectEqual([3]u8{ 0x10, 0x20, 0x30 }, corner);

    // Top fade at y=12 (dist 2.5 from y=10) and bottom fade at y=87 (dist 2.5 from y=90).
    const bg: [3]f32 = .{ 0x10, 0x20, 0x30 };
    const fg: [3]f32 = .{ 0x22, 0xaa, 0xee };
    const edge_fade: f32 = 2.5 / 14.0;
    for ([_]usize{ 12, 87 }) |y| {
        const px = rgb(native, 60, y);
        for (0..3) |ch| try testing.expectApproxEqAbs(fg[ch] * edge_fade + bg[ch] * (1 - edge_fade), @as(f32, @floatFromInt(px[ch])), 3);
    }
    const mid = rgb(native, 60, 50);
    for (0..3) |ch| try testing.expectApproxEqAbs(fg[ch], @as(f32, @floatFromInt(mid[ch])), 2);
}
