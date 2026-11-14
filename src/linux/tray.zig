//! Tray icons on Linux: a freedesktop `StatusNotifierItem` and its
//! `com.canonical.dbusmenu`, published on the session bus with GIO's GDBus
//! (dlopen'd, as GTK is) and answered on the main thread's GLib loop. Hosts
//! that speak the protocol draw the icon: Plasma, GNOME with its AppIndicator
//! extension, waybar, snixembed. There is no XEmbed fallback, so a bare X
//! session's tray shows nothing. The platform-free half is `tray_menu.zig`.
const std = @import("std");

const dbus = @import("tray_dbus.zig");
const gio = @import("gio.zig");
const menu_mod = @import("../menu_accel.zig");
const model = @import("tray_menu.zig");

pub const Click = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, tray: *Tray) void };
/// Where the icon is: the protocol does not tell an item, so zeros.
pub const Anchor = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Options = struct {
    /// The item's title; hosts show it as the tooltip when none is set.
    title: []const u8 = "",
    /// A name in the current icon theme: Linux has no SF Symbols, so a symbol
    /// name is an icon name.
    symbol: []const u8 = "",
    tooltip: []const u8 = "",
    menu: []const menu_mod.MenuItem = &.{},
    /// Called on a left click. With a menu and no click, the host opens the
    /// menu on a left click (`ItemIsMenu`); with both, a left click calls this
    /// and the host opens the menu on a right click.
    on_click: ?Click = null,
};

/// The app's hooks (`App.newTray` sets them): a `.quit` item with no click of
/// its own calls `quit`; `forget` drops a destroyed tray from the app.
pub const Owner = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) void,
    forget: *const fn (ctx: *anyopaque, tray: *Tray) void,
};

const fdo_interface: [*:0]const u8 = dbus.fdo_interface;
const item_path: [*:0]const u8 = dbus.item_path;
const kde_interface: [*:0]const u8 = dbus.kde_interface;
const menu_interface: [*:0]const u8 = dbus.menu_interface;
const menu_path: [*:0]const u8 = dbus.menu_path;
const watcher_interface: [*:0]const u8 = "org.kde.StatusNotifierWatcher";
const watcher_names = [_][*:0]const u8{ "org.kde.StatusNotifierWatcher", "org.freedesktop.StatusNotifierWatcher" };
const watcher_path: [*:0]const u8 = "/StatusNotifierWatcher";

pub const Tray = struct {
    gpa: std.mem.Allocator,
    app_name: []const u8,
    owner: ?Owner = null,
    on_click: ?Click = null,

    conn: ?*anyopaque = null,
    item_info: ?*anyopaque = null,
    fdo_info: ?*anyopaque = null,
    menu_info: ?*anyopaque = null,
    item_reg: c_uint = 0,
    fdo_reg: c_uint = 0,
    menu_reg: c_uint = 0,
    watcher_subs: [watcher_names.len]c_uint = @splat(0),
    /// `org.kde.StatusNotifierItem-<pid>-<n>`, owned.
    name: ?[:0]u8 = null,

    title: ?[]u8 = null,
    tooltip: ?[]u8 = null,
    icon_name: ?[]u8 = null,
    /// `setImage`'s pixels as the protocol wants them: straight alpha, A,R,G,B.
    icon_pixmap: []u8 = &.{},
    icon_width: u32 = 0,
    icon_height: u32 = 0,

    menu: ?*model.Model = null,
    /// What a callback is doing, so `destroy` there frees after it returns.
    callbacks: usize = 0,
    dead: bool = false,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, opts: Options) !*Tray {
        if (!gio.ready()) return error.GioMissing;
        const self = try gpa.create(Tray);
        self.* = .{ .gpa = gpa, .app_name = app_name, .on_click = opts.on_click };
        errdefer self.free();
        if (opts.title.len > 0) self.title = try gpa.dupe(u8, opts.title);
        if (opts.tooltip.len > 0) self.tooltip = try gpa.dupe(u8, opts.tooltip);
        if (opts.symbol.len > 0) self.icon_name = try gpa.dupe(u8, opts.symbol);
        if (opts.menu.len > 0) self.menu = try model.Model.create(gpa, app_name, opts.menu);
        try self.connect();
        try self.claimName();
        try self.publish();
        self.listen();
        self.register();
        return self;
    }

    /// Removes the icon. From inside a click callback the tray lives until the
    /// callback returns; the app stops seeing it at once.
    pub fn destroy(self: *Tray) void {
        if (self.dead) return;
        self.dead = true;
        if (self.owner) |o| {
            self.owner = null;
            o.forget(o.ctx, self);
        }
        if (self.callbacks > 0) return;
        self.free();
    }

    fn connect(self: *Tray) !void {
        var err: ?*anyopaque = null;
        self.conn = gio.api.g_bus_get_sync(gio.session_bus, null, &err) orelse {
            gio.logError("connecting to the session bus", err);
            return error.NoSessionBus;
        };
    }

    /// Owns `org.kde.StatusNotifierItem-<pid>-<n>`, the first suffix free.
    fn claimName(self: *Tray) !void {
        const conn = self.conn orelse return error.NoSessionBus;
        const pid = std.os.linux.getpid();
        var n: u32 = 1;
        while (n <= 8) : (n += 1) {
            const name = try self.gpa.printSentinel("org.kde.StatusNotifierItem-{d}-{d}", .{ pid, n }, 0);
            errdefer self.gpa.free(name);
            var err: ?*anyopaque = null;
            // DBUS_NAME_FLAG_DO_NOT_QUEUE: a queue would never be reached.
            const reply = gio.api.g_dbus_connection_call_sync(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", gio.api.g_variant_new("(su)", name.ptr, @as(c_uint, 4)), null, gio.no_flags, gio.timeout_ms, null, &err) orelse {
                gio.logError("claiming the item's bus name", err);
                return error.BusRejected;
            };
            const code = gio.firstU32(reply);
            gio.unref(reply);
            if (code == 1) {
                self.name = name;
                return;
            }
            self.gpa.free(name);
        }
        return error.NameTaken;
    }

    /// Exports the item and the menu at their well-known paths.
    fn publish(self: *Tray) !void {
        const conn = self.conn orelse return error.NoSessionBus;
        var err: ?*anyopaque = null;
        self.item_info = gio.api.g_dbus_node_info_new_for_xml(dbus.kde_item_xml, &err) orelse {
            gio.logError("reading the item's introspection", err);
            return error.BusRejected;
        };
        self.fdo_info = gio.api.g_dbus_node_info_new_for_xml(dbus.fdo_item_xml, &err) orelse {
            gio.logError("reading the item's introspection", err);
            return error.BusRejected;
        };
        self.menu_info = gio.api.g_dbus_node_info_new_for_xml(dbus.menu_xml, &err) orelse {
            gio.logError("reading the menu's introspection", err);
            return error.BusRejected;
        };
        const kde = gio.api.g_dbus_node_info_lookup_interface(self.item_info, kde_interface) orelse return error.BusRejected;
        const fdo = gio.api.g_dbus_node_info_lookup_interface(self.fdo_info, fdo_interface) orelse return error.BusRejected;
        const menu = gio.api.g_dbus_node_info_lookup_interface(self.menu_info, menu_interface) orelse return error.BusRejected;
        self.item_reg = exportObject(conn, item_path, kde, &dbus.item_vtable, self);
        self.fdo_reg = exportObject(conn, item_path, fdo, &dbus.item_vtable, self);
        self.menu_reg = exportObject(conn, menu_path, menu, &dbus.menu_vtable, self);
        if (self.item_reg == 0 or self.fdo_reg == 0 or self.menu_reg == 0) return error.BusRejected;
    }

    fn exportObject(conn: ?*anyopaque, path: [*:0]const u8, iface: ?*anyopaque, vtable: *const gio.VTable, self: *Tray) c_uint {
        var err: ?*anyopaque = null;
        const id = gio.api.g_dbus_connection_register_object(conn, path, iface, vtable, self, null, &err);
        if (id == 0) gio.logError("exporting a tray object", err);
        return id;
    }

    /// Registers with a watcher whenever one appears: a shell that starts
    /// after the app, or restarts, is covered.
    fn listen(self: *Tray) void {
        const conn = self.conn orelse return;
        for (watcher_names, 0..) |name, i| {
            self.watcher_subs[i] = gio.api.g_dbus_connection_signal_subscribe(conn, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", name, gio.signal_flags, onWatcher, self, null);
        }
    }

    /// Tells every watcher name we exist; the ones nobody owns fail quietly,
    /// and auto-start stays off.
    fn register(self: *Tray) void {
        const conn = self.conn orelse return;
        const name = self.name orelse return;
        for (watcher_names) |watcher| {
            gio.api.g_dbus_connection_call(conn, watcher, watcher_path, watcher_interface, "RegisterStatusNotifierItem", gio.api.g_variant_new("(s)", name.ptr), null, gio.no_flags, gio.timeout_ms, null, null, null);
        }
    }

    fn onWatcher(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, params: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(user_data orelse return));
        self.callbacks += 1;
        defer self.leave();
        if (self.dead) return;
        // (name, old owner, new owner): a watcher appearing has an owner.
        if (gio.stringAt(params, 2).len == 0) return;
        self.register();
    }

    /// The item's title, which hosts also fall back to for the tooltip.
    pub fn setTitle(self: *Tray, title: []const u8) void {
        if (self.dead) return;
        replace(self.gpa, &self.title, title);
        self.signalItem("NewTitle", null);
        self.signalItem("NewToolTip", null);
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) void {
        if (self.dead) return;
        replace(self.gpa, &self.tooltip, tooltip);
        self.signalItem("NewToolTip", null);
    }

    /// A name in the icon theme; it replaces any pixels set before.
    pub fn setSymbol(self: *Tray, name: []const u8) void {
        if (self.dead) return;
        replace(self.gpa, &self.icon_name, name);
        if (self.icon_pixmap.len > 0) self.gpa.free(self.icon_pixmap);
        self.icon_pixmap = &.{};
        self.icon_width = 0;
        self.icon_height = 0;
        self.signalItem("NewIcon", null);
    }

    /// Shows `bgra` (premultiplied, `width` × `height`) as the icon; it
    /// replaces any icon name. `scale` and `template` are the Mac's: a host
    /// shows the pixels as they are, and only named icons are tinted.
    pub fn setImage(self: *Tray, bgra: []const u8, width: usize, height: usize, scale: f64, template: bool) void {
        _ = scale;
        _ = template;
        if (self.dead or width == 0 or height == 0 or bgra.len < width * height * 4) return;
        const pixels = self.gpa.alloc(u8, width * height * 4) catch return;
        toArgb(pixels, bgra[0 .. width * height * 4]);
        if (self.icon_pixmap.len > 0) self.gpa.free(self.icon_pixmap);
        self.icon_pixmap = pixels;
        self.icon_width = @intCast(width);
        self.icon_height = @intCast(height);
        if (self.icon_name) |n| self.gpa.free(n);
        self.icon_name = null;
        self.signalItem("NewIcon", null);
    }

    /// The protocol does not report where an item is drawn.
    pub fn anchor(_: *Tray) Anchor {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    /// Replaces the menu with one built from `template`, which is copied: it
    /// may be a temporary.
    pub fn setMenu(self: *Tray, app_name: []const u8, template: []const menu_mod.MenuItem) !void {
        if (self.dead) return;
        const m = try model.Model.create(self.gpa, app_name, template);
        const revision = if (self.menu) |old| old.revision +% 1 else 1;
        if (self.menu) |old| old.destroy();
        self.menu = m;
        m.revision = revision;
        self.layoutUpdated(0);
    }

    /// `setMenu` under the app's name.
    pub fn updateMenu(self: *Tray, template: []const menu_mod.MenuItem) !void {
        return self.setMenu(self.app_name, template);
    }

    /// The menu's item whose template had `id`, to check or disable.
    pub fn menuItem(self: *Tray, id: []const u8) ?*menu_mod.Item {
        const m = self.menu orelse return null;
        return m.item(id);
    }

    // -- the loop's side ----------------------------------------------------

    pub fn leave(self: *Tray) void {
        self.callbacks -= 1;
        if (self.callbacks == 0 and self.dead) self.free();
    }

    fn free(self: *Tray) void {
        const gpa = self.gpa;
        const conn = self.conn;
        if (conn) |c| {
            if (self.item_reg != 0) _ = gio.api.g_dbus_connection_unregister_object(c, self.item_reg);
            if (self.fdo_reg != 0) _ = gio.api.g_dbus_connection_unregister_object(c, self.fdo_reg);
            if (self.menu_reg != 0) _ = gio.api.g_dbus_connection_unregister_object(c, self.menu_reg);
            for (self.watcher_subs) |sub| if (sub != 0) gio.api.g_dbus_connection_signal_unsubscribe(c, sub);
            if (self.name) |name| gio.api.g_dbus_connection_call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName", gio.api.g_variant_new("(s)", name.ptr), null, gio.no_flags, gio.timeout_ms, null, null, null);
            gio.api.g_object_unref(c);
        }
        if (self.item_info) |i| gio.api.g_dbus_node_info_unref(i);
        if (self.fdo_info) |i| gio.api.g_dbus_node_info_unref(i);
        if (self.menu_info) |i| gio.api.g_dbus_node_info_unref(i);
        if (self.name) |name| gpa.free(name);
        if (self.title) |t| gpa.free(t);
        if (self.tooltip) |t| gpa.free(t);
        if (self.icon_name) |n| gpa.free(n);
        if (self.icon_pixmap.len > 0) gpa.free(self.icon_pixmap);
        if (self.menu) |m| m.destroy();
        gpa.destroy(self);
    }

    fn signalItem(self: *Tray, member: [*:0]const u8, params: ?*anyopaque) void {
        self.emit(item_path, kde_interface, member, params);
    }

    pub fn emit(self: *Tray, path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, params: ?*anyopaque) void {
        const conn = self.conn orelse return;
        var err: ?*anyopaque = null;
        if (gio.api.g_dbus_connection_emit_signal(conn, null, path, iface, member, params, &err) == 0) gio.logError(member, err);
    }

    fn layoutUpdated(self: *Tray, parent: i32) void {
        const revision = if (self.menu) |m| m.revision else 1;
        self.emit(menu_path, menu_interface, "LayoutUpdated", gio.api.g_variant_new("(ui)", revision, @as(c_int, parent)));
    }

    /// Runs a menu item a host activated.
    pub fn click(self: *Tray, id: i32) void {
        const m = self.menu orelse return;
        const n = m.node(id) orelse return;
        const it = n.item orelse return;
        if (it.click == null and it.role == .quit) {
            if (self.owner) |o| o.quit(o.ctx);
            return;
        }
        menu_mod.Menu.activate(it);
        if (self.dead) return;
        // The host drew its copy already: tell it what changed.
        const updated = gio.Array.init("a(ia{sv})");
        updated.add(gio.api.g_variant_new("(i@a{sv})", @as(c_int, id), dbus.props(n)));
        self.emit(menu_path, menu_interface, "ItemsPropertiesUpdated", gio.api.g_variant_new("(@a(ia{sv})@a(ias))", updated.end(), gio.array("a(ias)", &.{})));
    }

    // -- the item's interface ------------------------------------------------

    pub fn property(self: *Tray, name: []const u8) ?*anyopaque {
        const eql = std.mem.eql;
        if (eql(u8, name, "Category")) return gio.str("ApplicationStatus");
        if (eql(u8, name, "Id")) return gio.str(if (self.app_name.len > 0) self.app_name else "nanoui");
        if (eql(u8, name, "Title")) return gio.str(self.titleText());
        if (eql(u8, name, "Status")) return gio.str("Active");
        if (eql(u8, name, "WindowId")) return gio.api.g_variant_new_int32(0);
        if (eql(u8, name, "IconName")) return gio.str(self.icon_name orelse "");
        if (eql(u8, name, "IconPixmap")) return self.pixmaps();
        if (eql(u8, name, "IconThemePath")) return gio.str("");
        if (eql(u8, name, "OverlayIconName") or eql(u8, name, "AttentionIconName") or eql(u8, name, "AttentionMovieName")) return gio.str("");
        if (eql(u8, name, "OverlayIconPixmap") or eql(u8, name, "AttentionIconPixmap")) return gio.Array.init("a(iiay)").end();
        if (eql(u8, name, "ToolTip")) return gio.api.g_variant_new("(s@a(iiay)@ss)", "", self.pixmaps(), gio.str(self.tooltipText()), "");
        if (eql(u8, name, "ItemIsMenu")) return gio.api.g_variant_new_boolean(@intFromBool(self.menu != null and self.on_click == null));
        if (eql(u8, name, "Menu")) return gio.api.g_variant_new_object_path(if (self.menu != null) menu_path else "/");
        return null;
    }

    fn titleText(self: *const Tray) []const u8 {
        if (self.title) |t| if (t.len > 0) return t;
        return self.app_name;
    }

    fn tooltipText(self: *const Tray) []const u8 {
        if (self.tooltip) |t| if (t.len > 0) return t;
        return self.titleText();
    }

    fn pixmaps(self: *Tray) ?*anyopaque {
        const a = gio.Array.init("a(iiay)");
        if (self.icon_pixmap.len > 0) a.add(gio.api.g_variant_new("(ii@ay)", @as(c_int, @intCast(self.icon_width)), @as(c_int, @intCast(self.icon_height)), gio.bytes(self.icon_pixmap)));
        return a.end();
    }
};

test "premultiplied BGRA becomes straight ARGB in network order" {
    var dst: [8]u8 = @splat(0);
    // Opaque red, premultiplied BGRA.
    toArgb(dst[0..4], &.{ 0, 0, 255, 255 });
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 0, 0 }, dst[0..4]);
    // Half transparent, premultiplied: straight red is all red.
    toArgb(dst[0..4], &.{ 0, 0, 128, 128 });
    try std.testing.expectEqualSlices(u8, &.{ 128, 255, 0, 0 }, dst[0..4]);
    // Nothing at all stays nothing.
    toArgb(dst[0..4], &.{ 12, 34, 56, 0 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, dst[0..4]);
}

/// `slot` takes a copy of `value`, or nothing when it is empty.
fn replace(gpa: std.mem.Allocator, slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value.len > 0) gpa.dupe(u8, value) catch null else null;
}

/// Premultiplied BGRA (`Tray.setImage`'s pixels) to the ARGB32 big-endian the
/// protocol names: straight alpha, bytes A,R,G,B.
fn toArgb(dst: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 4) {
        const b = src[i];
        const g = src[i + 1];
        const r = src[i + 2];
        const a = src[i + 3];
        dst[i] = a;
        if (a == 0) {
            dst[i + 1] = 0;
            dst[i + 2] = 0;
            dst[i + 3] = 0;
            continue;
        }
        // Undo the premultiplication, rounding to the nearest channel value.
        const av: u32 = a;
        const half = av / 2;
        dst[i + 1] = @intCast(@min((@as(u32, r) * 255 + half) / av, 255));
        dst[i + 2] = @intCast(@min((@as(u32, g) * 255 + half) / av, 255));
        dst[i + 3] = @intCast(@min((@as(u32, b) * 255 + half) / av, 255));
    }
}
