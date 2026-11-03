//! A map with the UI over it: bus stops around Joo Chiat as yellow chips,
//! a route line through them with a bus gliding along it, and a list of
//! the stops under the map. Tap a stop's card and the camera goes there;
//! tap a chip and its card is chosen. The stops are real (LTA codes and
//! places); the bus is made up, a step along the line every 2 seconds.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const map = nanoui.map;

const Stop = struct { code: []const u8, name: []const u8, at: map.Coord };

const stops = [_]Stop{
    .{ .code = "83149", .name = "Aft Changi Rd", .at = .{ .lat = 1.31746, .lng = 103.90875 } },
    .{ .code = "83131", .name = "Aft Lor H Telok Kurau", .at = .{ .lat = 1.31631, .lng = 103.90908 } },
    .{ .code = "83139", .name = "Aft Joo Chiat Pl", .at = .{ .lat = 1.31451, .lng = 103.90998 } },
    .{ .code = "83129", .name = "Aft Ji Xiang Ct", .at = .{ .lat = 1.31306, .lng = 103.91061 } },
    .{ .code = "83121", .name = "Bef Lor K Telok Kurau", .at = .{ .lat = 1.31261, .lng = 103.91063 } },
    .{ .code = "83159", .name = "Opp Parkway East Hosp", .at = .{ .lat = 1.31480, .lng = 103.90948 } },
    .{ .code = "83169", .name = "Bef Still Rd", .at = .{ .lat = 1.31428, .lng = 103.90687 } },
};

/// Telok Kurau Rd, north to south, through its stops.
const route = [_]map.Coord{ stops[0].at, stops[1].at, stops[2].at, stops[3].at, stops[4].at };

const Demo = struct {
    window: ?*nanoui.Window = null,
    m: map.Map,
    chosen: usize = 2,
    /// The bus's step along the route, in tenths of a leg.
    step: usize = 0,

    fn view(s: *Demo, c: *ui.Context) void {
        if (s.m.takeTap()) |id| {
            s.chosen = @intCast(id);
            nanoui.haptics.selection();
        }
        const sa = c.safe_area;
        const col = ui.div(c).column().sizeFull().bg(.hex(0xF2F2F4));
        defer col.end();
        {
            const top = ui.div(c).wFull().h(380 + sa.top);
            defer top.end();
            var pins: [stops.len + 1]map.Pin = undefined;
            for (stops, 0..) |st, i| pins[i] = .{ .id = i, .at = st.at, .label = st.code, .selected = i == s.chosen };
            pins[stops.len] = .{ .id = 100, .at = s.busAt(), .label = "16", .style = .bus };
            s.m.view(c, .{
                .pins = &pins,
                .line = .{ .points = &route, .color = .hex(0x1A73E8) },
                .camera = .{ .center = stops[s.chosen].at, .span = 0.006 },
                .user = true,
            });
            // A floating title over the map, solid: glass can't see MapKit.
            const chip = ui.div(c).absolute().offset(16 + sa.left, sa.top + 12).px(14).py(8).rounded(18).bg(.white).shadowMd();
            ui.text(c, "Nearby stops", .{ .size = 15, .weight = .semibold });
            chip.end();
        }
        const list = ui.div(c).column().wFull().grow().scrollY().gap(10).pt(14).pb(sa.bottom + 16).pl(sa.left + 16).pr(sa.right + 16);
        defer list.end();
        for (stops, 0..) |st, i| {
            c.next_key_int = i;
            const on = i == s.chosen;
            const card = ui.div(c).row().wFull().p(14).gap(12).rounded(18).bg(if (on) .hex(0x111111) else .white);
            const code = ui.div(c).px(8).py(4).rounded(6).bg(.hex(0xFFD100));
            ui.text(c, st.code, .{ .size = 13, .weight = .bold, .tabular = true, .color = .hex(0x111111) });
            code.end();
            ui.text(c, st.name, .{ .size = 16, .color = if (on) .white else .hex(0x111111) });
            if (card.clicked()) {
                s.chosen = i;
                nanoui.haptics.selection();
            }
            card.end();
        }
    }

    fn busAt(s: *const Demo) map.Coord {
        const legs = route.len - 1;
        const leg = (s.step / 10) % legs;
        const t: f64 = @as(f64, @floatFromInt(s.step % 10)) / 10;
        const a = route[leg];
        const b = route[leg + 1];
        return .{ .lat = a.lat + (b.lat - a.lat) * t, .lng = a.lng + (b.lng - a.lng) * t };
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Demo = @ptrCast(@alignCast(ctx));
        s.step += 1;
        if (s.window) |w| w.redraw();
        nanoui.App.after(2000, s, tick);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try nanoui.App.create(init, .{ .name = "Map" });
    defer app.destroy();
    var state: Demo = .{ .m = .init(gpa) };
    defer state.m.deinit();
    const where = nanoui.location.start(gpa, &state, moved) catch null;
    defer if (where) |l| l.stop();
    state.window = try app.newWindow(.{ .title = "Map", .width = 420, .height = 760, .full_bleed = true, .content = .{ .view = .init(&state, Demo.view) } });
    nanoui.App.after(2000, &state, Demo.tick);
    try app.run();
}

fn moved(s: *Demo, _: *nanoui.location.Location) void {
    if (s.window) |w| w.redraw();
}
