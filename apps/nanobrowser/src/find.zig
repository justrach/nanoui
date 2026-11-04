//! ⌘F: the display list's text searched without regard to case, every match
//! marked, the current one in the accent's color and scrolled to.
const std = @import("std");
const text_search = @import("text_search.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const box = @import("layout/box.zig");
const display = @import("paint/display.zig");
const replay = @import("paint/replay.zig");
const view = @import("page_view.zig");
const Page = @import("page.zig").Page;

pub const Find = struct {
    query: std.ArrayList(u8) = .empty,
    /// Which match is the current one.
    at: usize = 0,
    count: usize = 0,
};

pub fn matchesIn(text: []const u8, query: []const u8, out: []usize) usize {
    if (query.len == 0) return 0;
    var n: usize = 0;
    var from: usize = 0;
    while (n < out.len) {
        const i = text_search.find(text, from, query) orelse break;
        out[n] = i;
        n += 1;
        from = i + query.len;
    }
    return n;
}

fn jump(p: *Page) void {
    const l = if (p.list) |*x| x else return;
    const f = &p.find;
    var buf: [64]usize = undefined;
    var seen: usize = 0;
    for (l.items) |*it| {
        if (it.kind != .text or it.clip != 1) continue;
        const n = matchesIn(it.kind.text.str, f.query.items, &buf);
        if (f.at < seen + n) {
            view.scrollPageTo(p, it.rect.y - p.viewport_h / 3);
            return;
        }
        seen += n;
    }
}

fn recount(p: *Page) void {
    const l = if (p.list) |*x| x else return;
    var buf: [64]usize = undefined;
    var total: usize = 0;
    for (l.items) |*it| if (it.kind == .text) {
        total += matchesIn(it.kind.text.str, p.find.query.items, &buf);
    };
    p.find.count = total;
    if (p.find.at >= total) p.find.at = 0;
}

pub fn set(p: *Page, query: []const u8) void {
    p.find.query.clearRetainingCapacity();
    p.find.query.appendSlice(p.gpa, query) catch return;
    p.find.at = 0;
    recount(p);
    jump(p);
    p.redraw();
}

pub fn step(p: *Page, by: i32) void {
    const n = p.find.count;
    if (n == 0) return;
    const next = @mod(@as(i64, @intCast(p.find.at)) + by, @as(i64, @intCast(n)));
    p.find.at = @intCast(next);
    jump(p);
    p.redraw();
}

pub fn stop(p: *Page) void {
    p.find.query.clearRetainingCapacity();
    p.find.count = 0;
    p.redraw();
}

/// Marks what shows.
pub fn draw(p: *Page, c: *ui.Context, l: *const display.List, rect: box.Rect) void {
    const q = p.find.query.items;
    if (q.len == 0) return;
    var buf: [64]usize = undefined;
    var seen: usize = 0;
    for (l.items) |*it| {
        if (it.kind != .text) continue;
        const t = it.kind.text;
        const n = matchesIn(t.str, q, &buf);
        defer seen += n;
        if (n == 0) continue;
        const r = l.placed(it);
        if (r.y + r.h < rect.y or r.y > rect.y + rect.h) continue;
        const st = replay.textStyle(t.font);
        for (buf[0..n], seen..) |at, index| {
            const x0 = c.text.width(t.str[0..at], st);
            const w = c.text.width(t.str[at .. at + q.len], st);
            const here = index == p.find.at;
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = r.x + x0 - rect.x - 1, .y = r.y - rect.y },
                .width = .{ .px = w + 2 },
                .height = .{ .px = r.h },
                .radius = 2,
                .background = if (here) ui.Color.hex(0xffa500).alpha(0.55) else ui.Color.hex(0xffe066).alpha(0.45),
            }, .none, null);
        }
    }
}

test "matches ignore case and don't overlap" {
    var buf: [8]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), matchesIn("Bird, bird", "BIRD", &buf));
    try std.testing.expectEqual(@as(usize, 6), buf[1]);
    try std.testing.expectEqual(@as(usize, 2), matchesIn("aaaa", "aa", &buf));
    try std.testing.expectEqual(@as(usize, 0), matchesIn("x", "", &buf));
}
