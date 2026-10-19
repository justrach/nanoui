//! Native UI drawn with OpenGL on Linux: a GtkGLArea (GTK makes the
//! context, GLX or EGL) whose frames the OpenGL renderer draws. Where
//! there is no OpenGL 3.3, or `NANOUI_RENDERER=cpu`, the surface keeps the
//! CPU renderer's drawing area. GTK's GL functions are loaded apart from
//! the rest (`gtk.zig`), so a GTK without them still runs.
const std = @import("std");
const gtk = @import("gtk.zig");
const gl = @import("../ui/gl.zig");
const opengl = @import("../ui/opengl.zig");

const Api = struct {
    gtk_gl_area_new: *const fn () callconv(.c) *gtk.Widget,
    gtk_gl_area_set_required_version: *const fn (area: *gtk.Widget, major: c_int, minor: c_int) callconv(.c) void,
    gtk_gl_area_set_use_es: *const fn (area: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_gl_area_set_has_alpha: *const fn (area: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_gl_area_make_current: *const fn (area: *gtk.Widget) callconv(.c) void,
    gtk_gl_area_get_error: *const fn (area: *gtk.Widget) callconv(.c) ?*anyopaque,
    gtk_gl_area_queue_render: *const fn (area: *gtk.Widget) callconv(.c) void,
    gtk_widget_show: *const fn (w: *gtk.Widget) callconv(.c) void,
};

pub var api: Api = undefined;
var state: enum { unknown, loaded, missing } = .unknown;

fn load() bool {
    if (state == .unknown) state = blk: {
        if (!gl.load()) break :blk .missing;
        const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true }) orelse break :blk .missing;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse break :blk .missing;
            @field(api, name) = @ptrCast(@alignCast(sym));
        }
        break :blk .loaded;
    };
    return state == .loaded;
}

/// A GL area asking for OpenGL 3.3 core, opaque; null without OpenGL.
pub fn new() ?*gtk.Widget {
    if (!load()) return null;
    const area = api.gtk_gl_area_new();
    api.gtk_gl_area_set_use_es(area, 0);
    api.gtk_gl_area_set_required_version(area, 3, 3);
    api.gtk_gl_area_set_has_alpha(area, 0);
    return area;
}

/// The renderer for a GL area that was just realized, its context
/// current; null when GTK made no context or the renderer can't run on it.
pub fn start(area: *gtk.Widget) ?opengl.Renderer {
    api.gtk_gl_area_make_current(area);
    if (api.gtk_gl_area_get_error(area) != null) {
        std.log.warn("nanoui: no OpenGL context; drawing on the CPU", .{});
        return null;
    }
    return opengl.Renderer.init() catch {
        std.log.warn("nanoui: OpenGL renderer failed; drawing on the CPU", .{});
        return null;
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
