//! The gallery's Glass page: Liquid Glass with motion. A toolbar of glass
//! springs in over cards that scroll under it and stagger in; glass tabs
//! whose tinted lens slides; glass buttons that give when pressed and
//! bounce back; a glass menu and glass toasts; and a pane of clear glass
//! floating over it all, plus a sidebar reflecting the adjacent cards.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

pub const Demo = struct {
    taps: u32 = 0,
    tab: usize = 0,
    menu: bool = false,
    menu_at: ?ui.Rect = null,
    pinned_open: bool = true,
    folders_open: bool = true,
    selected: []const u8 = "2026 Trips",
    toaster: kit.Toaster = undefined,
    ready: bool = false,

    pub fn view(d: *Demo, c: *ui.Context) void {
        if (!d.ready) {
            d.toaster = .{ .gpa = std.heap.page_allocator, .glass = true, .corner = .bottom_right };
            d.ready = true;
        }
        const th = c.theme;
        // The page's width: beside the sidebar, or all of a phone's.
        const compact = @import("phone.zig").compact(c);
        const w = if (compact) c.size.w else c.size.w - 200;
        const page = ui.div(c).grow().hFull().clip();
        defer page.end();
        {
            const content = ui.div(c).column().sizeFull().scrollY().px(28).pt(96).pb(28).gap(14);
            defer content.end();
            const hues = [_]u24{ 0xe8453c, 0xf2a93b, 0x3fae5a, 0x2f6fd0, 0x8e44ad, 0x16a3a3 };
            const labels = [_][]const u8{ "Photos", "Albums", "Search" };
            for (0..18) |i| {
                ui.key(c, c.print("card-{d}-{d}", .{ d.tab, i }));
                // Each tab's cards come in one after another.
                const f = motion.frame(c, .{ .initial = .{ .y = 24, .opacity = 0, .scale = 0.97 }, .delay = motion.stagger(@min(i, 8), 0.04), .transition = .{ .spring = .{} } });
                const card = ui.div(c).row().wFull().h(64).px(if (compact) 18 else 210).gap(12).itemsCenter().rounded(16).bg(.hex(hues[(i + d.tab * 2) % hues.len])).motion(f);
                defer card.end();
                ui.icon(c, "photo", .{ .size = 18, .color = .white });
                ui.textf(c, .{ .size = 15, .weight = .semibold, .color = .white }, "{s} under the glass · {d}", .{ labels[d.tab], i + 1 });
            }
        }
        if (!compact) {
            // Cards were painted first and extend beneath this pane. Their
            // scrolling drives the live backdrop and its right-edge reflection.
            const side_top: f32 = if (c.size.h < 360) 92 else 104;
            const side_h: f32 = @max(80, c.size.h - side_top - 16);
            const sidebar = ui.div(c).absolute().offset(20, side_top).w(196).h(side_h).column().px(12).py(12).gap(8).rounded(20).clip().glass(.{ .style = .sidebar, .tint = th.surface.alpha(0.75) });
            defer sidebar.end();
            {
                const head = ui.div(c).row().wFull().px(6).itemsCenter();
                defer head.end();
                ui.text(c, "WORKSPACE", .{ .size = 10, .weight = .semibold, .color = th.muted });
                ui.spacer(c);
                const badge = ui.div(c).px(6).py(2).rounded(6).bg(th.text.alpha(0.08));
                ui.text(c, "11", .{ .size = 10, .weight = .semibold, .color = th.muted, .tabular = true });
                badge.end();
            }
            {
                const list = ui.div(c).column().wFull().grow().scrollY().scrollEdgeFade(14).scrollBarIdle(3.0);
                defer list.end();
                if (sectionHeader(c, "Pinned", d.pinned_open)) d.pinned_open = !d.pinned_open;
                if (d.pinned_open) {
                    if (sidebarRow(c, "star.fill", "Favorites", false, false)) d.selected = "Favorites";
                    {
                        const branch = ui.div(c).row().wFull().gap(8).pl(10);
                        defer branch.end();
                        _ = c.leaf(.{ .width = .{ .px = 1.5 }, .height = .fill, .background = th.border.alpha(0.75) }, .none, null);
                        const kids = ui.div(c).column().grow().gap(2);
                        defer kids.end();
                        for ([_]struct { []const u8, []const u8 }{ .{ "photo", "2026 Trips" }, .{ "sparkles", "Design" } }) |item| {
                            ui.key(c, item[1]);
                            if (sidebarRow(c, item[0], item[1], std.mem.eql(u8, d.selected, item[1]), true)) d.selected = item[1];
                        }
                    }
                    if (sidebarRow(c, "bookmark", "Shared", false, false)) d.selected = "Shared";
                    {
                        const branch = ui.div(c).row().wFull().gap(8).pl(10);
                        defer branch.end();
                        _ = c.leaf(.{ .width = .{ .px = 1.5 }, .height = .fill, .background = th.border.alpha(0.75) }, .none, null);
                        const kids = ui.div(c).column().grow().gap(2);
                        defer kids.end();
                        ui.key(c, "Invoices");
                        if (sidebarRow(c, "doc.text", "Invoices", std.mem.eql(u8, d.selected, "Invoices"), true)) d.selected = "Invoices";
                    }
                }
                // Keep a steady gap between sections even when the top one collapses.
                _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
                if (sectionHeader(c, "Folders", d.folders_open)) d.folders_open = !d.folders_open;
                if (d.folders_open) {
                    const folders = [_][]const u8{ "Work", "Personal", "Finances", "Travel", "Receipts", "Archive", "Screenshots", "Imports" };
                    for (folders) |label| {
                        ui.key(c, label);
                        if (sidebarRow(c, "folder", label, std.mem.eql(u8, d.selected, label), false)) d.selected = label;
                    }
                }
            }
            {
                const foot = ui.div(c).row().wFull().px(6).pt(2).itemsCenter();
                defer foot.end();
                ui.text(c, c.print("Selected · {s}", .{d.selected}), .{ .size = 11, .color = th.muted, .truncate = .ellipsis });
            }
        }
        {
            const f = motion.frame(c, .{ .initial = .{ .y = -30, .opacity = 0, .scale = 0.96 }, .transition = .{ .spring = motion.Spring.bouncy } });
            const bar = ui.div(c).absolute().offset(20, 20).w(w - 40).h(60).row().itemsCenter().gap(10).px(10).rounded(30).glass(.{}).motion(f);
            defer bar.end();
            _ = kit.tabs(c, &.{ "Photos", "Albums", "Search" }, &d.tab, .{ .variant = .glass });
            ui.spacer(c);
            if (!compact) ui.label(c, c.print("{d} taps", .{d.taps}));
            const m = kit.iconButton(c, "ellipsis", .{ .glass = true, .pill = true });
            if (m.clicked) d.menu = !d.menu;
            d.menu_at = m.rect;
            if (!compact and kit.button(c, "Tap", .{ .glass = true, .variant = .primary, .pill = true }).clicked) d.taps += 1;
        }
        {
            // A pane of clear glass, floating.
            const float = motion.keyframes(c, .{ .values = &.{ .{ .y = 0 }, .{ .y = -10 }, .{ .y = 0 } }, .duration = 4, .repeat = null });
            const pane = ui.div(c).absolute().offset(w - @as(f32, if (compact) 170 else 180), 150).w(140).h(140).rounded(36).glass(.{ .style = .clear }).itemsCenter().justifyCenter().control().motion(float);
            defer pane.end();
            if (pane.clicked()) d.toaster.push(.{ .status = .info, .title = "Clear glass", .message = "It floats over whatever scrolls under it.", .duration = 3 });
            ui.text(c, "Clear", .{ .size = 15, .weight = .semibold, .color = .white });
        }
        if (kit.menu(c, "glass-menu", &d.menu, d.menu_at, &.{
            .{ .label = "Share", .icon = "square.and.arrow.up" },
            .{ .label = "Favorite", .icon = "heart" },
            .{ .separator = true },
            .{ .label = "Show a toast", .icon = "bell" },
        }, .{ .glass = true, .placement = .bottom_end, .width = 200 })) |i| {
            if (i == 3) d.toaster.push(.{ .status = .success, .title = "On glass", .message = "Toasts can be glass too.", .duration = 3 });
        }
        d.toaster.view(c);
    }
};

fn sectionHeader(c: *ui.Context, title: []const u8, open: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    const hdr = ui.div(c).row().wFull().px(6).py(4).gap(6).itemsCenter().rounded(6).hover(th.surface_hover).control();
    defer hdr.end();
    ui.icon(c, if (open) "chevron.down" else "chevron.right", .{ .size = 10, .frame = 12, .color = th.muted });
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = th.muted });
    return hdr.clicked();
}

fn sidebarRow(c: *ui.Context, icon_name: []const u8, label: []const u8, selected: bool, nested: bool) bool {
    const th = c.theme;
    var r = ui.div(c).row().wFull().px(6).py(@as(f32, if (nested) 4 else 5)).gap(8).itemsCenter().rounded(7).control();
    r = if (selected) r.bg(th.accent.alpha(0.16)) else r.hover(th.surface_hover);
    defer r.end();
    const fg = if (selected) th.accent else th.text;
    ui.icon(c, icon_name, .{ .size = if (nested) 13 else 14, .frame = 16, .color = if (selected) th.accent else th.muted });
    ui.text(c, label, .{ .size = if (nested) 12.5 else 13.5, .weight = if (selected) .semibold else .regular, .color = fg, .truncate = .ellipsis });
    return r.clicked();
}
