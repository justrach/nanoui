//! OneMap's ways there (bus and MRT): the options and one way's legs,
//! with live waits for its buses, and what the map shows of a way.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const cards = @import("cards.zig");
const onemap = @import("onemap.zig");
const journey = @import("journey.zig");
const App = @import("main.zig").App;

const ink = cards.ink;
const gray = cards.gray;

fn label(c: *ui.Context, t: []const u8) void {
    ui.text(c, t, .{ .size = 13, .color = gray, .wrap = true });
}

fn minutes(sec: f64) u32 {
    return @intFromFloat(@round(sec / 60));
}

/// A bus service's black badge, or an MRT line's in its colour.
fn badge(c: *ui.Context, leg: *const onemap.Leg) void {
    if (leg.mode == .bus) return cards.badge(c, leg.routeOf());
    const d = ui.div(c).minW(44).px(8).py(4).rounded(8).bg(.hex(onemap.lineColor(leg.routeOf()))).justifyCenter().itemsCenter();
    ui.text(c, leg.routeOf(), .{ .size = 17, .weight = .semibold, .color = .white });
    d.end();
}

fn note(c: *ui.Context, j: *const journey.Journey) void {
    if (j.om_state == .sample) label(c, "Sample answer from OneMap's API docs (Farrer Park to Labrador Park), not your trip: there is no OneMap token here.") else label(c, "Bus and MRT ways from OneMap. Bus waits are live from LTA.");
}

/// Minutes to the next bus of `leg` at its first stop, if LTA has one.
fn liveWait(s: *App, leg: *const onemap.Leg) ?i64 {
    if (leg.mode != .bus) return null;
    const b = s.live.want(leg.from.codeOf()) orelse return null;
    const sv = b.find(leg.routeOf()) orelse return null;
    const bus = sv.buses[0] orelse return null;
    return b.minutes(bus);
}

/// OneMap's way `i` as a card in the merged list, with `tag` if any.
pub fn wayCard(s: *App, c: *ui.Context, i: usize, tag: ?[]const u8) void {
    const j = &s.journey;
    const it = &j.om[i];
    const box = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(10);
    defer box.end();
    if (box.clicked()) {
        j.om_chosen = i;
        nanoui.haptics.selection();
    }
    {
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer top.end();
        ui.text(c, c.print("{d}", .{minutes(it.seconds)}), .{ .size = 28, .weight = .semibold, .color = ink, .tabular = true });
        ui.text(c, "min", .{ .size = 17, .color = ink });
        ui.div(c).grow().end();
        if (tag) |t| {
            const chip = ui.div(c).px(10).py(4).rounded(10).bg(cards.yellow);
            ui.text(c, t, .{ .size = 13, .weight = .semibold, .color = ink });
            chip.end();
        }
    }
    const row = ui.div(c).row().wFull().gap(6).itemsCenter();
    var first = true;
    for (it.legs[0..it.n], 0..) |*leg, k| {
        c.next_key_int = k;
        if (leg.mode == .walk) continue;
        if (!first) label(c, "›");
        first = false;
        badge(c, leg);
    }
    row.end();
    const fare = if (it.fare_len > 0) c.print("· ${s}", .{it.fareOf()}) else "";
    label(c, c.print("OneMap · walk {d} m · {d} change{s} {s}", .{ @as(u32, @intFromFloat(it.walk_m)), it.transfers, if (it.transfers == 1) "" else "s", fare }));
}

pub fn noteOf(c: *ui.Context, j: *const journey.Journey) void {
    note(c, j);
}

pub fn legs(s: *App, c: *ui.Context, it: *const onemap.Itinerary) void {
    const j = &s.journey;
    {
        const top = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer top.end();
        ui.text(c, c.print("{d}", .{minutes(it.seconds)}), .{ .size = 28, .weight = .semibold, .color = ink, .tabular = true });
        ui.text(c, "min", .{ .size = 17, .color = ink });
        if (it.fare_len > 0) label(c, c.print("· ${s}", .{it.fareOf()}));
    }
    const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(14);
    for (it.legs[0..it.n], 0..) |*leg, k| {
        c.next_key_int = k;
        const row = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer row.end();
        if (leg.mode == .walk) {
            const dot = ui.div(c).w(44).justifyCenter().row();
            ui.div(c).size(10, 10).roundedFull().bg(.hex(0xC7C7CC)).end();
            dot.end();
        } else badge(c, leg);
        const col = ui.div(c).column().grow();
        defer col.end();
        const to = if (leg.to.name_len > 0) leg.to.nameOf() else "the end";
        switch (leg.mode) {
            .walk => ui.text(c, c.print("Walk {d} m to {s}", .{ @as(u32, @intFromFloat(leg.meters)), to }), .{ .size = 17, .color = ink, .wrap = true }),
            .bus => ui.text(c, c.print("Bus {s} from {s} to {s}", .{ leg.routeOf(), leg.from.nameOf(), to }), .{ .size = 17, .color = ink, .wrap = true }),
            else => ui.text(c, c.print("{s} line from {s} to {s}", .{ leg.routeOf(), leg.from.nameOf(), to }), .{ .size = 17, .color = ink, .wrap = true }),
        }
        if (liveWait(s, leg)) |m| label(c, if (m <= 0) "Bus arriving, live" else c.print("Next bus in {d} min, live", .{m})) else label(c, c.print("{d} min", .{minutes(leg.seconds)}));
    }
    card.end();
    note(c, j);
}

/// The map's line through each leg's ends, and a pin at each stop or station.
pub fn mapOf(s: *App, it: *const onemap.Itinerary, pins: []map.Pin, line: *std.ArrayList(map.Coord)) struct { []map.Pin, map.Camera } {
    line.clearRetainingCapacity();
    var n: usize = 0;
    var lo: map.Coord = .{ .lat = 90, .lng = 180 };
    var hi: map.Coord = .{ .lat = -90, .lng = -180 };
    for (it.legs[0..it.n], 0..) |*leg, k| {
        for ([2]*const onemap.Place{ &leg.from, &leg.to }) |p| {
            const at = p.at orelse continue;
            const pt: map.Coord = .{ .lat = at.lat, .lng = at.lng };
            if (line.items.len == 0 or !std.meta.eql(line.items[line.items.len - 1], pt)) line.append(s.gpa, pt) catch {};
            lo = .{ .lat = @min(lo.lat, pt.lat), .lng = @min(lo.lng, pt.lng) };
            hi = .{ .lat = @max(hi.lat, pt.lat), .lng = @max(hi.lng, pt.lng) };
            if (leg.mode != .walk and p.code_len > 0 and n + 1 < pins.len) {
                pins[n] = .{ .id = 300000 + k * 2 + @intFromBool(p == &leg.to), .at = pt, .label = p.codeOf(), .selected = n == 0 };
                n += 1;
            }
        }
    }
    const center: map.Coord = if (line.items.len > 0) .{ .lat = (lo.lat + hi.lat) / 2, .lng = (lo.lng + hi.lng) / 2 } else s.here;
    const span = if (line.items.len > 0) @max(hi.lat - lo.lat, hi.lng - lo.lng) * 1.4 + 0.006 else 0.02;
    return .{ pins[0..n], .{ .center = center, .span = span } };
}
