//! Native UI drawn with OpenGL on Linux: a GtkGLArea (GTK makes the
//! context, GLX or EGL) whose frames the OpenGL renderer draws. GTK may give
//! an OpenGL ES context even when desktop GL is asked for, so the API is
//! read from the context and the ES shaders are used for it. There is no
//! CPU fallback: `NANOUI_RENDERER=cpu` is the only way to draw on the CPU.
//! GTK's GL functions are loaded apart from the rest (`gtk.zig`), so a GTK
//! without them reports the missing OpenGL instead.
const std = @import("std");
const gtk = @import("gtk.zig");
const gl = @import("../ui/gl.zig");
const opengl = @import("../ui/opengl.zig");

const GError = extern struct {
    domain: u32,
    code: c_int,
    message: [*:0]u8,
};

const Api = struct {
    gtk_gl_area_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_gl_area_set_required_version: *const fn (area: *gtk.Widget, major: c_int, minor: c_int) callconv(.c) void,
    gtk_gl_area_set_use_es: *const fn (area: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_gl_area_make_current: *const fn (area: *gtk.Widget) callconv(.c) void,
    gtk_gl_area_get_error: *const fn (area: *gtk.Widget) callconv(.c) ?*anyopaque,
    gtk_gl_area_queue_render: *const fn (area: *gtk.Widget) callconv(.c) void,
    gtk_widget_show: *const fn (w: *gtk.Widget) callconv(.c) void,
};

pub var api: Api = undefined;
/// GTK 3's only (GTK 4's GL areas are opaque unless asked otherwise).
var set_has_alpha: ?*const fn (area: *gtk.Widget, on: c_int) callconv(.c) void = null;
var state: enum { unknown, loaded, missing } = .unknown;

fn load() bool {
    if (state == .unknown) state = blk: {
        // The GTK that's loaded (gtk.zig): GtkGLArea is the same in 3 and 4.
        const lib = std.c.dlopen(if (gtk.v4) "libgtk-4.so.1" else "libgtk-3.so.0", .{ .NOW = true }) orelse break :blk .missing;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse break :blk .missing;
            @field(api, name) = @ptrCast(@alignCast(sym));
        }
        if (std.c.dlsym(lib, "gtk_gl_area_set_has_alpha")) |sym| set_has_alpha = @ptrCast(@alignCast(sym));
        break :blk .loaded;
    };
    return state == .loaded;
}

/// A GL area asking for OpenGL 3.0, opaque unless `alpha` (a transparent
/// window's); null without OpenGL.
pub fn new(alpha: bool) ?*gtk.Widget {
    if (!load()) return null;
    const area = api.gtk_gl_area_new();
    api.gtk_gl_area_set_use_es(area, 0);
    api.gtk_gl_area_set_required_version(area, 3, 0);
    if (set_has_alpha) |f| f(area, @intFromBool(alpha));
    return area;
}

/// The renderer for a GL area that was just realized, its context current.
/// GTK's context can be desktop GL or OpenGL ES (NVIDIA's EGL gives ES 3.2
/// for a 3.0 request); the version string decides which shaders to use.
pub fn start(area: *gtk.Widget) !opengl.Renderer {
    api.gtk_gl_area_make_current(area);
    if (api.gtk_gl_area_get_error(area)) |err| {
        const e: *GError = @ptrCast(@alignCast(err));
        std.log.err("nanoui: GTK could not create a GL context: {s}", .{std.mem.span(e.message)});
        return error.NoOpenGLContext;
    }
    if (!gl.load() and !gl.loadEs()) {
        std.log.err("nanoui: no OpenGL loader is available", .{});
        return error.OpenGLUnavailable;
    }
    const version: []const u8 = if (gl.api.glGetString(gl.VERSION)) |v| std.mem.span(v) else "";
    if (std.mem.startsWith(u8, version, "OpenGL ES")) {
        return opengl.Renderer.initEs() catch |err| {
            std.log.err("nanoui: OpenGL ES renderer failed: {s}", .{@errorName(err)});
            return err;
        };
    }
    return opengl.Renderer.init() catch |err| {
        std.log.err("nanoui: OpenGL renderer failed: {s}", .{@errorName(err)});
        return err;
    };
}

/// The GPU the current context draws on, as the driver names it.
pub fn gpuName() []const u8 {
    return std.mem.span(gl.api.glGetString(gl.RENDERER) orelse return "?");
}

/// The framebuffer GTK draws the area from, bound when it asks to render.
pub fn target() u32 {
    var fbo: i32 = 0;
    gl.api.glGetIntegerv(gl.DRAW_FRAMEBUFFER_BINDING, &fbo);
    return @intCast(fbo);
}
