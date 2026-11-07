//! The row across the top: the traffic lights, the tabs, a plus, and at the far
//! end back, forward and reload. Tabs keep a fixed width so the cross always
//! lands in the same place; with too many they narrow, then show only their mark.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const m = theme.metrics;
const Tab = @import("tab.zig").Tab;

pub const Action = union(enum) {
    none,
    select: usize,
    close: usize,
    new_tab,
    back,
    forward,
    reload,
    /// A double click on the tab's title or on the row: the address field.
    address,
};

fn tabSpan(room: f32, n: usize) f32 {
    const count: f32 = @floatFromInt(@max(n, 1));
    const each = (room - (count - 1) * m.tab_gap) / count;
    return std.math.clamp(each, m.tab_min, m.tab_width);
}

/// Draws the strip across the window's width.
pub fn view(c: *ui.Context, tabs: []const *Tab, current: usize) Action {
    const p = theme.of(c);
    var action: Action = .none;
    const room = c.size.w - m.lights - m.plus - m.helm - 24;
    const span = tabSpan(room, tabs.len);
    _ = c.open(.{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = m.strip },
        .padding = .{ .left = m.lights, .right = 12 },
        .gap = m.tab_gap,
        .align_items = .center,
        .background = p.ground,
        .window_drag = true,
    }, "strip");
    defer c.end();
    c.title_bar_height = m.strip;
    if (c.interact(c.stack.items[c.stack.items.len - 1], .{}).double_clicked) action = .address;
    for (tabs, 0..) |t, i| {
        c.next_key_int = @intFromPtr(t);
        const a = tab(c, t, i == current, span);
        if (a == .select) action = .{ .select = i };
        if (a == .close) action = .{ .close = i };
    }
    if (square(c, "plus", 10, false, "New Tab")) action = .new_tab;
    ui.spacer(c);
    const live = if (current < tabs.len) tabs[current] else null;
    if (square(c, "chevron.left", 13, live == null or !live.?.canGoBack(), "Back")) action = .back;
    if (square(c, "chevron.right", 13, live == null or !live.?.canGoForward(), "Forward")) action = .forward;
    if (square(c, if (live != null and live.?.loading()) "xmark" else "arrow.clockwise", 12, live == null or live.?.isEmpty(), "Reload")) action = .reload;
    return action;
}

const TabAction = enum { none, select, close };

fn tab(c: *ui.Context, t: *Tab, live: bool, span: f32) TabAction {
    const p = theme.of(c);
    var result: TabAction = .none;
    const i = c.open(.{
        .direction = .row,
        .width = .{ .px = span },
        .height = .{ .px = 28 },
        .padding = .{ .left = if (span < m.tab_titled) 0 else 11, .right = if (span < m.tab_titled) 0 else 7 },
        .gap = 7,
        .radius = m.tab_radius,
        .align_items = .center,
        .justify = if (span < m.tab_titled) .center else .start,
        .control = true,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
    const n = c.node(i);
    n.style.background = if (live) p.wash else p.hover.alpha(hover);
    if (it.clicked) result = .select;
    if (t.loading()) {
        ui.icon(c, "circle.dotted", .{ .size = 13, .frame = 16, .color = p.muted });
    } else if (t.page) |page| {
        if (page.favicon()) |bytes| {
            if (!ui.image(c, .{ .key = page.faviconKey(), .bytes = bytes, .box = .{ .w = 16, .h = 16 }, .radius = 3 }))
                ui.icon(c, "globe", .{ .size = 13, .frame = 16, .color = p.muted });
        } else ui.icon(c, "globe", .{ .size = 13, .frame = 16, .color = p.muted });
    } else ui.icon(c, "globe", .{ .size = 13, .frame = 16, .color = p.muted });
    if (span >= m.tab_titled) {
        _ = c.leaf(.{ .grow = 1, .clip = true }, .{ .text = .{
            .str = t.title(),
            .style = .{ .size = 12.5, .weight = if (live) .medium else .regular, .truncate = .fade, .fade_width = 16 },
            .color = if (live) p.ink else p.muted,
        } }, null);
        const show = it.hovered or live;
        if (show) {
            const x = ui.pressable(c, .{ .width = .{ .px = 15 }, .height = .{ .px = 15 }, .radius = 4, .align_items = .center, .justify = .center }, p.faint.alpha(0.5));
            defer c.end();
            ui.icon(c, "xmark", .{ .size = 8, .weight = .semibold, .color = p.muted });
            if (x.clicked) result = .close;
        }
    }
    return result;
}

/// A small door in the row: an icon on a square that lights under the pointer.
fn square(c: *ui.Context, icon: []const u8, size: f32, off: bool, _: []const u8) bool {
    const p = theme.of(c);
    const i = c.open(.{
        .width = .{ .px = 26 },
        .height = .{ .px = 26 },
        .radius = m.tab_radius,
        .align_items = .center,
        .justify = .center,
        .control = true,
        .opacity = if (off) 0.4 else 1,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const hover = c.animate(it.id, 0, if (it.hovered and !off) 1 else 0, 20);
    c.node(i).style.background = p.hover.alpha(hover);
    ui.icon(c, icon, .{ .size = size, .weight = .medium, .color = p.muted });
    if (it.clicked and !off) {
        c.changed = true;
        return true;
    }
    return false;
}

test "tabs narrow to fit, then stop" {
    try std.testing.expectEqual(m.tab_width, tabSpan(1000, 2));
    try std.testing.expectApproxEqAbs(@as(f32, 98.2), tabSpan(1000, 10), 0.01);
    try std.testing.expectEqual(m.tab_min, tabSpan(1000, 100));
}
