//! GTK 3, GDK, GLib and cairo, loaded when the app starts (as mygo loads
//! them with purego): no headers and no libraries at build time, so Linux
//! builds come from any machine. Each function is looked up by its name
//! from the field of the same name.
const std = @import("std");

pub const Widget = anyopaque;
pub const Event = anyopaque;
pub const Callback = *const anyopaque;
pub const SourceFn = *const fn (data: ?*anyopaque) callconv(.c) c_int;
pub const FdFn = *const fn (fd: c_int, condition: c_uint, data: ?*anyopaque) callconv(.c) c_int;
pub const ChildFn = *const fn (pid: c_int, status: c_int, data: ?*anyopaque) callconv(.c) void;
pub const TickFn = *const fn (widget: *Widget, clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int;

pub const Rectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

pub const Api = struct {
    // GLib and GObject.
    g_signal_connect_data: *const fn (instance: *anyopaque, signal: [*:0]const u8, handler: Callback, data: ?*anyopaque, destroy: ?*anyopaque, flags: c_uint) callconv(.c) c_ulong,
    g_timeout_add: *const fn (ms: c_uint, func: SourceFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_idle_add: *const fn (func: SourceFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_source_remove: *const fn (id: c_uint) callconv(.c) c_int,
    g_unix_fd_add: *const fn (fd: c_int, condition: c_uint, func: FdFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_child_watch_add: *const fn (pid: c_int, func: ChildFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_main_context_iteration: *const fn (ctx: ?*anyopaque, may_block: c_int) callconv(.c) c_int,
    g_free: *const fn (ptr: ?*anyopaque) callconv(.c) void,
    g_object_unref: *const fn (obj: *anyopaque) callconv(.c) void,
    g_slist_free: *const fn (list: ?*anyopaque) callconv(.c) void,
    // GTK.
    gtk_init_check: *const fn (argc: ?*c_int, argv: ?*anyopaque) callconv(.c) c_int,
    gtk_main: *const fn () callconv(.c) void,
    gtk_main_quit: *const fn () callconv(.c) void,
    gtk_window_new: *const fn (kind: c_int) callconv(.c) *Widget,
    gtk_window_set_title: *const fn (w: *Widget, title: [*:0]const u8) callconv(.c) void,
    gtk_window_set_default_size: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_window_resize: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_window_move: *const fn (w: *Widget, x: c_int, y: c_int) callconv(.c) void,
    gtk_window_get_size: *const fn (w: *Widget, width: *c_int, height: *c_int) callconv(.c) void,
    gtk_window_get_position: *const fn (w: *Widget, x: *c_int, y: *c_int) callconv(.c) void,
    gtk_window_set_position: *const fn (w: *Widget, pos: c_int) callconv(.c) void,
    gtk_window_set_resizable: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_set_keep_above: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_present: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_iconify: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_maximize: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_unmaximize: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_is_maximized: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_window_fullscreen: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_unfullscreen: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_is_active: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_set_size_request: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_widget_show_all: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_hide: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_destroy: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_queue_draw_area: *const fn (w: *Widget, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void,
    gtk_widget_get_allocated_width: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_get_allocated_height: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_get_scale_factor: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_add_events: *const fn (w: *Widget, mask: c_int) callconv(.c) void,
    gtk_widget_set_can_focus: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_widget_grab_focus: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_get_window: *const fn (w: *Widget) callconv(.c) ?*anyopaque,
    gtk_widget_is_visible: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_add_tick_callback: *const fn (w: *Widget, func: TickFn, data: ?*anyopaque, notify: ?*anyopaque) callconv(.c) c_uint,
    gtk_widget_remove_tick_callback: *const fn (w: *Widget, id: c_uint) callconv(.c) void,
    gtk_container_add: *const fn (container: *Widget, child: *Widget) callconv(.c) void,
    gtk_drawing_area_new: *const fn () callconv(.c) *Widget,
    gtk_im_multicontext_new: *const fn () callconv(.c) *anyopaque,
    gtk_im_context_set_client_window: *const fn (im: *anyopaque, window: ?*anyopaque) callconv(.c) void,
    gtk_im_context_filter_keypress: *const fn (im: *anyopaque, event: *Event) callconv(.c) c_int,
    gtk_im_context_focus_in: *const fn (im: *anyopaque) callconv(.c) void,
    gtk_im_context_focus_out: *const fn (im: *anyopaque) callconv(.c) void,
    gtk_im_context_set_cursor_location: *const fn (im: *anyopaque, rect: *const Rectangle) callconv(.c) void,
    gtk_im_context_get_preedit_string: *const fn (im: *anyopaque, str: *?[*:0]u8, attrs: ?*anyopaque, cursor: *c_int) callconv(.c) void,
    gtk_clipboard_get: *const fn (selection: ?*anyopaque) callconv(.c) *anyopaque,
    gtk_clipboard_set_text: *const fn (cb: *anyopaque, text: [*]const u8, len: c_int) callconv(.c) void,
    gtk_clipboard_wait_for_text: *const fn (cb: *anyopaque) callconv(.c) ?[*:0]u8,
    gtk_message_dialog_new: *const fn (parent: ?*Widget, flags: c_int, kind: c_int, buttons: c_int, format: [*:0]const u8, ...) callconv(.c) *Widget,
    gtk_dialog_add_button: *const fn (dialog: *Widget, text: [*:0]const u8, response: c_int) callconv(.c) ?*Widget,
    gtk_dialog_run: *const fn (dialog: *Widget) callconv(.c) c_int,
    gtk_file_chooser_native_new: *const fn (title: [*:0]const u8, parent: ?*Widget, action: c_int, accept: ?[*:0]const u8, cancel: ?[*:0]const u8) callconv(.c) *anyopaque,
    gtk_native_dialog_run: *const fn (dialog: *anyopaque) callconv(.c) c_int,
    gtk_file_chooser_set_select_multiple: *const fn (chooser: *anyopaque, on: c_int) callconv(.c) void,
    gtk_file_chooser_set_current_name: *const fn (chooser: *anyopaque, name: [*:0]const u8) callconv(.c) void,
    gtk_file_chooser_set_current_folder: *const fn (chooser: *anyopaque, folder: [*:0]const u8) callconv(.c) c_int,
    gtk_file_chooser_get_filenames: *const fn (chooser: *anyopaque) callconv(.c) ?*SList,
    gtk_file_chooser_get_filename: *const fn (chooser: *anyopaque) callconv(.c) ?[*:0]u8,
    // GDK.
    gdk_event_get_coords: *const fn (e: *Event, x: *f64, y: *f64) callconv(.c) c_int,
    gdk_event_get_button: *const fn (e: *Event, button: *c_uint) callconv(.c) c_int,
    gdk_event_get_click_count: *const fn (e: *Event, count: *c_uint) callconv(.c) c_int,
    gdk_event_get_state: *const fn (e: *Event, state: *c_uint) callconv(.c) c_int,
    gdk_event_get_keyval: *const fn (e: *Event, keyval: *c_uint) callconv(.c) c_int,
    gdk_event_get_scroll_deltas: *const fn (e: *Event, dx: *f64, dy: *f64) callconv(.c) c_int,
    gdk_event_get_scroll_direction: *const fn (e: *Event, dir: *c_int) callconv(.c) c_int,
    gdk_event_get_event_type: *const fn (e: *Event) callconv(.c) c_int,
    gdk_keyval_to_unicode: *const fn (keyval: c_uint) callconv(.c) u32,
    gdk_atom_intern: *const fn (name: [*:0]const u8, only_if_exists: c_int) callconv(.c) ?*anyopaque,
    gdk_display_get_default: *const fn () callconv(.c) ?*anyopaque,
    gdk_cursor_new_from_name: *const fn (display: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque,
    gdk_window_set_cursor: *const fn (window: *anyopaque, cursor: ?*anyopaque) callconv(.c) void,
    // cairo.
    cairo_image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) *anyopaque,
    cairo_surface_set_device_scale: *const fn (surface: *anyopaque, x: f64, y: f64) callconv(.c) void,
    cairo_set_source_surface: *const fn (cr: *anyopaque, surface: *anyopaque, x: f64, y: f64) callconv(.c) void,
    cairo_paint: *const fn (cr: *anyopaque) callconv(.c) void,
    cairo_surface_destroy: *const fn (surface: *anyopaque) callconv(.c) void,
};

pub const SList = extern struct { data: ?*anyopaque, next: ?*SList };

pub var api: Api = undefined;
var loaded = false;

/// Loads GTK and what it links (GDK, GLib, cairo); false when it is not
/// installed.
pub fn load() bool {
    if (loaded) return true;
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse {
            std.log.err("nanoui: GTK lacks {s}", .{name});
            return false;
        };
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

pub fn connect(instance: *anyopaque, signal: [*:0]const u8, handler: Callback, data: ?*anyopaque) void {
    _ = api.g_signal_connect_data(instance, signal, handler, data, null, 0);
}

// Event masks.
pub const pointer_motion_mask = 1 << 2;
pub const button_press_mask = 1 << 8;
pub const button_release_mask = 1 << 9;
pub const key_press_mask = 1 << 10;
pub const leave_notify_mask = 1 << 13;
pub const focus_change_mask = 1 << 14;
pub const scroll_mask = 1 << 21;
pub const smooth_scroll_mask = 1 << 23;

// Modifier state.
pub const shift_mask = 1 << 0;
pub const control_mask = 1 << 2;
pub const alt_mask = 1 << 3;
pub const super_mask = 1 << 26;

// Event types.
pub const double_press = 5;
pub const triple_press = 6;
