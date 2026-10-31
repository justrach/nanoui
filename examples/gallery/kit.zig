//! The gallery's Kit page: every `nanoui.kit` component, after GPUI Kit.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;

pub const Demo = struct {
    toaster: kit.Toaster = undefined,
    ready: bool = false,
    tab: [4]usize = .{ 0, 0, 0, 0 },
    loading: bool = false,
    menu: bool = false,
    menu_at: ?ui.Rect = null,
    pop: bool = false,
    pop_at: ?ui.Rect = null,
    dialog: bool = false,
    sheet: bool = false,
    faq: ?usize = 0,
    more: bool = false,
    plan: usize = 1,
    size: ?usize = null,
    seats: f64 = 3,
    page: usize = 4,
    notes: ui.TextBuffer = .{},
    alert: bool = true,
    progress: f32 = 0.42,

    pub fn view(d: *Demo, c: *ui.Context) void {
        if (!d.ready) {
            d.toaster = .{ .gpa = std.heap.page_allocator };
            d.ready = true;
        }
        const whole = ui.div(c).grow().hFull().clip();
        defer whole.end();
        {
            const sc = ui.div(c).column().sizeFull().scrollY().p(if (@import("phone.zig").compact(c)) 24 else 28).gap(22);
            defer sc.end();
            ui.heading(c, "Kit");
            ui.text(c, "Components after GPUI Kit, drawn by nanoui and moved by ui.motion.", .{ .wrap = true, .color = c.theme.muted });
            d.buttons(c);
            d.display(c);
            d.navigation(c);
            d.forms(c);
            d.overlays(c);
        }
        d.toaster.view(c);
    }

    fn section(c: *ui.Context, title: []const u8) ui.Div {
        const s = ui.div(c).column().wFull().gap(12);
        ui.text(c, title, .{ .size = 15, .weight = .semibold });
        return s;
    }

    fn row(c: *ui.Context) ui.Div {
        return ui.div(c).row().gap(8).itemsCenter();
    }

    fn buttons(d: *Demo, c: *ui.Context) void {
        const s = section(c, "Buttons");
        defer s.end();
        const variants = [_]kit.Variant{ .default, .primary, .secondary, .danger, .success, .warning, .info, .ghost, .outline, .link };
        for (0..2) |half| {
            ui.key(c, c.print("variants-{d}", .{half}));
            const r = row(c);
            defer r.end();
            for (variants[half * 5 ..][0..5]) |v| {
                ui.key(c, @tagName(v));
                _ = kit.button(c, @tagName(v), .{ .variant = v });
            }
        }
        {
            const r = row(c);
            defer r.end();
            for ([_]kit.Size{ .xs, .sm, .md, .lg }) |sz| {
                ui.key(c, @tagName(sz));
                _ = kit.button(c, @tagName(sz), .{ .size = sz, .variant = .primary, .icon = "star.fill" });
            }
            if (kit.button(c, if (d.loading) "Saving…" else "Save", .{ .loading = d.loading, .icon = "square.and.arrow.down" }).clicked) d.loading = true;
            if (d.loading and kit.button(c, "Done", .{ .variant = .ghost }).clicked) d.loading = false;
            _ = kit.button(c, "Pill", .{ .pill = true, .variant = .outline });
            _ = kit.iconButton(c, "heart", .{ .tooltip = "Like" });
            _ = kit.iconButton(c, "square.and.arrow.up", .{ .tooltip = "Share" });
            _ = kit.iconButton(c, "trash", .{ .tooltip = "Delete", .variant = .danger });
        }
    }

    fn display(d: *Demo, c: *ui.Context) void {
        const s = section(c, "Display");
        defer s.end();
        {
            const r = row(c);
            defer r.end();
            kit.tag(c, "Neutral", .{});
            kit.tag(c, "Info", .{ .status = .info });
            kit.tag(c, "Shipped", .{ .status = .success, .icon = "checkmark" });
            kit.tag(c, "Beta", .{ .status = .warning, .outline = true });
            kit.tag(c, "Failing", .{ .status = .danger, .pill = true });
            {
                const b = ui.div(c).pl(10);
                defer b.end();
                _ = kit.iconButton(c, "bell", .{});
                kit.badge(c, 3, .{ .x = 30, .y = 2 });
            }
            kit.avatar(c, .{ .name = "Ada Lovelace" });
            kit.avatarGroup(c, &.{ "Grace Hopper", "Alan Turing", "Margaret Hamilton", "Linus Torvalds", "Barbara Liskov", "Ken Thompson" }, .{});
        }
        if (d.alert and kit.alert(c, .{ .status = .warning, .title = "Your trial ends in 3 days", .description = "Add a payment method to keep your projects. You can close this.", .closable = true })) d.alert = false;
        _ = kit.alert(c, .{ .status = .success, .title = "Deployed", .description = "nanoui 0.3 is live." });
        {
            const r = row(c).gap(18);
            defer r.end();
            const bars = ui.div(c).column().w(260).gap(10);
            {
                defer bars.end();
                kit.progress(c, d.progress, .{});
                kit.progress(c, 0.8, .{ .status = .success });
                kit.progress(c, null, .{ .status = .info });
                {
                    const r2 = row(c);
                    defer r2.end();
                    if (kit.button(c, "−", .{ .size = .xs }).clicked) d.progress = @max(0, d.progress - 0.1);
                    if (kit.button(c, "+", .{ .size = .xs }).clicked) d.progress = @min(1, d.progress + 0.1);
                }
            }
            kit.ring(c, d.progress, .{});
            kit.spinner(c, .{ .size = 20 });
            const sk = ui.div(c).column().w(200).gap(8);
            defer sk.end();
            {
                const r3 = row(c);
                defer r3.end();
                kit.skeleton(c, .{ .height = 32, .circle = true });
                const lines = ui.div(c).column().grow().gap(6);
                defer lines.end();
                kit.skeleton(c, .{ .height = 10 });
                kit.skeleton(c, .{ .height = 10, .width = .{ .px = 90 } });
            }
        }
    }

    fn navigation(d: *Demo, c: *ui.Context) void {
        const s = section(c, "Navigation");
        defer s.end();
        const names = [_][]const u8{ "Overview", "Activity", "Settings" };
        for ([_]kit.TabsVariant{ .underline, .pill, .segmented, .outline }, 0..) |v, i| {
            ui.key(c, c.print("tabs-{d}", .{i}));
            _ = kit.tabs(c, &names, &d.tab[i], .{ .variant = v });
        }
        _ = kit.breadcrumb(c, &.{ "Home", "Projects", "nanoui", "Kit" });
        _ = kit.pagination(c, &d.page, 24);
        const box = ui.div(c).column().w(520).gap(0);
        defer box.end();
        const qa = [_][2][]const u8{
            .{ "What is nanoui?", "A desktop framework in Zig: web pages with typed IPC, or native UI it draws itself." },
            .{ "Does motion poll?", "No. It draws frames only while something moves." },
            .{ "Where's the kit from?", "Its components follow GPUI Kit's." },
        };
        for (qa, 0..) |q, i| {
            ui.key(c, c.print("faq-{d}", .{i}));
            if (kit.accordion(c, c.print("faq-{d}", .{i}), q[0], i, &d.faq)) |sec| {
                defer sec.end();
                ui.text(c, q[1], .{ .size = 13, .color = c.theme.muted });
            }
            kit.separator(c, .{});
        }
    }

    fn forms(d: *Demo, c: *ui.Context) void {
        const s = section(c, "Forms");
        defer s.end();
        var r = row(c).gap(28).itemsStart();
        {
            const f = kit.field(c, "Plan", .{ .hint = "You can change it later." });
            defer f.end();
            _ = kit.radioGroup(c, &.{ "Hobby", "Pro", "Team" }, &d.plan, .{});
        }
        {
            const f = kit.field(c, "Size", .{ .required = true, .err = if (d.size == null) "Choose a size." else "" });
            defer f.end();
            _ = kit.select(c, "size", &.{ "Small", "Medium", "Large", "Extra large" }, &d.size, .{});
        }
        r.end();
        // Two to a row: a row wider than the page widens what's below it.
        r = row(c).gap(28).itemsStart();
        defer r.end();
        {
            const f = kit.field(c, "Seats", .{});
            defer f.end();
            _ = kit.numberInput(c, &d.seats, .{ .min = 1, .max = 50 });
        }
        {
            const f = kit.field(c, "Notes", .{ .hint = "Markdown works." });
            defer f.end();
            _ = ui.textField(c, &d.notes, .{ .placeholder = "Anything else?", .width = .{ .px = 220 } });
        }
    }

    fn overlays(d: *Demo, c: *ui.Context) void {
        const s = section(c, "Overlays");
        defer s.end();
        const r = row(c);
        defer r.end();
        const m = kit.button(c, "Menu", .{ .icon_after = "chevron.down" });
        if (m.clicked) d.menu = !d.menu;
        d.menu_at = m.rect;
        const p = kit.button(c, "Popover", .{});
        if (p.clicked) d.pop = !d.pop;
        d.pop_at = p.rect;
        if (kit.button(c, "Dialog", .{}).clicked) d.dialog = true;
        if (kit.button(c, "Sheet", .{}).clicked) d.sheet = true;
        if (kit.button(c, "Toast", .{ .variant = .primary }).clicked) d.toaster.push(.{ .status = .success, .title = "Saved", .message = "Your changes are in." });
        if (kit.button(c, "Error toast", .{ .variant = .danger }).clicked) d.toaster.push(.{ .status = .danger, .title = "Couldn't connect", .message = "Check your network and try again.", .duration = 6 });
        if (kit.menu(c, "menu", &d.menu, d.menu_at, &.{
            .{ .label = "New file", .icon = "doc", .shortcut = "⌘N" },
            .{ .label = "Open…", .icon = "folder", .shortcut = "⌘O" },
            .{ .separator = true },
            .{ .label = "Show hidden", .checked = true },
            .{ .label = "Delete", .icon = "trash", .danger = true },
        }, .{})) |i| d.toaster.push(.{ .title = "Menu", .message = c.print("Chose item {d}", .{i}), .duration = 2 });
        if (kit.popover(c, "pop", &d.pop, d.pop_at, .{ .width = 260 })) |pp| {
            defer pp.end();
            ui.text(c, "A popover", .{ .weight = .semibold });
            ui.text(c, "Click outside or press Escape to close it.", .{ .size = 12.5, .color = c.theme.muted, .wrap = true });
        }
        if (kit.dialog(c, "dialog", &d.dialog, .{ .title = "Delete project?", .description = "Its files and history go too. This can't be undone.", .ok = "Delete", .ok_variant = .danger })) |dl| {
            _ = kit.alert(c, .{ .status = .danger, .title = "3 people use it", .description = "They'll lose access at once." });
            if (dl.end() == .ok) d.toaster.push(.{ .status = .danger, .title = "Deleted", .message = "The project is gone." });
        }
        if (kit.sheet(c, "sheet", &d.sheet, .{ .title = "Settings" })) |sh| {
            defer sh.end();
            ui.text(c, "Sheets slide in from an edge.", .{ .color = c.theme.muted });
            _ = kit.radioGroup(c, &.{ "System", "Light", "Dark" }, &d.plan, .{});
        }
    }
};
