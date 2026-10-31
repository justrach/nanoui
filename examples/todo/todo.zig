//! The to-do list's state and its view. Light, quiet and roomy: an
//! off-white canvas, white cards with a soft shadow, a 24-point gutter,
//! four type sizes (32, 20, 16, 12, and 14 for the dates and the Add pill)
//! in two weights besides the headings', tabular digits, 44-point targets,
//! and corners that nest (a tile's radius is its card's less the padding).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const week = @import("week.zig");

pub const Task = struct {
    title: []const u8,
    time: []const u8,
    icon: []const u8,
    hue: u24,
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

/// What the Add buttons add, in turn.
const more = [_]Task{
    .{ .title = "Write release notes", .time = "3:30 PM", .icon = "doc.text.fill", .hue = 0x5e5ce6 },
    .{ .title = "Gym", .time = "6:00 PM", .icon = "figure.run", .hue = 0x30b0c7 },
    .{ .title = "Read 20 pages", .time = "9:00 PM", .icon = "book.fill", .hue = 0xff9500 },
};

pub const Todo = struct {
    tasks: [8]Task = undefined,
    count: usize = 5,
    added: usize = 0,
    tab: usize = 1,
    started: bool = false,

    fn start(t: *Todo) void {
        t.tasks[0..5].* = .{
            .{ .title = "Reply to client emails", .time = "9:00 AM", .icon = "envelope.fill", .hue = 0x0a84ff },
            .{ .title = "Daily stand-up", .time = "9:15 AM", .icon = "briefcase.fill", .hue = 0xa2672f },
            .{ .title = "Design review with PM", .time = "10:30 AM", .icon = "star.fill", .hue = 0xffb300 },
            .{ .title = "Fix onboarding flow", .time = "12:00 PM", .icon = "safari.fill", .hue = 0x2f80ed },
            .{ .title = "Sprint planning call", .time = "2:00 PM", .icon = "calendar", .hue = 0xff453a },
        };
        t.started = true;
    }

    fn add(t: *Todo) void {
        if (t.count == t.tasks.len) return;
        t.tasks[t.count] = more[t.added % more.len];
        t.count += 1;
        t.added += 1;
    }

    pub fn done(t: *const Todo) usize {
        var n: usize = 0;
        for (t.tasks[0..t.count]) |k| n += @intFromBool(k.done);
        return n;
    }

    /// The order the cards stand in: the tasks still to do as they were
    /// written, then the ones done in the order they were done. A task
    /// just checked keeps its place for `settle`, greyed, then moves.
    fn order(t: *Todo, c: *ui.Context, out: []usize) []usize {
        var n: usize = 0;
        var waiting = false;
        for (t.tasks[0..t.count], 0..) |k, i| {
            const moved = k.done and c.time - k.done_at >= settle;
            if (k.done and !moved) waiting = true;
            if (!moved) {
                out[n] = i;
                n += 1;
            }
        }
        const first_done = n;
        for (t.tasks[0..t.count], 0..) |k, i| {
            if (k.done and c.time - k.done_at >= settle) {
                out[n] = i;
                n += 1;
            }
        }
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
        {
            const sc = ui.div(c).column().sizeFull().scrollY().pt(safe.top + 20).pb(safe.bottom + 112);
            defer sc.end();
            {
                const head = ui.div(c).column().wFull().px(gutter).gap(16);
                defer head.end();
                ui.text(c, "To-do list", .{ .size = 32, .weight = .bold, .color = ink });
                week.strip(c, t.done(), t.count);
            }
            t.planHeader(c);
            t.cards(c);
        }
        t.tabBar(c);
    }

    fn planHeader(t: *Todo, c: *ui.Context) void {
        const r = ui.div(c).row().wFull().px(gutter).pt(24).pb(8).itemsCenter();
        defer r.end();
        ui.text(c, "Today\u{2019}s plan", .{ .size = 20, .weight = .bold, .color = ink });
        ui.spacer(c);
        // A 32-point pill in a 44-point target.
        const give = motion.frame(c, .{ .press = .{ .scale = 0.94 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const hit = ui.div(c).h(44).itemsCenter().control().motion(give);
        defer hit.end();
        if (hit.clicked()) t.add();
        const pill = ui.div(c).row().h(32).px(12).gap(4).roundedFull().bg(soft).itemsCenter();
        defer pill.end();
        ui.text(c, "Add", .{ .size = 14, .weight = .semibold, .color = ui.Color.hex(0x6b6e76) });
        ui.icon(c, "plus", .{ .size = 12, .weight = .bold, .color = ui.Color.hex(0x6b6e76) });
    }

    fn cards(t: *Todo, c: *ui.Context) void {
        var buf: [8]usize = undefined;
        const list = ui.div(c).column().wFull().px(gutter).gap(12);
        defer list.end();
        for (t.order(c, &buf)) |i| {
            const k = &t.tasks[i];
            ui.key(c, c.print("task-{d}", .{i}));
            const f = motion.frame(c, .{
                .initial = .{ .y = 16, .opacity = 0 },
                .delay = if (c.frame < 3) motion.stagger(i, 0.05) else 0,
                .layout = true,
                .transition = .{ .spring = glide() },
            });
            const card = ui.div(c).row().wFull().h(76).pl(card_pad).pr(4).gap(14).itemsCenter().rounded(card_radius).bg(.white)
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
                const words = ui.div(c).column().grow().gap(4);
                defer words.end();
                ui.text(c, k.title, .{ .size = 16, .weight = .semibold, .color = ink.mix(ui.Color.hex(0xc4c6cb), grey), .truncate = .ellipsis });
                const when = ui.div(c).row().gap(4).itemsCenter();
                defer when.end();
                const tint = muted.mix(ui.Color.hex(0xcdcfd4), grey);
                ui.icon(c, "clock.fill", .{ .size = 11, .frame = 12, .color = tint });
                ui.text(c, k.time, .{ .size = 12, .weight = .semibold, .color = tint, .tabular = true });
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
        // The + overlaps the bar's end by 12 points; the bar keeps its tabs clear of it.
        const pill_w = w - 2 * gutter - plus_size + 12;
        {
            const pill = ui.div(c).absolute().offset(gutter, y + 6).w(pill_w).h(64).row().p(6).pr(18).gap(2).roundedFull().bg(.white)
                .shadow(.{ .color = .{ .a = 0.08 }, .blur = 24, .y = 8 });
            defer pill.end();
            const tabs = [_][2][]const u8{ .{ "Home", "house.fill" }, .{ "Tasks", "checklist" }, .{ "Calendar", "calendar" }, .{ "Stats", "chart.bar.fill" } };
            for (tabs, 0..) |tab, i| {
                const on = t.tab == i;
                // The pill's radius less its padding: 32 - 6.
                const f = motion.frame(c, .{
                    .target = .{ .background = if (on) soft else ui.Color.hex(0xeeeff1).alpha(0) },
                    .press = .{ .scale = 0.94 },
                    .transition = .{ .spring = motion.Spring.snappy },
                });
                const item = ui.div(c).column().grow().hFull().gap(2).rounded(26).center().control().motion(f);
                defer item.end();
                if (item.clicked()) t.tab = i;
                const col = if (on) ink else muted;
                ui.icon(c, tab[1], .{ .size = 18, .frame = 22, .weight = .semibold, .color = col });
                ui.text(c, tab[0], .{ .size = 12, .weight = .semibold, .color = col });
            }
        }
        // The big + overlaps the bar's end.
        const f = motion.frame(c, .{ .press = .{ .scale = 0.9 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const plus = ui.div(c).absolute().offset(w - gutter - plus_size, y).w(plus_size).h(plus_size).roundedFull().bg(ink)
            .shadow(.{ .color = .{ .a = 0.22 }, .blur = 20, .y = 8 }).center().control().motion(f);
        defer plus.end();
        if (plus.clicked()) t.add();
        ui.icon(c, "plus", .{ .size = 24, .weight = .semibold, .color = .white });
    }
};

/// A round box with a 44-point target: grey ring, or green with a white
/// check the moment it's tapped. True when tapped.
fn checkbox(c: *ui.Context, on: bool) bool {
    const f = motion.frame(c, .{ .press = .{ .scale = 0.86 }, .transition = .{ .spring = motion.Spring.bouncy } });
    const hit = ui.div(c).w(44).h(44).center().control().motion(f);
    defer hit.end();
    const box = if (on)
        ui.div(c).w(26).h(26).roundedFull().bg(green).center()
    else
        ui.div(c).w(26).h(26).roundedFull().border(line).borderW(1.5).center();
    defer box.end();
    if (on) ui.icon(c, "checkmark", .{ .size = 12, .weight = .bold, .color = .white });
    return hit.clicked();
}
