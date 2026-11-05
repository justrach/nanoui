//! Follow this journey: one trip as a stop-by-stop timeline, built for a
//! glance. After the Duo subway layout in
//! https://x.com/proskuaaa/status/2118020447220441184, for Singapore's
//! buses and trains.
//!
//! - One thing to do now, always at the top ("Stay on EW to Tanah
//!   Merah"), with the time left beside the title. Nothing to hunt for.
//! - One timeline, no second summary: past stops faded with how long ago,
//!   the stop you're at a big dot in its line's colour, the rest with
//!   their clock times, and the next buses live at every bus you board.
//!   A change is its own block ("Change to CG"), and the line takes the
//!   new line's colour from there.
//! - It never scrolls by itself. When the stop you're at is off screen,
//!   the button by "Follow this journey" turns from green to yellow, and
//!   tapping it takes you back (instantly, the one jump there is).
//! - Calm and dark, high contrast, solid cards; glass only on what floats.
//!   Colour fades are the only motion, and with Reduce Motion they snap.
//!
//! Unfolded: the map in the left pane, the timeline in the right, a rail
//! of actions on its outer edge. Half open: the map and what to do now on
//! the top half, the timeline and Follow on the bottom. Folded: the map
//! above the timeline, and the tab bar as usual.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const raptor = @import("raptor.zig");
const cards = @import("cards.zig");
const nextbus = @import("nextbus.zig");
const nav_view = @import("nav_view.zig");
const App = @import("main.zig").App;

// A calm dark palette, high contrast on it.
pub const ground: ui.Color = .hex(0x0E0F12);
pub const card: ui.Color = .hex(0x1C1D22);
pub const raised: ui.Color = .hex(0x2A2B31);
pub const ink: ui.Color = .hex(0xF5F5F7);
pub const muted: ui.Color = .hex(0xA4A5AD);
pub const faint: ui.Color = .hex(0x6C6D74);
pub const on_track: ui.Color = .hex(0x30D158);
pub const away: ui.Color = cards.yellow;
pub const walk_gray: ui.Color = .hex(0x8E8E93);
/// A bus ride's line: the yellow of Singapore's stop poles, so a change
/// between a bus and the (green) East West Line still shows.
pub const bus_line: ui.Color = cards.yellow;

pub const Kind = enum { origin, walk, board, stop, alight, change, dest };

pub const Row = struct {
    kind: Kind,
    /// The ride (board, stop, alight, change) or walk (walk) it is part of.
    leg: u8 = 0,
    stop: u16 = 0,
    pos: u16 = 0,
    /// Planned minutes from the start.
    at: f64 = 0,
    /// The line from this row down to the next.
    color: ui.Color = walk_gray,
};

pub const Mode = enum { folded, side, stacked };

pub const max_rows = 192;

pub const Follow = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    cur: usize = 0,
    last_cur: ?usize = null,
    /// `Live.now` when each row was passed while following (0: not seen).
    passed: [max_rows]f64 = @splat(0),
    list_id: u64 = 0,
    cur_id: u64 = 0,
    /// The current row was on screen last frame.
    on_screen: bool = true,
    alerts: bool = true,
    saved: bool = false,
    copied_at: f64 = -100,
    /// Where you set off from, kept once you follow (you move on).
    origin_buf: [96]u8 = undefined,
    origin_len: usize = 0,
    /// Folded: the steps behind you shown in full.
    show_past: bool = false,

    fn add(f: *Follow, r: Row) void {
        if (f.n == max_rows) return;
        f.rows[f.n] = r;
        f.n += 1;
    }

    /// The rows of trip `t`, with planned times from the start.
    pub fn build(f: *Follow, s: *App, t: raptor.Option) void {
        const d = s.d;
        f.n = 0;
        var at: f64 = 0;
        f.add(.{ .kind = .origin, .color = if (t.walks[0] >= 30 or t.n == 0) walk_gray else legColor(s, t.rides[0].svc) });
        if (t.walks[0] >= 30) f.add(.{ .kind = .walk, .leg = 0, .color = walk_gray });
        for (0..t.n) |i| {
            const r = t.rides[i];
            const col = legColor(s, r.svc);
            const li: u8 = @intCast(i);
            if (i > 0) f.add(.{ .kind = .change, .leg = li, .at = at, .color = if (t.walks[i] >= 30) walk_gray else col });
            at += raptor.walkMin(t.walks[i]) + t.waits[i];
            const dir = d.services[r.svc].dirs[r.dir];
            f.add(.{ .kind = .board, .leg = li, .stop = dir[r.from], .pos = r.from, .at = at, .color = col });
            var total: f64 = 0;
            for (r.from..r.to) |p| total += raptor.segMin(d, r.svc, r.dir, p);
            const scale = if (total > 0) t.ride_min[i] / total else 0;
            var run: f64 = 0;
            for (r.from..r.to) |p| {
                run += raptor.segMin(d, r.svc, r.dir, p) * scale;
                const pos: u16 = @intCast(p + 1);
                const last = pos == r.to;
                f.add(.{ .kind = if (last) .alight else .stop, .leg = li, .stop = dir[pos], .pos = pos, .at = at + run, .color = if (last) walk_gray else col });
            }
            at += t.ride_min[i];
        }
        const end_walk = raptor.walkMin(t.walks[t.n]);
        if (t.walks[t.n] >= 30) f.add(.{ .kind = .walk, .leg = t.n, .at = at, .color = walk_gray });
        f.add(.{ .kind = .dest, .leg = t.n, .at = @max(at + end_walk, t.arrive), .color = .transparent });
    }

    fn find(f: *const Follow, kind: Kind, leg: usize) ?usize {
        for (f.rows[0..f.n], 0..) |r, i| if (r.kind == kind and r.leg == leg) return i;
        return null;
    }

    fn findPos(f: *const Follow, leg: usize, pos: u16) ?usize {
        for (f.rows[0..f.n], 0..) |r, i| if ((r.kind == .board or r.kind == .stop or r.kind == .alight) and r.leg == leg and r.pos == pos) return i;
        return null;
    }

    /// Where you are on the timeline: from turn by turn while following,
    /// else the start.
    fn locate(f: *const Follow, s: *App) usize {
        const nv = &s.nav;
        if (!nv.on or f.n == 0) return 0;
        if (nv.done) return f.n - 1;
        if (nv.cur >= nv.steps.items.len) return 0;
        const st = nv.steps.items[nv.cur];
        const n = nv.trip.n;
        return switch (st.kind) {
            .turn, .to_stop => if (st.leg == 0) f.find(.walk, 0) orelse 0 else if (st.leg >= n) f.find(.walk, n) orelse f.n - 1 else f.find(.change, st.leg) orelse 0,
            .ride => blk: {
                if (!nv.onBoard(st.leg, s.here)) break :blk f.find(.board, st.leg) orelse 0;
                const r = nv.trip.rides[st.leg];
                const k = nv.stopsLeft(st.leg, s.here);
                break :blk f.findPos(st.leg, r.to - k) orelse 0;
            },
            .arrive => f.find(.walk, n) orelse f.n - 1,
        };
    }

    /// Each frame: the rows, where you are, what you've passed.
    pub fn update(f: *Follow, s: *App, t: raptor.Option) void {
        f.build(s, t);
        const cur = @min(f.locate(s), f.n -| 1);
        if (!s.nav.on) {
            f.passed = @splat(0);
            f.last_cur = null;
        } else if (f.last_cur) |last| {
            if (cur > last) {
                for (last..cur) |i| if (f.passed[i] == 0) {
                    f.passed[i] = s.live.now;
                };
                if (f.alerts and (f.rows[cur].kind == .alight or f.rows[cur].kind == .change or (cur + 1 < f.n and f.rows[cur + 1].kind == .alight))) nanoui.haptics.notify(.warning);
            }
        }
        if (s.nav.on) f.last_cur = cur;
        f.cur = cur;
    }

    /// Minutes left to the door.
    fn left(f: *const Follow) f64 {
        if (f.n == 0) return 0;
        return @max(0, f.rows[f.n - 1].at - f.rows[f.cur].at);
    }
};

/// A ride's colour: its MRT or LRT line's, or bus yellow.
pub fn legColor(s: *const App, svc: u16) ui.Color {
    return if (s.d.services[svc].rail) |l| .hex(l.color) else bus_line;
}

/// "EW", "CG", "NS": how a line is said on the platform signs.
fn short(id: []const u8) []const u8 {
    const m = [_][2][]const u8{ .{ "NSL", "NS" }, .{ "EWL", "EW" }, .{ "CGL", "CG" }, .{ "NEL", "NE" }, .{ "CCL", "CC" }, .{ "DTL", "DT" }, .{ "TEL", "TE" }, .{ "BPL", "BP" }, .{ "SKE", "Sengkang LRT" }, .{ "SKW", "Sengkang LRT" }, .{ "PGE", "Punggol LRT" }, .{ "PGW", "Punggol LRT" } };
    for (m) |x| if (std.mem.eql(u8, x[0], id)) return x[1];
    return id;
}

/// "EW" for a train, "bus 24" for a bus.
fn svcName(s: *App, c: *ui.Context, svc: u16) []const u8 {
    const sv = s.d.services[svc];
    if (sv.rail) |l| return short(l.id);
    return c.print("bus {s}", .{sv.no});
}

fn towards(s: *App, r: raptor.Ride) []const u8 {
    const dir = s.d.services[r.svc].dirs[r.dir];
    return s.d.stops[dir[dir.len - 1]].name;
}

fn stopName(s: *App, stop: u16) []const u8 {
    return s.d.stops[stop].name;
}

fn hm(c: *ui.Context, secs: f64) []const u8 {
    const t: u32 = @intFromFloat(@mod(secs, 86400));
    return c.print("{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60 });
}

fn mins(v: f64) u32 {
    return @intFromFloat(@max(0, @round(v)));
}

/// The trip being shown: the one followed, else the one chosen.
pub fn tripOf(s: *App) ?raptor.Option {
    if (s.nav.on) return s.nav.trip;
    return s.journey.trip();
}

fn originName(s: *App) []const u8 {
    if (s.nav.on and s.follow.origin_len > 0) return s.follow.origin_buf[0..s.follow.origin_len];
    return if (s.near.len > 0) s.d.stops[s.near[0]].name else "here";
}

fn destName(s: *App) []const u8 {
    if (s.nav.on) return s.nav.destName();
    return if (s.journey.dest) |*d| d.name() else "";
}

/// The bus stop's live board for ride `leg`: next buses' minutes.
fn liveMins(s: *App, t: raptor.Option, leg: usize) ?struct { nextbus.Mins, [3]?@import("live.zig").Bus } {
    const r = t.rides[leg];
    const sv = s.d.services[r.svc];
    if (sv.rail != null) return null;
    const code = s.d.stops[raptor.stopAt(s.d, r.svc, r.dir, r.from)].code;
    const b = s.live.want(code) orelse return null;
    if (b.state != .ok) return null;
    const x = b.find(sv.no) orelse return null;
    var m: nextbus.Mins = .{ null, null, null };
    var buses: [3]?@import("live.zig").Bus = .{ null, null, null };
    for (x.buses, 0..) |bus, k| if (bus) |y| {
        m[k] = b.minutesF(y);
        buses[k] = y;
    };
    if (nextbus.count(m) == 0) return null;
    return .{ m, buses };
}

/// The one thing to do now, and a line of detail under it.
fn action(s: *App, c: *ui.Context, f: *const Follow, t: raptor.Option) [2][]const u8 {
    const cur = f.rows[f.cur];
    switch (cur.kind) {
        .origin, .walk => {
            if (cur.kind == .walk and cur.leg == t.n) return .{ c.print("Walk {d} min to {s}", .{ mins(raptor.walkMin(t.walks[t.n])), destName(s) }), "Last bit, on foot" };
            if (t.n == 0) return .{ c.print("Walk to {s}", .{destName(s)}), "" };
            const r = t.rides[0];
            const st = raptor.stopAt(s.d, r.svc, r.dir, r.from);
            if (t.walks[0] >= 30) return .{ c.print("Walk {d} min to {s}", .{ @max(1, mins(raptor.walkMin(t.walks[0]))), stopName(s, st) }), c.print("Then board {s} towards {s}", .{ svcName(s, c, r.svc), towards(s, r) }) };
            return boardAction(s, c, t, 0);
        },
        .board => return boardAction(s, c, t, cur.leg),
        .stop => {
            const r = t.rides[cur.leg];
            const k = r.to - cur.pos;
            const off = stopName(s, raptor.stopAt(s.d, r.svc, r.dir, r.to));
            if (k <= 1) return .{ c.print("Get off at the next stop: {s}", .{off}), if (cur.leg + 1 < t.n) c.print("Then change to {s}", .{svcName(s, c, t.rides[cur.leg + 1].svc)}) else "Then walk to the end" };
            return .{ c.print("Stay on {s} to {s}", .{ svcName(s, c, r.svc), off }), c.print("{d} more stops", .{k}) };
        },
        .alight => {
            if (cur.leg + 1 < t.n) {
                const r2 = t.rides[cur.leg + 1];
                return .{ c.print("Get off here. Change to {s}", .{svcName(s, c, r2.svc)}), c.print("Towards {s}", .{towards(s, r2)}) };
            }
            return .{ "Get off here", c.print("Then walk to {s}", .{destName(s)}) };
        },
        .change => {
            const r = t.rides[cur.leg];
            const w = raptor.walkMin(t.walks[cur.leg]);
            return .{ c.print("Change here to {s}", .{svcName(s, c, r.svc)}), if (w >= 1) c.print("Walk {d} min, then towards {s}", .{ mins(w), towards(s, r) }) else c.print("Towards {s}", .{towards(s, r)}) };
        },
        .dest => return .{ "You're there", destName(s) },
    }
}

fn boardAction(s: *App, c: *ui.Context, t: raptor.Option, leg: usize) [2][]const u8 {
    const r = t.rides[leg];
    const st = raptor.stopAt(s.d, r.svc, r.dir, r.from);
    if (s.d.services[r.svc].rail) |l| {
        const h = raptor.rail.headway(l, raptor.isPeak(s.journey.planNow()));
        return .{ c.print("Board the {s} towards {s}", .{ short(l.id), towards(s, r) }), c.print("At {s} · a train about every {d} min", .{ stopName(s, st), mins(h) }) };
    }
    const no = s.d.services[r.svc].no;
    if (liveMins(s, t, leg)) |got| {
        for (got[0]) |x| if (x) |v| if (v > -1) {
            if (v <= 1) return .{ c.print("Board {s} now: it's arriving", .{no}), c.print("At {s} ({s})", .{ stopName(s, st), s.d.stops[st].code }) };
            return .{ c.print("Board {s} in {d} min", .{ no, @as(u32, @intFromFloat(@floor(v))) }), c.print("At {s} ({s}), towards {s}", .{ stopName(s, st), s.d.stops[st].code, towards(s, r) }) };
        };
    }
    return .{ c.print("Board {s} towards {s}", .{ no, towards(s, r) }), c.print("At {s} ({s})", .{ stopName(s, st), s.d.stops[st].code }) };
}

// ---------------------------------------------------------------- the map

/// The map pane: the trip on a dark map, and its floating pills.
pub fn mapPane(s: *App, c: *ui.Context, sa: ui.Edges, mode: Mode) void {
    const t = tripOf(s) orelse return;
    const f = &s.follow;
    const host = ui.div(c).sizeFull();
    defer host.end();
    const box = c.rects.get(host.id()) orelse ui.Rect{ .w = c.size.w, .h = c.size.h };
    var pins: [12]map.Pin = undefined;
    var lines: [12]map.Line = undefined;
    var opts: map.Options = .{ .user = true };
    if (s.nav.on) {
        opts = nav_view.mapOpts(s, &pins, &lines);
    } else {
        s.journey.line(t, &s.line);
        opts.pins = s.journey.pins(t, &pins);
        opts.lines = s.journey.lines(t, &s.line, &lines);
        opts.camera = s.journey.camera();
    }
    s.line_for = null;
    // Each ride in its line's colour, buses yellow (as the timeline).
    var ride: usize = 0;
    for (@constCast(opts.lines)) |*l| if (!l.dashed and ride < t.n) {
        l.color = legColor(s, t.rides[ride].svc);
        ride += 1;
    };
    opts.dark = true;
    s.m.view(c, opts);
    // Solid pills: glass can't see through to MapKit.
    const x0 = 12 + sa.left;
    const y0 = sa.top + 12;
    {
        const from = originName(s);
        const pill = ui.div(c).absolute().offset(x0, y0).row().gap(8).itemsCenter().px(14).h(40).rounded(20).bg(card).shadowMd().maxW(@max(120, box.w - 32 - 150 - sa.left - sa.right));
        ui.text(c, c.print("{s} → {s}", .{ from, destName(s) }), .{ .size = 15, .weight = .semibold, .color = ink, .truncate = .ellipsis });
        pill.end();
    }
    {
        // Edit and Share, small, top right.
        const btns = ui.div(c).absolute().offset(box.w - 12 - sa.right - 150, y0).row().w(150).gap(8).justifyEnd();
        defer btns.end();
        const edit = ui.div(c).px(14).h(40).rounded(20).bg(card).shadowMd().justifyCenter().itemsCenter();
        ui.text(c, if (s.nav.on) "End" else "Edit", .{ .size = 15, .weight = .semibold, .color = ink });
        if (edit.clicked()) {
            s.nav.stop();
            s.journey.going = false;
            s.journey.chosen = null;
            nanoui.haptics.impact(.light);
        }
        edit.end();
        const share = ui.div(c).px(14).h(40).rounded(20).bg(card).shadowMd().justifyCenter().itemsCenter();
        const copied = s.live.now - f.copied_at < 2;
        ui.text(c, if (copied) "Copied" else "Share", .{ .size = 15, .weight = .semibold, .color = if (copied) on_track else ink });
        if (share.clicked()) {
            c.clipboard.write(c.clipboard.ctx, summary(s, c, t));
            f.copied_at = s.live.now;
            nanoui.haptics.notify(.success);
        }
        share.end();
    }
    if (mode == .stacked) {
        // Half open: what to do now rides on the top half, by the map.
        const w = @min(420, box.w * 0.5);
        const hd = ui.div(c).absolute().offset(x0, y0 + 52).column().w(w).gap(10).p(14).rounded(16).bg(card).shadowMd();
        header(s, c, t, mode);
        hd.end();
        return;
    }
    // The next change, floating low on the map.
    if (nextChange(s, c, f, t)) |p| {
        const pill = ui.div(c).absolute().offset(x0, box.h - 12 - 40 - @as(f32, if (mode == .folded) 0 else sa.bottom)).row().gap(8).itemsCenter().px(14).h(40).rounded(20).bg(card).shadowMd().maxW(box.w - 24);
        ui.div(c).size(12, 12).roundedFull().bg(p[1]).end();
        ui.text(c, p[0], .{ .size = 15, .weight = .semibold, .color = ink, .truncate = .ellipsis });
        pill.end();
    }
}

/// "Next change: CG at Tanah Merah · 3 stops", or where to get off.
fn nextChange(s: *App, c: *ui.Context, f: *const Follow, t: raptor.Option) ?struct { []const u8, ui.Color } {
    var k: usize = 0;
    var i = f.cur + 1;
    while (i < f.n) : (i += 1) {
        const r = f.rows[i];
        if (r.kind == .stop or r.kind == .alight) k += 1;
        if (r.kind == .change) {
            const rr = t.rides[r.leg];
            const at = stopName(s, raptor.stopAt(s.d, rr.svc, rr.dir, rr.from));
            return .{ c.print("Next change: {s} at {s}{s}", .{ svcName(s, c, rr.svc), at, if (k > 0) c.print(" · {d} stop{s}", .{ k, if (k == 1) "" else "s" }) else "" }), legColor(s, rr.svc) };
        }
    }
    if (t.n == 0) return null;
    const last = t.rides[t.n - 1];
    return .{ c.print("No more changes · off at {s}", .{stopName(s, raptor.stopAt(s.d, last.svc, last.dir, last.to))}), legColor(s, last.svc) };
}

/// The trip in words, for Share.
fn summary(s: *App, c: *ui.Context, t: raptor.Option) []const u8 {
    var buf = c.print("{s:<400}", .{""});
    var w: std.Io.Writer = .fixed(@constCast(buf));
    w.print("To {s}, about {d} min:", .{ destName(s), mins(t.arrive) }) catch {};
    for (0..t.n) |i| {
        const r = t.rides[i];
        w.print(" {s} {s} from {s} to {s}{s}", .{ if (i == 0) "" else "then", svcName(s, c, r.svc), stopName(s, raptor.stopAt(s.d, r.svc, r.dir, r.from)), stopName(s, raptor.stopAt(s.d, r.svc, r.dir, r.to)), if (i + 1 < t.n) "," else "." }) catch break;
    }
    buf = w.buffered();
    return buf;
}

// ----------------------------------------------------------- the timeline

const rail_w: f32 = 64;

/// Title, time left, and the one thing to do now.
fn header(s: *App, c: *ui.Context, t: raptor.Option, mode: Mode) void {
    const f = &s.follow;
    const big = mode == .side;
    if (mode == .folded) {
        // Folded: one line for where to and the time left.
        const top = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer top.end();
        const tw = ui.div(c).column().grow().minW(0);
        ui.text(c, destName(s), .{ .size = 22, .weight = .bold, .color = ink, .truncate = .ellipsis });
        tw.end();
        timeLeft(s, c, f, false);
    } else {
        ui.text(c, destName(s), .{ .size = if (big) 34 else 22, .weight = .bold, .color = ink, .wrap = true });
        timeLeft(s, c, f, big);
    }
    const a = action(s, c, f, t);
    const col = f.rows[f.cur].color;
    const now_card = ui.div(c).row().wFull().gap(12).rounded(16).bg(if (mode == .stacked) raised else card).p(14).itemsStretch().shadowMd();
    defer now_card.end();
    ui.div(c).w(6).rounded(3).bg(if (f.rows[f.cur].kind == .dest) on_track else if (col.a == 0) walk_gray else col).end();
    const words = ui.div(c).column().grow().gap(4);
    defer words.end();
    ui.text(c, "DO THIS NOW", .{ .size = 13, .weight = .bold, .color = muted });
    ui.text(c, a[0], .{ .size = if (big) 26 else 20, .weight = .bold, .color = ink, .wrap = true });
    if (a[1].len > 0) ui.text(c, a[1], .{ .size = 15, .color = muted, .wrap = true });
}

/// Time left: always in view, never behind a tap.
fn timeLeft(s: *App, c: *ui.Context, f: *const Follow, big: bool) void {
    const pill = ui.div(c).row().gap(10).px(14).h(40).rounded(20).bg(raised).itemsCenter();
    defer pill.end();
    ui.text(c, c.print("{d} min left", .{mins(f.left())}), .{ .size = if (big) 20 else 17, .weight = .bold, .color = ink, .tabular = true });
    if (s.live.clock()) |now| ui.text(c, c.print("arrive {s}", .{hm(c, now + f.left() * 60)}), .{ .size = 15, .weight = .medium, .color = muted, .tabular = true });
}

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
