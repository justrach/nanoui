//! The OpenGL renderer against the CPU renderer, in an OpenGL context
//! without a window (EGL's surfaceless platform, as Mesa has it): the
//! widgets and glass scenes drawn by both must come out the same, to
//! rounding. Skipped where there is no EGL or no OpenGL 3.3.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gl = @import("gl.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const Renderer = @import("opengl.zig").Renderer;

/// An OpenGL 3.3 core context with no surface, made current.
const Egl = struct {
    display: *anyopaque,
    context: *anyopaque,
    terminate: *const fn (*anyopaque) callconv(.c) u32,
    destroy: *const fn (*anyopaque, *anyopaque) callconv(.c) u32,

    fn init() ?Egl {
        const lib = std.c.dlopen("libEGL.so.1", .{ .NOW = true }) orelse return null;
        const getDisplay = sym(lib, *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque, "eglGetPlatformDisplay") orelse return null;
        const initialize = sym(lib, *const fn (*anyopaque, ?*i32, ?*i32) callconv(.c) u32, "eglInitialize") orelse return null;
        const bindApi = sym(lib, *const fn (u32) callconv(.c) u32, "eglBindAPI") orelse return null;
        const chooseConfig = sym(lib, *const fn (*anyopaque, [*]const i32, *?*anyopaque, i32, *i32) callconv(.c) u32, "eglChooseConfig") orelse return null;
        const createContext = sym(lib, *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, [*]const i32) callconv(.c) ?*anyopaque, "eglCreateContext") orelse return null;
        const makeCurrent = sym(lib, *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32, "eglMakeCurrent") orelse return null;
        const terminate = sym(lib, *const fn (*anyopaque) callconv(.c) u32, "eglTerminate") orelse return null;
        const destroy = sym(lib, *const fn (*anyopaque, *anyopaque) callconv(.c) u32, "eglDestroyContext") orelse return null;

        const surfaceless_mesa = 0x31DD;
        const display = getDisplay(surfaceless_mesa, null, null) orelse return null;
        if (initialize(display, null, null) == 0) return null;
        const opengl_api = 0x30A2;
        if (bindApi(opengl_api) == 0) return null;
        // EGL_SURFACE_TYPE pbuffer, EGL_RENDERABLE_TYPE OpenGL, EGL_NONE.
        const config_attribs = [_]i32{ 0x3033, 0x0001, 0x3040, 0x0008, 0x3038 };
        var config: ?*anyopaque = null;
        var n: i32 = 0;
        if (chooseConfig(display, &config_attribs, &config, 1, &n) == 0 or n == 0) return null;
        // Version 3.3, the core profile, EGL_NONE.
        const context_attribs = [_]i32{ 0x3098, 3, 0x30FB, 3, 0x30FD, 0x1, 0x3038 };
        const context = createContext(display, config, null, &context_attribs) orelse return null;
        if (makeCurrent(display, null, null, context) == 0) return null;
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
fn compare(t: *ui.Tester, limits: Limits) !void {
    const gpa = testing.allocator;
    var r = try Renderer.init();
    defer r.deinit();
    r.sync(t.text.atlas.mask(), t.text.atlas.generation, t.text.images.pictures(), t.text.images.generation);
    r.draw(t.instances.items, t.size, t.scale, t.theme.background, 0);
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
        std.debug.print("OpenGL vs CPU: mean {d:.4}, worst {d}, {d} of {d} channels off\n", .{ mean, worst, off, cpu.bytes.len });
    try testing.expect(mean < limits.mean);
    try testing.expect(worst <= limits.worst);
    // Edges may round differently; few channels more than 8 levels apart.
    try testing.expect(off * limits.off_in < cpu.bytes.len);
}

test "the OpenGL renderer draws what the CPU renderer draws" {
    const egl = Egl.init() orelse return error.SkipZigTest;
    defer egl.deinit();
    if (!gl.load()) return error.SkipZigTest;
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
        try compare(&t, .{ .mean = 0.05, .worst = 16, .off_in = 1000 });
    }
    for ([_]ui.Theme{ .light, .dark_theme }) |theme| {
        const Scene = @import("tests_glass.zig").Scene;
        var s: Scene = .{};
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 290, .theme = theme });
        defer t.deinit();
        t.settle(1);
        // Measured: a mean of 0.015 and at worst 2 levels apart.
        try compare(&t, .{ .mean = 0.1, .worst = 24, .off_in = 500 });
    }
}
