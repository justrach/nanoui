//! The Journey tab's three screens: where to (From and To), the ways
//! there, and one way's legs with a Go button.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const router = @import("router.zig");
const cards = @import("cards.zig");
const journey = @import("journey.zig");
const omv = @import("onemap_view.zig");
const App = @import("main.zig").App;

const ink = cards.ink;
const gray = cards.gray;

pub fn view(s: *App, c: *ui.Context) void {
    const j = &s.journey;
    if (j.omTrip()) |it| {
        backRow(s, c, "‹ Ways there", false);
        return omv.legs(s, c, it);
    }
    if (j.trip()) |t| return legs(s, c, t);
    if (j.dest != null and j.usingOneMap()) {
        backRow(s, c, "‹ Go where?", true);
        ui.text(c, c.print("To {s}", .{j.dest.?.name()}), .{ .size = 28, .weight = .semibold, .color = ink, .wrap = true });
        return omv.options(s, c);
    }
    if (j.dest != null) return options(s, c);
    form(s, c);
}

fn label(c: *ui.Context, t: []const u8) void {
    ui.text(c, t, .{ .size = 13, .color = gray });
}

fn form(s: *App, c: *ui.Context) void {
    const j = &s.journey;
    ui.text(c, "Go where?", .{ .size = 28, .weight = .semibold, .color = ink });
    {
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(4);
        defer card.end();
        label(c, "From");
        ui.text(c, "Current location", .{ .size = 17, .weight = .semibold, .color = ink });
        if (s.near.len > 0) label(c, c.print("near {s}", .{s.d.stops[s.near[0]].name}));
        ui.div(c).wFull().h(1).bg(cards.ground).end();
        label(c, "To");
        _ = ui.textField(c, &j.to, .{ .placeholder = "A place, a stop, a postal code", .width = .fill, .size = 17, .bare = true, .color = ink });
    }
    const q = std.mem.trim(u8, j.to.text(), " ");
    j.search(s.gpa, q);
    if (q.len == 0) {
        label(c, "Type where you're going. Places come from OneMap.");
        return;
    }
    for (j.places[0..j.n_places], 0..) |*p, i| {
        c.next_key_int = i;
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(2);
        ui.text(c, p.name(), .{ .size = 17, .weight = .semibold, .color = ink, .truncate = .ellipsis });
        const near = s.d.nearest(p.at, router.walk_radius, s.scratch[0..1]);
        label(c, if (near.len > 0) c.print("OneMap · near {s}", .{s.d.stops[near[0]].name}) else "OneMap · no stop within 450 m");
        if (card.clicked()) j.go(p.*);
        card.end();
    }
    var buf: [3]u16 = undefined;
    for (s.d.search(q, &buf), 0..) |st, i| {
        c.next_key_int = 100 + i;
        const card = ui.div(c).row().wFull().rounded(22).bg(.white).p(16).gap(10).itemsCenter();
        cards.chip(c, s.d.stops[st].code, false);
        ui.text(c, s.d.stops[st].name, .{ .size = 17, .color = ink, .truncate = .ellipsis });
        if (card.clicked()) j.go(.init(s.d.stops[st].name, s.d.stops[st].at, st));
        card.end();
    }
    if (j.inflight) label(c, "Searching OneMap...");
}

fn backRow(s: *App, c: *ui.Context, t: []const u8, to_form: bool) void {
    const row = ui.div(c).row().gap(8).itemsCenter().px(14).py(8).rounded(18).bg(.white);
    ui.text(c, t, .{ .size = 15, .weight = .semibold, .color = ink });
    if (row.clicked()) {
        if (to_form) s.journey.dest = null else {
            s.journey.chosen = null;
            s.journey.om_chosen = null;
        }
        s.journey.going = false;
    }
    row.end();
}

fn options(s: *App, c: *ui.Context) void {
    const j = &s.journey;
    backRow(s, c, "‹ Go where?", true);
    ui.text(c, c.print("To {s}", .{j.dest.?.name()}), .{ .size = 28, .weight = .semibold, .color = ink, .wrap = true });
    if (j.n_trips == 0) {
        label(c, "No bus there within a walk leh. Try a place nearer a stop.");
        return;
    }
    var evals: [3]journey.Eval = undefined;
    var order: [3]usize = .{ 0, 1, 2 };
    for (j.trips[0..j.n_trips], 0..) |t, i| evals[i] = j.evaluate(t);
    std.mem.sort(usize, order[0..j.n_trips], &evals, struct {
        fn lt(e: *const [3]journey.Eval, a: usize, b: usize) bool {
            return e[a].total < e[b].total;
        }
    }.lt);
    for (order[0..j.n_trips], 0..) |ti, rank| {
        const t = j.trips[ti];
        const e = evals[ti];
        c.next_key_int = ti;
        const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(10);
        defer card.end();
        if (card.clicked()) {
            j.chosen = ti;
            nanoui.haptics.selection();
        }
        {
            const top = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer top.end();
            ui.motion.roll(c, "total", c.print("{d}", .{@as(u32, @intFromFloat(@round(e.total)))}), .{ .size = 28, .weight = .semibold, .color = ink }, .{});
            ui.text(c, "min", .{ .size = 17, .color = ink });
            const sp = ui.div(c).grow();
            sp.end();
            if (rank == 0) {
                const tag = ui.div(c).px(10).py(4).rounded(10).bg(cards.yellow);
                ui.text(c, "Fastest leh", .{ .size = 13, .weight = .semibold, .color = ink });
                tag.end();
            }
        }
        const row = ui.div(c).row().wFull().gap(6).itemsCenter();
        if (t.walks[0] >= 30) label(c, c.print("Walk {d} ›", .{@as(u32, @intFromFloat(@ceil(router.walkMin(t.walks[0]))))}));
        for (0..t.n) |i| {
            c.next_key_int = i;
            if (i > 0) label(c, "›");
            cards.badge(c, s.d.services[t.rides[i].svc].no);
        }
        row.end();
        const wait = e.waits[0];
        const when = if (e.live[0]) c.print("next bus in {d} min", .{@as(u32, @intFromFloat(@round(wait)))}) else "no live time, about 8 min wait";
        if (journey.clockText(c, s, e.total)) |at| label(c, c.print("Arrive {s} · {s}", .{ at, when })) else label(c, when);
    }
    label(c, switch (j.om_state) {
        .asking => "Asking OneMap for bus and MRT ways...",
        .failed => c.print("OneMap answered {d}, so these are bus only, planned on this phone. Ride times are estimates.", .{j.om_status}),
        else => if (j.token == null) "Bus only, planned on this phone from LTA stop lists: OneMap's bus and MRT routing needs a token. Ride times are estimates." else "Bus only, planned on this phone. Ride times are estimates.",
    });
}

fn legs(s: *App, c: *ui.Context, t: router.Trip) void {
    const j = &s.journey;
    const e = j.evaluate(t);
    backRow(s, c, "‹ Ways there", false);
    {
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer top.end();
        ui.motion.roll(c, "trip", c.print("{d}", .{@as(u32, @intFromFloat(@round(e.total)))}), .{ .size = 28, .weight = .semibold, .color = ink }, .{});
        ui.text(c, "min", .{ .size = 17, .color = ink });
        if (journey.clockText(c, s, e.total)) |at| label(c, c.print("· arrive {s}", .{at}));
    }
    const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(14);
    var n: usize = 0;
    for (0..t.n) |i| {
        const r = t.rides[i];
        const a = s.d.stops[router.stopAt(s.d, r.svc, r.dir, r.from)];
        const b = s.d.stops[router.stopAt(s.d, r.svc, r.dir, r.to)];
        if (t.walks[i] >= 30) step(c, &n, null, c.print("Walk {d} m to {s}", .{ @as(u32, @intFromFloat(t.walks[i])), a.name }), c.print("{d} min", .{@as(u32, @intFromFloat(@ceil(router.walkMin(t.walks[i]))))}));
        const wait = if (e.live[i]) c.print("in {d} min, live", .{@as(u32, @intFromFloat(@round(e.waits[i])))}) else "about 8 min, no live time";
        step(c, &n, s.d.services[r.svc].no, c.print("From {s} ({s})", .{ a.name, a.code }), wait);
        step(c, &n, null, c.print("Get off at {s} ({s})", .{ b.name, b.code }), c.print("{d} stops, about {d} min", .{ r.to - r.from, @as(u32, @intFromFloat(@round(e.rides[i]))) }));
    }
    if (t.walks[t.n] >= 30) step(c, &n, null, c.print("Walk {d} m to {s}", .{ @as(u32, @intFromFloat(t.walks[t.n])), j.dest.?.name() }), c.print("{d} min", .{@as(u32, @intFromFloat(@ceil(router.walkMin(t.walks[t.n]))))}));
    card.end();
    const go = ui.div(c).row().wFull().justifyCenter().itemsCenter().h(56).roundedFull().bg(if (j.going) cards.yellow else ink);
    ui.text(c, if (j.going) "Going. Watch for the bus" else "Go", .{ .size = 17, .weight = .semibold, .color = if (j.going) ink else .white });
    if (go.clicked()) {
        j.going = true;
        nanoui.haptics.notify(.success);
    }
    go.end();
}

fn step(c: *ui.Context, n: *usize, svc: ?[]const u8, what: []const u8, detail: []const u8) void {
    c.next_key_int = n.*;
    n.* += 1;
    const row = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer row.end();
    if (svc) |no| cards.badge(c, no) else {
        const dot = ui.div(c).w(44).justifyCenter().row();
        ui.div(c).size(10, 10).roundedFull().bg(.hex(0xC7C7CC)).end();
        dot.end();
    }
    const col = ui.div(c).column().grow();
    ui.text(c, what, .{ .size = 17, .color = ink, .wrap = true });
    label(c, detail);
    col.end();
}
