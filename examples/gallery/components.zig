//! A page per `nanoui.kit` component: every variant, size and state it has,
//! in labelled sections, under a heading that names its call and its file
//! (`catalog.components`). Buttons and display here; navigation, forms and
//! overlays in `components_more.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const catalog = @import("catalog.zig");
const page = @import("page.zig");
const more = @import("components_more.zig");

/// What the pages' examples remember between frames.
pub const State = struct {
    toaster: kit.Toaster = undefined,
    ready: bool = false,
    loading: bool = false,
    selected: bool = true,
    likes: u32 = 3,
    alert: bool = true,
    progress: f32 = 0.42,
    commit: usize = 0,
    tab: [5]usize = @splat(0),
    small_tab: usize = 1,
    crumb: ?usize = null,
    page: usize = 4,
    faq: ?usize = 0,
    more: bool = false,
    plan: usize = 1,
    plan_row: usize = 0,
    size: ?usize = null,
    size_set: ?usize = 2,
    seats: f64 = 3,
    price: f64 = 19.5,
    name: ui.TextBuffer = .{},
    menu: bool = false,
    menu_at: ?ui.Rect = null,
    menu_glass: bool = false,
    menu_glass_at: ?ui.Rect = null,
    picked: ?usize = null,
    pop: bool = false,
    pop_at: ?ui.Rect = null,
    dialog: bool = false,
    danger_dialog: bool = false,
    sheet: [3]bool = @splat(false),

    pub fn deinit(s: *State) void {
        s.name.deinit();
        if (s.ready) s.toaster.deinit();
    }
};

/// Component `comp`'s page.
pub fn view(s: *State, c: *ui.Context, comp: catalog.Component) void {
    if (!s.ready) {
        s.toaster = .{ .gpa = std.heap.page_allocator };
        s.ready = true;
    }
    page.begin(c, comp.name, c.print("{s}  ·  {s}", .{ comp.call, comp.file }), null);
    ui.key(c, comp.id);
    const id = comp.id;
    inline for (.{
        .{ "button", button },                 .{ "icon-button", iconButton },      .{ "tag", tag },
        .{ "badge", badge },                   .{ "avatar", avatar },               .{ "kbd", kbd },
        .{ "alert", alert },                   .{ "progress", progress },           .{ "ring", ring },
        .{ "spinner", spinner },               .{ "skeleton", skeleton },           .{ "separator", separator },
        .{ "empty", empty },                   .{ "timeline", more.timeline },      .{ "tabs", more.tabs },
        .{ "breadcrumb", more.breadcrumb },    .{ "pagination", more.pagination },  .{ "accordion", more.accordion },
        .{ "field", more.field },              .{ "radio-group", more.radioGroup }, .{ "select", more.select },
        .{ "number-input", more.numberInput }, .{ "menu", more.menu },              .{ "popover", more.popover },
        .{ "tooltip", more.tooltip },          .{ "dialog", more.dialog },          .{ "sheet", more.sheet },
        .{ "toast", more.toast },
    }) |e| if (std.mem.eql(u8, id, e[0])) e[1](s, c);
    page.end(c);
    s.toaster.view(c);
}

const variants = [_]kit.Variant{ .default, .primary, .secondary, .danger, .success, .warning, .info, .ghost, .outline, .link, .text };
const sizes = [_]kit.Size{ .xs, .sm, .md, .lg };
const statuses = [_]kit.Status{ .neutral, .info, .success, .warning, .danger };

fn button(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Variants");
        defer sec.end();
        for (0..2) |half| {
            ui.key(c, c.print("variants-{d}", .{half}));
            const r = page.row(c);
            defer r.end();
            const part = if (half == 0) variants[0..6] else variants[6..];
            for (part) |v| {
                ui.key(c, @tagName(v));
                _ = kit.button(c, @tagName(v), .{ .variant = v });
            }
        }
    }
    {
        const sec = page.section(c, "Sizes");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        for (sizes) |sz| {
            ui.key(c, @tagName(sz));
            _ = kit.button(c, @tagName(sz), .{ .size = sz, .variant = .primary });
        }
    }
    {
        const sec = page.section(c, "Icons and shape");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        _ = kit.button(c, "Favorite", .{ .icon = "star.fill" });
        _ = kit.button(c, "Continue", .{ .icon_after = "arrow.right", .variant = .primary });
        _ = kit.button(c, "Pill", .{ .pill = true, .variant = .outline });
        _ = kit.button(c, "Glass", .{ .glass = true, .icon = "sparkles" });
    }
    {
        const sec = page.section(c, "States");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        if (kit.button(c, if (s.loading) "Saving…" else "Save", .{ .loading = s.loading, .icon = "square.and.arrow.up", .variant = .primary }).clicked) s.loading = !s.loading;
        if (kit.button(c, "Selected", .{ .selected = s.selected }).clicked) s.selected = !s.selected;
        _ = kit.button(c, "Disabled", .{ .disabled = true });
        _ = kit.button(c, "With a tooltip", .{ .tooltip = "Shown when the pointer rests on it" });
    }
    {
        const sec = page.section(c, "Full width");
        defer sec.end();
        const box = ui.div(c).column().w(320).gap(8);
        defer box.end();
        _ = kit.button(c, "Sign in", .{ .full_width = true, .variant = .primary });
        _ = kit.button(c, "Create an account", .{ .full_width = true, .variant = .outline });
    }
}

fn iconButton(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Variants");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        for ([_]kit.Variant{ .default, .primary, .secondary, .ghost, .outline, .danger }) |v| {
            ui.key(c, @tagName(v));
            _ = kit.iconButton(c, "bookmark", .{ .variant = v, .tooltip = @tagName(v) });
        }
    }
    {
        const sec = page.section(c, "Sizes");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        for (sizes) |sz| {
            ui.key(c, @tagName(sz));
            _ = kit.iconButton(c, "square.and.arrow.up", .{ .size = sz, .tooltip = @tagName(sz) });
        }
    }
    {
        const sec = page.section(c, "States");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        if (kit.iconButton(c, "star.fill", .{ .selected = s.selected, .tooltip = "Toggle" }).clicked) s.selected = !s.selected;
        _ = kit.iconButton(c, "trash", .{ .disabled = true, .tooltip = "Disabled" });
        _ = kit.iconButton(c, "sparkles", .{ .glass = true, .tooltip = "Glass" });
    }
}

fn tag(_: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Statuses");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        for (statuses) |st| {
            ui.key(c, @tagName(st));
            kit.tag(c, @tagName(st), .{ .status = st });
        }
    }
    {
        const sec = page.section(c, "Outline and pill");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        for (statuses) |st| {
            ui.key(c, c.print("outline-{s}", .{@tagName(st)}));
            kit.tag(c, @tagName(st), .{ .status = st, .outline = true });
        }
        for (statuses[1..]) |st| {
            ui.key(c, c.print("pill-{s}", .{@tagName(st)}));
            kit.tag(c, @tagName(st), .{ .status = st, .pill = true });
        }
    }
    {
        const sec = page.section(c, "Icons and sizes");
        defer sec.end();
        const r = page.row(c);
        defer r.end();
        kit.tag(c, "Shipped", .{ .status = .success, .icon = "checkmark" });
        kit.tag(c, "Blocked", .{ .status = .danger, .icon = "xmark" });
        for (sizes) |sz| {
            ui.key(c, @tagName(sz));
            kit.tag(c, @tagName(sz), .{ .size = sz, .status = .info });
        }
        kit.tag(c, "Custom", .{ .color = .hex(0xbf5af2), .pill = true });
    }
}

fn badge(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Counts and dots");
    defer sec.end();
    const r = page.row(c).gap(28);
    defer r.end();
    const marks = [_]struct { icon: []const u8, n: u32, dot: bool = false }{
        .{ .icon = "bell", .n = s.likes },
        .{ .icon = "doc.text", .n = 42 },
        .{ .icon = "folder", .n = 120 },
        .{ .icon = "person.fill", .n = 0, .dot = true },
    };
    for (marks, 0..) |m, i| {
        ui.key(c, c.print("mark-{d}", .{i}));
        const b = ui.div(c).column().gap(6).itemsCenter();
        defer b.end();
        {
            const box = ui.div(c);
            defer box.end();
            if (kit.iconButton(c, m.icon, .{}).clicked and i == 0) s.likes += 1;
            kit.badge(c, m.n, .{ .x = 30, .y = 2, .dot = m.dot });
        }
        page.note(c, if (m.dot) "dot" else if (m.n > 99) "over max" else c.print("{d}", .{m.n}));
    }
}

fn avatar(_: *State, c: *ui.Context) void {
    const people = [_][]const u8{ "Ada Lovelace", "Grace Hopper", "Alan Turing", "Margaret Hamilton", "Linus Torvalds", "Barbara Liskov", "Ken Thompson" };
    {
        const sec = page.section(c, "Sizes");
        defer sec.end();
        const r = page.row(c).gap(14);
        defer r.end();
        for ([_]f32{ 24, 32, 40, 56 }, 0..) |sz, i| {
            ui.key(c, c.print("size-{d}", .{i}));
            kit.avatar(c, .{ .name = people[i], .size = sz });
        }
        kit.avatar(c, .{ .size = 40 });
        kit.avatar(c, .{ .name = "Ada Lovelace", .size = 40, .ring = c.theme.accent });
    }
    {
        const sec = page.section(c, "A group");
        defer sec.end();
        const r = page.row(c).gap(24);
        defer r.end();
        kit.avatarGroup(c, &people, .{});
        kit.avatarGroup(c, people[0..3], .{ .size = 36 });
    }
}

fn kbd(_: *State, c: *ui.Context) void {
    const sets = [_]struct { label: []const u8, keys: []const []const u8 }{
        .{ .label = "Shortcuts", .keys = &.{ ui.keys.label("⌘K"), ui.keys.label("⇧⌘P"), ui.keys.label("⌥⌘I"), ui.keys.label("⌃⌘F") } },
        .{ .label = "Keys", .keys = &.{ "Esc", "Tab", "Space", "F5", "↵", "←", "Up" } },
        .{ .label = "Sequences", .keys = &.{ "G G", ui.keys.label("⌘K ⌘S") } },
    };
    for (sets) |set| {
        const sec = page.section(c, set.label);
        defer sec.end();
        const r = page.row(c).gap(18);
        defer r.end();
        for (set.keys, 0..) |k, i| {
            ui.key(c, c.print("{s}-{d}", .{ set.label, i }));
            kit.kbd(c, k);
        }
    }
    {
        const sec = page.section(c, "Small, inside a control");
        defer sec.end();
        const r = page.row(c).gap(18);
        defer r.end();
        const field = ui.div(c).row().w(260).h(30).px(10).gap(6).itemsCenter().rounded(7).bg(c.theme.surface).border(c.theme.border);
        ui.icon(c, "magnifyingglass", .{ .size = 13, .frame = 16, .color = c.theme.muted });
        ui.text(c, "Search…", .{ .size = 12.5, .color = c.theme.muted });
        ui.spacer(c);
        kit.kbdWith(c, ui.keys.label("⌘K"), .{ .size = .sm });
        field.end();
        kit.kbdWith(c, ui.keys.label("⇧⌘P"), .{ .color = c.theme.accent });
    }
}

fn alert(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Statuses");
        defer sec.end();
        const box = ui.div(c).column().wFull().maxW(560).gap(10);
        defer box.end();
        _ = kit.alert(c, .{ .status = .info, .title = "Heads up", .description = "A new version is ready to install." });
        _ = kit.alert(c, .{ .status = .success, .title = "Deployed", .description = "The release is live." });
        _ = kit.alert(c, .{ .status = .danger, .title = "Couldn't save", .description = "The disk is full." });
    }
    {
        const sec = page.section(c, "Closable and banner");
        defer sec.end();
        const box = ui.div(c).column().wFull().maxW(560).gap(10);
        defer box.end();
        if (s.alert) {
            if (kit.alert(c, .{ .status = .warning, .title = "Your trial ends in 3 days", .description = "Close this, and the button below brings it back.", .closable = true })) s.alert = false;
        } else if (kit.button(c, "Show the alert again", .{ .size = .sm }).clicked) s.alert = true;
        _ = kit.alert(c, .{ .status = .info, .title = "Scheduled maintenance tonight at 22:00", .banner = true });
    }
}

fn progress(s: *State, c: *ui.Context) void {
    {
        const sec = page.section(c, "Statuses");
        defer sec.end();
        const box = ui.div(c).column().w(320).gap(12);
        defer box.end();
        for (statuses, 0..) |st, i| {
            ui.key(c, @tagName(st));
            kit.progress(c, 0.2 + 0.15 * @as(f32, @floatFromInt(i)), .{ .status = st });
        }
    }
    {
        const sec = page.section(c, "Indeterminate, height and value");
        defer sec.end();
        const box = ui.div(c).column().w(320).gap(12);
        defer box.end();
        kit.progress(c, null, .{ .status = .info });
        kit.progress(c, s.progress, .{ .height = 12 });
        stepper(s, c);
    }
}

fn stepper(s: *State, c: *ui.Context) void {
    const r = page.row(c);
    defer r.end();
    if (kit.button(c, "−", .{ .size = .xs }).clicked) s.progress = @max(0, s.progress - 0.1);
    if (kit.button(c, "+", .{ .size = .xs }).clicked) s.progress = @min(1, s.progress + 0.1);
    page.note(c, c.print("{d:.0}%", .{s.progress * 100}));
}

fn ring(s: *State, c: *ui.Context) void {
    const sec = page.section(c, "Values, sizes and colors");
    defer sec.end();
    {
        const r = page.row(c).gap(20);
        defer r.end();
        kit.ring(c, s.progress, .{});
        kit.ring(c, 0.75, .{ .size = 72, .label = "75%" });
        kit.ring(c, 1, .{ .size = 40, .color = c.theme.success });
        kit.ring(c, 0.1, .{ .size = 40, .color = c.theme.danger });
    }
    stepper(s, c);
}

fn spinner(_: *State, c: *ui.Context) void {
    const sec = page.section(c, "Sizes and colors");
    defer sec.end();
    const r = page.row(c).gap(20);
    defer r.end();
    for ([_]f32{ 12, 16, 20, 28 }, 0..) |sz, i| {
        ui.key(c, c.print("size-{d}", .{i}));
        kit.spinner(c, .{ .size = sz });
    }
    kit.spinner(c, .{ .size = 20, .color = c.theme.accent });
}

fn skeleton(_: *State, c: *ui.Context) void {
    const sec = page.section(c, "Lines, blocks and circles");
    defer sec.end();
    const card = ui.div(c).column().w(360).gap(12).p(16).rounded(10).border(c.theme.border);
    defer card.end();
    {
        const r = page.row(c);
        defer r.end();
        kit.skeleton(c, .{ .height = 40, .circle = true });
        const lines = ui.div(c).column().grow().gap(6);
        defer lines.end();
        kit.skeleton(c, .{ .height = 12 });
        kit.skeleton(c, .{ .height = 10, .width = .{ .px = 120 } });
    }
    kit.skeleton(c, .{ .height = 120, .radius = 8 });
}

fn separator(_: *State, c: *ui.Context) void {
    const sec = page.section(c, "Plain, labelled and vertical");
    defer sec.end();
    const box = ui.div(c).column().w(360).gap(14);
    defer box.end();
    kit.separator(c, .{});
    kit.separator(c, .{ .label = "OR" });
    const r = page.row(c).h(24);
    defer r.end();
    ui.text(c, "Edit", .{});
    kit.separator(c, .{ .vertical = true });
    ui.text(c, "View", .{});
    kit.separator(c, .{ .vertical = true });
    ui.text(c, "Help", .{});
}

fn empty(_: *State, c: *ui.Context) void {
    const sec = page.section(c, "Default and custom");
    defer sec.end();
    const r = ui.div(c).row().gap(16).itemsStart();
    defer r.end();
    for ([_][3][]const u8{
        .{ "tray", "Nothing here", "" },
        .{ "magnifyingglass", "No results", "Try another word." },
        .{ "folder", "No projects yet", "Projects you make appear here." },
    }, 0..) |e, i| {
        ui.key(c, c.print("empty-{d}", .{i}));
        const box = ui.div(c).w(220).h(180).rounded(10).border(c.theme.border).center();
        defer box.end();
        kit.empty(c, .{ .icon = e[0], .title = e[1], .description = e[2] });
    }
}
