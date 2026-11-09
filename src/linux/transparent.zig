//! A transparent window on Linux (`Options.transparent`): only what the view
//! draws shows. GTK 4 takes it by turning the window's own background off
//! (one CSS rule) and letting the frame's alpha through: on Wayland the
//! compositor always blends it. GTK 3, where a compositor runs (X11 with
//! one, and every Wayland session) the window takes the screen's RGBA visual,
//! is cleared to nothing before its child draws, and the GL area keeps an
//! alpha channel: the corners of a rounded panel are antialiased against the
//! desktop. Where none runs, alpha can't show, so the window is cut instead
//! to what the frame draws more than half opaque (the Shape extension: hard
//! edges, but nothing square behind the corners); the CPU renderer draws it,
//! so the shape can be read from its pixels. The GTK 3 functions are looked
//! up, not required: a GTK without them leaves the window opaque.
const std = @import("std");
const gtk = @import("gtk.zig");

pub const Mode = enum {
    /// An ordinary window.
    none,
    /// RGBA: the frame's alpha is the window's.
    alpha,
    /// No compositor: the window is shaped to the frame.
    shape,
};

const Api = struct {
    gtk_widget_get_screen: *const fn (w: *gtk.Widget) callconv(.c) ?*anyopaque,
    gdk_screen_get_rgba_visual: *const fn (screen: *anyopaque) callconv(.c) ?*anyopaque,
    gdk_screen_is_composited: *const fn (screen: *anyopaque) callconv(.c) c_int,
    gtk_widget_set_visual: *const fn (w: *gtk.Widget, visual: ?*anyopaque) callconv(.c) void,
    gtk_widget_set_app_paintable: *const fn (w: *gtk.Widget, on: c_int) callconv(.c) void,
    gtk_widget_shape_combine_region: *const fn (w: *gtk.Widget, region: ?*anyopaque) callconv(.c) void,
    gdk_cairo_region_create_from_surface: *const fn (surface: *anyopaque) callconv(.c) ?*anyopaque,
    cairo_region_destroy: *const fn (region: *anyopaque) callconv(.c) void,
    cairo_region_is_empty: *const fn (region: *anyopaque) callconv(.c) c_int,
    cairo_region_create_rectangle: *const fn (rect: *const gtk.Rectangle) callconv(.c) ?*anyopaque,
    cairo_set_operator: *const fn (cr: *anyopaque, op: c_int) callconv(.c) void,
    cairo_set_source_rgba: *const fn (cr: *anyopaque, r: f64, g: f64, b: f64, a: f64) callconv(.c) void,
};

var api: Api = undefined;
var loaded: ?bool = null;
const cairo_operator_source = 1;
const cairo_operator_over = 2;

fn load() bool {
    if (loaded) |l| return l;
    loaded = blk: {
        const libs = [_][*:0]const u8{ "libgtk-3.so.0", "libgdk-3.so.0", "libcairo.so.2" };
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            const sym = for (libs) |lib| {
                const h = std.c.dlopen(lib, .{ .NOW = true }) orelse continue;
                if (std.c.dlsym(h, name)) |s| break s;
            } else break :blk false;
            @field(api, name) = @ptrCast(@alignCast(sym));
        }
        break :blk true;
    };
    return loaded.?;
}

/// Makes `win` (a GTK toplevel, not yet realized) transparent, as far as
/// the screen allows: which way it went.
pub fn setup(win: *gtk.Widget) Mode {
    if (gtk.v4) return setupV4(win);
    if (!load()) return .none;
    const screen = api.gtk_widget_get_screen(win) orelse return .none;
    // The theme's background isn't drawn under the view, in either mode.
    api.gtk_widget_set_app_paintable(win, 1);
    gtk.connect(win, "draw", @ptrCast(&clear), null);
    if (api.gdk_screen_is_composited(screen) == 0) return .shape;
    const visual = api.gdk_screen_get_rgba_visual(screen) orelse return .shape;
    api.gtk_widget_set_visual(win, visual);
    return .alpha;
}

/// GTK 4's own: the window's background (the theme's, painted behind the
/// child) is turned off with one CSS provider, and what the view draws —
/// alpha and all — is what shows. On Wayland that is exactly the frame's
/// alpha; on X11 it shows where a compositor runs.
const Api4 = struct {
    gtk_css_provider_new: *const fn () callconv(.c) *anyopaque,
    gtk_css_provider_load_from_data: *const fn (p: *anyopaque, data: [*]const u8, len: isize) callconv(.c) void,
    gtk_style_context_add_provider_for_display: *const fn (display: *anyopaque, provider: *anyopaque, priority: c_uint) callconv(.c) void,
    gtk_widget_add_css_class: *const fn (w: *gtk.Widget, name: [*:0]const u8) callconv(.c) void,
};

var api4: Api4 = undefined;
var loaded4: ?bool = null;
/// The provider is the display's, added once for every transparent window.
var css_added = false;
/// GTK_STYLE_PROVIDER_PRIORITY_USER: above the theme's own window background.
const css_priority = 800;

fn load4() bool {
    if (loaded4) |l| return l;
    loaded4 = blk: {
        const lib = std.c.dlopen("libgtk-4.so.1", .{ .NOW = true, .GLOBAL = true }) orelse break :blk false;
        inline for (@typeInfo(Api4).@"struct".field_names) |name| {
            const sym = std.c.dlsym(lib, name) orelse break :blk false;
            @field(api4, name) = @ptrCast(@alignCast(sym));
        }
        break :blk true;
    };
    return loaded4.?;
}

fn setupV4(win: *gtk.Widget) Mode {
    if (!load4()) return .none;
    const display = gtk.api.gdk_display_get_default() orelse return .none;
    if (!css_added) {
        const provider = api4.gtk_css_provider_new();
        // Only what takes the class: an app's other windows keep theirs.
        const css = "window.nanoui-transparent { background: none; }";
        api4.gtk_css_provider_load_from_data(provider, css, css.len);
        api4.gtk_style_context_add_provider_for_display(display, provider, css_priority);
        gtk.api.g_object_unref(provider);
        css_added = true;
    }
    api4.gtk_widget_add_css_class(win, "nanoui-transparent");
    return .alpha;
}

/// Before the child draws: the window cleared to nothing.
fn clear(_: *gtk.Widget, cr: *anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    api.cairo_set_operator(cr, cairo_operator_source);
    api.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    gtk.api.cairo_paint(cr);
    api.cairo_set_operator(cr, cairo_operator_over);
    // The default draw still runs, and draws the child.
    return 0;
}

/// No compositor: `win` (`width` × `height` points) cut to what `surface`
/// (the frame, as cairo has it) draws more than half opaque.
pub fn shapeTo(win: *gtk.Widget, surface: *anyopaque, width: f32, height: f32) void {
    if (loaded != true) return;
    var region = api.gdk_cairo_region_create_from_surface(surface) orelse return;
    if (api.cairo_region_is_empty(region) != 0) {
        // Nothing drawn yet (a view fading in): one pixel in the middle is
        // kept, or no part of the window would be left to draw the next
        // frame in, and it would stay cut to nothing.
        api.cairo_region_destroy(region);
        const dot: gtk.Rectangle = .{ .x = @intFromFloat(width / 2), .y = @intFromFloat(height / 2), .width = 1, .height = 1 };
        region = api.cairo_region_create_rectangle(&dot) orelse return;
    }
    defer api.cairo_region_destroy(region);
    api.gtk_widget_shape_combine_region(win, region);
}

/// The frame's pixels go on as they are, alpha and all, rather than over
/// what was there (`cairo_set_operator`'s SOURCE).
pub fn replace(cr: *anyopaque) void {
    if (loaded == true) api.cairo_set_operator(cr, cairo_operator_source);
}
