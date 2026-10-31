//! The to-do list's state and its view: nanoui's own components on a
//! phone. Liquid Glass for the bars that float over the list (filter tabs
//! with a sliding lens, a menu, the tab bar and the + button) and for the
//! sheet a new task comes in on; kit tags on each card, a progress ring
//! and bar for the day, switches and pill tabs in the sheet; and springs
//! for every press, check and move.
//!
//! Light, quiet and roomy: an off-white canvas with a soft wash of color
//! for the glass to bend, white cards with a soft shadow, a 24-point
//! gutter, tabular digits, 44-point targets, and corners that nest.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const week = @import("week.zig");

/// What kind of task it is: the tag on its card.
pub const Kind = enum {
    work,
    meeting,
    personal,

    fn label(k: Kind) []const u8 {
        return switch (k) {
            .work => "Work",
            .meeting => "Meeting",
            .personal => "Personal",
        };
    }

    fn color(k: Kind) ui.Color {
        return switch (k) {
            .work => .hex(0x2f78c4),
            .meeting => .hex(0x8e5cd9),
            .personal => .hex(0x1f9d6b),
        };
    }
};

pub const Task = struct {
    title: []const u8,
    time: []const u8,
    icon: []const u8,
    hue: u24,
    kind: Kind = .work,
    urgent: bool = false,
    remind: bool = false,
    done: bool = false,
    /// When it was checked (the clock's seconds): it moves down a moment later.
    done_at: f64 = 0,
};

/// The palette, after the design's.
pub const ink = ui.Color.hex(0x111214);
pub const muted = ui.Color.hex(0x9a9ca3);
pub const canvas = ui.Color.hex(0xf8f9fa);
pub const green = ui.Color.hex(0x34c759);
const line = ui.Color.hex(0xd5d7dc);
const soft = ui.Color.hex(0xeeeff1);

const gutter = 24;
const card_radius = 24;
const card_pad = 12;
/// A checked task waits this long, greyed, before it moves down.
const settle = 0.28;
/// The cards' glide to a new place: a spring that lands in about 0.38 s
/// without overshoot, so a second check mid-glide carries on from there.
fn glide() motion.Spring {
    return motion.Spring.visual(0.38, 0);
}

/// What the sheet adds, in turn.
const more = [_]Task{
    .{ .title = "Write release notes", .time = "3:30 PM", .icon = "doc.text.fill", .hue = 0x5e5ce6 },
    .{ .title = "Gym", .time = "6:00 PM", .icon = "figure.run", .hue = 0x30b0c7 },
    .{ .title = "Read 20 pages", .time = "9:00 PM", .icon = "book.fill", .hue = 0xff9500 },
};

const filters = [_][]const u8{ "All", "To do", "Done" };
const kinds = [_][]const u8{ "Work", "Meeting", "Personal" };

pub const Todo = struct {
    tasks: [8]Task = undefined,
    count: usize = 5,
    added: usize = 0,
    tab: usize = 1,
    filter: usize = 0,
    started: bool = false,
    menu: bool = false,
    menu_at: ?ui.Rect = null,
    /// The sheet a new task comes in on, and what it's set to.
    sheet: bool = false,
    draft_kind: usize = 0,
    draft_urgent: bool = false,
    draft_remind: bool = true,

    fn start(t: *Todo) void {
        t.tasks[0..5].* = .{
            .{ .title = "Reply to client emails", .time = "9:00 AM", .icon = "envelope.fill", .hue = 0x0a84ff, .kind = .work },
            .{ .title = "Daily stand-up", .time = "9:15 AM", .icon = "briefcase.fill", .hue = 0xa2672f, .kind = .meeting },
            .{ .title = "Design review with PM", .time = "10:30 AM", .icon = "star.fill", .hue = 0xffb300, .kind = .meeting, .remind = true },
            .{ .title = "Fix onboarding flow", .time = "12:00 PM", .icon = "safari.fill", .hue = 0x2f80ed, .kind = .work, .urgent = true },
            .{ .title = "Sprint planning call", .time = "2:00 PM", .icon = "calendar", .hue = 0xff453a, .kind = .meeting },
        };
        t.started = true;
    }

    fn next(t: *const Todo) Task {
        return more[t.added % more.len];
    }

    fn add(t: *Todo) void {
        if (t.count == t.tasks.len) return;
        var k = t.next();
        k.kind = @fromBackingInt(@intCast(t.draft_kind));
        k.urgent = t.draft_urgent;
        k.remind = t.draft_remind;
        t.tasks[t.count] = k;
        t.count += 1;
        t.added += 1;
        // Show it: a new task is one to do.
        if (t.filter == 2) t.filter = 0;
    }

    pub fn done(t: *const Todo) usize {
        var n: usize = 0;
        for (t.tasks[0..t.count]) |k| n += @intFromBool(k.done);
        return n;
    }

    fn countWhere(t: *const Todo, comptime f: fn (Task) bool) usize {
        var n: usize = 0;
        for (t.tasks[0..t.count]) |k| n += @intFromBool(f(k));
        return n;
    }

    /// The order the cards stand in: the tasks still to do as they were
    /// written, then the ones done in the order they were done. A task
    /// just checked keeps its place for `settle`, greyed, then moves.
    /// The filter tabs leave out what they don't show.
    fn order(t: *Todo, c: *ui.Context, out: []usize) []usize {
        var n: usize = 0;
        var waiting = false;
        for (t.tasks[0..t.count], 0..) |k, i| {
            const moved = k.done and c.time - k.done_at >= settle;
            if (k.done and !moved) waiting = true;
            if (!moved and (t.filter != 2 or k.done)) {
                out[n] = i;
                n += 1;
            }
        }
        const first_done = n;
        if (t.filter != 1) for (t.tasks[0..t.count], 0..) |k, i| {
            if (k.done and c.time - k.done_at >= settle) {
                out[n] = i;
                n += 1;
            }
        };
        // The done ones by when: the first checked first.
        std.mem.sort(usize, out[first_done..n], t, struct {
            fn lt(s: *Todo, a: usize, b: usize) bool {
                return s.tasks[a].done_at < s.tasks[b].done_at;
            }
        }.lt);
        // Wake for the move, even with nothing else moving.
        if (waiting) c.animationFrame();
        return out[0..n];
    }

    pub fn view(t: *Todo, c: *ui.Context) void {
        if (!t.started) t.start();
        const safe = c.safe_area;
        const root = ui.div(c).sizeFull().clip().bg(canvas);
        defer root.end();
        wash(c);
        {
            const sc = ui.div(c).column().sizeFull().scrollY().scrollbar(.{ .overlay = ink.alpha(0.35) }).pt(safe.top + 84).pb(safe.bottom + 112);
            defer sc.end();
            {
                const head = ui.div(c).column().wFull().px(gutter).gap(16);
                defer head.end();
                ui.text(c, "To-do list", .{ .size = 32, .weight = .bold, .color = ink });
                week.strip(c, t.done(), t.count);
            }
            t.today(c);
            t.planHeader(c);
            t.cards(c);
        }
        t.topBar(c);
        t.tabBar(c);
        t.addSheet(c);
    }

    /// The top bar: glass, floating over the list as it scrolls under.
    /// Filter tabs whose tinted lens slides, and a menu of glass.
    fn topBar(t: *Todo, c: *ui.Context) void {
        const f = motion.frame(c, .{ .initial = .{ .y = -24, .opacity = 0, .scale = 0.96 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const bar = ui.div(c).absolute().offset(16, c.safe_area.top + 8).w(c.size.w - 32).h(60).row().itemsCenter().gap(10).px(8).rounded(30).glass(.{}).motion(f);
        defer bar.end();
        _ = kit.tabs(c, &filters, &t.filter, .{ .variant = .glass });
        ui.spacer(c);
        const m = kit.iconButton(c, "ellipsis", .{ .glass = true, .pill = true });
        if (m.clicked) t.menu = !t.menu;
        t.menu_at = m.rect;
        if (kit.menu(c, "more", &t.menu, t.menu_at, &.{
            .{ .label = "Check all", .icon = "checkmark.circle" },
            .{ .label = "Uncheck all", .icon = "arrow.uturn.backward" },
            .{ .separator = true },
            .{ .label = "Clear done", .icon = "trash", .danger = true },
        }, .{ .glass = true, .placement = .bottom_end, .width = 210 })) |i| switch (i) {
            0, 1 => for (t.tasks[0..t.count]) |*k| {
                if (k.done != (i == 0)) {
                    k.done = i == 0;
                    k.done_at = c.time;
                }
            },
            3 => {
                var n: usize = 0;
                for (t.tasks[0..t.count]) |k| if (!k.done) {
                    t.tasks[n] = k;
                    n += 1;
                };
                t.count = n;
            },
            else => {},
        };
    }

    /// Today: a progress ring and bar, and tags for what's urgent and
    /// what will remind you.
    fn today(t: *Todo, c: *ui.Context) void {
        const wrap = ui.div(c).wFull().px(gutter).pt(20);
        defer wrap.end();
        const card = ui.div(c).column().wFull().p(18).gap(14).rounded(28).bg(.white).shadow(.{ .color = .{ .a = 0.05 }, .blur = 20, .y = 6 });
        defer card.end();
        const d = t.done();
        const share: f32 = if (t.count == 0) 0 else @as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(t.count));
        const eased = motion.number(c, "share", share, .{ .spring = motion.Spring.visual(0.6, 0) });
        {
            const r = ui.div(c).row().wFull().gap(16).itemsCenter();
            defer r.end();
            kit.ring(c, eased, .{ .size = 64, .label = c.print("{d}/{d}", .{ d, t.count }), .color = green });
            const words = ui.div(c).column().grow().gap(8);
            defer words.end();
            ui.text(c, "Today", .{ .size = 20, .weight = .bold, .color = ink });
            ui.text(c, c.print("{d} of {d} done", .{ d, t.count }), .{ .size = 14, .weight = .medium, .color = muted, .tabular = true });
            kit.progress(c, eased, .{ .status = .success });
        }
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        const urgent = t.countWhere(struct {
            fn f(k: Task) bool {
                return k.urgent and !k.done;
            }
        }.f);
        const reminders = t.countWhere(struct {
            fn f(k: Task) bool {
                return k.remind and !k.done;
            }
        }.f);
        kit.tag(c, c.print("{d} urgent", .{urgent}), .{ .status = if (urgent > 0) .danger else .neutral, .pill = true, .icon = "flame.fill" });
        kit.tag(c, c.print("{d} {s}", .{ reminders, if (reminders == 1) "reminder" else "reminders" }), .{ .status = .info, .pill = true, .icon = "bell.fill" });
        if (d == t.count and t.count > 0) kit.tag(c, "All done", .{ .status = .success, .pill = true, .icon = "checkmark" });
    }

    fn planHeader(t: *Todo, c: *ui.Context) void {
        const r = ui.div(c).row().wFull().px(gutter).pt(24).pb(8).gap(8).itemsCenter();
        defer r.end();
        ui.text(c, "Today\u{2019}s plan", .{ .size = 20, .weight = .bold, .color = ink });
        kit.tag(c, c.print("{d}", .{t.count - t.done()}), .{ .pill = true });
        ui.spacer(c);
        // A 32-point pill in a 44-point target.
        const give = motion.frame(c, .{ .press = .{ .scale = 0.94 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const hit = ui.div(c).h(44).itemsCenter().control().motion(give);
        defer hit.end();
        if (hit.clicked()) t.sheet = true;
        const pill = ui.div(c).row().h(32).px(12).gap(4).roundedFull().bg(soft).itemsCenter();
        defer pill.end();
        ui.text(c, "Add", .{ .size = 14, .weight = .semibold, .color = ui.Color.hex(0x6b6e76) });
        ui.icon(c, "plus", .{ .size = 12, .weight = .bold, .color = ui.Color.hex(0x6b6e76) });
    }

    fn cards(t: *Todo, c: *ui.Context) void {
        var buf: [8]usize = undefined;
        const list = ui.div(c).column().wFull().px(gutter).gap(12);
        defer list.end();
        const shown = t.order(c, &buf);
        if (shown.len == 0) {
            kit.empty(c, .{ .icon = "checklist", .title = "Nothing here", .description = "Tasks you check off show up here." });
            return;
        }
        for (shown) |i| {
            const k = &t.tasks[i];
            ui.key(c, c.print("task-{d}", .{i}));
            const f = motion.frame(c, .{
                .initial = .{ .y = 16, .opacity = 0, .scale = 0.97 },
                .delay = if (c.frame < 3) motion.stagger(i, 0.05) else 0,
                .layout = true,
                .transition = .{ .spring = glide() },
            });
            const card = ui.div(c).row().wFull().h(84).pl(card_pad).pr(4).gap(14).itemsCenter().rounded(card_radius).bg(.white)
                .shadow(.{ .color = .{ .a = 0.045 }, .blur = 18, .y = 4 }).motion(f);
            defer card.end();
            // Grey, over a quarter of a second, once checked.
            const grey = motion.number(c, "grey", if (k.done) 1 else 0, .{ .tween = .{ .duration = 0.25, .ease = .ease_out } });
            {
                const tile = ui.div(c).w(52).h(52).rounded(card_radius - card_pad).bg(ui.Color.hex(k.hue).alpha(0.12)).center().opacity(1 - 0.55 * grey);
                defer tile.end();
                ui.icon(c, k.icon, .{ .size = 22, .frame = 26, .weight = .semibold, .color = .hex(k.hue) });
            }
            {
                const words = ui.div(c).column().grow().gap(6).opacity(1 - 0.45 * grey);
                defer words.end();
                ui.text(c, k.title, .{ .size = 16, .weight = .semibold, .color = ink.mix(ui.Color.hex(0xc4c6cb), grey), .truncate = .ellipsis });
                const when = ui.div(c).row().gap(6).itemsCenter();
                defer when.end();
                const tint = muted.mix(ui.Color.hex(0xcdcfd4), grey);
                ui.icon(c, "clock.fill", .{ .size = 11, .frame = 12, .color = tint });
                ui.text(c, k.time, .{ .size = 12, .weight = .semibold, .color = tint, .tabular = true });
                kit.tag(c, k.kind.label(), .{ .color = k.kind.color(), .pill = true, .size = .xs });
                if (k.urgent) kit.tag(c, "Urgent", .{ .status = .danger, .pill = true, .size = .xs });
                if (k.remind) ui.icon(c, "bell.fill", .{ .size = 11, .frame = 12, .color = kit.tokens(c).info.mix(ui.Color.hex(0xcdcfd4), grey) });
            }
            if (checkbox(c, k.done)) {
                k.done = !k.done;
                k.done_at = c.time;
            }
        }
    }

    fn tabBar(t: *Todo, c: *ui.Context) void {
        const w = c.size.w;
        const y = c.size.h - c.safe_area.bottom - 76;
        const plus_size = 64;
        // The + stands 12 points clear of the bar's end.
        const pill_w = w - 2 * gutter - plus_size - 12;
        {
            const pill = ui.div(c).absolute().offset(gutter, y).w(pill_w).h(64).row().p(6).gap(2).roundedFull().glass(.{})
                .shadow(.{ .color = .{ .a = 0.06 }, .blur = 24, .y = 8 });
            defer pill.end();
            const tabs = [_][2][]const u8{ .{ "Home", "house.fill" }, .{ "Tasks", "checklist" }, .{ "Calendar", "calendar" }, .{ "Stats", "chart.bar.fill" } };
            for (tabs, 0..) |tab, i| {
                const on = t.tab == i;
                // The pill's radius less its padding: 32 - 6.
                const f = motion.frame(c, .{
                    .target = .{ .background = if (on) ui.Color.white.alpha(0.7) else ui.Color.white.alpha(0) },
                    .press = .{ .scale = 0.9 },
                    .transition = .{ .spring = motion.Spring.bouncy },
                });
                const item = ui.div(c).column().grow().hFull().gap(2).rounded(26).center().control().motion(f);
                defer item.end();
                if (item.clicked()) t.tab = i;
                const col = if (on) ink else ui.Color.hex(0x6b6e76);
                ui.icon(c, tab[1], .{ .size = 18, .frame = 22, .weight = .semibold, .color = col });
                ui.text(c, tab[0], .{ .size = 11, .weight = .semibold, .color = col });
            }
        }
        // The + : a pane of glass tinted ink, that gives when pressed.
        const f = motion.frame(c, .{ .press = .{ .scale = 0.88 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const plus = ui.div(c).absolute().offset(w - gutter - plus_size, y).w(plus_size).h(plus_size).roundedFull().glass(.{ .tint = ink.alpha(0.9) })
            .shadow(.{ .color = .{ .a = 0.2 }, .blur = 20, .y = 8 }).center().control().motion(f);
        defer plus.end();
        if (plus.clicked()) t.sheet = true;
        ui.icon(c, "plus", .{ .size = 24, .weight = .semibold, .color = .white });
    }

    /// The sheet a new task comes in on: a pane of glass from the bottom,
    /// with pill tabs for its kind, switches, and the button that adds it.
    fn addSheet(t: *Todo, c: *ui.Context) void {
        const size = 430 + c.safe_area.bottom;
        const sh = kit.sheet(c, "new-task", &t.sheet, .{ .side = .bottom, .size = size, .title = "New task" }) orelse return;
        const s = sh.rounded(32).glass(.{}).px(24).pt(24).pb(c.safe_area.bottom + 16).gap(18);
        defer s.end();
        const k = t.next();
        {
            const r = ui.div(c).row().wFull().h(72).px(12).gap(14).itemsCenter().rounded(22).bg(ui.Color.white.alpha(0.75));
            defer r.end();
            {
                const tile = ui.div(c).w(48).h(48).rounded(14).bg(ui.Color.hex(k.hue).alpha(0.14)).center();
                defer tile.end();
                ui.icon(c, k.icon, .{ .size = 20, .frame = 24, .weight = .semibold, .color = .hex(k.hue) });
            }
            const words = ui.div(c).column().grow().gap(4);
            defer words.end();
            ui.text(c, k.title, .{ .size = 16, .weight = .semibold, .color = ink });
            ui.text(c, k.time, .{ .size = 12, .weight = .semibold, .color = muted, .tabular = true });
        }
        _ = kit.tabs(c, &kinds, &t.draft_kind, .{ .variant = .pill });
        {
            const box = ui.div(c).column().wFull().px(16).py(6).rounded(22).bg(ui.Color.white.alpha(0.75));
            defer box.end();
            switchRow(c, "flame.fill", .hex(0xff3b30), "Urgent", &t.draft_urgent);
            kit.separator(c, .{});
            switchRow(c, "bell.fill", .hex(0x2f78c4), "Remind me", &t.draft_remind);
        }
        if (kit.button(c, "Add task", .{ .variant = .primary, .size = .lg, .pill = true, .full_width = true, .icon = "plus" }).clicked) {
            t.add();
            t.sheet = false;
        }
    }
};

/// A row of the sheet: an icon, a label, and a switch at the end.
fn switchRow(c: *ui.Context, icon: []const u8, col: ui.Color, label: []const u8, on: *bool) void {
    const r = ui.div(c).row().wFull().h(48).gap(12).itemsCenter();
    defer r.end();
    ui.icon(c, icon, .{ .size = 15, .frame = 20, .color = col });
    ui.text(c, label, .{ .size = 16, .weight = .medium, .color = ink });
    ui.spacer(c);
    _ = ui.toggle(c, "", on);
}

/// A soft wash of color behind the top of the page, for the glass to
/// bend: three blurred discs.
fn wash(c: *ui.Context) void {
    const w = c.size.w;
    const blobs = [_]struct { x: f32, y: f32, r: f32, hue: u24 }{
        .{ .x = -40, .y = -60, .r = 90, .hue = 0xff8a65 },
        .{ .x = w - 160, .y = -40, .r = 90, .hue = 0x7c83ff },
        .{ .x = w * 0.3, .y = 40, .r = 60, .hue = 0x5ad1a5 },
    };
    for (blobs) |b| {
        const col = ui.Color.hex(b.hue);
        const d = ui.div(c).absolute().offset(b.x, b.y).w(2 * b.r).h(2 * b.r).roundedFull().bg(col.alpha(0))
            .shadow(.{ .color = col.alpha(0.45), .blur = 70 });
        d.end();
    }
}

/// A round box with a 44-point target: grey ring, or green with a white
/// check the moment it's tapped, on a spring that gives. True when tapped.
fn checkbox(c: *ui.Context, on: bool) bool {
    const f = motion.frame(c, .{ .press = .{ .scale = 0.86 }, .transition = .{ .spring = motion.Spring.bouncy } });
    const hit = ui.div(c).w(44).h(44).center().control().motion(f);
    defer hit.end();
    const pop = motion.frame(c, .{ .target = .{ .scale = if (on) 1 else 0.92 }, .transition = .{ .spring = motion.Spring.bouncy } });
    const box = if (on)
        ui.div(c).w(26).h(26).roundedFull().bg(green).center().motion(pop)
    else
        ui.div(c).w(26).h(26).roundedFull().border(line).borderW(1.5).center().motion(pop);
    defer box.end();
    if (on) ui.icon(c, "checkmark", .{ .size = 12, .weight = .bold, .color = .white });
    return hit.clicked();
}
