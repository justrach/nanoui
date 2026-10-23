//! Menus built from templates of `MenuItem`, used as the menu bar, context
//! menus and the menus of tray icons, after mygo's.
//!
//!     try app.setMenu(&.{
//!         .{ .role = .app_menu },
//!         .{ .label = "File", .submenu = &.{
//!             .{ .label = "New", .accelerator = "CmdOrCtrl+N", .click = .of(&state, State.new) },
//!             .separator,
//!             .{ .role = .close },
//!         } },
//!         .{ .role = .edit_menu },
//!         .{ .role = .window_menu },
//!     });
const std = @import("std");
const objc = @import("objc.zig");

const menu_types = @import("menu_types.zig");
pub const Kind = menu_types.Kind;
pub const Role = menu_types.Role;
pub const Click = menu_types.Click(Item);
pub const MenuItem = menu_types.MenuItem(Item);

/// An item of a built menu: its state, changeable while the menu shows.
/// Items live until their menu is destroyed, or their submenu rebuilt.
pub const Item = struct {
    menu: *Menu,
    ns: objc.Object,
    id: []const u8,
    kind: Kind,
    checked: bool,
    click: ?Click,
    selector: ?[:0]const u8 = null,
    on_open: ?Click = null,
    /// The submenu it holds, if it holds one.
    submenu: ?objc.Object = null,
    /// The item whose submenu it is in (null in the menu itself).
    parent: ?*Item = null,
    /// Radio items of one run share a group (0: none).
    group: u32 = 0,
    gone: bool = false,

    pub fn setChecked(it: *Item, on: bool) void {
        if (on and it.kind == .radio) {
            for (it.menu.items.items) |other| if (other.group == it.group) other.applyChecked(false);
        }
        it.applyChecked(on);
    }

    fn applyChecked(it: *Item, on: bool) void {
        it.checked = on;
        objc.msg(void, it.ns, "setState:", .{@as(objc.NSInteger, @intFromBool(on))});
    }

    pub fn setEnabled(it: *Item, on: bool) void {
        objc.msg(void, it.ns, "setEnabled:", .{on});
    }

    pub fn setLabel(it: *Item, label: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, it.ns, "setTitle:", .{objc.nsString(label)});
    }

    /// Replaces the key combination ("Cmd+Shift+T"; "" for none).
    pub fn setAccelerator(it: *Item, accel: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const a = parseAccelerator(accel);
        var buf: [8]u8 = undefined;
        objc.msg(void, it.ns, "setKeyEquivalent:", .{objc.nsString(a.keyString(&buf))});
        objc.msg(void, it.ns, "setKeyEquivalentModifierMask:", .{a.mods});
    }

    /// Replaces the items of its submenu (made if it had none) with
    /// `template`'s; the old ones' `Item`s are freed. Other items keep theirs.
    pub fn setSubmenu(it: *Item, template: []const MenuItem) error{OutOfMemory}!void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const m = it.menu;
        const sub = it.submenu orelse blk: {
            const title = objc.msg(objc.Object, it.ns, "title", .{});
            const sub = objc.msg(objc.Object, objc.alloc("NSMenu"), "initWithTitle:", .{title});
            defer objc.release(sub);
            objc.msg(void, sub, "setAutoenablesItems:", .{objc.NO});
            if (it.on_open != null) objc.msg(void, sub, "setDelegate:", .{m.target});
            objc.msg(void, it.ns, "setSubmenu:", .{sub});
            it.submenu = sub;
            break :blk sub;
        };
        m.dropUnder(it);
        objc.msg(void, sub, "removeAllItems", .{});
        try m.build(sub, template, it);
    }
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    ns: objc.Object,
    target: objc.Object,
    app_name: []const u8,
    items: std.ArrayList(*Item) = .empty,
    next_group: u32 = 1,
    /// The window menu, for `NSApp.windowsMenu`.
    windows_menu: ?objc.Object = null,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, template: []const MenuItem) !*Menu {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Menu);
        errdefer gpa.destroy(self);
        const target_class = objc.defineClass(.{
            .name = "NanoUIMenuTarget",
            .protocols = &.{"NSMenuDelegate"},
            .methods = &.{
                .{ .name = "itemClicked:", .imp = &itemClicked, .types = "v@:@" },
                .{ .name = "menuNeedsUpdate:", .imp = &menuNeedsUpdate, .types = "v@:@" },
            },
        });
        const target = objc.msg(objc.Object, target_class, "new", .{});
        objc.setZig(target, self);
        self.* = .{ .gpa = gpa, .ns = objc.new("NSMenu"), .target = target, .app_name = app_name };
        errdefer self.destroyItems();
        try self.build(self.ns, template, null);
        objc.msg(void, self.ns, "setAutoenablesItems:", .{objc.NO});
        return self;
    }

    pub fn destroy(self: *Menu) void {
        objc.setZig(self.target, null);
        objc.release(self.target);
        objc.release(self.ns);
        self.destroyItems();
        self.gpa.destroy(self);
    }

    fn destroyItems(self: *Menu) void {
        for (self.items.items) |it| self.gpa.destroy(it);
        self.items.deinit(self.gpa);
    }

    /// The item whose template had `id`.
    pub fn item(self: *Menu, id: []const u8) ?*Item {
        for (self.items.items) |it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// Shows the menu as a context menu at `x`, `y` (points, top left) of
    /// `view`, until the user picks an item or dismisses it.
    pub fn popup(self: *Menu, view: objc.Object, x: f64, y: f64) void {
        const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
        const h = objc.msg(objc.CGRect, view, "bounds", .{}).size.height;
        const at: objc.CGPoint = .{ .x = x, .y = if (flipped) y else h - y };
        _ = objc.msg(objc.BOOL, self.ns, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(?objc.Object, null), at, view });
    }

    /// Keeps `fields` as an item of the menu.
    fn track(self: *Menu, fields: Item) error{OutOfMemory}!*Item {
        const it = try self.gpa.create(Item);
        it.* = fields;
        self.items.append(self.gpa, it) catch |e| {
            self.gpa.destroy(it);
            return e;
        };
        return it;
    }

    /// Frees the items inside `holder`'s submenu, however deep.
    fn dropUnder(self: *Menu, holder: *Item) void {
        // Decided before anything is freed: the parent chains are all live.
        for (self.items.items) |x| {
            var p = x.parent;
            while (p) |q| : (p = q.parent) if (q == holder) {
                x.gone = true;
                break;
            };
        }
        var kept: usize = 0;
        for (self.items.items) |x| {
            if (x.gone) {
                self.gpa.destroy(x);
            } else {
                self.items.items[kept] = x;
                kept += 1;
            }
        }
        self.items.shrinkRetainingCapacity(kept);
    }

    fn build(self: *Menu, menu: objc.Object, template: []const MenuItem, parent: ?*Item) error{OutOfMemory}!void {
        var group: u32 = 0;
        for (template) |t| {
            if (t.role) |r| if (expand(r)) |items| {
                const holder = try self.addSubmenu(menu, if (t.label.len > 0) t.label else wholeMenuTitle(r, self.app_name), t, t.submenu orelse items, parent);
                if (r == .window_menu) self.windows_menu = holder.submenu;
                group = 0;
                continue;
            };
            if (t.is_separator) {
                objc.msg(void, menu, "addItem:", .{objc.msg(objc.Object, objc.class("NSMenuItem"), "separatorItem", .{})});
                group = 0;
                continue;
            }
            if (t.hidden) continue;
            if (t.submenu) |sub| {
                _ = try self.addSubmenu(menu, t.label, t, sub, parent);
                group = 0;
                continue;
            }
            if (t.kind == .radio) {
                if (group == 0) {
                    group = self.next_group;
                    self.next_group += 1;
                }
            } else group = 0;
            const ns = makeItem(t, self.app_name);
            defer objc.release(ns);
            const it = try self.track(.{ .menu = self, .ns = ns, .id = t.id, .kind = t.kind, .checked = t.checked, .click = t.click, .selector = t.selector, .group = group, .parent = parent });
            objc.msg(void, menu, "addItem:", .{ns});
            if ((t.role == null and t.selector == null) or t.click != null) {
                objc.msg(void, ns, "setTarget:", .{self.target});
                objc.msg(void, ns, "setAction:", .{objc.sel("itemClicked:")});
            }
            objc.msg(void, ns, "setTag:", .{@as(objc.NSInteger, @bitCast(@intFromPtr(it)))});
            it.applyChecked(t.checked);
        }
    }

    fn addSubmenu(self: *Menu, menu: objc.Object, title: []const u8, t: MenuItem, template: []const MenuItem, parent: ?*Item) error{OutOfMemory}!*Item {
        const holder = objc.new("NSMenuItem");
        defer objc.release(holder);
        objc.msg(void, holder, "setTitle:", .{objc.nsString(title)});
        decorate(holder, t);
        const sub = objc.msg(objc.Object, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString(title)});
        defer objc.release(sub);
        objc.msg(void, sub, "setAutoenablesItems:", .{objc.NO});
        if (t.on_open != null) objc.msg(void, sub, "setDelegate:", .{self.target});
        objc.msg(void, holder, "setSubmenu:", .{sub});
        objc.msg(void, menu, "addItem:", .{holder});
        const it = try self.track(.{ .menu = self, .ns = holder, .id = t.id, .kind = .normal, .checked = false, .click = null, .on_open = t.on_open, .submenu = sub, .parent = parent });
        try self.build(sub, template, it);
        return it;
    }
};

/// The items of a whole-menu role.
fn expand(r: Role) ?[]const MenuItem {
    return switch (r) {
        .app_menu => &.{ .{ .role = .about }, .separator, .{ .role = .hide }, .{ .role = .hide_others }, .{ .role = .unhide }, .separator, .{ .role = .quit } },
        .edit_menu => &.{ .{ .role = .undo }, .{ .role = .redo }, .separator, .{ .role = .cut }, .{ .role = .copy }, .{ .role = .paste }, .{ .role = .select_all } },
        .view_menu => &.{.{ .role = .toggle_full_screen }},
        .window_menu => &.{ .{ .role = .minimize }, .{ .role = .zoom }, .separator, .{ .role = .front }, .separator, .{ .role = .close } },
        else => null,
    };
}

fn wholeMenuTitle(r: Role, app_name: []const u8) []const u8 {
    return switch (r) {
        .app_menu => app_name,
        .edit_menu => "Edit",
        .view_menu => "View",
        else => "Window",
    };
}

const RoleInfo = struct { label: []const u8, action: [:0]const u8, accel: []const u8 = "" };

fn roleInfo(r: Role) RoleInfo {
    return switch (r) {
        .about => .{ .label = "About {s}", .action = "orderFrontStandardAboutPanel:" },
        .hide => .{ .label = "Hide {s}", .action = "hide:", .accel = "Cmd+H" },
        .hide_others => .{ .label = "Hide Others", .action = "hideOtherApplications:", .accel = "Cmd+Alt+H" },
        .unhide => .{ .label = "Show All", .action = "unhideAllApplications:" },
        .quit => .{ .label = "Quit {s}", .action = "terminate:", .accel = "Cmd+Q" },
        .undo => .{ .label = "Undo", .action = "undo:", .accel = "Cmd+Z" },
        .redo => .{ .label = "Redo", .action = "redo:", .accel = "Cmd+Shift+Z" },
        .cut => .{ .label = "Cut", .action = "cut:", .accel = "Cmd+X" },
        .copy => .{ .label = "Copy", .action = "copy:", .accel = "Cmd+C" },
        .paste => .{ .label = "Paste", .action = "paste:", .accel = "Cmd+V" },
        .delete => .{ .label = "Delete", .action = "delete:" },
        .select_all => .{ .label = "Select All", .action = "selectAll:", .accel = "Cmd+A" },
        .minimize => .{ .label = "Minimize", .action = "performMiniaturize:", .accel = "Cmd+M" },
        .zoom => .{ .label = "Zoom", .action = "performZoom:" },
        .close => .{ .label = "Close Window", .action = "performClose:", .accel = "Cmd+W" },
        .toggle_full_screen => .{ .label = "Enter Full Screen", .action = "toggleFullScreen:", .accel = "Cmd+Ctrl+F" },
        .front => .{ .label = "Bring All to Front", .action = "arrangeInFront:" },
        else => .{ .label = "", .action = "noop:" },
    };
}

fn makeItem(t: MenuItem, app_name: []const u8) objc.Object {
    var buf: [256]u8 = undefined;
    var label = t.label;
    var accel = t.accelerator;
    var action: [:0]const u8 = "itemClicked:";
    if (t.role) |r| {
        const info = roleInfo(r);
        if (label.len == 0) label = if (std.mem.indexOf(u8, info.label, "{s}")) |i|
            std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ info.label[0..i], app_name, info.label[i + 3 ..] }) catch info.label
        else
            info.label;
        if (accel.len == 0) accel = info.accel;
        action = info.action;
    } else if (t.selector) |sel| action = sel;
    const parsed = parseAccelerator(accel);
    var key_buf: [8]u8 = undefined;
    const key = parsed.keyString(&key_buf);
    const ns = objc.msg(objc.Object, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{
        objc.nsString(label), objc.sel(action), objc.nsString(key),
    });
    if (key.len > 0) objc.msg(void, ns, "setKeyEquivalentModifierMask:", .{parsed.mods});
    decorate(ns, t);
    return ns;
}

/// What an item and a submenu's holder share: state, tooltip, picture.
fn decorate(ns: objc.Object, t: MenuItem) void {
    if (t.disabled) objc.msg(void, ns, "setEnabled:", .{objc.NO});
    if (t.tooltip.len > 0) objc.msg(void, ns, "setToolTip:", .{objc.nsString(t.tooltip)});
    if (t.alternate) objc.msg(void, ns, "setAlternate:", .{objc.YES});
    if (t.image_png.len > 0) {
        const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, t.image_png.ptr), t.image_png.len });
        const img = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{data}) orelse return;
        defer objc.release(img);
        objc.msg(void, img, "setSize:", .{objc.CGSize{ .width = 16, .height = 16 }});
        objc.msg(void, ns, "setImage:", .{img});
    } else if (t.image_symbol.len > 0) {
        const img = objc.msg(?objc.Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.nsString(t.image_symbol), @as(?objc.Object, null) }) orelse return;
        objc.msg(void, ns, "setImage:", .{img});
    }
}

pub const Accelerator = menu_types.Accelerator;
pub const mod_shift = menu_types.mod_shift;
pub const mod_ctrl = menu_types.mod_ctrl;
pub const mod_alt = menu_types.mod_alt;
pub const mod_cmd = menu_types.mod_cmd;
pub const parseAccelerator = menu_types.parseAccelerator;

fn itemClicked(self_obj: objc.Object, _: objc.SEL, sender: objc.Object) callconv(.c) void {
    const menu = objc.getZig(Menu, self_obj) orelse return;
    const tag: usize = @bitCast(objc.msg(objc.NSInteger, sender, "tag", .{}));
    // The item, if it is still the menu's.
    const it = for (menu.items.items) |x| {
        if (@intFromPtr(x) == tag) break x;
    } else return;
    switch (it.kind) {
        .checkbox => it.setChecked(!it.checked),
        .radio => it.setChecked(true),
        .normal => {},
    }
    if (it.click) |c| c.func(c.ctx, it);
}

/// A submenu is about to show: its item's `on_open` may refill it.
fn menuNeedsUpdate(self_obj: objc.Object, _: objc.SEL, sub: objc.Object) callconv(.c) void {
    const menu = objc.getZig(Menu, self_obj) orelse return;
    for (menu.items.items) |it| if (it.submenu) |s| if (s == sub) {
        if (it.on_open) |c| c.func(c.ctx, it);
        return;
    };
}
