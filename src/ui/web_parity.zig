//! Browser-driven asynchronous WebGPU/CPU pixel parity. No native windows.
const std = @import("std");
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const webgpu = @import("webgpu.zig");
const Widgets = @import("tests_raster.zig").Scene;
const Glass = @import("tests_glass.zig").Scene;
const Motion = @import("web_motion_reference.zig");
const TextureScene = @import("web_texture_tests.zig").Scene;
const Effects = @import("web_scenes.zig").Effects;
const Canvas = @import("tests_canvas.zig").Scene;
const gpa = std.heap.wasm_allocator;

var fonts_ready = false;
var picture: []const u8 = &.{};
var widgets: Widgets = .{};
var canvas: Canvas = .{};
var glass: Glass = .{};
var effects: Effects = .{};
var motion: Motion.Scene = .{};
var texture_scene: TextureScene = .{};
var tester: ?*ui.Tester = null;
var renderer: ?webgpu.Renderer = null;
var target: ?webgpu.Target = null;
var shown: ?gpu.Pixels = null;
var ready = false;
var read_ok = false;
var scene_id: u32 = 0;
var mean: f64 = 0;
var worst: u8 = 0;
var off: usize = 0;

export fn parity_draw(scene: u32, scale: f32, format: u32) u32 {
    draw(scene, scale, format) catch return 1;
    return 0;
}

fn draw(scene: u32, scale: f32, format: u32) !void {
    if (shown != null and !ready) return error.ReadPending;
    if (scene > 18 or (scale != 1 and scale != 2) or format > 1) return error.InvalidScene;
    if (!fonts_ready) {
        if (!ui.registerFont(@embedFile("web_fonts/DejaVuSans.ttf")) or !ui.registerFont(@embedFile("web_fonts/DejaVuSans-Bold.ttf"))) return error.Font;
        fonts_ready = true;
        var px: [48 * 32 * 4]u8 = undefined;
        for (0..32) |y| for (0..48) |x| {
            const a: u8 = @intCast(255 - x * 2);
            px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(y * 8 * a / 255), @intCast(x * 5 * a / 255), @intCast(200 * @as(u32, a) / 255), a };
        };
        picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
    }
    if (renderer == null) renderer = try webgpu.Renderer.init();
    cleanupScene();
    scene_id = scene;
    ready = false;
    read_ok = false;
    const t = try gpa.create(ui.Tester);
    widgets = .{ .picture = picture };
    texture_scene.prepare(scene);
    const view = switch (scene) {
        0, 16 => ui.View.init(&widgets, Widgets.view),
        1 => ui.View.init(&canvas, Canvas.view),
        2, 3 => ui.View.init(&glass, Glass.view),
        4 => ui.View.init(&effects, Effects.view),
        13 => ui.View.init(&motion, Motion.Scene.view),
        else => ui.View.init(&texture_scene, TextureScene.view),
    };
    t.init(gpa, view, .{ .width = if (scene == 1) 240 else 360, .height = if (scene == 1) 180 else 300, .scale = scale, .dark = scene == 3 }) catch |err| {
        gpa.destroy(t);
        return err;
    };
    tester = t;
    if (scene == 16) {
        t.text.images.sink = .{ .ctx = &renderer.?, .upload = webgpu.Renderer.uploadImage };
        t.text.images.invalidateAtlas();
    }
    t.settle(1);
    if (scene == 13) for (t.instances.items) |*i| if (i.rect[0] == 25 and i.rect[1] == 150) {
        i.vel = .{ 9, 4, 0, 0 };
    };
    const width: u32 = @intFromFloat(t.size.w * scale);
    const height: u32 = @intFromFloat(t.size.h * scale);
    target = try .init(width, height, @fromBackingInt(@intCast(format)));
    shown = .{ .bytes = try gpa.alloc(u8, width * height * 4), .width = width, .height = height };
    const r = &renderer.?;
    r.gradients = t.ctx.gradients.items;
    r.textures = t.ctx.textures.items;
    r.before_encode = if (scene == 10) .{ .ctx = &texture_scene, .func = TextureScene.encode } else null;
    // Each scene has a fresh TextSystem and Images with fresh generations.
    r.atlas_generation = std.math.maxInt(u64);
    r.images_generation = std.math.maxInt(u64);
    r.sync(t.text.atlas.mask(), t.text.atlas.generation, if (scene == 16) .{} else t.text.images.pictures(), t.text.images.generation);
    r.draw(t.instances.items, t.size, scale, t.theme.background, target.?, t.ctx.time);
    r.readInto(target.?, shown.?, t, completed);
}

fn completed(_: *anyopaque, ok: bool) void {
    read_ok = ok;
    ready = true;
}

export fn parity_compare() u32 {
    return compare() catch 1;
}

fn compare() !u32 {
    if (!ready or !read_ok) return error.Readback;
    const cpu = if (scene_id == 13) try Motion.render(tester.?, gpa) else try tester.?.render(gpa);
    defer cpu.deinit(gpa);
    var total: u64 = 0;
    worst = 0;
    off = 0;
    for (shown.?.bytes, cpu.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.bytes.len));
    if ((scene_id >= 5 and scene_id <= 15 and scene_id != 13) or scene_id >= 17) return if (mean < 0.5 and worst <= 24 and off * 200 < cpu.bytes.len) 0 else 2;
    const glass_scene = scene_id == 2 or scene_id == 3;
    return if (mean < (if (glass_scene) @as(f64, 0.1) else 0.05) and worst <= (if (glass_scene) @as(u8, 24) else if (scene_id == 1) @as(u8, 32) else 16) and off * (if (glass_scene) @as(usize, 500) else 1000) < cpu.bytes.len) 0 else 2;
}

export fn parity_mean() f64 {
    return mean;
}
export fn parity_worst() u32 {
    return worst;
}
export fn parity_off() u32 {
    return @intCast(off);
}
export fn parity_instances() u32 {
    return @intCast(tester.?.instances.items.len);
}
export fn parity_pixels() [*]const u8 {
    return shown.?.bytes.ptr;
}
export fn parity_cpu_pixels() [*]const u8 {
    // For failed-scene diagnostics only; freed with parity_deinit.
    if (diagnostic_cpu) |px| px.deinit(gpa);
    diagnostic_cpu = (if (scene_id == 13) Motion.render(tester.?, gpa) else tester.?.render(gpa)) catch return shown.?.bytes.ptr;
    return diagnostic_cpu.?.bytes.ptr;
}
var diagnostic_cpu: ?gpu.Pixels = null;

fn cleanupScene() void {
    if (shown) |px| px.deinit(gpa);
    shown = null;
    if (diagnostic_cpu) |px| px.deinit(gpa);
    diagnostic_cpu = null;
    if (renderer) |*r| r.clearSamples();
    if (target) |t| t.deinit();
    target = null;
    if (tester) |t| {
        t.deinit();
        gpa.destroy(t);
    }
    tester = null;
}

export fn parity_deinit() void {
    if (shown != null and !ready) return;
    cleanupScene();
    if (renderer) |*r| r.deinit();
    renderer = null;
}

export fn parity_source(handle: u32, external: u32, r: u32, g: u32, b: u32) void {
    texture_scene.handle = handle;
    texture_scene.external = external;
    texture_scene.external_rgb = .{ @intCast(r), @intCast(g), @intCast(b) };
}

export fn parity_reset_renderer() void {
    cleanupScene();
    if (renderer) |*r| r.deinit();
    renderer = null;
}

export fn parity_instances_ptr() usize {
    return @intFromPtr(tester.?.instances.items.ptr);
}

export fn parity_reference() usize {
    return @intFromPtr(&texture_scene.reference);
}
