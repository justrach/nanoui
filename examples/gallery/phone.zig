//! The gallery on a phone, or in any narrow window: its pages as a list, as
//! iOS's Settings lists its own, each pushed in from the right with a back
//! button to return.
//!
//! Quiet on purpose: an off-white canvas (near-black in the dark), 24-point
//! gutters, roomy rows and no dividers, three type sizes (27, 16, 14) in
//! two weights, glass for the search field and the buttons, pills for the
//! chips, and the accent (never red) for counts. Every target is at least
//! 44 points; corners nest (a tile's radius is its row's less the padding).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;

/// The pages' names and icons, in the sidebar's order; each one's tile color here.
pub const pages = [_][2][]const u8{
    .{ "Controls", "slider.horizontal.3" },
    .{ "Tasks", "checklist" },
    .{ "Typography", "textformat" },
    .{ "List", "list.bullet" },
    .{ "Glass", "sparkles" },
    .{ "Motion", "wand.and.stars" },
    .{ "Kit", "square.grid.2x2" },
};
const tiles = [pages.len]u24{ 0x0a84ff, 0x30d158, 0xff9f0a, 0x5e5ce6, 0x64d2ff, 0xff375f, 0xbf5af2 };
/// A line under each page's name.
const blurbs = [pages.len][]const u8{
    "Buttons, toggles, sliders, fields",
    "A to-do list with checkboxes",
    "System text, weights, wrapping",
    "10 000 rows, filtered live",
    "Liquid Glass bars, tabs, toasts",
    "Springs, staggers, shared elements",
    "Every nanoui.kit component",
};
/// The chips, and which of them each page is under.
const chips = [_][]const u8{ "All", "Widgets", "Effects", "Text" };
const chip_of = [pages.len]usize{ 1, 1, 3, 1, 2, 2, 1 };

/// The phone's spacing and motion.
const gutter = 24;
const row_radius = 22;
const row_pad = 12;
const push: motion.Spring = .{ .stiffness = 320, .damping = 34 };

/// Narrow enough for the phone's layout.
pub fn compact(c: *ui.Context) bool {
    return c.size.w < 600;
}

/// The page's canvas: the theme's off-white (near-black in the dark), with
/// no cards on it; the same as the window's, under the status bar too.
fn canvas(th: ui.Theme) ui.Color {
    return th.background;
}

pub fn view(g: anytype, c: *ui.Context) void {
    const th = c.theme;
    const w = c.size.w;
    const root = ui.div(c).sizeFull().clip().bg(canvas(th));
    defer root.end();
    {
        // The list slides back a little under the page pushed over it.
        const f = motion.frame(c, .{
            .target = .{ .x = if (g.open) -w * 0.28 else 0, .opacity = if (g.open) 0.5 else 1 },
            .transition = .{ .spring = push },
        });
        const under = ui.div(c).sizeFull().motion(f);
        defer under.end();
        home(g, c);
    }
    if (motion.present(c, "pushed", g.open, .{
        .initial = .{ .x = w },
        .exit = .{ .x = w },
        .transition = .{ .spring = push },
    })) |f| {
        const screen = ui.div(c).absolute().offset(0, 0).w(w).h(c.size.h).column().clip().bg(canvas(th))
            .shadow(.{ .color = .{ .a = if (th.dark) 0.5 else 0.12 }, .blur = 24, .x = -4 }).motion(f);
        defer screen.end();
        {
            const bar = ui.div(c).row().wFull().px(gutter - 8).pt(8).gap(8).itemsCenter();
            defer bar.end();
            if (glassButton(c, "chevron.right", std.math.pi)) g.open = false;
        }
        // A row, so the page's own grow() takes the width.
        const body = ui.div(c).row().wFull().grow();
        defer body.end();
        g.content(c);
    }
    // Escape (Android's Back) returns too, once the page didn't take it
    // and no field has the focus (it lets go of that first).
    if (g.open and c.focused_text == null and c.shortcut(.{ .key = ui.Shortcut.escape })) g.open = false;
}

/// A round glass button with a 44-point target; true when tapped.
fn glassButton(c: *ui.Context, icon: []const u8, rotation: f32) bool {
    const f = motion.frame(c, .{ .press = .{ .scale = 0.9 }, .transition = .{ .spring = motion.Spring.bouncy } });
    const b = ui.div(c).w(44).h(44).roundedFull().glass(.{}).itemsCenter().justifyCenter().control().motion(f);
    defer b.end();
    ui.icon(c, icon, .{ .size = 16, .frame = 20, .weight = .semibold, .color = c.theme.text, .rotation = rotation });
    return b.clicked();
}

fn home(g: anytype, c: *ui.Context) void {
    const th = c.theme;
    const sc = ui.div(c).column().sizeFull().scrollY().pt(16).pb(gutter);
    defer sc.end();
    {
        const head = ui.div(c).column().wFull().px(gutter).gap(4);
        defer head.end();
        {
            const r = ui.div(c).row().wFull().itemsCenter();
            defer r.end();
            ui.text(c, "nanoui", .{ .size = 27, .weight = .semibold });
            ui.spacer(c);
            // + starts a task: the Tasks page, its field ready.
            if (glassButton(c, "plus", 0)) {
                g.page = 1;
                g.open = true;
            }
        }
        ui.text(c, c.print("Zig 0.17 · {s} · {d} frames", .{ c.renderer, c.frame }), .{ .size = 14, .color = th.muted, .tabular = true });
    }
    {
        // Search, on glass.
        const pad = ui.div(c).wFull().px(gutter).pt(20);
        defer pad.end();
        const s = ui.div(c).row().wFull().h(44).px(16).gap(10).itemsCenter().roundedFull().glass(.{});
        defer s.end();
        ui.icon(c, "magnifyingglass", .{ .size = 16, .weight = .semibold, .color = th.muted });
        _ = ui.textField(c, &g.search, .{ .placeholder = "Search pages", .bare = true, .width = .fill, .size = 16 });
    }
    chipRow(g, c);
    const q = g.search.text();
    var shown: usize = 0;
    const list = ui.div(c).column().wFull().px(gutter - row_pad).gap(2);
    defer list.end();
    for (pages, 0..) |p, i| {
        if (g.chip != 0 and chip_of[i] != g.chip) continue;
        if (q.len > 0 and std.ascii.findIgnoreCase(p[0], q) == null) continue;
        // Each chip's rows come in one after another.
        ui.key(c, c.print("row-{d}-{d}", .{ g.chip, i }));
        const f = motion.frame(c, .{
            .initial = .{ .y = 18, .opacity = 0 },
            .press = .{ .scale = 0.98 },
            .delay = motion.stagger(shown, 0.045),
            .transition = .{ .spring = motion.Spring.snappy },
        });
        shown += 1;
        const row = ui.div(c).row().wFull().h(76).p(row_pad).gap(14).itemsCenter().rounded(row_radius)
            .hover(th.text.alpha(0.05)).control().motion(f);
        defer row.end();
        if (row.clicked()) {
            g.page = i;
            g.open = true;
        }
        {
            const tile = ui.div(c).w(52).h(52).rounded(row_radius - row_pad).bg(.hex(tiles[i])).itemsCenter().justifyCenter();
            defer tile.end();
            ui.icon(c, p[1], .{ .size = 22, .weight = .semibold, .color = .white });
        }
        {
            const words = ui.div(c).column().grow().gap(2);
            defer words.end();
            ui.text(c, p[0], .{ .size = 16, .weight = .semibold });
            ui.text(c, blurbs[i], .{ .size = 14, .color = th.muted, .truncate = .ellipsis });
        }
        if (badge(g, i)) |n| {
            const b = ui.div(c).px(10).h(24).roundedFull().bg(th.accent.alpha(0.14)).itemsCenter().justifyCenter();
            defer b.end();
            ui.text(c, n, .{ .size = 14, .weight = .semibold, .color = th.accent, .tabular = true });
        }
        ui.icon(c, "chevron.right", .{ .size = 14, .weight = .semibold, .color = th.muted.alpha(0.6) });
    }
    if (shown == 0) {
        const none = ui.div(c).px(gutter).pt(24);
        defer none.end();
        ui.text(c, "No page matches.", .{ .size = 14, .color = th.muted });
    }
}

/// A count beside a page, in the accent: tasks left, rows, the new page.
fn badge(g: anytype, i: usize) ?[]const u8 {
    const S = struct {
        var buf: [8]u8 = undefined;
    };
    return switch (i) {
        1 => blk: {
            var left: usize = 0;
            for (g.items[0..g.count]) |it| left += @intFromBool(!it.done);
            break :blk std.fmt.bufPrint(&S.buf, "{d}", .{left}) catch null;
        },
        3 => "10k",
        else => null,
    };
}

/// Pill chips: the chosen one fills with the text's color, the rest a
/// light gray; the fill and the label ease over as the choice moves.
fn chipRow(g: anytype, c: *ui.Context) void {
    const th = c.theme;
    const r = ui.div(c).row().px(gutter).pt(12).pb(8).gap(8).itemsCenter();
    defer r.end();
    for (chips, 0..) |name, i| {
        const on = g.chip == i;
        // 36 points tall, inside a 44-point target.
        const give = motion.frame(c, .{ .press = .{ .scale = 0.94 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const hit = ui.div(c).h(44).itemsCenter().control().motion(give);
        defer hit.end();
        if (hit.clicked()) g.chip = i;
        const f = motion.frame(c, .{
            .target = .{ .background = if (on) th.text else th.text.alpha(if (th.dark) 0.1 else 0.06) },
            .transition = .{ .spring = motion.Spring.snappy },
        });
        const chip = ui.div(c).h(36).px(16).roundedFull().itemsCenter().justifyCenter().motion(f);
        defer chip.end();
        ui.text(c, name, .{ .size = 14, .weight = .semibold, .color = if (on) canvas(th) else th.muted });
    }
}
