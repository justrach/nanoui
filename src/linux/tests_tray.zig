//! A tray on a real session bus, end to end: the item's property read, the
//! menu's layout fetched and a click run, all through the bus daemon. Skips
//! unless `DBUS_SESSION_BUS_ADDRESS` names a bus (CI runs the suite under
//! `dbus-run-session`), so it never touches the developer's own session.
const std = @import("std");

const gio = @import("gio.zig");
const tray_mod = @import("tray.zig");

const Call = struct {
    conn: ?*anyopaque,
    done: bool = false,
    reply: ?*anyopaque = null,
    err: ?*anyopaque = null,
};

fn onReply(_: ?*anyopaque, result: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const c: *Call = @ptrCast(@alignCast(user_data orelse return));
    c.reply = gio.api.g_dbus_connection_call_finish(c.conn, result, &c.err);
    c.done = true;
}

/// Calls the tray's own object and waits for the answer, running the main
/// context the tray answers on.
fn call(t: *tray_mod.Tray, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*anyopaque) !?*anyopaque {
    var c = Call{ .conn = t.conn };
    gio.api.g_dbus_connection_call(t.conn, t.name.?, path, iface, method, params, null, gio.no_flags, gio.timeout_ms, null, &onReply, &c);
    var spins: usize = 0;
    while (!c.done and spins < 5000) : (spins += 1) _ = gio.api.g_main_context_iteration(null, 1);
    if (c.err) |err| {
        gio.api.g_error_free(err);
        return error.CallFailed;
    }
    return c.reply orelse error.NoReply;
}

fn onItem(t: *tray_mod.Tray, iface: [*:0]const u8, name: [*:0]const u8) !?*anyopaque {
    return call(t, "/StatusNotifierItem", "org.freedesktop.DBus.Properties", "Get", gio.api.g_variant_new("(s@s)", iface, gio.str(std.mem.span(name))));
}

/// Unwraps the `v` a `Properties.Get` answers with.
fn unwrap(reply: ?*anyopaque) ?*anyopaque {
    const wrapped = gio.child(reply, 0) orelse return null;
    defer gio.unref(wrapped);
    return gio.api.g_variant_get_variant(wrapped);
}

test "a tray answers the bus: its title, its menu, a click" {
    if (!gio.ready()) return error.SkipZigTest;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var clicked: bool = false;
    const t = try tray_mod.Tray.create(gpa, "nanoui-tests", .{
        .title = "nanoui test",
        .tooltip = "a tray for the tests",
        .menu = &.{
            .{ .id = "box", .label = "Box", .kind = .checkbox, .click = .{ .ctx = &clicked, .func = struct {
                fn click(ctx: *anyopaque, item: *@import("../menu_accel.zig").Item) void {
                    const flag: *bool = @ptrCast(@alignCast(ctx));
                    flag.* = item.checked;
                }
            }.click } },
        },
    });
    defer t.destroy();

    // A title, as a host reads it.
    const title = try onItem(t, "org.kde.StatusNotifierItem", "Title");
    defer gio.unref(title);
    const title_value = unwrap(title) orelse return error.NoReply;
    defer gio.unref(title_value);
    try std.testing.expectEqualStrings("nanoui test", gio.string(title_value));

    // The menu's tree: a revision, then the layout tuple.
    const layout = try call(t, "/MenuBar", "com.canonical.dbusmenu", "GetLayout", gio.api.g_variant_new("(ii@as)", @as(c_int, 0), @as(c_int, -1), gio.Array.init("as").end()));
    defer gio.unref(layout);
    try std.testing.expectEqual(@as(usize, 2), gio.api.g_variant_n_children(layout));

    // The root's properties and its one checkbox row, which carries a label:
    // an `a{sv}` whose values are variants.
    const root = gio.child(layout, 1) orelse return error.NoReply;
    defer gio.unref(root);
    const root_props = gio.child(root, 1) orelse return error.NoReply;
    defer gio.unref(root_props);
    try std.testing.expect(gio.api.g_variant_n_children(root_props) >= 4);
    const rows = gio.child(root, 2) orelse return error.NoReply;
    defer gio.unref(rows);
    try std.testing.expectEqual(@as(usize, 1), gio.api.g_variant_n_children(rows));
    const row = gio.api.g_variant_get_variant(gio.child(rows, 0) orelse return error.NoReply) orelse return error.NoReply;
    defer gio.unref(row);
    const row_props = gio.child(row, 1) orelse return error.NoReply;
    defer gio.unref(row_props);
    try std.testing.expect(gio.api.g_variant_n_children(row_props) >= 4);

    // A host clicks the checkbox: the template's item toggles and the
    // callback runs.
    const ev = try call(t, "/MenuBar", "com.canonical.dbusmenu", "Event", gio.api.g_variant_new("(is@vu)", @as(c_int, 1), "clicked", gio.variant(gio.api.g_variant_new_int32(0)), @as(c_uint, 0)));
    defer gio.unref(ev);
    try std.testing.expect(clicked);
    try std.testing.expect(t.menuItem("box").?.checked);
}

const watcher_xml =
    \\<node>
    \\ <interface name="org.kde.StatusNotifierWatcher">
    \\  <method name="RegisterStatusNotifierItem">
    \\   <arg type="s" name="service" direction="in"/>
    \\  </method>
    \\  <signal name="StatusNotifierItemRegistered"><arg type="s" name="service"/></signal>
    \\ </interface>
    \\</node>
;

/// The half of `org.kde.StatusNotifierWatcher` GNOME's AppIndicator extension
/// (and KDE's host) needs from an item: the registration call, recorded.
const Watcher = struct {
    gpa: std.mem.Allocator,
    seen: ?[]u8 = null,
};

fn onWatcher(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, member: [*:0]const u8, params: ?*anyopaque, invocation: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(user_data orelse return));
    if (std.mem.eql(u8, std.mem.span(member), "RegisterStatusNotifierItem")) {
        if (w.seen) |old| w.gpa.free(old);
        w.seen = w.gpa.dupe(u8, gio.stringAt(params, 0)) catch null;
    }
    gio.api.g_dbus_method_invocation_return_value(invocation, null);
}

const watcher_vtable = gio.VTable{ .method_call = onWatcher };

test "a tray registers itself with the watcher" {
    if (!gio.ready()) return error.SkipZigTest;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var err: ?*anyopaque = null;
    const conn = gio.api.g_bus_get_sync(gio.session_bus, null, &err) orelse {
        gio.logError("connecting to the session bus", err);
        return error.NoSessionBus;
    };
    defer gio.api.g_object_unref(conn);

    // This process plays the host: GNOME's extension owns this name too.
    const claimed = gio.api.g_dbus_connection_call_sync(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", gio.api.g_variant_new("(su)", "org.kde.StatusNotifierWatcher", @as(c_uint, 4)), null, gio.no_flags, gio.timeout_ms, null, &err) orelse {
        gio.logError("claiming the watcher's name", err);
        return error.BusRejected;
    };
    defer gio.unref(claimed);
    defer gio.api.g_dbus_connection_call(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName", gio.api.g_variant_new("(s)", "org.kde.StatusNotifierWatcher"), null, gio.no_flags, gio.timeout_ms, null, null, null);
    // Somebody else's session already has a host: nothing to fake here.
    if (gio.firstU32(claimed) != 1) return error.SkipZigTest;

    const info = gio.api.g_dbus_node_info_new_for_xml(watcher_xml, &err) orelse return error.BusRejected;
    defer gio.api.g_dbus_node_info_unref(info);
    const iface = gio.api.g_dbus_node_info_lookup_interface(info, "org.kde.StatusNotifierWatcher") orelse return error.BusRejected;
    var w: Watcher = .{ .gpa = gpa };
    defer if (w.seen) |seen| gpa.free(seen);
    const reg = gio.api.g_dbus_connection_register_object(conn, "/StatusNotifierWatcher", iface, &watcher_vtable, &w, null, &err);
    if (reg == 0) return error.BusRejected;
    defer _ = gio.api.g_dbus_connection_unregister_object(conn, reg);

    const t = try tray_mod.Tray.create(gpa, "nanoui-tests", .{ .title = "watched" });
    defer t.destroy();

    // The registration is a message to ourselves: run the loop until it
    // arrives.
    var spins: usize = 0;
    while (w.seen == null and spins < 100) : (spins += 1) _ = gio.api.g_main_context_iteration(null, 1);
    try std.testing.expectEqualStrings(t.name.?, w.seen orelse return error.NoRegistration);
}

test "a destroyed tray gives its bus name back" {
    if (!gio.ready()) return error.SkipZigTest;
    if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const t = try tray_mod.Tray.create(gpa, "nanoui-tests", .{ .title = "gone" });
    // `destroy` frees the tray's copy of the name.
    const name = try gpa.printSentinel("{s}", .{t.name.?}, 0);
    defer gpa.free(name);
    const conn = t.conn.?;
    // A ref of our own: the item's is released with it, the bus's own stays.
    var err: ?*anyopaque = null;
    const bus = gio.api.g_bus_get_sync(gio.session_bus, null, &err) orelse {
        gio.logError("reconnecting to the session bus", err);
        return error.NoSessionBus;
    };
    defer gio.api.g_object_unref(bus);
    t.destroy();
    const reply = gio.api.g_dbus_connection_call_sync(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", gio.api.g_variant_new("(s)", name.ptr), null, gio.no_flags, gio.timeout_ms, null, &err) orelse {
        gio.logError("asking the bus who owns the name", err);
        return error.BusRejected;
    };
    defer gio.unref(reply);
    try std.testing.expect(!gio.boolean(gio.child(reply, 0).?));
}
