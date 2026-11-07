//! The system's appearance on Linux: the color scheme the XDG desktop portal
//! publishes (KDE and GNOME keep it current while apps run), where GTK's own
//! settings are only what the desktop wrote for the next start.
const std = @import("std");

const gtk = @import("gtk.zig");

/// What the desktop asks for; `unset` leaves the answer to GTK.
pub const Scheme = enum { unset, dark, light };

const Api = struct {
    g_bus_get_sync: *const fn (bus: c_int, cancellable: ?*anyopaque, err: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_dbus_connection_call_sync: *const fn (conn: ?*anyopaque, bus_name: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*anyopaque, reply: ?[*:0]const u8, flags: c_int, timeout: c_int, cancellable: ?*anyopaque, err: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_dbus_connection_signal_subscribe: *const fn (conn: ?*anyopaque, sender: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, path: [*:0]const u8, arg0: ?[*:0]const u8, flags: c_int, callback: *const anyopaque, data: ?*anyopaque, destroy: ?*anyopaque) callconv(.c) c_uint,
    g_variant_new: *const fn (format: [*:0]const u8, ...) callconv(.c) ?*anyopaque,
    g_variant_get_child_value: *const fn (value: *anyopaque, index: usize) callconv(.c) ?*anyopaque,
    g_variant_get_variant: *const fn (value: *anyopaque) callconv(.c) ?*anyopaque,
    g_variant_get_uint32: *const fn (value: *anyopaque) callconv(.c) u32,
    g_variant_get_type_string: *const fn (value: *anyopaque) callconv(.c) [*:0]const u8,
    g_variant_unref: *const fn (value: *anyopaque) callconv(.c) void,
};

const session_bus: c_int = 2;

var api: Api = undefined;
var state: enum { unknown, ready, absent } = .unknown;
var tried = false;
var connection: ?*anyopaque = null;
var scheme_cache: Scheme = .unset;
var watchers: ?*Watch = null;

/// What the desktop's color scheme says, read once and kept current.
pub fn scheme() Scheme {
    ensure();
    return scheme_cache;
}

/// A window that follows the system's appearance: `notify` is called (with
/// `ctx`) when the portal or GTK says it changed.
pub const Watch = struct {
    notify: *const fn (?*anyopaque) callconv(.c) void = noop,
    ctx: ?*anyopaque = null,
    settings: ?*anyopaque = null,
    settings_handlers: [2]c_ulong = .{ 0, 0 },
    next: ?*Watch = null,

    fn noop(_: ?*anyopaque) callconv(.c) void {}

    pub fn start(self: *Watch, ctx: ?*anyopaque, notify: *const fn (?*anyopaque) callconv(.c) void) void {
        self.ctx = ctx;
        self.notify = notify;
        ensure();
        self.settings = gtk.api.gtk_settings_get_default();
        if (self.settings) |settings| self.settings_handlers = gtk.watchAppearance(settings, @ptrCast(&onSettingsChanged), self);
        self.next = watchers;
        watchers = self;
    }

    pub fn stop(self: *Watch) void {
        if (self.settings) |settings| for (self.settings_handlers) |id| if (id != 0) gtk.api.g_signal_handler_disconnect(settings, id);
        var link = &watchers;
        while (link.*) |watch| {
            if (watch == self) {
                link.* = self.next;
                break;
            }
            link = &watch.next;
        }
        self.next = null;
    }
};

fn ensure() void {
    if (tried) return;
    tried = true;
    if (!load()) return;
    connection = api.g_bus_get_sync(session_bus, null, null) orelse return;
    read();
    _ = api.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Settings", "SettingChanged", "/org/freedesktop/portal/desktop", "org.freedesktop.appearance", 0, @ptrCast(&onSettingChanged), null, null);
}

fn read() void {
    const conn = connection orelse return;
    const reply = api.g_dbus_connection_call_sync(conn, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read", api.g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"), null, 0, 500, null, null) orelse return;
    defer api.g_variant_unref(reply);
    var value = api.g_variant_get_child_value(reply, 0) orelse return;
    defer api.g_variant_unref(value);
    // The setting comes wrapped in a variant; some portals wrap it twice.
    while (std.mem.eql(u8, std.mem.span(api.g_variant_get_type_string(value)), "v")) {
        const inner = api.g_variant_get_variant(value) orelse return;
        api.g_variant_unref(value);
        value = inner;
    }
    if (!std.mem.eql(u8, std.mem.span(api.g_variant_get_type_string(value)), "u")) return;
    scheme_cache = switch (api.g_variant_get_uint32(value)) {
        1 => .dark,
        2 => .light,
        else => .unset,
    };
}

fn onSettingChanged(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    read();
    var watch = watchers;
    while (watch) |w| : (watch = w.next) w.notify(w.ctx);
}

fn onSettingsChanged(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const watch: *Watch = @ptrCast(@alignCast(data.?));
    watch.notify(watch.ctx);
}

fn load() bool {
    switch (state) {
        .ready => return true,
        .absent => return false,
        .unknown => {},
    }
    state = .absent;
    const gio = std.c.dlopen("libgio-2.0.so.0", .{ .NOW = true }) orelse return false;
    const glib = std.c.dlopen("libglib-2.0.so.0", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        var symbol: ?*anyopaque = null;
        for ([_]*anyopaque{ gio, glib }) |lib| {
            if (symbol == null) symbol = std.c.dlsym(lib, name);
        }
        @field(api, name) = @ptrCast(@alignCast(symbol orelse return false));
    }
    state = .ready;
    return true;
}
