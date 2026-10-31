//! The app basics: haptic taps, the device's location, and a value kept
//! between launches. In the iOS Simulator, set a location with
//! `xcrun simctl location <device> set 1.3145,103.9100`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Basics = struct {
    gpa: std.mem.Allocator,
    window: ?*nanoui.Window = null,
    where: ?*nanoui.location.Location = null,
    unsupported: bool = false,
    launches: u32 = 0,
    taps: u32 = 0,

    fn view(s: *Basics, c: *ui.Context) void {
        const sa = c.safe_area;
        const col = ui.div(c).column().sizeFull().gap(12).bg(.hex(0xF2F2F4))
            .pt(sa.top + 12).pb(sa.bottom + 20).pl(sa.left + 20).pr(sa.right + 20);
        defer col.end();
        ui.text(c, "Basics", .{ .size = 28, .weight = .semibold });
        s.card(c, "Location", s.whereText(c));
        s.card(c, "Kept between launches", c.print("Launched {d}x", .{s.launches}));
        s.card(c, "Haptics", c.print("{d} taps", .{s.taps}));
        const row = ui.div(c).row().gap(10);
        defer row.end();
        inline for (.{ "Light", "Medium", "Heavy", "Select", "Done" }) |label| {
            const b = ui.div(c).px(14).py(10).rounded(14).bg(.hex(0x111111));
            ui.text(c, label, .{ .size = 15, .color = .white });
            if (b.clicked()) {
                s.taps += 1;
                if (comptime std.mem.eql(u8, label, "Light")) nanoui.haptics.impact(.light);
                if (comptime std.mem.eql(u8, label, "Medium")) nanoui.haptics.impact(.medium);
                if (comptime std.mem.eql(u8, label, "Heavy")) nanoui.haptics.impact(.heavy);
                if (comptime std.mem.eql(u8, label, "Select")) nanoui.haptics.selection();
                if (comptime std.mem.eql(u8, label, "Done")) nanoui.haptics.notify(.success);
            }
            b.end();
        }
    }

    fn card(_: *Basics, c: *ui.Context, title: []const u8, body: []const u8) void {
        const b = ui.div(c).column().wFull().p(16).gap(4).bg(.white).rounded(22);
        defer b.end();
        ui.text(c, title, .{ .size = 13, .color = .hex(0x6e6e73) });
        ui.text(c, body, .{ .size = 17, .tabular = true });
    }

    fn whereText(s: *Basics, c: *ui.Context) []const u8 {
        if (s.unsupported) return "Not on this platform";
        const l = s.where orelse return "Starting";
        if (l.fix) |f| return c.print("{d:.5}, {d:.5} (within {d:.0} m)", .{ f.lat, f.lng, f.accuracy });
        return switch (l.permission) {
            .undecided => "Asking",
            .denied => "Not allowed",
            .allowed => if (l.failed) |e| c.print("No fix yet (error {d})", .{e}) else "Waiting for a fix",
        };
    }

    fn moved(s: *Basics, _: *nanoui.location.Location) void {
        if (s.window) |w| w.redraw();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try nanoui.App.create(init, .{ .name = "Basics" });
    defer app.destroy();
    var state: Basics = .{ .gpa = gpa };
    const kv = nanoui.kv.standard();
    if (try kv.get(gpa, "launches")) |v| {
        defer gpa.free(v);
        state.launches = std.fmt.parseInt(u32, v, 10) catch 0;
    }
    state.launches += 1;
    try kv.set("launches", try std.fmt.allocPrint(init.arena.allocator(), "{d}", .{state.launches}));
    state.where = nanoui.location.start(gpa, &state, Basics.moved) catch |e| switch (e) {
        error.Unsupported => blk: {
            state.unsupported = true;
            break :blk null;
        },
        else => return e,
    };
    defer if (state.where) |l| l.stop();
    state.window = try app.newWindow(.{ .title = "Basics", .width = 420, .height = 640, .full_bleed = true, .content = .{ .view = .init(&state, Basics.view) } });
    try app.run();
}
