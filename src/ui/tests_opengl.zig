//! The OpenGL renderer against the CPU renderer, in an OpenGL context
//! without a window (EGL's surfaceless platform, as Mesa has it): the
//! widgets, glass and canvas scenes drawn by both must come out the same, to
//! rounding; with OpenGL 3.3, and with OpenGL ES 3 as Android draws (on
//! Android too, its driver's, in a tiny pbuffer's context). Skipped where
//! there is no EGL, or no such OpenGL.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gl = @import("gl.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const Renderer = @import("opengl.zig").Renderer;

/// An OpenGL 3.3 core (or OpenGL ES 3) context with no surface, made current.
const Egl = struct {
    display: *anyopaque,
    context: *anyopaque,
    terminate: *const fn (*anyopaque) callconv(.c) u32,
    destroy: *const fn (*anyopaque, *anyopaque) callconv(.c) u32,

    fn init(es: bool) ?Egl {
        const android = @import("builtin").abi.isAndroid();
        const lib = std.c.dlopen(if (android) "libEGL.so" else "libEGL.so.1", .{ .NOW = true }) orelse return null;
        const getDisplay = sym(lib, *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque, "eglGetPlatformDisplay") orelse return null;
        const initialize = sym(lib, *const fn (*anyopaque, ?*i32, ?*i32) callconv(.c) u32, "eglInitialize") orelse return null;
        const bindApi = sym(lib, *const fn (u32) callconv(.c) u32, "eglBindAPI") orelse return null;
        const chooseConfig = sym(lib, *const fn (*anyopaque, [*]const i32, *?*anyopaque, i32, *i32) callconv(.c) u32, "eglChooseConfig") orelse return null;
        const createContext = sym(lib, *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque, "eglCreateContext") orelse return null;
        const makeCurrent = sym(lib, *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32, "eglMakeCurrent") orelse return null;
        const terminate = sym(lib, *const fn (*anyopaque) callconv(.c) u32, "eglTerminate") orelse return null;
        const destroy = sym(lib, *const fn (*anyopaque, *anyopaque) callconv(.c) u32, "eglDestroyContext") orelse return null;
        const createPbuffer = sym(lib, *const fn (*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque, "eglCreatePbufferSurface") orelse return null;

        // Android's EGL has no surfaceless platform: its own, the default display.
        const surfaceless_mesa = 0x31DD;
        const platform_android = 0x3141;
        if (android and !es) return null;
        const display = getDisplay(if (android) platform_android else surfaceless_mesa, null, null) orelse return null;
        if (initialize(display, null, null) == 0) return null;
        // EGL_OPENGL_ES_API, EGL_OPENGL_API.
        if (bindApi(if (es) 0x30A0 else 0x30A2) == 0) return null;
        // EGL_SURFACE_TYPE pbuffer, EGL_RENDERABLE_TYPE OpenGL ES 3 or OpenGL, EGL_NONE.
        const config_attribs = [_]i32{ 0x3033, 0x0001, 0x3040, if (es) 0x0040 else 0x0008, 0x3038 };
        var config: ?*anyopaque = null;
        var n: i32 = 0;
        if (chooseConfig(display, &config_attribs, &config, 1, &n) == 0 or n == 0) return null;
        // Version 3.3, the core profile, EGL_NONE; or OpenGL ES 3.
        const gl_attribs = [_]i32{ 0x3098, 3, 0x30FB, 3, 0x30FD, 0x1, 0x3038 };
        const es_attribs = [_]i32{ 0x3098, 3, 0x3038 };
        const context = createContext(display, config, null, if (es) &es_attribs else &gl_attribs) orelse return null;
        // Android's needs a surface to be current: one pixel's, never drawn.
        const pbuffer = if (android) createPbuffer(display, config, &[_]i32{ 0x3057, 1, 0x3056, 1, 0x3038 }) orelse return null else null;
        if (makeCurrent(display, pbuffer, pbuffer, context) == 0) return null;
        return .{ .display = display, .context = context, .terminate = terminate, .destroy = destroy };
    }

    fn sym(lib: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
        return @ptrCast(@alignCast(std.c.dlsym(lib, name) orelse return null));
    }

    fn deinit(e: Egl) void {
        _ = e.destroy(e.display, e.context);
        _ = e.terminate(e.display);
    }
};

const Limits = struct { mean: f64, worst: u8, off_in: usize };

/// Draws the Tester's last frame with OpenGL and with the CPU renderer,
/// and expects them within `limits`.
fn compare(t: *ui.Tester, limits: Limits, es: bool) !void {
    const gpa = testing.allocator;
    var r = if (es) try Renderer.initEs() else try Renderer.init();
    defer r.deinit();
    r.sync(t.text.atlas.mask(), t.text.atlas.generation, t.text.images.pictures(), t.text.images.generation);
    r.draw(t.instances.items, t.size, t.scale, t.theme.background, 0, t.ctx.time);
    const ours = try r.read(gpa);
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
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.bytes.len));
    if (mean >= limits.mean or worst > limits.worst or off * limits.off_in >= cpu.bytes.len)
        std.debug.print("OpenGL{s} vs CPU: mean {d:.4}, worst {d}, {d} of {d} channels off\n", .{ if (es) " ES" else "", mean, worst, off, cpu.bytes.len });
    try testing.expect(mean < limits.mean);
    try testing.expect(worst <= limits.worst);
    // Edges may round differently; few channels more than 8 levels apart.
    try testing.expect(off * limits.off_in < cpu.bytes.len);
}

test "the OpenGL renderer draws what the CPU renderer draws" {
    const egl = Egl.init(false) orelse return error.SkipZigTest;
    defer egl.deinit();
    if (!gl.load()) return error.SkipZigTest;
    try scenes(false);
}

test "the OpenGL ES renderer draws what the CPU renderer draws" {
    const egl = Egl.init(true) orelse return error.SkipZigTest;
    defer egl.deinit();
    if (!gl.loadEs()) return error.SkipZigTest;
    try scenes(true);
}

/// The scenes, drawn by both renderers.
fn scenes(es: bool) !void {
    const gpa = testing.allocator;
    // A gradient picture, half transparent at one end.
    var px: [48 * 32 * 4]u8 = undefined;
    for (0..32) |y| for (0..48) |x| {
        const a: u8 = @intCast(255 - x * 2);
        px[(y * 48 + x) * 4 ..][0..4].* = .{ @intCast(y * 8 * a / 255), @intCast(x * 5 * a / 255), @intCast(200 * @as(u32, a) / 255), a };
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
    defer gpa.free(picture);
    {
        const Scene = @import("tests_raster.zig").Scene;
        var s: Scene = .{ .picture = picture };
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
        defer t.deinit();
        t.settle(1);
        // The Metal comparison's limits. Measured on an Intel Arc (Mesa):
        // a mean of 0.004 and at worst 1 level apart.
        try compare(&t, .{ .mean = 0.05, .worst = 16, .off_in = 1000 }, es);
    }
    for ([_]ui.Theme{ .light, .dark_theme }) |theme| {
        const Scene = @import("tests_glass.zig").Scene;
        var s: Scene = .{};
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 290, .theme = theme });
        defer t.deinit();
        t.settle(1);
        // Measured: a mean of 0.015 and at worst 2 levels apart.
        try compare(&t, .{ .mean = 0.1, .worst = 24, .off_in = 500 }, es);
    }
    {
        // Lines, dashes, a filled polygon (triangles meeting at an edge).
        const Scene = @import("tests_canvas.zig").Scene;
        var s: Scene = .{};
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, Scene.view), .{ .width = 240, .height = 180 });
        defer t.deinit();
        t.settle(0.1);
        try compare(&t, .{ .mean = 0.05, .worst = 32, .off_in = 1000 }, es);
    }
}
