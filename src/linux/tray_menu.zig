//! The Linux tray's platform-free half, tested on every platform: a menu
//! template as the tree a `com.canonical.dbusmenu` host asks for — ids,
//! labels, separators, submenus, toggles and accelerators — with the live
//! state and clicks read from the template's `menu_accel` items.
const std = @import("std");

const menu_accel = @import("../menu_accel.zig");
const menu_types = @import("../menu_types.zig");

pub const Kind = enum { standard, separator, submenu };

pub const Node = struct {
    /// The dbusmenu id: 0 for the root, then the template's pre-order.
    id: i32,
    label: []const u8 = "",
    kind: Kind = .standard,
    /// The template's accelerator, for the host to show.
    shortcut: menu_types.Accelerator = .{},
    /// Live state and what a click runs; null for a submenu or a separator.
    item: ?*menu_accel.Item = null,
    /// The template's `disabled`, which only a submenu and a separator keep:
    /// a leaf's enabled state is its item's, live.
    disabled: bool = false,
    children: []const Node = &.{},
};

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    /// The same template as items: their `checked` and `disabled` are read
    /// when a host asks, so `Item.setChecked` shows the next time.
    menu: *menu_accel.Menu,
    root: Node,
    /// Bumped when the menu is replaced; hosts refetch when it moves.
    revision: u32 = 1,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, template: []const menu_accel.MenuItem) !*Model {
        const self = try gpa.create(Model);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        self.menu = try menu_accel.Menu.create(gpa, template);
        errdefer self.menu.destroy();
        var ids: i32 = 0;
        var cursor: usize = 0;
        const children = try self.build(app_name, template, &ids, &cursor);
        self.root = .{ .id = 0, .children = children };
        self.revision = 1;
        return self;
    }

    pub fn destroy(self: *Model) void {
        const gpa = self.arena.child_allocator;
        self.menu.destroy();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn build(self: *Model, app_name: []const u8, template: []const menu_accel.MenuItem, ids: *i32, cursor: *usize) ![]const Node {
        const a = self.arena.allocator();
        var nodes: std.ArrayList(Node) = .empty;
        for (template) |t| {
            if (t.hidden) continue;
            ids.* += 1;
            if (t.is_separator) {
                try nodes.append(a, .{ .id = ids.*, .kind = .separator });
                continue;
            }
            const label = if (t.label.len > 0 or t.role != .quit)
                try a.dupe(u8, t.label)
            else
                try std.fmt.allocPrint(a, "Quit {s}", .{app_name});
            if (t.submenu) |sub| {
                try nodes.append(a, .{
                    .id = ids.*,
                    .label = label,
                    .kind = .submenu,
                    .disabled = t.disabled,
                    .children = try self.build(app_name, sub, ids, cursor),
                });
                continue;
            }
            // `menu_accel.Menu` flattens the template the same way, in place.
            const live = &self.menu.items.items[cursor.*];
            cursor.* += 1;
            try nodes.append(a, .{
                .id = ids.*,
                .label = label,
                .shortcut = menu_types.parseAccelerator(t.accelerator),
                .item = live,
            });
        }
        return try nodes.toOwnedSlice(a);
    }

    /// The node with this id, the root included.
    pub fn node(self: *const Model, id: i32) ?*const Node {
        if (self.root.id == id) return &self.root;
        return find(&self.root, id);
    }

    fn find(n: *const Node, id: i32) ?*const Node {
        for (n.children) |*c| {
            if (c.id == id) return c;
            if (find(c, id)) |hit| return hit;
        }
        return null;
    }

    /// The template's item with this id, to check or disable it.
    pub fn item(self: *const Model, id: []const u8) ?*menu_accel.Item {
        return self.menu.item(id);
    }
};

/// What a host shows for `shortcut`: GLib's names for the modifiers and the
/// key, or null when there is no accelerator.
pub fn shortcutKeys(a: menu_types.Accelerator, names: *[4][]const u8, key_buf: *[8]u8) ?[]const []const u8 {
    if (a.key == 0) return null;
    const key = menu_types.Accelerator.keyString(a, key_buf);
    if (key.len == 0) return null;
    var n: usize = 0;
    if (a.mods & menu_types.mod_ctrl != 0) {
        names[n] = "Control";
        n += 1;
    }
    if (a.mods & menu_types.mod_cmd != 0) {
        names[n] = "Super";
        n += 1;
    }
    if (a.mods & menu_types.mod_alt != 0) {
        names[n] = "Alt";
        n += 1;
    }
    if (a.mods & menu_types.mod_shift != 0) {
        names[n] = "Shift";
        n += 1;
    }
    names[n] = key;
    return names[0 .. n + 1];
}

test "a template becomes the menu's tree, ids in pre-order" {
    const gpa = std.testing.allocator;
    const m = try Model.create(gpa, "Alchemist Render", &.{
        .{ .id = "a", .label = "A" },
        .{ .is_separator = true },
        .{ .label = "Sub", .submenu = &.{
            .{ .id = "b", .label = "B", .kind = .checkbox, .checked = true },
        } },
        .{ .id = "hidden", .label = "H", .hidden = true },
        .{ .id = "c", .label = "C", .kind = .radio, .accelerator = "CmdOrCtrl+Q" },
    });
    defer m.destroy();

    try std.testing.expectEqual(@as(i32, 0), m.root.id);
    try std.testing.expectEqual(@as(usize, 4), m.root.children.len);
    try std.testing.expectEqualStrings("A", m.node(1).?.label);
    try std.testing.expectEqual(Kind.separator, m.node(2).?.kind);
    try std.testing.expectEqualStrings("Sub", m.node(3).?.label);
    try std.testing.expectEqualStrings("B", m.node(4).?.label);
    try std.testing.expectEqualStrings("C", m.node(5).?.label);
    try std.testing.expect(m.node(6) == null);

    // The live state is the template's: a click toggles the checkbox.
    const b = m.item("b").?;
    try std.testing.expect(b.checked);
    menu_accel.Menu.activate(b);
    try std.testing.expect(!b.checked);
    try std.testing.expectEqual(@as(?*menu_accel.Item, b), m.node(4).?.item);
}

test "a shortcut becomes GLib's key names" {
    var list: [4][]const u8 = undefined;
    var buf: [8]u8 = undefined;
    const keys = shortcutKeys(menu_types.parseAccelerator("Ctrl+Shift+Q"), &list, &buf).?;
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("Control", keys[0]);
    try std.testing.expectEqualStrings("Shift", keys[1]);
    try std.testing.expectEqualStrings("q", keys[2]);
    try std.testing.expect(shortcutKeys(.{}, &list, &buf) == null);
}
