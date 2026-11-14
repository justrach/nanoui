//! The two interfaces nanoui's tray exports: `StatusNotifierItem`'s
//! properties and click methods, and `com.canonical.dbusmenu`'s tree and
//! events, with their introspection XML and the GDBus tables that route a
//! host's calls to them. Split from `tray.zig` by responsibility, and to keep
//! every file under the project's line limit.
const std = @import("std");

const gio = @import("gio.zig");
const menu_types = @import("../menu_types.zig");
const model = @import("tray_menu.zig");
const tray_mod = @import("tray.zig");

pub const Tray = tray_mod.Tray;

pub const fdo_interface = "org.freedesktop.StatusNotifierItem";
pub const item_path = "/StatusNotifierItem";
pub const kde_interface = "org.kde.StatusNotifierItem";
pub const menu_interface = "com.canonical.dbusmenu";
pub const menu_path = "/MenuBar";

pub const item_vtable = gio.VTable{ .method_call = onItemMethod, .get_property = onItemProperty };
pub const menu_vtable = gio.VTable{ .method_call = onMenuMethod, .get_property = onMenuProperty };

const node_properties = [_][]const u8{ "label", "enabled", "visible", "type", "children-display", "toggle-type", "toggle-state", "shortcut" };

// -- the item ---------------------------------------------------------------

fn onItemMethod(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, member: [*:0]const u8, _: ?*anyopaque, invocation: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const t: *Tray = @ptrCast(@alignCast(user_data orelse return));
    t.callbacks += 1;
    defer t.leave();
    if (t.dead) return gio.api.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownObject", "the item is gone");
    const m = std.mem.span(member);
    const eql = std.mem.eql;
    if (eql(u8, m, "Activate")) {
        if (t.on_click) |c| c.func(c.ctx, t);
    } else if (!eql(u8, m, "SecondaryActivate") and !eql(u8, m, "ContextMenu") and !eql(u8, m, "Scroll")) {
        return gio.api.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }
    gio.api.g_dbus_method_invocation_return_value(invocation, null);
}

fn onItemProperty(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, err: *?*anyopaque, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const t: *Tray = @ptrCast(@alignCast(user_data orelse return null));
    return t.property(std.mem.span(name)) orelse {
        gio.api.g_set_error_literal(err, gio.api.g_quark_from_static_string("nanoui-tray"), 0, "no such property");
        return null;
    };
}

// -- the menu ---------------------------------------------------------------

fn onMenuProperty(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, name: [*:0]const u8, err: *?*anyopaque, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    const n = std.mem.span(name);
    const eql = std.mem.eql;
    if (eql(u8, n, "Version")) return gio.api.g_variant_new_uint32(3);
    if (eql(u8, n, "TextDirection")) return gio.str("ltr");
    if (eql(u8, n, "Status")) return gio.str("normal");
    if (eql(u8, n, "IconThemePath")) return gio.Array.init("as").end();
    gio.api.g_set_error_literal(err, gio.api.g_quark_from_static_string("nanoui-tray"), 0, "no such property");
    return null;
}

fn onMenuMethod(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, member: [*:0]const u8, params: ?*anyopaque, invocation: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const t: *Tray = @ptrCast(@alignCast(user_data orelse return));
    t.callbacks += 1;
    defer t.leave();
    if (t.dead) return gio.api.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownObject", "the item is gone");
    const m = std.mem.span(member);
    const eql = std.mem.eql;
    if (eql(u8, m, "GetLayout")) return getLayout(t, params, invocation);
    if (eql(u8, m, "GetGroupProperties")) return getGroupProperties(t, params, invocation);
    if (eql(u8, m, "GetProperty")) return getProperty(t, params, invocation);
    if (eql(u8, m, "Event")) return event(t, params, invocation);
    if (eql(u8, m, "EventGroup")) return gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(@ai)", gio.Array.init("ai").end()));
    if (eql(u8, m, "AboutToShow")) return gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(b)", @as(c_int, 0)));
    if (eql(u8, m, "AboutToShowGroup")) return gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(@ai@ai)", gio.Array.init("ai").end(), gio.Array.init("ai").end()));
    gio.api.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
}

fn getLayout(t: *Tray, params: ?*anyopaque, invocation: ?*anyopaque) void {
    const parent = gio.int32At(params, 0);
    const depth = gio.int32At(params, 1);
    const m = t.menu orelse return emptyLayout(invocation, 1, parent);
    const n = m.node(parent) orelse return emptyLayout(invocation, m.revision, parent);
    gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(u@(ia{sv}av))", m.revision, nodeVariant(t, n, depth)));
}

fn emptyLayout(invocation: ?*anyopaque, revision: u32, parent: i32) void {
    const node = gio.api.g_variant_new("(i@a{sv}@av)", @as(c_int, parent), gio.Array.init("a{sv}").end(), gio.Array.init("av").end());
    gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(u@(ia{sv}av))", revision, node));
}

fn getGroupProperties(t: *Tray, params: ?*anyopaque, invocation: ?*anyopaque) void {
    const out = gio.Array.init("a(ia{sv})");
    const ids = gio.child(params, 0);
    defer gio.unref(ids);
    var i: usize = 0;
    while (ids != null and i < gio.api.g_variant_n_children(ids)) : (i += 1) {
        const id = gio.int32At(ids, i);
        const m = t.menu orelse continue;
        const n = m.node(id) orelse continue;
        out.add(gio.api.g_variant_new("(i@a{sv})", @as(c_int, id), props(n)));
    }
    gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(@a(ia{sv}))", out.end()));
}

fn getProperty(t: *Tray, params: ?*anyopaque, invocation: ?*anyopaque) void {
    const id = gio.int32At(params, 0);
    const name = gio.stringAt(params, 1);
    const m = t.menu orelse return unknownProperty(invocation);
    const n = m.node(id) orelse return unknownProperty(invocation);
    const v = propValue(n, name) orelse return unknownProperty(invocation);
    gio.api.g_dbus_method_invocation_return_value(invocation, gio.api.g_variant_new("(@v)", gio.variant(v)));
}

fn event(t: *Tray, params: ?*anyopaque, invocation: ?*anyopaque) void {
    const id = gio.int32At(params, 0);
    if (std.mem.eql(u8, gio.stringAt(params, 1), "clicked")) t.click(id);
    gio.api.g_dbus_method_invocation_return_value(invocation, null);
}

fn unknownProperty(invocation: ?*anyopaque) void {
    gio.api.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", "no such property");
}

/// `(ia{sv}av)`, the tree's per-node form; `depth` 0 leaves children out and
/// a negative depth means all of them.
fn nodeVariant(t: *Tray, n: *const model.Node, depth: i32) ?*anyopaque {
    const kids = gio.Array.init("av");
    if (depth != 0) for (n.children) |*c| {
        kids.add(gio.variant(nodeVariant(t, c, if (depth > 0) depth - 1 else depth)));
    };
    return gio.api.g_variant_new("(i@a{sv}@av)", @as(c_int, n.id), props(n), kids.end());
}

/// `a{sv}` for one node: what a host draws the row from.
pub fn props(n: *const model.Node) ?*anyopaque {
    const a = gio.Array.init("a{sv}");
    for (node_properties) |name| {
        const value = propValue(n, name) orelse continue;
        a.add(gio.dictEntry(gio.str(name), value));
    }
    return a.end();
}

/// One property of a node, or null when it has none.
fn propValue(n: *const model.Node, name: []const u8) ?*anyopaque {
    const eql = std.mem.eql;
    if (eql(u8, name, "label")) return gio.str(n.label);
    if (eql(u8, name, "enabled")) {
        const enabled = if (n.item) |it| !it.disabled else !n.disabled;
        return gio.api.g_variant_new_boolean(@intFromBool(enabled));
    }
    if (eql(u8, name, "visible")) return gio.api.g_variant_new_boolean(1);
    if (eql(u8, name, "type")) return gio.str(if (n.kind == .separator) "separator" else "standard");
    if (eql(u8, name, "children-display")) return if (n.kind == .submenu) gio.str("submenu") else null;
    const it = n.item orelse return null;
    if (eql(u8, name, "toggle-type")) return switch (it.kind) {
        .checkbox => gio.str("checkmark"),
        .radio => gio.str("radio"),
        .normal => null,
    };
    if (eql(u8, name, "toggle-state")) return switch (it.kind) {
        .checkbox, .radio => gio.api.g_variant_new_int32(@intFromBool(it.checked)),
        .normal => null,
    };
    if (eql(u8, name, "shortcut")) return shortcut(n.shortcut);
    return null;
}

/// `aas`: one chord of GLib key names, the menu's shortcut.
fn shortcut(a: menu_types.Accelerator) ?*anyopaque {
    var names: [4][]const u8 = undefined;
    var buf: [8]u8 = undefined;
    const keys = model.shortcutKeys(a, &names, &buf) orelse return null;
    const chord = gio.Array.init("as");
    for (keys) |k| chord.add(gio.str(k));
    const all = gio.Array.init("aas");
    all.add(chord.end());
    return all.end();
}

// -- the interfaces, as GDBus reads them ------------------------------------

/// The item's members, under whichever interface name `{s}` is.
const item_xml =
    \\<node>
    \\ <interface name="{s}">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="IconThemePath" type="s" access="read"/>
    \\  <property name="OverlayIconName" type="s" access="read"/>
    \\  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionIconName" type="s" access="read"/>
    \\  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionMovieName" type="s" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <method name="Activate">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="SecondaryActivate">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="ContextMenu">
    \\   <arg type="i" name="x" direction="in"/>
    \\   <arg type="i" name="y" direction="in"/>
    \\  </method>
    \\  <method name="Scroll">
    \\   <arg type="i" name="delta" direction="in"/>
    \\   <arg type="s" name="orientation" direction="in"/>
    \\  </method>
    \\  <signal name="NewTitle"/>
    \\  <signal name="NewIcon"/>
    \\  <signal name="NewAttentionIcon"/>
    \\  <signal name="NewOverlayIcon"/>
    \\  <signal name="NewToolTip"/>
    \\  <signal name="NewStatus"><arg type="s" name="status"/></signal>
    \\ </interface>
    \\</node>
;

pub const kde_item_xml = std.fmt.comptimePrint(item_xml, .{kde_interface});
pub const fdo_item_xml = std.fmt.comptimePrint(item_xml, .{fdo_interface});

pub const menu_xml =
    \\<node>
    \\ <interface name="com.canonical.dbusmenu">
    \\  <property name="Version" type="u" access="read"/>
    \\  <property name="TextDirection" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconThemePath" type="as" access="read"/>
    \\  <method name="GetLayout">
    \\   <arg type="i" name="parentId" direction="in"/>
    \\   <arg type="i" name="recursionDepth" direction="in"/>
    \\   <arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="u" name="revision" direction="out"/>
    \\   <arg type="(ia{sv}av)" name="layout" direction="out"/>
    \\  </method>
    \\  <method name="GetGroupProperties">
    \\   <arg type="ai" name="ids" direction="in"/>
    \\   <arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="a(ia{sv})" name="properties" direction="out"/>
    \\  </method>
    \\  <method name="GetProperty">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="s" name="name" direction="in"/>
    \\   <arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="Event">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="s" name="eventId" direction="in"/>
    \\   <arg type="v" name="data" direction="in"/>
    \\   <arg type="u" name="timestamp" direction="in"/>
    \\  </method>
    \\  <method name="EventGroup">
    \\   <arg type="a(isvu)" name="events" direction="in"/>
    \\   <arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <method name="AboutToShow">
    \\   <arg type="i" name="id" direction="in"/>
    \\   <arg type="b" name="needUpdate" direction="out"/>
    \\  </method>
    \\  <method name="AboutToShowGroup">
    \\   <arg type="ai" name="ids" direction="in"/>
    \\   <arg type="ai" name="updatesNeeded" direction="out"/>
    \\   <arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <signal name="ItemsPropertiesUpdated">
    \\   <arg type="a(ia{sv})" name="updatedProps"/>
    \\   <arg type="a(ias)" name="removedProps"/>
    \\  </signal>
    \\  <signal name="LayoutUpdated">
    \\   <arg type="u" name="revision"/>
    \\   <arg type="i" name="parent"/>
    \\  </signal>
    \\  <signal name="ItemActivationRequested">
    \\   <arg type="i" name="id"/>
    \\   <arg type="u" name="timestamp"/>
    \\  </signal>
    \\ </interface>
    \\</node>
;
