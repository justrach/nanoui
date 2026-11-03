//! The trip in turn by turn: the step to do now on a solid card, how far
//! to go in big type, the next step under it, and on a Duo opened flat
//! the rest of the way in the second pane. Text wraps: nothing runs off.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const cards = @import("cards.zig");
const navm = @import("nav.zig");
const nextbus = @import("nextbus.zig");
const App = @import("main.zig").App;

const ink = cards.ink;
const gray = cards.gray;

/// Type sizes: bigger on the big screen.
const Type = struct { big: f32, title: f32, sub: f32 };

pub fn view(s: *App, c: *ui.Context, wide: bool) void {
    const nv = &s.nav;
    const ty: Type = if (wide) .{ .big = 40, .title = 24, .sub = 15 } else .{ .big = 28, .title = 20, .sub = 15 };
    {
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer top.end();
        const end = ui.div(c).row().gap(8).itemsCenter().px(14).py(8).rounded(18).bg(.white);
        ui.text(c, "‹ End", .{ .size = 15, .weight = .semibold, .color = ink });
        if (end.clicked()) {
            nv.stop();
            s.journey.going = false;
            nanoui.haptics.impact(.light);
        }
        end.end();
        ui.div(c).grow().end();
        if (nv.steps.items.len > 0 and !nv.done) ui.text(c, c.print("Step {d} of {d}", .{ nv.cur + 1, nv.steps.items.len }), .{ .size = 13, .color = gray });
    }
    ui.text(c, c.print("To {s}", .{nv.destName()}), .{ .size = if (wide) 40 else 28, .weight = .semibold, .color = ink, .wrap = true });
    if (nv.asking()) {
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(6).shadowMd();
        ui.text(c, "Asking Apple Maps for the walks...", .{ .size = ty.title, .weight = .semibold, .color = ink, .wrap = true });
        card.end();
        return;
    }
    if (nv.done) {
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(6).shadowMd();
        ui.text(c, "You're there", .{ .size = ty.big, .weight = .semibold, .color = ink });
        ui.text(c, nv.destName(), .{ .size = ty.title, .color = ink, .wrap = true });
        card.end();
        return;
    }
    if (nv.cur >= nv.steps.items.len) return;
    current(s, c, nv.cur, ty);
    if (nv.cur + 1 < nv.steps.items.len) {
        ui.text(c, "Then", .{ .size = 13, .weight = .semibold, .color = gray });
        // The next buses go on the Then card while you walk towards a
        // stop, unless the card above already has them.
        const nx = nv.steps.items[nv.cur + 1];
        const here_has = waitsFor(s, nv.steps.items[nv.cur]);
        const times: ?u8 = if (waitsFor(s, nx) != null and (here_has == null or here_has.? != nx.leg)) nx.leg else null;
        later(s, c, nv.cur + 1, 17, times);
    }
    if (wide and nv.cur + 2 < nv.steps.items.len) {
        ui.text(c, "After that", .{ .size = 13, .weight = .semibold, .color = gray });
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(14);
        defer card.end();
        for (nv.steps.items[nv.cur + 2 ..], nv.cur + 2..) |_, k| {
            c.next_key_int = k;
            row(s, c, k, 15);
        }
    }
}

/// The step to do now.
fn current(s: *App, c: *ui.Context, k: usize, ty: Type) void {
    const nv = &s.nav;
    const st = nv.steps.items[k];
    const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(8).shadowMd();
    defer card.end();
    {
        const top = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer top.end();
        icon(s, c, st);
        const far = farText(s, c, st);
        ui.text(c, far, .{ .size = ty.big, .weight = .semibold, .color = ink, .tabular = true });
    }
    ui.text(c, title(s, c, st, true), .{ .size = ty.title, .weight = .semibold, .color = ink, .wrap = true });
    const sub = subText(s, c, st);
    if (sub.len > 0) ui.text(c, sub, .{ .size = ty.sub, .color = gray, .wrap = true });
    if (waitsFor(s, st)) |leg| nextOnes(s, c, leg, ty.sub);
}

/// The next step, on its own card, with the next buses or trains for
/// ride `times` when it has them.
fn later(s: *App, c: *ui.Context, k: usize, size: f32, times: ?u8) void {
    const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(10);
    defer card.end();
    row(s, c, k, size);
    if (times) |leg| nextOnes(s, c, leg, 15);
}

/// The ride a step waits for: walking to its stop, or at it, not yet on.
fn waitsFor(s: *App, st: navm.Step) ?u8 {
    return switch (st.kind) {
        .to_stop => st.leg,
        .ride => if (s.nav.onBoard(st.leg, s.here)) null else st.leg,
        else => null,
    };
}

/// Minutes' walk left to ride `leg`'s stop (none once you're at it).
fn walkLeft(s: *App, leg: u8) f64 {
    const m = data.meters(s.here, s.nav.ends(leg)[1]);
    return if (m < 25) 0 else raptor.walkMin(m);
}

/// The next buses at the stop, live, or the trains, estimated.
fn nextOnes(s: *App, c: *ui.Context, leg: u8, size: f32) void {
    const nv = &s.nav;
    const r = nv.trip.rides[leg];
    const sv = s.d.services[r.svc];
    const walk = walkLeft(s, leg);
    const box = ui.div(c).column().wFull().gap(8).p(12).rounded(16).bg(cards.ground);
    defer box.end();
    if (sv.rail) |l| return nextTrains(s, c, l, walk, size);
    const code = s.d.stops[nv.boardStop(leg)].code;
    const b = s.live.want(code) orelse return ui.text(c, "No live times", .{ .size = size, .color = gray });
    if (b.state == .loading) return ui.text(c, "Getting live times...", .{ .size = size, .color = gray });
    var m: nextbus.Mins = .{ null, null, null };
    var buses: [3]?@import("live.zig").Bus = .{ null, null, null };
    if (b.state == .ok) if (b.find(sv.no)) |x| for (x.buses, 0..) |bus, k| if (bus) |y| {
        m[k] = b.minutesF(y);
        buses[k] = y;
    };
    if (nextbus.count(m) == 0) return ui.text(c, "No live times", .{ .size = size, .weight = .semibold, .color = ink });
    var lb: [96]u8 = undefined;
    ui.text(c, c.print("{s}", .{nextbus.line(&lb, sv.no, m)}), .{ .size = size + 2, .weight = .semibold, .color = ink, .tabular = true, .wrap = true });
    const k = nextbus.catchable(m, walk);
    {
        const chips = ui.div(c).row().gap(8).itemsCenter();
        defer chips.end();
        for (buses, 0..) |bus, i| if (bus) |y| if (m[i].? > -1) {
            c.next_key_int = i;
            const on = k != null and k.? == i;
            const missed = k == null or i < k.?;
            const ch = ui.div(c).row().gap(6).itemsCenter().px(10).py(6).rounded(12).bg(if (on) ink else .white);
            var tb: [16]u8 = undefined;
            ui.text(c, c.print("{s}", .{nextbus.one(&tb, m[i].?)}), .{ .size = 15, .weight = .semibold, .tabular = true, .color = if (on) .white else if (missed) gray else ink });
            cards.loadBars(c, y.load);
            if (!y.wab) ui.text(c, "no ramp", .{ .size = 13, .color = if (on) .white else gray });
            ch.end();
        };
    }
    var mb: [128]u8 = undefined;
    if (nextbus.missLine(&mb, m, walk)) |t| ui.text(c, c.print("{s}", .{t}), .{ .size = size, .weight = .semibold, .color = cards.red, .wrap = true });
    ui.text(c, "Live from LTA, every 20 s", .{ .size = 13, .color = gray });
}

/// Trains by the phone's clock: about every N min (not live), or none
/// until the first train.
fn nextTrains(s: *App, c: *ui.Context, l: *const data.Line, walk: f64, size: f32) void {
    var now = s.journey.planNow();
    const clock = now.clock orelse {
        ui.text(c, c.print("A train about every {d} min", .{@as(u32, @intFromFloat(@round(raptor.rail.headway(l, true))))}), .{ .size = size + 2, .weight = .semibold, .color = ink });
        return ui.text(c, "Estimated from timetables, not live", .{ .size = 13, .color = gray });
    };
    // When you'll be on the platform.
    const at = clock + (walk + raptor.rail.entry_min) * 60;
    now.clock = at;
    var hb: [8]u8 = undefined;
    switch (nextbus.trains(l, at, raptor.isPeak(now))) {
        .every => |h| {
            ui.text(c, c.print("A train about every {d} min", .{@as(u32, @intFromFloat(@round(h)))}), .{ .size = size + 2, .weight = .semibold, .color = ink });
            ui.text(c, "Estimated from timetables, not live", .{ .size = 13, .color = gray });
        },
        .closed => |f| {
            const now_open = nextbus.trains(l, clock, false) == .every;
            if (now_open) {
                ui.text(c, c.print("Last train about {s}: you may miss it", .{nextbus.hm(&hb, raptor.rail.last_min)}), .{ .size = size + 2, .weight = .semibold, .color = cards.red, .wrap = true });
            } else ui.text(c, c.print("No trains now, first train about {s}", .{nextbus.hm(&hb, f)}), .{ .size = size + 2, .weight = .semibold, .color = cards.red, .wrap = true });
            var hb2: [8]u8 = undefined;
            ui.text(c, c.print("Trains run about {s} to {s}. Check for a night bus.", .{ nextbus.hm(&hb2, f), nextbus.hm(&hb, raptor.rail.last_min) }), .{ .size = 13, .color = gray, .wrap = true });
        },
    }
}

fn row(s: *App, c: *ui.Context, k: usize, size: f32) void {
    const st = s.nav.steps.items[k];
    const r = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer r.end();
    icon(s, c, st);
    const col = ui.div(c).column().grow();
    defer col.end();
    ui.text(c, title(s, c, st, false), .{ .size = size, .color = ink, .wrap = true });
}

fn icon(s: *App, c: *ui.Context, st: navm.Step) void {
    switch (st.kind) {
        .ride => {
            const sv = s.d.services[s.nav.trip.rides[st.leg].svc];
            if (sv.rail) |l| cards.lineBadge(c, l.id, l.color) else cards.badge(c, sv.no);
        },
        else => {
            const d = ui.div(c).minW(44).px(8).py(4).rounded(8).bg(.hex(0x1A73E8)).justifyCenter().itemsCenter();
            ui.text(c, if (st.kind == .arrive) "End" else "Walk", .{ .size = 15, .weight = .semibold, .color = .white });
            d.end();
        },
    }
}

fn meters(c: *ui.Context, m: f64) []const u8 {
    if (m >= 1000) return c.print("{d:.1} km", .{m / 1000});
    // Tens of meters, as a sign would say.
    const r: u32 = @intFromFloat(@max(10, @round(m / 10) * 10));
    return c.print("{d} m", .{r});
}

/// How far to go: to the turn, the stop, the door; or stops left.
fn farText(s: *App, c: *ui.Context, st: navm.Step) []const u8 {
    if (st.kind == .ride) {
        const left = s.nav.stopsLeft(st.leg, s.here);
        if (left == 0) return "Get off here";
        return c.print("{d} stop{s}", .{ left, if (left == 1) "" else "s" });
    }
    return meters(c, data.meters(s.here, st.at));
}

fn stopName(s: *App, c: *ui.Context, stop: u16, svc: u16) []const u8 {
    return c.print("{s} ({s})", .{ s.d.stops[stop].name, raptor.rail.codeOn(s.d, stop, svc) });
}

/// What to do: "Walk 120 m, then turn left onto Jurong Gateway Rd",
/// "Board 66 at Blk 123 (83139), 4 stops, alight at ..."; `now` counts
/// from where you are, else from where the step starts.
fn title(s: *App, c: *ui.Context, st: navm.Step, now: bool) []const u8 {
    const nv = &s.nav;
    switch (st.kind) {
        .turn => {
            // `st` is a copy on this stack: print its words before returning them.
            const t = st.text();
            if (!now) return c.print("{s}", .{t});
            const lower = if (t.len > 0) c.print("{c}{s}", .{ std.ascii.toLower(t[0]), t[1..] }) else t;
            return c.print("Walk {s}, then {s}", .{ meters(c, data.meters(s.here, st.at)), lower });
        },
        .to_stop => {
            const i = st.leg;
            const svc = nv.trip.rides[i].svc;
            const where = stopName(s, c, nv.boardStop(i), svc);
            return if (now) c.print("Walk {s} to {s}", .{ meters(c, data.meters(s.here, st.at)), where }) else c.print("Walk to {s}", .{where});
        },
        .ride => {
            const i = st.leg;
            const r = nv.trip.rides[i];
            const sv = s.d.services[r.svc];
            const to = stopName(s, c, nv.alightStop(i), r.svc);
            const stops = r.to - r.from;
            const pl = if (stops == 1) "" else "s";
            const on = now and nv.onBoard(i, s.here);
            if (sv.rail) |l| {
                if (on) return c.print("Ride the {s} to {s}", .{ l.id, to });
                return c.print("Ride the {s} to {s}, {d} stop{s}", .{ l.id, to, stops, pl });
            }
            if (on) return c.print("Ride {s} to {s}", .{ sv.no, to });
            return c.print("Board {s} at {s}, {d} stop{s}, alight at {s}", .{ sv.no, stopName(s, c, nv.boardStop(i), r.svc), stops, pl, to });
        },
        .arrive => return if (now) c.print("Walk {s} to {s}", .{ meters(c, data.meters(s.here, st.at)), nv.destName() }) else c.print("Arrive at {s}", .{nv.destName()}),
    }
}

/// The smaller line under it: which way a train goes, the wait, the source.
fn subText(s: *App, c: *ui.Context, st: navm.Step) []const u8 {
    const nv = &s.nav;
    return switch (st.kind) {
        .turn => "Walking directions from Apple Maps",
        .to_stop, .arrive => if (!st.apple) "Straight line, our own estimate: Apple Maps had no walk here" else "Walking directions from Apple Maps",
        .ride => blk: {
            const i = st.leg;
            const r = nv.trip.rides[i];
            const sv = s.d.services[r.svc];
            const dir = sv.dirs[r.dir];
            const end = s.d.stops[dir[dir.len - 1]].name;
            if (nv.onBoard(i, s.here)) break :blk c.print("Get off at {s}", .{stopName(s, c, nv.alightStop(i), r.svc)});
            if (sv.rail) |l| break :blk c.print("{s} towards {s}, from {s}", .{ l.name, end, stopName(s, c, nv.boardStop(i), r.svc) });
            break :blk c.print("Towards {s}", .{end});
        },
    };
}

/// What the map shows in turn by turn: the way, its stops, and you.
pub fn mapOpts(s: *App, pins: []map.Pin, lines: []map.Line) map.Options {
    const nv = &s.nav;
    var n: usize = 0;
    const t = nv.trip;
    for (0..t.n) |i| {
        const r = t.rides[i];
        for ([2]u16{ nv.boardStop(i), nv.alightStop(i) }) |st| {
            var dup = false;
            for (pins[0..n]) |p| if (p.id == st) {
                dup = true;
            };
            if (dup or n + 2 >= pins.len) continue;
            pins[n] = .{ .id = st, .at = s.d.stops[st].at, .label = raptor.rail.codeOn(s.d, st, r.svc) };
            n += 1;
        }
    }
    pins[n] = .{ .id = 200000, .at = nv.dest, .label = "To here", .style = .bus };
    n += 1;
    const sim = nv.sim != null;
    if (sim) {
        pins[n] = .{ .id = 400000, .at = s.here, .label = "You", .style = .bus, .selected = true };
        n += 1;
    }
    const riding = nv.cur < nv.steps.items.len and nv.steps.items[nv.cur].kind == .ride and nv.onBoard(nv.steps.items[nv.cur].leg, s.here);
    return .{
        .pins = pins[0..n],
        .lines = nv.mapLines(lines),
        .user = !sim,
        .camera = .{ .center = s.here, .span = if (riding) 0.03 else 0.0045, .animated = !sim },
    };
}
