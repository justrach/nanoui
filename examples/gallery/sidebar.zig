//! The desktop gallery's sidebar: the palette's search, then the pages under
//! three headings. Foundations and Demos are rows; Components is a group per
//! kind of component, each shut until opened (or holding the page shown),
//! easing open over its members.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const catalog = @import("catalog.zig");
const page = @import("page.zig");
const phone = @import("phone.zig");

const zig_mark = @embedFile("zig-mark.svg");

pub const width: f32 = 200;
const ease_s: f32 = 0.18;
const member_h: f32 = 28;
const member_gap: f32 = 2;

/// Which component groups are open, and how far each has eased toward it.
pub const State = struct {
    open: [catalog.group_count]bool = @splat(false),
    openness: [catalog.group_count]f32 = @splat(0),

    /// Opens the group holding page `i`, at once, so a page reached from the
    /// palette or the command line shows where it lives.
    pub fn reveal(s: *State, i: usize) void {
        const comp = catalog.component(i) orelse return;
        const k = @backingInt(comp.group);
        s.open[k] = true;
        s.openness[k] = 1;
    }
};

pub fn view(g: anytype, c: *ui.Context) void {
    const th = c.theme;
    c.title_bar_height = 40;
    ui.column(c, .{
        .width = .{ .px = width },
        .height = .fill,
        .padding = .{ .bottom = 12 },
        .clip = true,
        .background = th.surface.alpha(0.6),
        .border = th.border,
        .border_width = 0,
    });
    defer ui.end(c);
    {
        // The name shares the title bar with macOS's traffic lights, at its
        // right.
        const head = ui.div(c).row().wFull().h(c.title_bar_height).px(14).itemsCenter();
        defer head.end();
        ui.spacer(c);
        ui.text(c, "nanoui", .{ .size = 18, .weight = .bold });
    }
    {
        // The rules run edge to edge, so the rest carries the side padding.
        const pad = ui.div(c).wFull().h(page.head_h - c.title_bar_height).px(12);
        defer pad.end();
        const trigger = ui.div(c).row().wFull().h(30).px(10).gap(6).itemsCenter().rounded(7).bg(th.background.alpha(0.65)).border(th.border).hover(th.surface_hover).control();
        defer trigger.end();
        if (trigger.clicked()) g.palette.toggle(c);
        ui.icon(c, "magnifyingglass", .{ .size = 13, .frame = 16, .color = th.muted });
        ui.text(c, "Search…", .{ .size = 12.5, .color = th.muted });
        ui.spacer(c);
        kit.kbdWith(c, ui.keys.label("⌘K"), .{ .size = .sm });
    }
    ui.divider(c);
    {
        const nav = ui.div(c).column().wFull().grow().px(12).gap(2).scrollY().scrollEdgeFade(12).scrollBarIdle(3.0);
        defer nav.end();
        heading(c, "Foundations");
        for ([_]struct { usize, []const u8, []const u8 }{
            .{ catalog.colors, "Colors", "circle.lefthalf.filled" },
            .{ catalog.typography, "Typography", "textformat" },
            .{ catalog.icons, "Icons", "square.grid.3x3" },
        }) |f| if (row(c, f[0], f[2], f[1], if (f[0] == catalog.icons) c.print("{d}", .{ui.icons.all.len}) else null, g.page == f[0])) {
            g.page = f[0];
        };
        heading(c, "Components");
        for (std.enums.values(catalog.Group)) |which| group(g, c, which);
        heading(c, "Demos");
        for (phone.pages, 0..) |p, i| {
            if (i == catalog.typography or i == catalog.kit_demo) continue;
            if (row(c, i, p[1], p[0], phone.badge(g, i), g.page == i)) g.page = i;
        }
    }
    ui.divider(c);
    {
        const foot = ui.div(c).column().wFull().px(14).pt(8).gap(2);
        defer foot.end();
        {
            const r = ui.div(c).row().wFull().itemsCenter();
            defer r.end();
            ui.label(c, c.print("{d} frames", .{c.frame}));
            ui.spacer(c);
            ui.label(c, c.print("{d:.0} fps", .{g.fps}));
        }
        {
            const r = ui.div(c).row().wFull().gap(5).itemsCenter();
            defer r.end();
            _ = ui.svg(c, .{ .key = "zig-mark", .bytes = zig_mark, .width = 14, .height = 12.8 });
            ui.label(c, "Zig 0.17");
            ui.spacer(c);
            ui.label(c, c.renderer);
        }
    }
}

fn heading(c: *ui.Context, title: []const u8) void {
    const h = ui.div(c).wFull().px(10).pt(14).pb(4);
    defer h.end();
    var buf: [24]u8 = undefined;
    ui.text(c, std.ascii.upperString(buf[0..title.len], title), .{ .size = 10.5, .weight = .semibold, .color = c.theme.muted });
}

/// A page's row: its icon, its name and a count; true when clicked.
fn row(c: *ui.Context, i: usize, icon: []const u8, label: []const u8, count: ?[]const u8, selected: bool) bool {
    const th = c.theme;
    ui.key(c, c.print("page-{d}", .{i}));
    var item = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(7);
    item = if (selected) item.bg(th.accent) else item.hover(th.surface_hover);
    defer item.end();
    const fg = if (selected) th.accent_text else th.text;
    ui.icon(c, icon, .{ .size = 14, .frame = 18, .color = fg });
    ui.text(c, label, .{ .weight = .medium, .color = fg });
    if (count) |n| {
        ui.spacer(c);
        pill(c, n, selected);
    }
    return item.clicked();
}

fn pill(c: *ui.Context, n: []const u8, selected: bool) void {
    const th = c.theme;
    const bg = if (selected) th.accent_text.alpha(0.22) else th.text.alpha(0.07);
    const fg = if (selected) th.accent_text else th.muted;
    const p = ui.div(c).px(7).h(18).roundedFull().bg(bg).itemsCenter().justifyCenter();
    defer p.end();
    ui.text(c, n, .{ .size = 11, .weight = .semibold, .color = fg, .tabular = true });
}

/// A group: its row (a chevron, its name, how many it holds), then, open,
/// its members, revealed from the top as it eases open.
fn group(g: anytype, c: *ui.Context, which: catalog.Group) void {
    const th = c.theme;
    const k = @backingInt(which);
    const s = &g.sidebar;
    var buf: [catalog.components.len]usize = undefined;
    const pages = catalog.members(which, &buf);
    const holds_page = for (pages) |p| {
        if (p == g.page) break true;
    } else false;
    {
        ui.key(c, c.print("group-{s}", .{which.title()}));
        const item = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(7).hover(th.surface_hover).control();
        defer item.end();
        if (item.clicked()) s.open[k] = !s.open[k];
        ui.icon(c, if (s.open[k]) "chevron.down" else "chevron.right", .{ .size = 10, .frame = 10, .color = th.muted });
        ui.icon(c, which.icon(), .{ .size = 14, .frame = 18, .color = if (holds_page and !s.open[k]) th.accent else th.text });
        ui.text(c, which.title(), .{ .weight = .medium });
        ui.spacer(c);
        pill(c, c.print("{d}", .{pages.len}), false);
    }
    // Ease toward open or shut, asking for frames until it lands.
    const t = &s.openness[k];
    const target: f32 = if (s.open[k]) 1 else 0;
    if (t.* != target) {
        const step = @min(c.dt, 0.05) / ease_s;
        t.* = if (t.* < target) @min(target, t.* + step) else @max(target, t.* - step);
        c.animationFrame();
    }
    if (t.* == 0) return;
    const nf: f32 = @floatFromInt(pages.len);
    const full = nf * member_h + (nf - 1) * member_gap;
    const eased = t.* * t.* * (3 - 2 * t.*);
    _ = c.open(.{ .direction = .column, .width = .fill, .height = .{ .px = @round(full * eased) }, .clip = true, .opacity = eased }, c.print("reveal-{d}", .{k}));
    defer c.end();
    _ = c.open(.{ .direction = .column, .width = .fill, .gap = member_gap, .padding = .{ .left = 24 } }, c.print("members-{d}", .{k}));
    defer c.end();
    for (pages) |p| {
        const comp = catalog.component(p).?;
        const on = g.page == p;
        ui.key(c, comp.id);
        var item = ui.div(c).row().wFull().h(member_h).px(10).itemsCenter().rounded(6);
        item = if (on) item.bg(th.accent) else item.hover(th.surface_hover);
        defer item.end();
        if (item.clicked()) g.page = p;
        ui.text(c, comp.name, .{ .size = 13, .color = if (on) th.accent_text else th.text });
    }
}
