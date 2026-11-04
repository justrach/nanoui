//! ⌘K: the open tabs, narrowed by what is typed; Return goes to the first.
const std = @import("std");
const text_search = @import("../text_search.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const address = @import("address.zig");
const m = theme.metrics;

pub const Row = struct { title: []const u8, url: []const u8 };

/// Whether a tab stays listed for what was typed.
pub fn matches(row: Row, typed: []const u8) bool {
    if (typed.len == 0) return true;
    return text_search.find(row.title, 0, typed) != null or text_search.find(row.url, 0, typed) != null;
}

pub const Switcher = struct {
    showing: bool = false,
    field: ui.TextBuffer = .{},
    wants_focus: bool = false,
    picked: usize = 0,

    pub fn open(s: *Switcher) void {
        s.showing = true;
        s.wants_focus = true;
        s.picked = 0;
        s.field.clear();
    }

    /// The tab chosen, if one was this frame; closes itself then.
    pub fn view(s: *Switcher, c: *ui.Context, x: f32, y: f32, w: f32, h: f32, rows: []const Row) ?usize {
        const p = theme.of(c);
        var chosen: ?usize = null;
        const scrim = c.open(.{
            .absolute = true,
            .fixed = true,
            .offset = .{ .x = x, .y = y },
            .width = .{ .px = w },
            .height = .{ .px = h },
            .background = p.ground.alpha(0.74),
            .layer = 3,
        }, "switcher");
        defer c.end();
        if (c.interact(scrim, .{}).clicked) s.showing = false;
        const pane_w = @min(m.field_width, w - 48);
        _ = c.open(.{
            .absolute = true,
            .offset = .{ .x = (w - pane_w) / 2, .y = @max(16, h / 2 - 180) },
            .width = .{ .px = pane_w },
            .padding = .all(6),
            .gap = 2,
            .radius = m.field_radius,
            .background = p.ground,
            .border = p.hairline,
            .shadow = .{ .color = .{ .a = 0.08 }, .blur = 24, .y = 8 },
        }, "pane");
        defer c.end();
        _ = c.open(.{ .width = .fill, .padding = .xy(16, 10), .direction = .row }, "head");
        if (s.wants_focus) {
            c.focus = c.peekId("query");
            s.wants_focus = false;
        }
        ui.key(c, "query");
        const r = ui.textField(c, &s.field, .{ .placeholder = "Find a tab", .width = .fill, .size = 15, .bare = true, .color = p.ink, .placeholder_color = p.muted });
        c.end();
        if (r.changed) s.picked = 0;
        var seen: usize = 0;
        var first: ?usize = null;
        var picked_tab: ?usize = null;
        for (rows, 0..) |row, i| {
            if (!matches(row, s.field.text())) continue;
            if (first == null) first = i;
            if (seen == s.picked) picked_tab = i;
            c.next_key_int = i;
            const it = ui.pressable(c, .{ .direction = .row, .width = .fill, .padding = .xy(14, 8), .gap = 10, .radius = 9, .align_items = .center, .control = true, .background = if (seen == s.picked) p.wash else null }, p.hover);
            defer c.end();
            if (it.clicked) chosen = i;
            _ = c.leaf(.{ .grow = 1, .clip = true }, .{ .text = .{ .str = row.title, .style = .{ .size = 13, .truncate = .fade }, .color = p.ink } }, null);
            _ = c.leaf(.{ .clip = true, .max_width = 180 }, .{ .text = .{ .str = address.hostOf(row.url), .style = .{ .size = 12, .truncate = .fade }, .color = p.muted } }, null);
            seen += 1;
        }
        if (r.focused) {
            if (c.shortcut(.{ .key = ui.Shortcut.down }) and s.picked + 1 < seen) s.picked += 1;
            if (c.shortcut(.{ .key = ui.Shortcut.up })) s.picked -|= 1;
        }
        if (r.submitted) chosen = picked_tab orelse first;
        if (chosen != null) s.showing = false;
        return chosen;
    }
};

test "tabs stay listed by title or address" {
    const row: Row = .{ .title = "Bird - Wikipedia", .url = "https://en.wikipedia.org/wiki/Bird" };
    try std.testing.expect(matches(row, ""));
    try std.testing.expect(matches(row, "BIRD"));
    try std.testing.expect(matches(row, "wikipedia.org"));
    try std.testing.expect(!matches(row, "fish"));
}
