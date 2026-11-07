//! Follow this journey's timeline pane: the rows, Follow and the jump
//! back, and on two panes the rail. The model, the colours and the map pane
//! are in follow.zig.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const cards = @import("cards.zig");
const nextbus = @import("nextbus.zig");
const App = @import("main.zig").App;
const fz = @import("follow.zig");
const ground = fz.ground;
const card = fz.card;
const raised = fz.raised;
const ink = fz.ink;
const muted = fz.muted;
const faint = fz.faint;
const on_track = fz.on_track;
const away = fz.away;
const walk_gray = fz.walk_gray;
const bus_line = fz.bus_line;
const Row = fz.Row;
const Mode = fz.Mode;
const Follow = fz.Follow;
const legColor = fz.legColor;
const tripOf = fz.tripOf;
const short = fz.short;
const towards = fz.towards;
const stopName = fz.stopName;
const hm = fz.hm;
const mins = fz.mins;
const originName = fz.originName;
const destName = fz.destName;
const liveMins = fz.liveMins;
const rail_w = fz.rail_w;
const header = fz.header;

/// The timeline pane: header (unless the top half has it), the rows,
/// Follow and the jump back, and on two panes the rail.
pub fn listPane(s: *App, c: *ui.Context, sa: ui.Edges, mode: Mode) void {
    const t = tripOf(s) orelse return;
    const f = &s.follow;
    const host = ui.div(c).column().sizeFull().bg(ground);
    defer host.end();
    const box = c.rects.get(host.id()) orelse ui.Rect{ .w = c.size.w, .h = c.size.h };
    const two = mode != .folded;
    const right = sa.right + 16 + @as(f32, if (two) rail_w + 12 else 0);
    // Folded, the tab bar sits under Follow.
    const tab_room: f32 = if (mode == .folded) 64 + 8 else 0;
    const bar_h: f32 = 56;
    const bar_y = box.h - bar_h - @max(sa.bottom, 12) - tab_room;
    if (mode != .stacked) {
        const hd = ui.div(c).column().wFull().gap(12).pt(sa.top + 16).pl(sa.left + 16).pr(right).pb(4);
        header(s, c, t, mode);
        hd.end();
    }
    {
        const list = ui.div(c).column().wFull().grow().scrollY().pt(12).pl(sa.left + 16).pr(right).pb(box.h - bar_y + 16);
        defer list.end();
        f.list_id = list.id();
        // Folded there's little room: what's behind you folds into one
        // line (a tap shows it), so where you are sits near the top
        // without the list moving by itself.
        const fold_past = mode == .folded and !f.show_past and f.cur > 0;
        if (fold_past) {
            const k = f.cur;
            const more = ui.div(c).row().wFull().gap(12).itemsCenter().pb(10);
            ui.div(c).w(30).end();
            ui.text(c, c.print("{d} earlier step{s} · show", .{ k, if (k == 1) "" else "s" }), .{ .size = 15, .weight = .semibold, .color = muted });
            if (more.clicked()) f.show_past = true;
            more.end();
        }
        for (f.rows[0..f.n], 0..) |_, i| {
            if (fold_past and i < f.cur) continue;
            c.next_key_int = i;
            row(s, c, t, i, mode);
        }
        if (mode == .folded and f.show_past and f.cur > 0) {
            const less = ui.div(c).py(8);
            ui.text(c, "Hide earlier steps", .{ .size = 15, .weight = .semibold, .color = muted });
            if (less.clicked()) f.show_past = false;
            less.end();
        }
        if (!s.journey.sample) ui.text(c, "Bus times live from LTA. Train times and ride times are estimates.", .{ .size = 13, .color = faint, .wrap = true });
    }
    // Is where you are on screen? (Last frame's layout.)
    const lr = c.rects.get(f.list_id);
    const cr = c.rects.get(f.cur_id);
    if (lr != null and cr != null) {
        const bottom = @min(lr.?.y + lr.?.h, box.y + bar_y);
        // On screen: its dot and name clear of the top and of Follow.
        f.on_screen = cr.?.y + @min(cr.?.h, 40) > lr.?.y + 8 and cr.?.y + 40 < bottom;
    }
    // The rail sits mid-height, so Follow can run to the edge.
    followBar(s, c, box, sa, mode, bar_y, sa.right + 16);
    if (two) followRail(s, c, box, sa);
}

const status_w: f32 = 92;

fn followBar(s: *App, c: *ui.Context, box: ui.Rect, sa: ui.Edges, mode: Mode, y: f32, right: f32) void {
    const f = &s.follow;
    _ = mode;
    const w = box.w - (sa.left + 16) - right;
    const bar = ui.div(c).absolute().offset(sa.left + 16, y).row().w(w).h(56).gap(10);
    defer bar.end();
    {
        // Follow: glass, it floats over the list.
        const following = s.nav.on;
        const pill = ui.div(c).row().w(w - status_w - 10).hFull().roundedFull().glass(.{ .tint = (if (following) card else ink).alpha(0.9) }).shadowMd().justifyCenter().itemsCenter().gap(8).px(6);
        if (following) ui.div(c).size(10, 10).roundedFull().bg(on_track).end();
        ui.text(c, if (following) "Following" else "Follow this journey", .{ .size = 16, .weight = .bold, .color = if (following) ink else ground, .truncate = .ellipsis });
        if (pill.clicked() and !following) {
            if (s.journey.trip()) |t| {
                // Where it starts, kept before nav starts: once it's on,
                // originName gives back origin_buf itself (a follow
                // before this one), and copying that onto itself panics.
                const o = originName(s);
                const n = @min(o.len, f.origin_buf.len);
                @memcpy(f.origin_buf[0..n], o[0..n]);
                f.origin_len = n;
                s.journey.going = true;
                s.nav.start(t, s.journey.dest.?.at, s.journey.dest.?.name());
                f.passed = @splat(0);
                f.last_cur = null;
                nanoui.haptics.notify(.success);
            }
        }
        pill.end();
    }
    {
        // Green while where you are is on screen; yellow when you've
        // scrolled off it, and a tap takes you back.
        const k = ui.motion.number(c, "follow-away", if (f.on_screen) 0 else 1, .{ .tween = .{ .duration = 0.25 } });
        const col = on_track.mix(away, k);
        const b = ui.div(c).row().w(status_w).hFull().roundedFull().bg(col).shadowMd().justifyCenter().itemsCenter().gap(6);
        ui.text(c, if (f.on_screen) "● Now" else "↑ Back", .{ .size = 16, .weight = .bold, .color = ground });
        if (b.clicked()) jumpBack(s, c);
        b.end();
    }
}

/// Puts the row you're at near the top of the list: the one jump.
fn jumpBack(s: *App, c: *ui.Context) void {
    const f = &s.follow;
    const lr = c.rects.get(f.list_id) orelse return;
    const cr = c.rects.get(f.cur_id) orelse return;
    const off = c.scroll.get(f.list_id) orelse 0;
    c.scroll.put(c.gpa, f.list_id, @max(0, off + (cr.y - lr.y) - 24)) catch {};
    nanoui.haptics.selection();
    if (s.window) |w| w.redraw();
}

/// The rail on the outer edge: alerts, save, back to the ways.
fn followRail(s: *App, c: *ui.Context, box: ui.Rect, sa: ui.Edges) void {
    const f = &s.follow;
    const h: f32 = 3 * 60 + 12;
    const bar = ui.div(c).absolute().offset(box.w - rail_w - 8 - sa.right, @max(sa.top + 12, (box.h - h) / 2)).column().w(rail_w).h(h).p(6).gap(0).rounded(24).glass(.{ .tint = card.alpha(0.9) }).shadowMd();
    defer bar.end();
    const items = [_]struct { []const u8, []const u8, bool }{
        .{ "Alerts", if (f.alerts) "on" else "off", f.alerts },
        .{ "Save", if (f.saved) "saved" else "trip", f.saved },
        .{ "Ways", "back", false },
    };
    for (items, 0..) |it, i| {
        c.next_key_int = i;
        const b = ui.div(c).column().wFull().h(60).rounded(18).justifyCenter().itemsCenter().gap(2);
        if (it[2]) _ = b.bg(ink);
        ui.text(c, it[0], .{ .size = 13, .weight = .bold, .color = if (it[2]) ground else ink });
        ui.text(c, it[1], .{ .size = 11, .color = if (it[2]) ground else muted });
        if (b.clicked()) switch (i) {
            0 => {
                f.alerts = !f.alerts;
                nanoui.haptics.selection();
            },
            1 => {
                f.saved = !f.saved;
                s.kv.set("saved_trip", if (f.saved) destName(s) else "") catch {};
                nanoui.haptics.impact(.medium);
            },
            else => {
                s.nav.stop();
                s.journey.going = false;
                s.journey.chosen = null;
                nanoui.haptics.impact(.light);
            },
        };
        b.end();
    }
}

/// One row: the line and its dot on the left, the words on the right.
fn row(s: *App, c: *ui.Context, t: raptor.Option, i: usize, mode: Mode) void {
    const f = &s.follow;
    const r = f.rows[i];
    const past = i < f.cur;
    const here = i == f.cur;
    const in_col: ui.Color = if (i == 0) .transparent else f.rows[i - 1].color;
    const out_col = r.color;
    const big = mode == .side;
    const line = ui.div(c).row().wFull().gap(12).itemsStretch();
    defer line.end();
    if (past) _ = line.opacity(0.42);
    if (here) f.cur_id = line.id();
    {
        // The gutter: the line in, the dot, the line out.
        const dot: f32 = if (here) 26 else if (r.kind == .board or r.kind == .alight or r.kind == .change or r.kind == .dest or r.kind == .origin) 16 else 10;
        const g = ui.div(c).column().w(30).itemsCenter();
        defer g.end();
        ui.div(c).w(6).h(if (here) 8 else 12).bg(in_col).end();
        const ring = if (here) dotColor(r, in_col) else dotColor(r, in_col);
        const d = ui.div(c).size(dot, dot).roundedFull();
        if (here) {
            _ = d.bg(ring).border(ink).borderW(3).shadow(.{ .color = ring.alpha(0.75), .blur = 18, .y = 0, .spread = 4 });
        } else if (r.kind == .stop) {
            _ = d.bg(ground).border(ring).borderW(2);
        } else _ = d.bg(ring);
        d.end();
        ui.div(c).w(6).grow().bg(out_col).end();
    }
    const body = ui.div(c).column().grow().gap(4).pb(if (r.kind == .stop) 10 else 16).pt(if (here) 0 else 4);
    defer body.end();
    const name_size: f32 = if (here) (if (big) 24 else 20) else if (r.kind == .stop) 15 else 17;
    const when = whenText(s, c, i);
    switch (r.kind) {
        .origin => titleRow(c, c.print("From {s}", .{originName(s)}), when, name_size, here),
        .walk => {
            const m = raptor.walkMin(t.walks[r.leg]);
            const card_ = ui.div(c).column().wFull().rounded(16).bg(card).p(12).gap(2);
            defer card_.end();
            titleRow(c, c.print("Walk {d} min", .{@max(1, mins(m))}), when, name_size, here);
            const to = if (r.leg == t.n) destName(s) else stopName(s, raptor.stopAt(s.d, t.rides[r.leg].svc, t.rides[r.leg].dir, t.rides[r.leg].from));
            ui.text(c, c.print("{d} m to {s}", .{ @as(u32, @intFromFloat(t.walks[r.leg])), to }), .{ .size = 15, .color = muted, .wrap = true });
        },
        .board => {
            const rr = t.rides[r.leg];
            {
                const top = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer top.end();
                badge(s, c, rr.svc);
                ui.text(c, if (s.d.services[rr.svc].rail != null) "Board" else "Board the bus", .{ .size = 15, .weight = .semibold, .color = muted });
                ui.div(c).grow().end();
                if (!here) ui.text(c, when, .{ .size = 15, .weight = .semibold, .color = muted, .tabular = true });
            }
            ui.text(c, stopName(s, r.stop), .{ .size = name_size, .weight = .bold, .color = ink, .wrap = true });
            if (here) ui.text(c, when, .{ .size = 17, .weight = .bold, .color = ink, .tabular = true });
            ui.text(c, c.print("{s} · towards {s} · {d} stop{s}", .{ raptor.rail.codeOn(s.d, r.stop, rr.svc), towards(s, rr), rr.to - rr.from, if (rr.to - rr.from == 1) "" else "s" }), .{ .size = 15, .color = muted, .wrap = true });
            if (!past) liveRow(s, c, t, r.leg);
        },
        .stop => titleRow(c, stopName(s, r.stop), when, name_size, here),
        .alight => {
            titleRow(c, stopName(s, r.stop), when, name_size, here);
            ui.text(c, c.print("Get off here · {s}", .{raptor.rail.codeOn(s.d, r.stop, t.rides[r.leg].svc)}), .{ .size = 15, .weight = .semibold, .color = if (past) muted else ink });
        },
        .change => {
            const rr = t.rides[r.leg];
            const col = legColor(s, rr.svc);
            const blk = ui.div(c).column().wFull().rounded(16).bg(card).p(12).gap(4).border(col).borderW(2);
            defer blk.end();
            {
                const top = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer top.end();
                ui.text(c, "Change to", .{ .size = name_size, .weight = .bold, .color = ink });
                badge(s, c, rr.svc);
                ui.div(c).grow().end();
                if (!here) ui.text(c, when, .{ .size = 15, .weight = .semibold, .color = muted, .tabular = true });
            }
            if (here) ui.text(c, when, .{ .size = 17, .weight = .bold, .color = ink, .tabular = true });
            const w = raptor.walkMin(t.walks[r.leg]);
            ui.text(c, c.print("Towards {s} · ride {d} stop{s}", .{ towards(s, rr), rr.to - rr.from, if (rr.to - rr.from == 1) "" else "s" }), .{ .size = 15, .color = muted, .wrap = true });
            if (w >= 0.5) ui.text(c, c.print("Walk {d} min ({d} m) to {s}", .{ @max(1, mins(w)), @as(u32, @intFromFloat(t.walks[r.leg])), stopName(s, raptor.stopAt(s.d, rr.svc, rr.dir, rr.from)) }), .{ .size = 15, .color = muted, .wrap = true });
        },
        .dest => {
            titleRow(c, destName(s), when, if (here) name_size else 20, here);
            ui.text(c, "Your stop", .{ .size = 15, .color = muted });
        },
    }
}

fn dotColor(r: Row, in_col: ui.Color) ui.Color {
    return switch (r.kind) {
        .origin, .walk => walk_gray,
        .dest => on_track,
        .alight, .stop => if (in_col.a == 0) walk_gray else in_col,
        else => if (r.color.a == 0) walk_gray else r.color,
    };
}

fn titleRow(c: *ui.Context, name: []const u8, when: []const u8, size: f32, here: bool) void {
    if (here) {
        // Where you are: the name gets the whole width, the time under it.
        ui.text(c, name, .{ .size = size, .weight = .bold, .color = ink, .wrap = true });
        if (when.len > 0) ui.text(c, when, .{ .size = 17, .weight = .bold, .color = ink, .tabular = true });
        return;
    }
    const top = ui.div(c).row().wFull().gap(8).itemsStart();
    defer top.end();
    const nm = ui.div(c).column().grow().minW(0);
    ui.text(c, name, .{ .size = size, .weight = .medium, .color = ink, .wrap = true });
    nm.end();
    if (when.len > 0) ui.text(c, when, .{ .size = 15, .weight = .semibold, .color = muted, .tabular = true });
}

/// A row's time: "12m ago" behind you, "Now 22:04", or its clock time.
fn whenText(s: *App, c: *ui.Context, i: usize) []const u8 {
    const f = &s.follow;
    const r = f.rows[i];
    if (i < f.cur) {
        const secs = if (f.passed[i] > 0) s.live.now - f.passed[i] else (f.rows[f.cur].at - r.at) * 60;
        if (secs < 60) return "just now";
        return c.print("{d}m ago", .{@as(u32, @intFromFloat(secs / 60))});
    }
    const now = s.live.clock() orelse return if (i == f.cur) "Now" else c.print("+{d} min", .{mins(r.at - f.rows[f.cur].at)});
    if (i == f.cur) return c.print("Now {s}", .{hm(c, now)});
    return hm(c, now + (r.at - f.rows[f.cur].at) * 60);
}

fn badge(s: *App, c: *ui.Context, svc: u16) void {
    const sv = s.d.services[svc];
    if (sv.rail) |l| {
        const d = ui.div(c).minW(40).px(8).py(3).rounded(8).bg(.hex(l.color)).justifyCenter().itemsCenter();
        ui.text(c, short(l.id), .{ .size = 15, .weight = .bold, .color = .white });
        d.end();
    } else {
        const d = ui.div(c).minW(40).px(8).py(3).rounded(8).bg(bus_line).justifyCenter().itemsCenter();
        ui.text(c, sv.no, .{ .size = 15, .weight = .bold, .color = cards.ink, .tabular = true });
        d.end();
    }
}

/// The next buses at a bus you board, live, or the trains' rhythm.
fn liveRow(s: *App, c: *ui.Context, t: raptor.Option, leg: usize) void {
    const r = t.rides[leg];
    const sv = s.d.services[r.svc];
    const box = ui.div(c).row().wFull().gap(8).itemsCenter().pt(4);
    defer box.end();
    if (sv.rail) |l| {
        const h = raptor.rail.headway(l, raptor.isPeak(s.journey.planNow()));
        chipText(c, c.print("Every ~{d} min", .{mins(h)}), true);
        ui.text(c, "timetable, not live", .{ .size = 13, .color = faint });
        return;
    }
    const got = liveMins(s, t, leg) orelse {
        ui.text(c, "Getting live times...", .{ .size = 15, .color = muted });
        return;
    };
    const st = raptor.stopAt(s.d, r.svc, r.dir, r.from);
    const m = data.meters(s.here, s.d.stops[st].at);
    const walk = if (m < 25) 0 else raptor.walkMin(m);
    const k = nextbus.catchable(got[0], walk);
    var shown: usize = 0;
    for (got[0], 0..) |x, i| if (x) |v| if (v > -1 and shown < 3) {
        c.next_key_int = i;
        var tb: [16]u8 = undefined;
        chipText(c, c.print("{s}", .{nextbus.one(&tb, v)}), k != null and k.? == i);
        shown += 1;
    };
    ui.text(c, "live", .{ .size = 13, .weight = .semibold, .color = on_track });
}

fn chipText(c: *ui.Context, text: []const u8, on: bool) void {
    const d = ui.div(c).px(10).py(5).rounded(10).bg(if (on) ink else raised);
    ui.text(c, text, .{ .size = 15, .weight = .bold, .color = if (on) ground else ink, .tabular = true });
    d.end();
}
