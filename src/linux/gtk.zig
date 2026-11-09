//! GTK (4 where it's installed, else 3), GDK, GLib and cairo, loaded when
//! the app starts (as mygo loads them with purego): no headers and no
//! libraries at build time, so Linux builds come from any machine. Each
//! function is looked up by its name from the field of the same name.
const std = @import("std");

pub const Widget = anyopaque;
pub const Event = anyopaque;
pub const Callback = *const anyopaque;
pub const SourceFn = *const fn (data: ?*anyopaque) callconv(.c) c_int;
pub const FdFn = *const fn (fd: c_int, condition: c_uint, data: ?*anyopaque) callconv(.c) c_int;
pub const ChildFn = *const fn (pid: c_int, status: c_int, data: ?*anyopaque) callconv(.c) void;
pub const TickFn = *const fn (widget: *Widget, clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int;

pub const Rectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

/// What GTK 3 and 4 both have, alike: GLib, GObject, cairo, and the GTK
/// calls that didn't change.
pub const Api = struct {
    // GLib, GObject and GIO.
    g_signal_connect_data: *const fn (instance: *anyopaque, signal: [*:0]const u8, handler: Callback, data: ?*anyopaque, destroy: ?*anyopaque, flags: c_uint) callconv(.c) c_ulong,
    g_timeout_add: *const fn (ms: c_uint, func: SourceFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_idle_add: *const fn (func: SourceFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_source_remove: *const fn (id: c_uint) callconv(.c) c_int,
    g_unix_fd_add: *const fn (fd: c_int, condition: c_uint, func: FdFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_child_watch_add: *const fn (pid: c_int, func: ChildFn, data: ?*anyopaque) callconv(.c) c_uint,
    g_main_context_iteration: *const fn (ctx: ?*anyopaque, may_block: c_int) callconv(.c) c_int,
    g_main_loop_new: *const fn (ctx: ?*anyopaque, running: c_int) callconv(.c) *anyopaque,
    g_main_loop_run: *const fn (loop: *anyopaque) callconv(.c) void,
    g_main_loop_quit: *const fn (loop: *anyopaque) callconv(.c) void,
    g_main_loop_unref: *const fn (loop: *anyopaque) callconv(.c) void,
    g_free: *const fn (ptr: ?*anyopaque) callconv(.c) void,
    g_object_unref: *const fn (obj: *anyopaque) callconv(.c) void,
    g_object_ref_sink: *const fn (obj: *anyopaque) callconv(.c) *anyopaque,
    g_object_new: *const fn (kind: usize, first_property: ?[*:0]const u8, ...) callconv(.c) ?*anyopaque,
    g_object_get: *const fn (obj: *anyopaque, first_property: [*:0]const u8, ...) callconv(.c) void,
    g_signal_handler_disconnect: *const fn (instance: *anyopaque, id: c_ulong) callconv(.c) void,
    g_memory_input_stream_new_from_data: *const fn (data: [*]const u8, len: isize, destroy: ?*anyopaque) callconv(.c) *anyopaque,
    g_slist_free: *const fn (list: ?*anyopaque) callconv(.c) void,
    // GTK, the same in 3 and 4.
    gtk_settings_get_default: *const fn () callconv(.c) ?*anyopaque,
    gtk_window_set_title: *const fn (w: *Widget, title: [*:0]const u8) callconv(.c) void,
    gtk_window_set_default_size: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_window_set_resizable: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_set_decorated: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_get_decorated: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_window_present: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_maximize: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_unmaximize: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_is_maximized: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_window_fullscreen: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_unfullscreen: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_is_active: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_set_size_request: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_widget_queue_draw: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_get_allocated_width: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_get_allocated_height: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_get_scale_factor: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_grab_focus: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_is_visible: *const fn (w: *Widget) callconv(.c) c_int,
    gtk_widget_set_opacity: *const fn (w: *Widget, opacity: f64) callconv(.c) void,
    gtk_widget_get_opacity: *const fn (w: *Widget) callconv(.c) f64,
    gtk_widget_add_tick_callback: *const fn (w: *Widget, func: TickFn, data: ?*anyopaque, notify: ?*anyopaque) callconv(.c) c_uint,
    gtk_widget_remove_tick_callback: *const fn (w: *Widget, id: c_uint) callconv(.c) void,
    gtk_drawing_area_new: *const fn () callconv(.c) *Widget,
    gtk_im_multicontext_new: *const fn () callconv(.c) *anyopaque,
    gtk_im_context_focus_in: *const fn (im: *anyopaque) callconv(.c) void,
    gtk_im_context_focus_out: *const fn (im: *anyopaque) callconv(.c) void,
    gtk_im_context_set_cursor_location: *const fn (im: *anyopaque, rect: *const Rectangle) callconv(.c) void,
    gtk_im_context_get_preedit_string: *const fn (im: *anyopaque, str: *?[*:0]u8, attrs: ?*anyopaque, cursor: *c_int) callconv(.c) void,
    gtk_message_dialog_new: *const fn (parent: ?*Widget, flags: c_int, kind: c_int, buttons: c_int, format: [*:0]const u8, ...) callconv(.c) *Widget,
    gtk_dialog_add_button: *const fn (dialog: *Widget, text: [*:0]const u8, response: c_int) callconv(.c) ?*Widget,
    gtk_file_chooser_native_new: *const fn (title: [*:0]const u8, parent: ?*Widget, action: c_int, accept: ?[*:0]const u8, cancel: ?[*:0]const u8) callconv(.c) *anyopaque,
    gtk_file_chooser_set_select_multiple: *const fn (chooser: *anyopaque, on: c_int) callconv(.c) void,
    gtk_file_chooser_set_current_name: *const fn (chooser: *anyopaque, name: [*:0]const u8) callconv(.c) void,
    // GDK.
    gdk_keyval_to_unicode: *const fn (keyval: c_uint) callconv(.c) u32,
    gdk_display_get_default: *const fn () callconv(.c) ?*anyopaque,
    gdk_display_get_default_seat: *const fn (display: *anyopaque) callconv(.c) *anyopaque,
    gdk_seat_get_pointer: *const fn (seat: *anyopaque) callconv(.c) ?*anyopaque,
    // cairo.
    cairo_image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) *anyopaque,
    cairo_surface_set_device_scale: *const fn (surface: *anyopaque, x: f64, y: f64) callconv(.c) void,
    cairo_set_source_surface: *const fn (cr: *anyopaque, surface: *anyopaque, x: f64, y: f64) callconv(.c) void,
    cairo_paint: *const fn (cr: *anyopaque) callconv(.c) void,
    cairo_surface_destroy: *const fn (surface: *anyopaque) callconv(.c) void,
};

/// GTK 3's own: its main loop, window placement, events as structs, the
/// clipboard and dialogs that wait.
pub const Api3 = struct {
    gtk_init_check: *const fn (argc: ?*c_int, argv: ?*anyopaque) callconv(.c) c_int,
    gtk_main: *const fn () callconv(.c) void,
    gtk_main_quit: *const fn () callconv(.c) void,
    gtk_window_new: *const fn (kind: c_int) callconv(.c) *Widget,
    gtk_window_resize: *const fn (w: *Widget, width: c_int, height: c_int) callconv(.c) void,
    gtk_window_move: *const fn (w: *Widget, x: c_int, y: c_int) callconv(.c) void,
    gtk_window_get_size: *const fn (w: *Widget, width: *c_int, height: *c_int) callconv(.c) void,
    gtk_window_get_position: *const fn (w: *Widget, x: *c_int, y: *c_int) callconv(.c) void,
    gtk_window_set_position: *const fn (w: *Widget, pos: c_int) callconv(.c) void,
    gtk_window_begin_move_drag: *const fn (w: *Widget, button: c_int, root_x: c_int, root_y: c_int, time: u32) callconv(.c) void,
    gdk_device_get_position: *const fn (device: *anyopaque, screen: ?*anyopaque, x: *c_int, y: *c_int) callconv(.c) void,
    gtk_window_set_keep_above: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_set_skip_taskbar_hint: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_set_skip_pager_hint: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_window_get_skip_taskbar_hint: *const fn (w: *Widget) callconv(.c) c_int,
    gdk_screen_get_default: *const fn () callconv(.c) ?*anyopaque,
    gdk_screen_get_width: *const fn (screen: *anyopaque) callconv(.c) c_int,
    gdk_screen_get_height: *const fn (screen: *anyopaque) callconv(.c) c_int,
    gtk_window_iconify: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_set_icon: *const fn (w: *Widget, icon: ?*anyopaque) callconv(.c) void,
    gdk_pixbuf_loader_new: *const fn () callconv(.c) ?*anyopaque,
    gdk_pixbuf_loader_write: *const fn (loader: *anyopaque, buf: [*]const u8, count: usize, err: ?*?*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_loader_close: *const fn (loader: *anyopaque, err: ?*?*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_loader_get_pixbuf: *const fn (loader: *anyopaque) callconv(.c) ?*anyopaque,
    gtk_widget_show_all: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_hide: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_queue_draw_area: *const fn (w: *Widget, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void,
    gtk_widget_destroy: *const fn (w: *Widget) callconv(.c) void,
    gtk_widget_add_events: *const fn (w: *Widget, mask: c_int) callconv(.c) void,
    gtk_widget_set_can_focus: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_widget_get_window: *const fn (w: *Widget) callconv(.c) ?*anyopaque,
    gtk_container_add: *const fn (container: *Widget, child: *Widget) callconv(.c) void,
    gtk_im_context_set_client_window: *const fn (im: *anyopaque, window: ?*anyopaque) callconv(.c) void,
    gtk_im_context_filter_keypress: *const fn (im: *anyopaque, event: *Event) callconv(.c) c_int,
    gtk_clipboard_get: *const fn (selection: ?*anyopaque) callconv(.c) *anyopaque,
    gtk_clipboard_set_text: *const fn (cb: *anyopaque, text: [*]const u8, len: c_int) callconv(.c) void,
    gtk_clipboard_wait_for_text: *const fn (cb: *anyopaque) callconv(.c) ?[*:0]u8,
    gtk_dialog_run: *const fn (dialog: *Widget) callconv(.c) c_int,
    gtk_native_dialog_run: *const fn (dialog: *anyopaque) callconv(.c) c_int,
    gtk_file_chooser_set_current_folder: *const fn (chooser: *anyopaque, folder: [*:0]const u8) callconv(.c) c_int,
    gtk_file_chooser_get_filenames: *const fn (chooser: *anyopaque) callconv(.c) ?*SList,
    gtk_file_chooser_get_filename: *const fn (chooser: *anyopaque) callconv(.c) ?[*:0]u8,
    gdk_event_get_coords: *const fn (e: *Event, x: *f64, y: *f64) callconv(.c) c_int,
    gdk_event_get_button: *const fn (e: *Event, button: *c_uint) callconv(.c) c_int,
    gdk_event_get_click_count: *const fn (e: *Event, count: *c_uint) callconv(.c) c_int,
    gdk_event_get_state: *const fn (e: *Event, state: *c_uint) callconv(.c) c_int,
    gdk_event_get_keyval: *const fn (e: *Event, keyval: *c_uint) callconv(.c) c_int,
    gdk_event_get_scroll_deltas: *const fn (e: *Event, dx: *f64, dy: *f64) callconv(.c) c_int,
    gdk_event_get_scroll_direction: *const fn (e: *Event, dir: *c_int) callconv(.c) c_int,
    gdk_event_get_event_type: *const fn (e: *Event) callconv(.c) c_int,
    gdk_atom_intern: *const fn (name: [*:0]const u8, only_if_exists: c_int) callconv(.c) ?*anyopaque,
    gdk_cursor_new_from_name: *const fn (display: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque,
    gdk_window_set_cursor: *const fn (window: *anyopaque, cursor: ?*anyopaque) callconv(.c) void,
};

/// GTK 4's own: one child per window, event controllers instead of event
/// signals, a draw function, and a clipboard and dialogs that answer later.
pub const Api4 = struct {
    gtk_init_check: *const fn () callconv(.c) c_int,
    gtk_window_new: *const fn () callconv(.c) *Widget,
    gtk_window_set_child: *const fn (w: *Widget, child: ?*Widget) callconv(.c) void,
    gtk_window_destroy: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_minimize: *const fn (w: *Widget) callconv(.c) void,
    gtk_window_get_default_size: *const fn (w: *Widget, width: *c_int, height: *c_int) callconv(.c) void,
    gtk_native_get_surface: *const fn (native: *Widget) callconv(.c) ?*anyopaque,
    gdk_surface_get_device_position: *const fn (surface: *anyopaque, device: *anyopaque, x: *f64, y: *f64, mask: ?*c_uint) callconv(.c) c_int,
    gdk_toplevel_begin_move: *const fn (toplevel: *anyopaque, device: *anyopaque, button: c_int, x: f64, y: f64, time: u32) callconv(.c) void,
    gtk_widget_set_visible: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_widget_set_focusable: *const fn (w: *Widget, on: c_int) callconv(.c) void,
    gtk_widget_set_cursor_from_name: *const fn (w: *Widget, name: ?[*:0]const u8) callconv(.c) void,
    gtk_widget_add_controller: *const fn (w: *Widget, controller: *anyopaque) callconv(.c) void,
    gtk_drawing_area_set_draw_func: *const fn (area: *Widget, func: DrawFn, data: ?*anyopaque, destroy: ?*anyopaque) callconv(.c) void,
    gtk_gesture_click_new: *const fn () callconv(.c) *anyopaque,
    gtk_gesture_single_set_button: *const fn (gesture: *anyopaque, button: c_uint) callconv(.c) void,
    gtk_event_controller_motion_new: *const fn () callconv(.c) *anyopaque,
    gtk_event_controller_scroll_new: *const fn (flags: c_uint) callconv(.c) *anyopaque,
    gtk_event_controller_key_new: *const fn () callconv(.c) *anyopaque,
    gtk_event_controller_focus_new: *const fn () callconv(.c) *anyopaque,
    gtk_event_controller_get_current_event_state: *const fn (controller: *anyopaque) callconv(.c) c_uint,
    gtk_event_controller_key_set_im_context: *const fn (controller: *anyopaque, im: *anyopaque) callconv(.c) void,
    gtk_im_context_set_client_widget: *const fn (im: *anyopaque, widget: ?*Widget) callconv(.c) void,
    gtk_native_dialog_show: *const fn (dialog: *anyopaque) callconv(.c) void,
    gtk_file_chooser_set_current_folder: *const fn (chooser: *anyopaque, file: *anyopaque, err: ?*anyopaque) callconv(.c) c_int,
    gtk_file_chooser_get_files: *const fn (chooser: *anyopaque) callconv(.c) *anyopaque,
    gtk_file_chooser_get_file: *const fn (chooser: *anyopaque) callconv(.c) ?*anyopaque,
    g_list_model_get_n_items: *const fn (list: *anyopaque) callconv(.c) c_uint,
    g_list_model_get_item: *const fn (list: *anyopaque, i: c_uint) callconv(.c) ?*anyopaque,
    g_file_new_for_path: *const fn (path: [*:0]const u8) callconv(.c) *anyopaque,
    g_file_get_path: *const fn (file: *anyopaque) callconv(.c) ?[*:0]u8,
    gdk_display_get_clipboard: *const fn (display: *anyopaque) callconv(.c) *anyopaque,
    gdk_clipboard_set_text: *const fn (cb: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    gdk_clipboard_read_text_async: *const fn (cb: *anyopaque, cancel: ?*anyopaque, done: AsyncFn, data: ?*anyopaque) callconv(.c) void,
    gdk_clipboard_read_text_finish: *const fn (cb: *anyopaque, result: *anyopaque, err: ?*anyopaque) callconv(.c) ?[*:0]u8,
};

pub const DrawFn = *const fn (area: *Widget, cr: *anyopaque, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void;
pub const AsyncFn = *const fn (source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void;

/// gtk4-layer-shell (`libgtk4-layer-shell.so.0`): GTK 4 turns a window into
/// a Wayland layer surface (a panel, a bar, a launcher) instead of a window
/// among windows. Built for GTK 4: with GTK 3 there is none. Loaded ahead
/// of GTK 4 when a window asks for a layer surface (`wants_layer_shell`),
/// because that order is what makes the library work at all
/// (`layerShellLib`).
pub const LayerShell = struct {
    gtk_layer_is_supported: *const fn () callconv(.c) c_int,
    gtk_layer_init_for_window: *const fn (w: *Widget) callconv(.c) void,
    gtk_layer_set_namespace: *const fn (w: *Widget, name: [*:0]const u8) callconv(.c) void,
    gtk_layer_set_layer: *const fn (w: *Widget, layer: c_int) callconv(.c) void,
    gtk_layer_set_anchor: *const fn (w: *Widget, edge: c_int, anchor: c_int) callconv(.c) void,
    gtk_layer_set_margin: *const fn (w: *Widget, edge: c_int, margin: c_int) callconv(.c) void,
    gtk_layer_set_exclusive_zone: *const fn (w: *Widget, zone: c_int) callconv(.c) void,
    gtk_layer_auto_exclusive_zone_enable: *const fn (w: *Widget) callconv(.c) void,
    gtk_layer_set_keyboard_mode: *const fn (w: *Widget, mode: c_int) callconv(.c) void,
};

pub var layer_shell: LayerShell = undefined;
var layer_shell_state: enum { unknown, loaded, missing } = .unknown;
var layer_shell_lib: ?*anyopaque = null;
var layer_shell_lib_tried = false;

/// Set before GTK is first loaded, by a window that asks for one: whether
/// gtk4-layer-shell should be loaded ahead of GTK 4.
pub var wants_layer_shell = false;

/// The gtk4-layer-shell handle. Loaded into the global scope *before* GTK 4
/// where a layer surface is wanted, and that order is the whole point:
/// gtk4-layer-shell hooks libwayland's proxy calls with a shim of its own
/// (that is how the library is built), and the shim only wins the symbol
/// lookups if it is in the global scope ahead of libwayland, which GTK 4's
/// GDK links. Loaded after GTK 4 (nanoui's usual way with libraries), the
/// shim is never called, and `gtk_layer_is_supported` says no.
fn layerShellLib() ?*anyopaque {
    if (!layer_shell_lib_tried) {
        layer_shell_lib_tried = true;
        const libs = [_][*:0]const u8{ "libgtk4-layer-shell.so.0", "libgtk4-layer-shell.so.1", "libgtk4-layer-shell.so" };
        layer_shell_lib = for (libs) |name| {
            if (std.c.dlopen(name, .{ .NOW = true, .GLOBAL = true })) |h| break h;
        } else null;
    }
    return layer_shell_lib;
}

/// Loads gtk4-layer-shell where it is installed; false when it isn't (the
/// window stays ordinary). Looked up once.
pub fn loadLayerShell() bool {
    if (layer_shell_state == .unknown) layer_shell_state = blk: {
        const lib = layerShellLib() orelse break :blk .missing;
        if (!table(LayerShell, lib, &layer_shell)) break :blk .missing;
        break :blk .loaded;
    };
    return layer_shell_state == .loaded;
}

// gtk4-layer-shell's enums.
pub const layer_background = 0;
pub const layer_bottom = 1;
pub const layer_top = 2;
pub const layer_overlay = 3;
pub const edge_left = 0;
pub const edge_right = 1;
pub const edge_top = 2;
pub const edge_bottom = 3;
pub const keyboard_none = 0;
pub const keyboard_exclusive = 1;
pub const keyboard_on_demand = 2;

pub const SList = extern struct { data: ?*anyopaque, next: ?*SList };

pub var api: Api = undefined;
pub var v3: Api3 = undefined;
pub var v4api: Api4 = undefined;
/// GTK 4 is loaded (else GTK 3).
pub var v4 = false;
/// Only GTK 3 will do: the WebKitGTK a page needs is built for it.
pub var force3 = false;
var loaded = false;
var display: ?bool = null;

/// `NANOUI_GTK=3` asks for GTK 3.
pub fn wantsThree() bool {
    return if (std.c.getenv("NANOUI_GTK")) |v| std.mem.eql(u8, std.mem.span(v), "3") else false;
}

/// GTK is loaded and started, for what needs a display and may come before
/// any window (a dialog, the clipboard); false without GTK or a display.
pub fn ready() bool {
    if (!load()) return false;
    if (display == null) {
        const ok = if (v4) v4api.gtk_init_check() else v3.gtk_init_check(null, null);
        display = ok != 0;
    }
    return display.?;
}

/// Loads GTK and what it links (GDK, GLib, cairo): GTK 4 where it's
/// installed, else GTK 3 (`wantsThree`, `force3`); false when neither is.
/// Enough for GLib's timers and watches: `ready` starts it for windows.
pub fn load() bool {
    if (loaded) return true;
    if (!wantsThree() and !force3) {
        // Ahead of GTK 4, when a layer surface is coming: see `layerShellLib`.
        if (wants_layer_shell) _ = layerShellLib();
        if (std.c.dlopen("libgtk-4.so.1", .{ .NOW = true, .GLOBAL = true })) |lib| {
            if (table(Api, lib, &api) and table(Api4, lib, &v4api)) {
                v4 = true;
                loaded = true;
                return true;
            }
        }
    }
    const lib = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .GLOBAL = true }) orelse return false;
    if (!table(Api, lib, &api) or !table(Api3, lib, &v3)) return false;
    loaded = true;
    return true;
}

/// Each function of `T`, looked up by its field's name.
fn table(comptime T: type, lib: *anyopaque, out: *T) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse {
            std.log.err("nanoui: GTK lacks {s}", .{name});
            return false;
        };
        @field(out.*, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

pub fn connect(instance: *anyopaque, signal: [*:0]const u8, handler: Callback, data: ?*anyopaque) void {
    _ = api.g_signal_connect_data(instance, signal, handler, data, null, 0);
}

/// Calls `handler` with `data` when GtkSettings' appearance changes: the dark
/// preference, or the theme name. Returns the handlers, for disconnecting.
pub fn watchAppearance(settings: *anyopaque, handler: Callback, data: ?*anyopaque) [2]c_ulong {
    return .{
        api.g_signal_connect_data(settings, "notify::gtk-application-prefer-dark-theme", handler, data, null, 0),
        api.g_signal_connect_data(settings, "notify::gtk-theme-name", handler, data, null, 0),
    };
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
