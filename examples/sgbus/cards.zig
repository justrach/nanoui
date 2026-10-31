//! A stop's card: its code chip, name and star, then a row per service
//! with the minutes to its next bus rolling as they change, the two after
//! it, how full it is and what kind of bus. Solid white on the gray
//! ground; tapping the name chooses the stop (the map goes there), a
//! service's row opens its route.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const live = @import("live.zig");
const App = @import("main.zig").App;

pub const ink: ui.Color = .hex(0x111111);
pub const gray: ui.Color = .hex(0x6E6E73);
pub const yellow: ui.Color = .hex(0xFFD100);
pub const green: ui.Color = .hex(0x009645);
pub const orange: ui.Color = .hex(0xFA9E0D);
pub const red: ui.Color = .hex(0xD42E12);
pub const ground: ui.Color = .hex(0xF2F2F4);

pub fn chip(c: *ui.Context, code: []const u8, on: bool) void {
    const d = ui.div(c).px(8).py(3).rounded(7).bg(if (on) ink else yellow);
    ui.text(c, code, .{ .size = 13, .weight = .semibold, .tabular = true, .color = if (on) yellow else ink });
    d.end();
}

/// A train line's badge: its id on the line's colour.
pub fn lineBadge(c: *ui.Context, id: []const u8, color: u24) void {
    const d = ui.div(c).minW(44).px(8).py(4).rounded(8).bg(.hex(color)).justifyCenter().itemsCenter();
    ui.text(c, id, .{ .size = 17, .weight = .semibold, .color = .white });
    d.end();
}

pub fn badge(c: *ui.Context, no: []const u8) void {
    const d = ui.div(c).minW(44).px(8).py(4).rounded(8).bg(ink).justifyCenter().itemsCenter();
    ui.text(c, no, .{ .size = 17, .weight = .semibold, .tabular = true, .color = .white });
    d.end();
}

pub fn loadBars(c: *ui.Context, load: live.Load) void {
    const n: usize, const col: ui.Color = switch (load) {
        .sea => .{ 1, green },
        .sda => .{ 2, orange },
        .lsd => .{ 3, red },
        .unknown => .{ 0, gray },
    };
    const row = ui.div(c).row().gap(2).itemsEnd().h(14);
    for (0..3) |i| {
        c.next_key_int = i;
        ui.div(c).w(4).h(6 + 4 * @as(f32, @floatFromInt(i))).rounded(2).bg(if (i < n) col else .hex(0xD8D8DC)).end();
    }
    row.end();
}

/// "Arr", "~12" (an estimate) or "12", for a bus `m` minutes away.
pub fn mins(c: *ui.Context, m: i64, monitored: bool) []const u8 {
    if (m <= 0) return "Arr";
    return if (monitored) c.print("{d}", .{m}) else c.print("~{d}", .{m});
}

pub fn stopCard(s: *App, c: *ui.Context, idx: u16, on: bool) void {
    const st = s.d.stops[idx];
    c.next_key = st.code;
    const card = ui.div(c).column().wFull().rounded(22).bg(.white).p(16).gap(12);
    defer card.end();
    if (on) _ = card.border(ink).borderW(2);
    {
        const head = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer head.end();
        const name = ui.div(c).row().grow().gap(10).itemsCenter();
        chip(c, st.code, on);
        const words = ui.div(c).column().grow();
        ui.text(c, st.name, .{ .size = 17, .weight = .semibold, .color = ink, .truncate = .ellipsis });
        ui.text(c, st.road, .{ .size = 13, .color = gray, .truncate = .ellipsis });
        words.end();
        if (name.clicked()) s.choose(idx);
        name.end();
        const starred = s.isStarred(idx);
        const star = ui.div(c).size(36, 36).roundedFull().bg(if (starred) yellow else ground).justifyCenter().itemsCenter();
        ui.text(c, if (starred) "★" else "☆", .{ .size = 17, .color = ink });
        if (star.clicked()) s.toggleStar(idx);
        star.end();
    }
    const b = s.live.want(st.code) orelse return;
    switch (b.state) {
        .loading => return ui.text(c, "Getting times...", .{ .size = 13, .color = gray }),
        .failed => return ui.text(c, "Cannot connect leh. Pull down to try again.", .{ .size = 13, .color = gray }),
        .ok => {},
    }
    if (b.svcs.items.len == 0) return ui.text(c, "No bus now leh", .{ .size = 13, .color = gray });
    for (b.svcs.items, 0..) |*sv, i| {
        c.next_key_int = i;
        serviceRow(s, c, idx, b, sv);
    }
}

fn serviceRow(s: *App, c: *ui.Context, stop: u16, b: *const live.Board, sv: *const live.Svc) void {
    const row = ui.div(c).row().wFull().gap(12).itemsCenter().py(2);
    defer row.end();
    if (row.clicked()) s.openRoute(stop, sv.no());
    badge(c, sv.no());
    {
        const mid = ui.div(c).column().grow();
        defer mid.end();
        const to = if (s.d.find(sv.dest())) |di| s.d.stops[di].name else sv.dest();
        ui.text(c, c.print("to {s}", .{to}), .{ .size = 13, .color = gray, .truncate = .ellipsis });
        if (sv.buses[0]) |bus| {
            const tags = ui.div(c).row().gap(6);
            defer tags.end();
            if (bus.kind[0] == 'D') ui.text(c, "2 deck", .{ .size = 13, .color = gray });
            if (bus.kind[0] == 'B') ui.text(c, "bendy", .{ .size = 13, .color = gray });
            if (!bus.wab) ui.text(c, "no ramp", .{ .size = 13, .color = gray });
            var later: [2][]const u8 = .{ "", "" };
            var n: usize = 0;
            for (sv.buses[1..]) |nb| if (nb) |x| {
                later[n] = mins(c, @max(1, b.minutes(x)), x.monitored);
                n += 1;
            };
            if (n == 2) ui.text(c, c.print("then {s}, {s}", .{ later[0], later[1] }), .{ .size = 13, .color = gray, .tabular = true }) else if (n == 1) ui.text(c, c.print("then {s}", .{later[0]}), .{ .size = 13, .color = gray, .tabular = true });
        }
    }
    const bus = sv.buses[0] orelse return ui.text(c, "No bus now leh", .{ .size = 13, .color = gray });
    const m = b.minutes(bus);
    const right = ui.div(c).row().gap(8).itemsCenter();
    defer right.end();
    const color: ui.Color = if (m <= 0) green else if (bus.monitored) ink else gray;
    if (m < -1) {
        ui.text(c, "leaving liao", .{ .size = 13, .color = gray });
    } else {
        ui.motion.roll(c, c.print("m{s}{s}", .{ b.code(), sv.no() }), mins(c, m, bus.monitored), .{ .size = 28, .weight = .semibold, .color = color }, .{});
        if (m > 0) ui.text(c, "min", .{ .size = 13, .color = gray });
    }
    loadBars(c, bus.load);
}
