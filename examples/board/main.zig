//! A departure board: minutes that roll as they count down, and a list
//! you pull down to refresh. The times are made up; every 4 seconds a
//! minute goes by. Try `--nanoui-play="wait:2;scroll:220"` on iOS.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Row = struct { svc: []const u8, to: []const u8, min: u32 };

const Board = struct {
    window: ?*nanoui.Window = null,
    rows: [6]Row = start,
    pull: ui.motion.Pull = .{},
    refreshes: u32 = 0,

    const start = [6]Row{
        .{ .svc = "10", .to = "Kent Ridge Ter", .min = 2 },
        .{ .svc = "14", .to = "Clementi Int", .min = 6 },
        .{ .svc = "16", .to = "Bt Merah Int", .min = 9 },
        .{ .svc = "32", .to = "Changi Village", .min = 12 },
        .{ .svc = "155", .to = "Bedok Int", .min = 17 },
        .{ .svc = "196", .to = "Clementi Int", .min = 21 },
    };

    fn view(s: *Board, c: *ui.Context) void {
        const sa = c.safe_area;
        const list = ui.div(c).column().sizeFull().gap(10).scrollY().bg(.hex(0xF2F2F4))
            .pt(sa.top + 12).pb(sa.bottom + 20).pl(sa.left + 20).pr(sa.right + 20);
        defer list.end();
        if (s.pull.update(c, list.id())) s.refresh();
        const hint = if (s.pull.armed) "Let go to refresh" else if (s.pull.distance > 4) "Pull to refresh" else "";
        ui.text(c, "Departures", .{ .size = 28, .weight = .semibold });
        ui.text(c, if (hint.len > 0) hint else c.print("Refreshed {d}x", .{s.refreshes}), .{ .size = 13, .color = .hex(0x6e6e73) });
        for (s.rows, 0..) |r, i| {
            ui.keyInt(c, i);
            const card = ui.div(c).row().wFull().p(16).gap(12).bg(.white).rounded(22).itemsCenter();
            defer card.end();
            const chip = ui.div(c).px(10).py(4).rounded(8).bg(.hex(0xFFD100));
            ui.text(c, r.svc, .{ .size = 17, .weight = .bold, .color = .hex(0x111111) });
            chip.end();
            const mid = ui.div(c).column().grow();
            ui.text(c, r.to, .{ .size = 15, .color = .hex(0x3a3a3c), .truncate = .ellipsis });
            mid.end();
            ui.motion.roll(c, "min", if (r.min == 0) "Arr" else c.print("{d}", .{r.min}), .{ .size = 30, .weight = .bold }, .{});
            ui.text(c, if (r.min == 0) "" else " min", .{ .size = 15, .color = .hex(0x6e6e73) });
        }
    }

    fn refresh(s: *Board) void {
        s.refreshes += 1;
        s.rows = start;
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Board = @ptrCast(@alignCast(ctx));
        for (&s.rows) |*r| r.min = if (r.min == 0) 20 else r.min - 1;
        if (s.window) |w| w.redraw();
        nanoui.App.after(4000, s, tick);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Board" });
    defer app.destroy();
    var state: Board = .{};
    state.window = try app.newWindow(.{ .title = "Board", .width = 420, .height = 640, .full_bleed = true, .content = .{ .view = .init(&state, Board.view) } });
    nanoui.App.after(4000, &state, Board.tick);
    try app.run();
}
