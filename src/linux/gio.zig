//! GIO's GDBus and GLib's GVariant, loaded with dlopen: the session bus the
//! tray publishes on, and the variants it speaks. The same style as
//! `appearance.zig`: no `@cImport`, no libdbus, nothing at link time.
const std = @import("std");

/// `GDBusInterfaceVTable`, whose callbacks GDBus calls on the main thread.
pub const VTable = extern struct {
    method_call: *const fn (conn: ?*anyopaque, sender: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, params: ?*anyopaque, invocation: *anyopaque, user_data: ?*anyopaque) callconv(.c) void,
    get_property: ?*const fn (conn: ?*anyopaque, sender: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, name: [*:0]const u8, err: *?*anyopaque, user_data: ?*anyopaque) callconv(.c) ?*anyopaque = null,
    set_property: ?*const anyopaque = null,
    padding: [8]?*anyopaque = @splat(null),
};

pub const SignalCallback = *const fn (conn: ?*anyopaque, sender: ?[*:0]const u8, path: ?[*:0]const u8, iface: ?[*:0]const u8, member: ?[*:0]const u8, params: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void;

pub const Api = struct {
    // GLib's memory, errors and quarks.
    g_error_free: *const fn (err: ?*anyopaque) callconv(.c) void,
    g_free: *const fn (mem: ?*anyopaque) callconv(.c) void,
    g_malloc: *const fn (size: usize) callconv(.c) ?*anyopaque,
    g_quark_from_static_string: *const fn (s: [*:0]const u8) callconv(.c) u32,
    g_set_error_literal: *const fn (err: *?*anyopaque, domain: u32, code: c_int, message: [*:0]const u8) callconv(.c) void,
    g_strndup: *const fn (s: [*]const u8, n: usize) callconv(.c) ?*anyopaque,
    g_object_unref: *const fn (obj: ?*anyopaque) callconv(.c) void,
    // Connections and exported objects.
    g_bus_get_sync: *const fn (bus: c_int, cancellable: ?*anyopaque, err: *?*anyopaque) callconv(.c) ?*anyopaque,
    g_main_context_iteration: *const fn (context: ?*anyopaque, may_block: c_int) callconv(.c) c_int,
    g_dbus_connection_call_finish: *const fn (conn: ?*anyopaque, result: ?*anyopaque, err: *?*anyopaque) callconv(.c) ?*anyopaque,
    g_dbus_connection_call: *const fn (conn: ?*anyopaque, bus_name: ?[*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*anyopaque, reply_type: ?*const anyopaque, flags: c_int, timeout: c_int, cancellable: ?*anyopaque, callback: ?*const anyopaque, user_data: ?*anyopaque) callconv(.c) void,
    g_dbus_connection_call_sync: *const fn (conn: ?*anyopaque, bus_name: ?[*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*anyopaque, reply_type: ?*const anyopaque, flags: c_int, timeout: c_int, cancellable: ?*anyopaque, err: *?*anyopaque) callconv(.c) ?*anyopaque,
    g_dbus_connection_emit_signal: *const fn (conn: ?*anyopaque, destination: ?[*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, params: ?*anyopaque, err: *?*anyopaque) callconv(.c) c_int,
    g_dbus_connection_register_object: *const fn (conn: ?*anyopaque, path: [*:0]const u8, iface: ?*anyopaque, vtable: *const VTable, user_data: ?*anyopaque, destroy: ?*const anyopaque, err: *?*anyopaque) callconv(.c) c_uint,
    g_dbus_connection_signal_subscribe: *const fn (conn: ?*anyopaque, sender: ?[*:0]const u8, iface: ?[*:0]const u8, member: ?[*:0]const u8, path: ?[*:0]const u8, arg0: ?[*:0]const u8, flags: c_int, callback: SignalCallback, user_data: ?*anyopaque, destroy: ?*const anyopaque) callconv(.c) c_uint,
    g_dbus_connection_signal_unsubscribe: *const fn (conn: ?*anyopaque, id: c_uint) callconv(.c) void,
    g_dbus_connection_unregister_object: *const fn (conn: ?*anyopaque, id: c_uint) callconv(.c) c_int,
    g_dbus_method_invocation_return_dbus_error: *const fn (invocation: ?*anyopaque, name: [*:0]const u8, message: [*:0]const u8) callconv(.c) void,
    g_dbus_method_invocation_return_value: *const fn (invocation: ?*anyopaque, params: ?*anyopaque) callconv(.c) void,
    g_dbus_node_info_lookup_interface: *const fn (info: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque,
    g_dbus_node_info_new_for_xml: *const fn (xml: [*:0]const u8, err: *?*anyopaque) callconv(.c) ?*anyopaque,
    g_dbus_node_info_unref: *const fn (info: ?*anyopaque) callconv(.c) void,
    // GVariant.
    g_variant_builder_add_value: *const fn (b: ?*anyopaque, value: ?*anyopaque) callconv(.c) void,
    g_variant_builder_end: *const fn (b: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_builder_new: *const fn (type_name: [*:0]const u8) callconv(.c) ?*anyopaque,
    g_variant_builder_unref: *const fn (b: ?*anyopaque) callconv(.c) void,
    g_variant_get_boolean: *const fn (v: ?*anyopaque) callconv(.c) c_int,
    g_variant_get_child_value: *const fn (v: ?*anyopaque, index: usize) callconv(.c) ?*anyopaque,
    g_variant_get_int32: *const fn (v: ?*anyopaque) callconv(.c) i32,
    g_variant_get_string: *const fn (v: ?*anyopaque, len: ?*usize) callconv(.c) [*:0]const u8,
    g_variant_get_type_string: *const fn (v: ?*anyopaque) callconv(.c) [*:0]const u8,
    g_variant_get_uint32: *const fn (v: ?*anyopaque) callconv(.c) u32,
    g_variant_get_variant: *const fn (v: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_n_children: *const fn (v: ?*anyopaque) callconv(.c) usize,
    g_variant_new: *const fn (format: [*:0]const u8, ...) callconv(.c) ?*anyopaque,
    g_variant_new_boolean: *const fn (value: c_int) callconv(.c) ?*anyopaque,
    g_variant_new_dict_entry: *const fn (key: ?*anyopaque, value: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_new_from_data: *const fn (type_name: [*:0]const u8, data: ?*const anyopaque, size: usize, trusted: c_int, notify: ?*const fn (?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_new_int32: *const fn (value: i32) callconv(.c) ?*anyopaque,
    g_variant_new_object_path: *const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque,
    g_variant_new_take_string: *const fn (s: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_new_uint32: *const fn (value: u32) callconv(.c) ?*anyopaque,
    g_variant_new_variant: *const fn (value: ?*anyopaque) callconv(.c) ?*anyopaque,
    g_variant_unref: *const fn (v: ?*anyopaque) callconv(.c) void,
};

pub var api: Api = undefined;

/// G_BUS_TYPE_SESSION.
pub const session_bus: c_int = 2;
/// G_DBUS_CALL_FLAGS_NONE.
pub const no_flags: c_int = 0;
/// G_DBUS_SIGNAL_FLAGS_NONE.
pub const signal_flags: c_int = 0;
/// Long enough for a local bus, short enough not to hang a start.
pub const timeout_ms: c_int = 1000;

var state: enum { unknown, ready, absent } = .unknown;
var gio_lib: ?*anyopaque = null;
var glib_lib: ?*anyopaque = null;

fn find(name: [*:0]const u8) ?*anyopaque {
    if (gio_lib) |h| if (std.c.dlsym(h, name)) |s| return s;
    if (glib_lib) |h| if (std.c.dlsym(h, name)) |s| return s;
    return null;
}

/// Loads GIO and GLib once; false where neither is installed.
pub fn load() bool {
    switch (state) {
        .ready => return true,
        .absent => return false,
        .unknown => {},
    }
    state = .absent;
    gio_lib = std.c.dlopen("libgio-2.0.so.0", .{ .NOW = true }) orelse return false;
    glib_lib = std.c.dlopen("libglib-2.0.so.0", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const symbol = find(name) orelse return false;
        @field(api, name) = @ptrCast(@alignCast(symbol));
    }
    state = .ready;
    return true;
}

/// Whether GIO is there, loading it if need be.
pub fn ready() bool {
    return load();
}

/// Frees the `GError*` a call left, logging what it said.
pub fn logError(context: [*:0]const u8, err: ?*anyopaque) void {
    const e = err orelse return;
    api.g_error_free(e);
    std.log.scoped(.nanoui).warn("tray: {s} failed", .{context});
}

// -- building variants ------------------------------------------------------

/// A copy of `data` as an `ay`, freed with the variant by GLib: a variant may
/// outlive the call that made it, so nothing here borrows.
pub fn bytes(data: []const u8) ?*anyopaque {
    const copy = api.g_malloc(data.len) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(copy))[0..data.len], data);
    // Trusted: the serialised form of an `ay` is its bytes.
    return api.g_variant_new_from_data("ay", copy, data.len, 1, api.g_free, null);
}

/// An `s` from a slice that need not be NUL-terminated (a copy it takes).
pub fn str(s: []const u8) ?*anyopaque {
    const copy = api.g_strndup(s.ptr, s.len) orelse return null;
    return api.g_variant_new_take_string(copy);
}

/// A `{sv}` entry: the key as it is, the value wrapped in a variant; it takes
/// both. (`g_variant_new_dict_entry` does not wrap by itself.)
pub fn dictEntry(key: ?*anyopaque, value: ?*anyopaque) ?*anyopaque {
    return api.g_variant_new_dict_entry(key, variant(value));
}

/// A `v` wrapping `value`, which it takes.
pub fn variant(value: ?*anyopaque) ?*anyopaque {
    return api.g_variant_new_variant(value);
}

/// An array being filled; `end` returns it, the builder gone either way.
pub const Array = struct {
    b: ?*anyopaque,

    pub fn init(type_name: [*:0]const u8) Array {
        if (!load()) return .{ .b = null };
        return .{ .b = api.g_variant_builder_new(type_name) };
    }

    pub fn add(self: Array, value: ?*anyopaque) void {
        if (self.b) |b| api.g_variant_builder_add_value(b, value);
    }

    /// The finished array (floating), or null when the builder could not be made.
    pub fn end(self: Array) ?*anyopaque {
        const b = self.b orelse return null;
        const v = api.g_variant_builder_end(b);
        api.g_variant_builder_unref(b);
        return v;
    }
};

/// An array of `type` holding `values`, which it takes.
pub fn array(type_name: [*:0]const u8, values: []const ?*anyopaque) ?*anyopaque {
    const a = Array.init(type_name);
    for (values) |v| a.add(v);
    return a.end();
}

// -- reading variants -------------------------------------------------------

pub fn child(v: ?*anyopaque, index: usize) ?*anyopaque {
    return api.g_variant_get_child_value(v, index);
}

pub fn string(v: ?*anyopaque) []const u8 {
    return std.mem.span(api.g_variant_get_string(v, null));
}

pub fn int32(v: ?*anyopaque) i32 {
    return api.g_variant_get_int32(v);
}

pub fn uint32(v: ?*anyopaque) u32 {
    return api.g_variant_get_uint32(v);
}

pub fn boolean(v: ?*anyopaque) bool {
    return api.g_variant_get_boolean(v) != 0;
}

pub fn unref(v: ?*anyopaque) void {
    if (v) |value| api.g_variant_unref(value);
}

/// The `i` at `index` of a tuple; the copy is freed at once.
pub fn int32At(v: ?*anyopaque, index: usize) i32 {
    const c = child(v, index) orelse return 0;
    defer unref(c);
    return int32(c);
}

/// The string at `index` of a tuple: it points into `v`, which must outlive it.
pub fn stringAt(v: ?*anyopaque, index: usize) []const u8 {
    const c = child(v, index) orelse return "";
    const s = string(c);
    unref(c);
    return s;
}

/// The first `u` of a tuple reply (a `RequestName`'s answer).
pub fn firstU32(v: ?*anyopaque) u32 {
    const c = child(v, 0) orelse return 0;
    defer unref(c);
    return uint32(c);
}

test "an a{sv} keeps its entries" {
    if (!load()) return error.SkipZigTest;
    const a = Array.init("a{sv}");
    a.add(dictEntry(str("label"), str("Open kocr")));
    const v = a.end() orelse return error.SkipZigTest;
    defer unref(v);
    try std.testing.expectEqualStrings("a{sv}", std.mem.span(api.g_variant_get_type_string(v)));
    try std.testing.expectEqual(@as(usize, 1), api.g_variant_n_children(v));
}
