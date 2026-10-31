//! SG Bus: Singapore bus arrivals, in nanoui. The stops around you on a
//! map with their next buses (live, from LTA DataMall through arrivelah),
//! a service's route with its buses on it, starred stops, a journey
//! planner, and on a foldable a map pane beside (or above) the times.
//! See README.md for the data, its licence, and what shipping needs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;
const data = @import("data.zig");
const live = @import("live.zig");
const cards = @import("cards.zig");
const route = @import("route.zig");
const journey = @import("journey.zig");
const about = @import("about.zig");
const omv = @import("onemap_view.zig");

pub const Tab = enum { nearby, starred, journey, about };

pub const App = struct {
    gpa: std.mem.Allocator,
    window: ?*nanoui.Window = null,
    d: *data.Data,
    live: live.Live,
    m: map.Map,
    kv: nanoui.kv.Store,
    /// Where you are: Core Location's fix, else Joo Chiat (the sim's spot).
    here: map.Coord = .{ .lat = 1.31451, .lng = 103.90998 },
    near_buf: [6]u16 = undefined,
    near: []u16 = &.{},
    near_for: ?map.Coord = null,
    scratch: [8]u16 = undefined,
    tab: Tab = .nearby,
    chosen: ?u16 = null,
    route: ?route.Route = null,
    line: std.ArrayList(map.Coord) = .empty,
    line_for: ?[2]u16 = null,
    stars: std.ArrayList(u16) = .empty,
    pull: ui.motion.Pull = .{},
    answers_seen: u32 = 0,
    refreshing: bool = false,
    journey: journey.Journey = .{},
    ticks: u32 = 0,

    fn view(s: *App, c: *ui.Context) void {
        s.live.frame(c.time);
        s.located();
        if (s.m.takeTap()) |id| if (id < s.d.stops.len) s.choose(@intCast(id));
        if (s.refreshing and s.live.answers != s.answers_seen) {
            s.refreshing = false;
            nanoui.haptics.impact(.light);
        }
        const root = ui.div(c).column().sizeFull().bg(cards.ground);
        defer root.end();
        const two = c.device.split() != .none or c.size.w >= 600;
        if (two) {
            const p = ui.panes(c, .{ .ratio = 0.5 });
            s.mapView(c, .{});
            if (p.second()) s.content(c, .{});
            p.end();
            return;
        }
        const sa = c.safe_area;
        if (s.showMap()) {
            const top = ui.div(c).wFull().h(@round(c.size.h * 0.36));
            s.mapView(c, sa);
            top.end();
            s.content(c, .{ .left = sa.left, .right = sa.right, .bottom = sa.bottom });
        } else s.content(c, sa);
    }

    fn showMap(s: *const App) bool {
        return switch (s.tab) {
            .nearby, .starred => true,
            .journey => s.journey.trip() != null or s.journey.omTrip() != null,
            .about => false,
        };
    }

    fn mapView(s: *App, c: *ui.Context, sa: ui.Edges) void {
        var pins: [12]map.Pin = undefined;
        var opts: map.Options = .{ .user = true, .pins = &.{} };
        if (s.route) |r| {
            s.setLine(r.svc, r.dir);
            opts.pins = route.pins(s, c, r, &pins);
            opts.line = .{ .points = s.line.items, .color = cards.green };
            opts.camera = route.camera(s, r);
        } else if (s.tab == .journey and s.journey.omTrip() != null) {
            const got = omv.mapOf(s, s.journey.omTrip().?, &pins, &s.line);
            s.line_for = null;
            opts.pins = got[0];
            opts.line = .{ .points = s.line.items, .color = cards.green };
            opts.camera = got[1];
        } else if (s.tab == .journey and s.journey.dest != null and s.journey.trip() != null) {
            const t = s.journey.trip().?;
            s.journey.line(t, &s.line);
            s.line_for = null;
            opts.pins = s.journey.pins(t, &pins);
            opts.line = .{ .points = s.line.items, .color = cards.green };
            opts.camera = s.journey.camera();
        } else {
            const list = if (s.tab == .starred) s.stars.items else s.near;
            var n: usize = 0;
            for (list) |i| {
                if (n == pins.len) break;
                pins[n] = .{ .id = i, .at = s.d.stops[i].at, .label = s.d.stops[i].code, .selected = s.chosen == i };
                n += 1;
            }
            opts.pins = pins[0..n];
            opts.camera = .{ .center = if (s.chosen) |i| s.d.stops[i].at else s.here, .span = 0.007 };
        }
        s.m.view(c, opts);
        // Floating over the map, solid: glass can't see through to MapKit.
        if (s.route) |r| {
            const pill = ui.div(c).absolute().offset(16 + sa.left, sa.top + 12).px(14).py(8).rounded(18).bg(.white).shadowMd();
            ui.text(c, c.print("‹ {s}", .{s.d.stops[r.stop].code}), .{ .size = 15, .weight = .semibold, .color = cards.ink });
            if (pill.clicked()) s.route = null;
            pill.end();
        }
    }

    fn content(s: *App, c: *ui.Context, sa: ui.Edges) void {
        const host = ui.div(c).column().wFull().grow();
        defer host.end();
        const box = c.rects.get(host.id()) orelse ui.Rect{ .w = c.size.w, .h = c.size.h };
        {
            const list = ui.div(c).column().sizeFull().scrollY().gap(12).pt(sa.top + 16).pb(sa.bottom + 96).pl(sa.left + 16).pr(sa.right + 16);
            defer list.end();
            if (s.pull.update(c, list.id())) s.refresh();
            if (s.pull.distance > 4) ui.text(c, if (s.pull.armed) "Let go to refresh" else "Pull to refresh", .{ .size = 13, .color = cards.gray });
            if (s.route) |r| route.panel(s, c, r) else switch (s.tab) {
                .nearby => s.stopList(c, "Nearby", s.near),
                .starred => s.stopList(c, "Starred", s.stars.items),
                .journey => journey.view(s, c),
                .about => about.view(c),
            }
        }
        s.tabBar(c, box, sa);
    }

    fn stopList(s: *App, c: *ui.Context, title: []const u8, list: []const u16) void {
        ui.text(c, title, .{ .size = 28, .weight = .semibold, .color = cards.ink });
        ui.text(c, s.updated(c), .{ .size = 13, .color = cards.gray });
        if (list.len == 0) ui.text(c, if (s.tab == .starred) "Star a stop and it shows up here." else "No stop within 600 m leh.", .{ .size = 17, .color = cards.gray });
        for (list) |i| cards.stopCard(s, c, i, s.chosen == i);
    }

    fn updated(s: *App, c: *ui.Context) []const u8 {
        var at: f64 = -1;
        for (s.live.boards.items) |b| if (b.state == .ok) {
            at = @max(at, b.at);
        };
        if (at < 0) return "Live from LTA";
        const ago: u32 = @intFromFloat(@max(0, s.live.now - at));
        return if (ago < 5) "Live from LTA · just now" else c.print("Live from LTA · {d} s ago", .{ago});
    }

    fn tabBar(s: *App, c: *ui.Context, box: ui.Rect, sa: ui.Edges) void {
        const tabs = [_]struct { Tab, []const u8 }{ .{ .nearby, "Nearby" }, .{ .starred, "Starred" }, .{ .journey, "Journey" }, .{ .about, "About" } };
        const w: f32 = 4 * 82 + 12;
        const bar = ui.div(c).absolute().offset(@max(8, (box.w - w) / 2), box.h - 64 - @max(sa.bottom, 12)).row().w(w).h(56).p(6).gap(0).roundedFull().glass(.{}).shadowMd();
        defer bar.end();
        for (tabs) |t| {
            c.next_key = t[1];
            const on = s.tab == t[0] and s.route == null;
            const b = ui.div(c).w(82).hFull().roundedFull().justifyCenter().itemsCenter();
            if (on) _ = b.bg(cards.ink);
            ui.text(c, t[1], .{ .size = 13, .weight = .semibold, .color = if (on) .white else cards.ink });
            if (b.clicked()) {
                s.tab = t[0];
                s.route = null;
                s.chosen = null;
                nanoui.haptics.selection();
            }
            b.end();
        }
    }

    pub fn choose(s: *App, idx: u16) void {
        s.chosen = if (s.chosen == idx) null else idx;
        nanoui.haptics.selection();
    }

    pub fn openRoute(s: *App, stop: u16, no: []const u8) void {
        s.route = route.find(s.d, stop, no) orelse return;
        s.chosen = stop;
        nanoui.haptics.impact(.light);
    }

    pub fn isStarred(s: *const App, idx: u16) bool {
        return std.mem.indexOfScalar(u16, s.stars.items, idx) != null;
    }

    pub fn toggleStar(s: *App, idx: u16) void {
        if (std.mem.indexOfScalar(u16, s.stars.items, idx)) |i| {
            _ = s.stars.orderedRemove(i);
            nanoui.haptics.impact(.light);
        } else {
            s.stars.append(s.gpa, idx) catch return;
            nanoui.haptics.impact(.medium);
        }
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (s.stars.items, 0..) |i, n| w.print("{s}{s}", .{ if (n > 0) "," else "", s.d.stops[i].code }) catch break;
        s.kv.set("starred", w.buffered()) catch {};
    }

    fn loadStars(s: *App) void {
        const v = (s.kv.get(s.gpa, "starred") catch null) orelse return;
        defer s.gpa.free(v);
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |code| if (s.d.find(code)) |i| s.stars.append(s.gpa, i) catch {};
    }

    fn refresh(s: *App) void {
        s.refreshing = true;
        s.answers_seen = s.live.answers;
        s.live.refresh();
    }

    fn setLine(s: *App, svc: u16, dir: u8) void {
        if (s.line_for) |f| if (f[0] == svc and f[1] == dir) return;
        s.line_for = .{ svc, dir };
        const lines = s.d.services[svc].lines;
        if (dir < lines.len) data.decode(s.gpa, lines[dir], &s.line) catch {} else s.line.clearRetainingCapacity();
    }

    /// The stops near `here`, again when it has moved 40 m.
    fn located(s: *App) void {
        if (s.near_for) |f| if (data.meters(f, s.here) < 40) return;
        s.near_for = s.here;
        s.near = s.d.nearest(s.here, 600, &s.near_buf);
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *App = @ptrCast(@alignCast(ctx));
        s.ticks += 1;
        if (s.ticks % 4 == 0) s.live.refresh();
        if (s.window) |w| w.redraw();
        nanoui.App.after(5000, s, tick);
    }
};

/// Room for a first-launch welcome (what the app does, the location ask):
/// not designed yet, so it is never shown.
fn needsOnboarding(kv: nanoui.kv.Store) bool {
    _ = kv;
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try nanoui.App.create(init, .{ .name = "SG Bus" });
    defer app.destroy();
    const d = try data.Data.load(gpa);
    defer d.deinit(gpa);
    var s: App = .{ .gpa = gpa, .d = d, .live = .{ .gpa = gpa }, .m = .init(gpa), .kv = nanoui.kv.standard() };
    defer s.live.deinit();
    defer s.m.deinit();
    defer s.line.deinit(gpa);
    defer s.stars.deinit(gpa);
    s.journey.app = &s;
    // At run time only: never stored, printed or bundled.
    s.journey.token = init.environ_map.get("ONEMAP_TOKEN");
    s.journey.sample = init.environ_map.get("SGBUS_ONEMAP_SAMPLE") != null;
    // SGBUS_FRESH: start with no stars, as on a first launch (for a
    // scripted playthrough that stars a stop itself).
    if (init.environ_map.get("SGBUS_FRESH") != null) s.kv.set("starred", "") catch {} else s.loadStars();
    _ = needsOnboarding(s.kv);
    const where = nanoui.location.start(gpa, &s, moved) catch null;
    defer if (where) |l| l.stop();
    s.window = try app.newWindow(.{ .title = "SG Bus", .width = 420, .height = 860, .full_bleed = true, .content = .{ .view = .init(&s, App.view) } });
    s.live.window = s.window;
    nanoui.App.after(5000, &s, App.tick);
    try app.run();
}

fn moved(s: *App, l: *nanoui.location.Location) void {
    if (l.fix) |f| s.here = .{ .lat = f.lat, .lng = f.lng };
    if (s.window) |w| w.redraw();
}
