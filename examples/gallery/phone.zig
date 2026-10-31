//! The gallery on a phone, or in any narrow window: its pages as a list, as
//! iOS's Settings lists its own, each pushed in from the right with a back
//! button to return.
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
    .{ "Kit", "square.stack.3d.up" },
    .{ "Windows", "macwindow" },
};
const tiles = [pages.len]u24{ 0x0a84ff, 0x30d158, 0xff9f0a, 0x5e5ce6, 0x64d2ff, 0xff375f, 0xbf5af2, 0x8e8e93 };

/// Narrow enough for the phone's layout.
pub fn compact(c: *ui.Context) bool {
    return c.size.w < 600;
}

pub fn view(g: anytype, c: *ui.Context) void {
    if (!g.open) return home(g, c);
    // A new page slides in each time one is opened.
    ui.key(c, c.print("pushed-{d}", .{g.page}));
    const f = motion.frame(c, .{
        .initial = .{ .x = c.size.w * 0.6, .opacity = 0 },
        .transition = .{ .spring = motion.Spring.snappy },
    });
    const screen = ui.div(c).column().sizeFull().clip().motion(f);
    defer screen.end();
    const th = c.theme;
    const back = ui.div(c).row().px(10).py(8).gap(4).itemsCenter().rounded(8).hover(th.surface_hover);
    if (back.clicked()) g.open = false;
    ui.icon(c, "chevron.left", .{ .size = 16, .color = th.accent });
    ui.text(c, "nanoui", .{ .size = 17, .color = th.accent });
    back.end();
    g.content(c);
    // Escape (Android's Back) returns too, once the page didn't take it
    // and no field has the focus (it lets go of that first).
    if (c.focused_text == null and c.shortcut(.{ .key = ui.Shortcut.escape })) g.open = false;
}

fn home(g: anytype, c: *ui.Context) void {
    const th = c.theme;
    ui.scroll(c, .{ .width = .fill, .height = .fill, .padding = .{ .top = 20, .left = 16, .right = 16, .bottom = 16 }, .gap = 6 });
    defer ui.end(c);
    ui.text(c, "nanoui", .{ .size = 34, .weight = .bold });
    ui.label(c, c.print("Zig 0.17 · {s} · {d} frames", .{ c.renderer, c.frame }));
    _ = c.leaf(.{ .height = .{ .px = 14 } }, .none, null);
    ui.card(c, .{ .width = .fill, .padding = .xy(0, 4), .gap = 0 });
    defer ui.end(c);
    for (pages, 0..) |p, i| {
        if (i > 0) ui.divider(c);
        const row = ui.div(c).row().wFull().px(14).py(10).gap(12).itemsCenter().hover(th.surface_hover);
        defer row.end();
        if (row.clicked()) {
            g.page = i;
            g.open = true;
        }
        {
            const tile = ui.div(c).w(30).h(30).rounded(8).bg(.hex(tiles[i])).itemsCenter().justifyCenter();
            defer tile.end();
            ui.icon(c, p[1], .{ .size = 15, .color = .hex(0xffffff) });
        }
        ui.text(c, p[0], .{ .size = 17 });
        ui.spacer(c);
        ui.icon(c, "chevron.right", .{ .size = 13, .color = th.muted });
    }
}
