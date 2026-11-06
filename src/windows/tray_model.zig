//! The Windows tray's platform-free half, tested on every platform: a menu
//! template flattened into the rows its popup menu is built from (UTF-16
//! labels with `&` doubled, separators tidied, command ids), the items a
//! click reaches with their live state (checked, disabled), the `MF_*`
//! flags of a row, the notify icon's callback decoded into what to do, and
//! the icon's pixels made straight-alpha.
const std = @import("std");
const menu_accel = @import("../menu_accel.zig");

pub const MenuItem = menu_accel.MenuItem;
pub const Item = menu_accel.Item;

// `AppendMenuW`'s flags.
pub const MF_STRING: u32 = 0x0;
pub const MF_GRAYED: u32 = 0x1;
pub const MF_CHECKED: u32 = 0x8;
pub const MF_POPUP: u32 = 0x10;
pub const MF_SEPARATOR: u32 = 0x800;

pub const Row = struct {
    kind: Kind,
    /// UTF-16, `&` doubled (a lone one would mark a mnemonic), NUL-terminated.
    label: [:0]const u16 = &empty,
    /// `.item`: its command id, which is 1 + its index in `Model.items`.
    command: u16 = 0,
    /// `.open`: the submenu's own item is greyed.
    disabled: bool = false,

    pub const Kind = enum { item, separator, open, close };
    const empty = [_:0]u16{};
};

/// A tray menu as rows and items, owning copies of everything in the
/// template: the template may be a temporary the caller rebuilds each time.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,
    /// What a click reaches, by command id; their `checked` and `disabled`
    /// are read each time the popup is built, so `Item.setChecked` and
    /// `setEnabled` show the next time it opens.
    menu: *menu_accel.Menu,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, template: []const MenuItem) !*Model {
        const self = try gpa.create(Model);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const menu = try gpa.create(menu_accel.Menu);
        menu.* = .{ .gpa = gpa };
        errdefer menu.destroy();
        var b: Builder = .{ .arena = self.arena.allocator(), .gpa = gpa, .menu = menu, .app_name = app_name };
        try b.add(template);
        b.trimSeparator();
        self.rows = b.rows.items;
        self.menu = menu;
        return self;
    }

    pub fn destroy(self: *Model) void {
        const gpa = self.menu.gpa;
        self.menu.destroy();
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn items(self: *const Model) []Item {
        return self.menu.items.items;
    }

    /// The item a command id names, if any does.
    pub fn itemOf(self: *const Model, command: usize) ?*Item {
        const all = self.items();
        if (command == 0 or command > all.len) return null;
        return &all[command - 1];
    }

    pub fn item(self: *const Model, id: []const u8) ?*Item {
        return self.menu.item(id);
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    menu: *menu_accel.Menu,
    app_name: []const u8,
    rows: std.ArrayList(Row) = .empty,

    fn add(b: *Builder, template: []const MenuItem) !void {
        for (template) |t| {
            if (t.hidden) continue;
            if (t.is_separator) {
                // None first, none after another, none straight after a
                // submenu opens: hidden items can leave such runs behind.
                const last = if (b.rows.items.len > 0) b.rows.items[b.rows.items.len - 1].kind else Row.Kind.open;
                if (last == .separator or last == .open) continue;
                try b.rows.append(b.arena, .{ .kind = .separator });
                continue;
            }
            const label = try labelOf(b.arena, t, b.app_name);
            if (t.submenu) |sub| {
                try b.rows.append(b.arena, .{ .kind = .open, .label = label, .disabled = t.disabled });
                try b.add(sub);
                b.trimSeparator();
                try b.rows.append(b.arena, .{ .kind = .close });
                continue;
            }
            if (b.menu.items.items.len >= std.math.maxInt(u16)) return error.TooManyItems;
            try b.menu.items.append(b.gpa, .{
                .menu = b.menu,
                .id = try b.arena.dupe(u8, t.id),
                .kind = t.kind,
                .checked = t.checked,
                .disabled = t.disabled,
                .click = t.click,
                .role = t.role,
                .accel = menu_accel.parseAccelerator(t.accelerator),
            });
            try b.rows.append(b.arena, .{ .kind = .item, .label = label, .command = @intCast(b.menu.items.items.len) });
        }
    }

    /// Drops a separator that ends a menu.
    fn trimSeparator(b: *Builder) void {
        if (b.rows.items.len > 0 and b.rows.items[b.rows.items.len - 1].kind == .separator) b.rows.items.len -= 1;
    }
};

/// The label a row shows: its own, or for a `.quit` item with none
/// "Quit <app>", as the Mac's menu names it.
fn labelOf(arena: std.mem.Allocator, t: MenuItem, app_name: []const u8) ![:0]const u16 {
    if (t.label.len == 0 and t.role == .quit) {
        const s = try std.fmt.allocPrint(arena, "Quit {s}", .{app_name});
        return encodeLabel(arena, s);
    }
    return encodeLabel(arena, t.label);
}

/// `s` as a menu label: UTF-16, NUL-terminated, every `&` doubled, and a
/// byte that is not UTF-8 shown as U+FFFD rather than dropping the label.
pub fn encodeLabel(gpa: std.mem.Allocator, s: []const u8) ![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        var cp: u21 = 0xFFFD;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |len| {
            if (i + len > s.len) {
                // A sequence cut short ends the label.
                i = s.len;
            } else if (std.unicode.utf8Decode(s[i .. i + len])) |c| {
                cp = c;
                i += len;
            } else |_| i += 1;
        } else |_| i += 1;
        if (cp == '&') try out.append(gpa, '&');
        if (cp < 0x10000) {
            try out.append(gpa, @intCast(cp));
        } else {
            try out.append(gpa, 0xD800 | @as(u16, @intCast((cp - 0x10000) >> 10)));
            try out.append(gpa, 0xDC00 | @as(u16, @intCast((cp - 0x10000) & 0x3FF)));
        }
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// A row's `AppendMenuW` flags, from the item's state now. A checked radio
/// item takes `MF_CHECKED` too; the caller gives it the round bullet.
pub fn flags(row: Row, it: ?*const Item) u32 {
    return switch (row.kind) {
        .separator => MF_SEPARATOR,
        .open => MF_POPUP | (if (row.disabled) MF_GRAYED else 0),
        .close => 0,
        .item => blk: {
            const i = it orelse break :blk MF_GRAYED;
            var f: u32 = MF_STRING;
            if (i.disabled) f |= MF_GRAYED;
            if (i.checked and i.kind != .normal) f |= MF_CHECKED;
            break :blk f;
        },
    };
}

// The notify icon's callback (`NOTIFYICON_VERSION_4`): the event in the low
// word of lParam, the icon's id in the high word, and where (in screen
// pixels) in wParam's two words.
pub const NIN_SELECT: u16 = 0x0400;
pub const NIN_KEYSELECT: u16 = 0x0401;
pub const WM_CONTEXTMENU: u16 = 0x007B;

pub const Callback = struct { event: u16, id: u16, x: i32, y: i32 };

pub fn decode(wp: usize, lp: isize) Callback {
    const l: usize = @bitCast(lp);
    return .{
        .event = @truncate(l),
        .id = @truncate(l >> 16),
        .x = @as(i16, @bitCast(@as(u16, @truncate(wp)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))),
    };
}

pub const Action = enum { none, click, menu };

/// What an event does. A left click (or Enter on the focused icon) calls
/// `on_click` when there is one and shows the menu otherwise; a right click
/// (or the menu key) shows the menu: Windows' convention, where the Mac's
/// menu takes every click.
pub fn action(event: u16, has_click: bool, has_menu: bool) Action {
    return switch (event) {
        NIN_SELECT, NIN_KEYSELECT => if (has_click) .click else if (has_menu) .menu else .none,
        WM_CONTEXTMENU => if (has_menu) .menu else .none,
        else => .none,
    };
}

/// Premultiplied BGRA (as `Tray.setImage` takes it) to the straight alpha
/// an icon's colour bitmap holds.
pub fn straightAlpha(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        const a = src[i + 3];
        dst[i + 3] = a;
        for (0..3) |k| dst[i + k] = if (a == 0) 0 else @intCast(@min(255, (@as(u32, src[i + k]) * 255 + a / 2) / a));
    }
}

const testing = std.testing;

fn utf16(comptime s: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "a tray menu's rows: labels, separators tidied, submenus, command ids" {
    const gpa = testing.allocator;
    const m = try Model.create(gpa, "Alchemist Render", &.{
        .separator,
        .{ .label = "Working: 2 jobs", .disabled = true, .id = "status" },
        .separator,
        .separator,
        .{ .label = "Open", .id = "open" },
        .{ .label = "Hidden", .hidden = true },
        .{ .label = "Pause & resume", .kind = .checkbox, .checked = true, .id = "pause" },
        .{ .label = "More", .submenu = &.{
            .separator,
            .{ .label = "Logs", .id = "logs" },
            .separator,
        } },
        .separator,
        .{ .role = .quit, .id = "quit" },
        .separator,
    });
    defer m.destroy();
    const kinds = [_]Row.Kind{ .item, .separator, .item, .item, .open, .item, .close, .separator, .item };
    try testing.expectEqual(kinds.len, m.rows.len);
    for (kinds, m.rows) |k, r| try testing.expectEqual(k, r.kind);
    try testing.expectEqualSlices(u16, utf16("Working: 2 jobs"), m.rows[0].label);
    try testing.expectEqualSlices(u16, utf16("Pause && resume"), m.rows[3].label);
    try testing.expectEqualSlices(u16, utf16("More"), m.rows[4].label);
    try testing.expectEqualSlices(u16, utf16("Quit Alchemist Render"), m.rows[8].label);
    // Items in order, one command each, ids copied.
    try testing.expectEqual(@as(usize, 5), m.items().len);
    try testing.expectEqual(@as(u16, 1), m.rows[0].command);
    try testing.expectEqual(@as(u16, 4), m.rows[5].command);
    try testing.expectEqual(@as(u16, 5), m.rows[8].command);
    try testing.expectEqualStrings("logs", m.itemOf(4).?.id);
    try testing.expect(m.itemOf(0) == null and m.itemOf(6) == null);
    try testing.expectEqualStrings("pause", m.item("pause").?.id);
}

test "a row's flags follow its item's state now" {
    const gpa = testing.allocator;
    const m = try Model.create(gpa, "app", &.{
        .{ .label = "Info", .disabled = true },
        .{ .label = "Check", .kind = .checkbox, .id = "c" },
        .{ .label = "Plain", .checked = true },
        .separator,
        .{ .label = "Sub", .disabled = true, .submenu = &.{.{ .label = "x" }} },
    });
    defer m.destroy();
    try testing.expectEqual(MF_GRAYED, flags(m.rows[0], m.itemOf(1)));
    try testing.expectEqual(MF_STRING, flags(m.rows[1], m.itemOf(2)));
    // A normal item never shows a check.
    try testing.expectEqual(MF_STRING, flags(m.rows[2], m.itemOf(3)));
    try testing.expectEqual(MF_SEPARATOR, flags(m.rows[3], null));
    try testing.expectEqual(MF_POPUP | MF_GRAYED, flags(m.rows[4], null));
    // A click toggles the checkbox, and the next popup shows it; so does setEnabled.
    menu_accel.Menu.activate(m.item("c").?);
    m.item("c").?.setEnabled(false);
    try testing.expectEqual(MF_CHECKED | MF_GRAYED, flags(m.rows[1], m.itemOf(2)));
}

test "a click reaches its item's handler" {
    const gpa = testing.allocator;
    const State = struct {
        hits: usize = 0,
        fn hit(s: *@This(), it: *Item) void {
            s.hits += 1;
            std.debug.assert(std.mem.eql(u8, it.id, "open"));
        }
    };
    var state: State = .{};
    const m = try Model.create(gpa, "app", &.{.{ .label = "Open", .id = "open", .click = .of(&state, State.hit) }});
    defer m.destroy();
    menu_accel.Menu.activate(m.itemOf(m.rows[0].command).?);
    try testing.expectEqual(@as(usize, 1), state.hits);
}

test "labels: ampersands doubled, non-BMP as surrogates, bad bytes kept visible" {
    const gpa = testing.allocator;
    const a = try encodeLabel(gpa, "R&D");
    defer gpa.free(a);
    try testing.expectEqualSlices(u16, utf16("R&&D"), a);
    const b = try encodeLabel(gpa, "a\u{1F600}");
    defer gpa.free(b);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xD83D, 0xDE00 }, b);
    const c = try encodeLabel(gpa, "a\xffb");
    defer gpa.free(c);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b' }, c);
    const d = try encodeLabel(gpa, "x\xe2\x82");
    defer gpa.free(d);
    try testing.expectEqualSlices(u16, &.{ 'x', 0xFFFD }, d);
    try testing.expectEqual(@as(u16, 0), d[d.len]);
}

test "the notify icon's callback: what each event does" {
    // lParam: event | id << 16; wParam: x | y << 16, signed (a monitor left of the primary).
    const cb = decode(@as(usize, 0xFFF6) | (@as(usize, 300) << 16), @bitCast(@as(usize, NIN_SELECT) | (@as(usize, 7) << 16)));
    try testing.expectEqual(NIN_SELECT, cb.event);
    try testing.expectEqual(@as(u16, 7), cb.id);
    try testing.expectEqual(@as(i32, -10), cb.x);
    try testing.expectEqual(@as(i32, 300), cb.y);
    try testing.expectEqual(Action.click, action(NIN_SELECT, true, true));
    try testing.expectEqual(Action.menu, action(NIN_SELECT, false, true));
    try testing.expectEqual(Action.none, action(NIN_SELECT, false, false));
    try testing.expectEqual(Action.click, action(NIN_KEYSELECT, true, false));
    try testing.expectEqual(Action.menu, action(WM_CONTEXTMENU, true, true));
    try testing.expectEqual(Action.none, action(WM_CONTEXTMENU, true, false));
    // Mouse moves and button downs are not clicks.
    try testing.expectEqual(Action.none, action(0x0200, true, true));
}

test "an icon's pixels lose their premultiplication" {
    const src = [_]u8{ 64, 32, 0, 128, 10, 20, 30, 0, 255, 255, 255, 255 };
    var dst: [12]u8 = undefined;
    straightAlpha(&dst, &src);
    try testing.expectEqualSlices(u8, &.{ 128, 64, 0, 128, 0, 0, 0, 0, 255, 255, 255, 255 }, &dst);
}
