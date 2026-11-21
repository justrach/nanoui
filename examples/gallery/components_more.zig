//! The component pages for the timeline, navigation, forms and overlays
//! (`components.zig` has the rest).
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const page = @import("page.zig");
const State = @import("components.zig").State;

pub fn timeline(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Rows, colors and the selected row");
    defer sec.end();
    const th = c.theme;
    const t = kit.tokens(c);
    const commits = [_]struct { sha: []const u8, title: []const u8, meta: []const u8, color: ?ui.Color = null }{
        .{ .sha = "9f4c1a8", .title = "Release v0.3.0", .meta = "main · Ada · 12m ago", .color = t.success },
        .{ .sha = "6e8b210", .title = "feat(ui): masked scroll edge fades", .meta = "Ada · 1h ago", .color = t.info },
        .{ .sha = "3c7d92e", .title = "fix(glass): clip and scroll sidebar", .meta = "Linus · 3h ago" },
        .{ .sha = "a1054f2", .title = "init: nanoui workspace", .meta = "Grace · yesterday" },
    };
    const box = ui.div(c).column().wFull().maxW(560).gap(0);
    defer box.end();
    for (commits, 0..) |e, i| {
        ui.key(c, e.sha);
        var item = kit.timelineItem(c, .{ .height = 58, .first = i == 0, .last = i == commits.len - 1, .selected = s.commit == i, .color = e.color });
        item = item.control().rounded(8).pr(8);
        if (s.commit != i) item = item.hover(th.surface_hover);
        if (item.clicked()) s.commit = i;
        defer item.end();
        const body = ui.div(c).column().grow().gap(3);
        defer body.end();
        {
            const top = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer top.end();
            ui.text(c, e.title, .{ .size = 13.5, .weight = if (s.commit == i) .semibold else .medium, .truncate = .ellipsis });
            ui.spacer(c);
            ui.text(c, e.sha, .{ .size = 11.5, .mono = true, .color = th.muted });
        }
        ui.text(c, e.meta, .{ .size = 11.5, .color = th.muted, .truncate = .ellipsis });
    }
}

const tab_names = [_][]const u8{ "Overview", "Activity", "Settings" };

pub fn tabs(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Variants");
        defer sec.end();
        for ([_]kit.TabsVariant{ .underline, .pill, .segmented, .outline, .glass }, 0..) |v, i| {
            ui.key(c, @tagName(v));
            const r = page.row(c).gap(16);
            defer r.end();
            const l = ui.div(c).w(90);
            page.note(c, @tagName(v));
            l.end();
            _ = kit.tabs(c, &tab_names, &s.tab[i], .{ .variant = v });
        }
    }
    {
        const sec = page.section(c, "Sizes");
        defer sec.end();
        for ([_]kit.Size{ .sm, .md, .lg }) |sz| {
            ui.key(c, @tagName(sz));
            _ = kit.tabs(c, &tab_names, &s.small_tab, .{ .variant = .segmented, .size = sz });
        }
    }
}

pub fn breadcrumb(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "A path, each step a link");
    defer sec.end();
    if (kit.breadcrumb(c, &.{ "Home", "Projects", "nanoui", "Kit" })) |i| s.crumb = i;
    _ = kit.breadcrumb(c, &.{ "Documents", "Reports" });
    page.note(c, if (s.crumb) |i| c.print("Last chose step {d}", .{i + 1}) else "Click a step.");
}

pub fn pagination(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Few pages and many");
    defer sec.end();
    var few: usize = 1;
    _ = kit.pagination(c, &few, 3);
    _ = kit.pagination(c, &s.page, 24);
    page.note(c, c.print("Page {d} of 24", .{s.page + 1}));
}

pub fn accordion(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Accordion: one open at a time");
        defer sec.end();
        const box = ui.div(c).column().w(520).gap(0);
        defer box.end();
        const qa = [_][2][]const u8{
            .{ "What is nanoui?", "A desktop framework in Zig: web pages with typed IPC, or native UI it draws itself." },
            .{ "Does motion poll?", "No. It draws frames only while something moves." },
            .{ "Where's the kit from?", "Its components follow GPUI Kit's." },
        };
        for (qa, 0..) |q, i| {
            ui.key(c, c.print("faq-{d}", .{i}));
            if (kit.accordion(c, c.print("faq-{d}", .{i}), q[0], i, &s.faq)) |part| {
                defer part.end();
                ui.text(c, q[1], .{ .size = 13, .color = c.theme.muted });
            }
            kit.separator(c, .{});
        }
    }
    {
        const sec = page.section(c, "Collapsible: on its own");
        defer sec.end();
        const box = ui.div(c).column().w(520);
        defer box.end();
        if (kit.collapsible(c, "more", "Advanced options", &s.more)) |part| {
            defer part.end();
            ui.text(c, "Hidden until asked for.", .{ .size = 13, .color = c.theme.muted });
        }
    }
}

pub fn field(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Label, hint, required and error");
    defer sec.end();
    const r = ui.div(c).row().gap(28).itemsStart();
    defer r.end();
    {
        const f = kit.field(c, "Name", .{ .hint = "As it appears on invoices." });
        defer f.end();
        _ = ui.textField(c, &s.name, .{ .placeholder = "Ada Lovelace", .width = .{ .px = 220 } });
    }
    {
        const f = kit.field(c, "Size", .{ .required = true, .err = if (s.size == null) "Choose a size." else "" });
        defer f.end();
        _ = kit.select(c, "field-size", &.{ "Small", "Medium", "Large" }, &s.size, .{});
    }
}

pub fn radioGroup(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Vertical, horizontal and disabled");
    defer sec.end();
    const r = ui.div(c).row().gap(40).itemsStart();
    defer r.end();
    _ = kit.radioGroup(c, &.{ "Hobby", "Pro", "Team" }, &s.plan, .{});
    _ = kit.radioGroup(c, &.{ "Monthly", "Yearly" }, &s.plan_row, .{ .horizontal = true });
    var off: usize = 0;
    _ = kit.radioGroup(c, &.{ "Locked", "Also locked" }, &off, .{ .disabled = true });
}

pub fn select(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Empty, chosen and disabled");
    defer sec.end();
    const r = ui.div(c).row().gap(16).itemsStart();
    defer r.end();
    const options = [_][]const u8{ "Small", "Medium", "Large", "Extra large" };
    _ = kit.select(c, "select-empty", &options, &s.size, .{});
    _ = kit.select(c, "select-set", &options, &s.size_set, .{ .width = 160 });
    var none: ?usize = null;
    _ = kit.select(c, "select-off", &options, &none, .{ .disabled = true, .placeholder = "Unavailable" });
}

pub fn numberInput(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Whole numbers, decimals and bounds");
    defer sec.end();
    const r = ui.div(c).row().gap(28).itemsStart();
    defer r.end();
    {
        const f = kit.field(c, "Seats", .{ .hint = "1 to 50" });
        defer f.end();
        _ = kit.numberInput(c, &s.seats, .{ .min = 1, .max = 50 });
    }
    {
        const f = kit.field(c, "Price", .{ .hint = "Steps of 0.5" });
        defer f.end();
        _ = kit.numberInput(c, &s.price, .{ .min = 0, .step = 0.5, .decimals = 2 });
    }
}

pub fn menu(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Plain and glass");
    defer sec.end();
    const r = page.row(c);
    defer r.end();
    const items = [_]kit.MenuItem{
        .{ .label = "New file", .icon = "doc", .shortcut = "⌘N" },
        .{ .label = "Open…", .icon = "folder", .shortcut = "⌘O" },
        .{ .separator = true },
        .{ .label = "Show hidden", .checked = true },
        .{ .label = "Unavailable", .disabled = true },
        .{ .label = "Delete", .icon = "trash", .danger = true },
    };
    const m = kit.button(c, "Menu", .{ .icon_after = "chevron.down" });
    if (m.clicked) s.menu = !s.menu;
    s.menu_at = m.rect;
    const g = kit.button(c, "Glass menu", .{ .icon_after = "chevron.down" });
    if (g.clicked) s.menu_glass = !s.menu_glass;
    s.menu_glass_at = g.rect;
    if (kit.menu(c, "menu", &s.menu, s.menu_at, &items, .{})) |i| s.picked = i;
    if (kit.menu(c, "menu-glass", &s.menu_glass, s.menu_glass_at, &items, .{ .glass = true })) |i| s.picked = i;
    page.note(c, if (s.picked) |i| c.print("Chose {s}", .{items[i].label}) else "");
}

pub fn popover(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Anchored to its button");
    defer sec.end();
    const p = kit.button(c, "Popover", .{});
    if (p.clicked) s.pop = !s.pop;
    s.pop_at = p.rect;
    if (kit.popover(c, "pop", &s.pop, s.pop_at, .{ .width = 260 })) |pp| {
        defer pp.end();
        ui.text(c, "A popover", .{ .weight = .semibold });
        ui.text(c, "Click outside or press Escape to close it.", .{ .size = 12.5, .color = c.theme.muted, .wrap = true });
    }
}

pub fn tooltip(_: *State, c: *ui.Context) void {
    const sec = page.section(c, "Placements: rest the pointer on one");
    defer sec.end();
    const r = page.row(c);
    defer r.end();
    for ([_]kit.Placement{ .top, .bottom, .left, .right }) |pl| {
        ui.key(c, @tagName(pl));
        const b = kit.button(c, @tagName(pl), .{});
        kit.tooltip(c, b, c.print("Placed {s}", .{@tagName(pl)}), .{ .placement = pl });
    }
}

pub fn dialog(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Confirm and destructive");
    defer sec.end();
    const r = page.row(c);
    defer r.end();
    if (kit.button(c, "Open dialog", .{}).clicked) s.dialog = true;
    if (kit.button(c, "Delete project…", .{ .variant = .danger }).clicked) s.danger_dialog = true;
    if (kit.dialog(c, "dialog", &s.dialog, .{ .title = "Rename the project?", .description = "Links to the old name keep working.", .ok = "Rename" })) |d| {
        if (d.end() == .ok) s.toaster.push(.{ .status = .success, .title = "Renamed" });
    }
    if (kit.dialog(c, "danger-dialog", &s.danger_dialog, .{ .title = "Delete project?", .description = "Its files and history go too. This can't be undone.", .ok = "Delete", .ok_variant = .danger })) |d| {
        _ = kit.alert(c, .{ .status = .danger, .title = "3 people use it", .description = "They'll lose access at once." });
        if (d.end() == .ok) s.toaster.push(.{ .status = .danger, .title = "Deleted", .message = "The project is gone." });
    }
}

pub fn sheet(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "From each edge");
    defer sec.end();
    const r = page.row(c);
    defer r.end();
    const names = [_][]const u8{ "left", "right", "bottom" };
    for (names, 0..) |name, i| {
        ui.key(c, name);
        if (kit.button(c, name, .{}).clicked) s.sheet[i] = true;
    }
    inline for (.{ .left, .right, .bottom }, 0..) |side, i| {
        if (kit.sheet(c, "sheet-" ++ names[i], &s.sheet[i], .{ .side = side, .size = if (i == 2) 240 else 340, .title = "Settings" })) |sh| {
            defer sh.end();
            ui.text(c, "Sheets slide in from an edge. Escape closes them.", .{ .color = c.theme.muted, .wrap = true });
        }
    }
}

pub fn toast(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Statuses");
    defer sec.end();
    const r = page.row(c);
    defer r.end();
    const kinds = [_]struct { st: kit.Status, title: []const u8, msg: []const u8 }{
        .{ .st = .neutral, .title = "Copied", .msg = "The link is on the clipboard." },
        .{ .st = .success, .title = "Saved", .msg = "Your changes are in." },
        .{ .st = .warning, .title = "Offline", .msg = "Changes will sync later." },
        .{ .st = .danger, .title = "Couldn't connect", .msg = "Check your network and try again." },
    };
    for (kinds) |k| {
        ui.key(c, @tagName(k.st));
        if (kit.button(c, @tagName(k.st), .{ .variant = switch (k.st) {
            .success => .success,
            .warning => .warning,
            .danger => .danger,
            else => .default,
        } }).clicked) s.toaster.push(.{ .status = k.st, .title = k.title, .message = k.msg });
    }
}
