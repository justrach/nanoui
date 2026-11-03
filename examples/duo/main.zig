//! Foldables: the posture, the hinge and the fold's band (`c.device`), and
//! `ui.panes`, which keeps both panes clear of the band. On the iPhone Duo
//! simulator, try `hinge close`, `hinge open`, `hinge half` and
//! `hinge rotate left`; elsewhere it is one pane, posture `none`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const rows = [_][]const u8{ "Aft Joo Chiat Pl", "Opp Blk 106", "Bef Still Rd Sth", "Telok Kurau Pr Sch", "Blk 153", "Kembangan Stn", "Opp Bedok Reservoir", "Marine Pde Stn Exit 2" };

const Duo = struct {
    selected: usize = 0,
    rotations: u32 = 0,

    fn view(s: *Duo, c: *ui.Context) void {
        if (c.device.rotated) s.rotations += 1;
        const bg = ui.div(c).column().sizeFull().bg(.hex(0xF2F2F4));
        defer bg.end();
        const p = ui.panes(c, .{});
        s.list(c, p.two);
        if (p.second()) s.detail(c);
        p.end();
    }

    fn list(s: *Duo, c: *ui.Context, two: bool) void {
        const col = ui.div(c).column().sizeFull().p(20).gap(10).scrollY();
        defer col.end();
        ui.text(c, "Stops", .{ .size = 28, .weight = .semibold });
        for (rows, 0..) |r, i| {
            ui.keyInt(c, i);
            const card = ui.div(c).row().wFull().p(14).gap(10).bg(if (i == s.selected) .hex(0x111111) else .white).rounded(22).itemsCenter();
            defer card.end();
            if (card.clicked()) s.selected = i;
            const fg: ui.Color = if (i == s.selected) .white else .hex(0x111111);
            ui.text(c, r, .{ .size = 17, .color = fg, .truncate = .ellipsis });
        }
        if (!two) s.detail(c);
    }

    fn detail(s: *Duo, c: *ui.Context) void {
        const d = &c.device;
        const col = ui.div(c).column().sizeFull().p(20).gap(8);
        defer col.end();
        ui.text(c, rows[s.selected], .{ .size = 28, .weight = .semibold, .wrap = true });
        ui.text(c, c.print("posture {s}", .{@tagName(d.posture())}), .{ .size = 17 });
        if (d.hinge_angle) |a| ui.text(c, c.print("hinge {s}, {d:.0} degrees", .{ @tagName(d.hinge), a }), .{ .size = 17, .tabular = true });
        ui.text(c, c.print("window {d:.0} x {d:.0} pt, {s}, rotated {d}x", .{ d.size.w, d.size.h, @tagName(d.orientation), s.rotations }), .{ .size = 13, .tabular = true, .color = .hex(0x6e6e73) });
        ui.text(c, c.print("size classes w {s}, h {s}", .{ @tagName(d.horizontal), @tagName(d.vertical) }), .{ .size = 13, .color = .hex(0x6e6e73) });
        for (d.list()) |r| ui.text(c, c.print("{s}{s} x {d:.1} y {d:.1} w {d:.1} h {d:.1}", .{ @tagName(r.kind), if (r.active) "" else " (inactive)", r.rect.x, r.rect.y, r.rect.w, r.rect.h }), .{ .size = 13, .tabular = true, .color = .hex(0x6e6e73) });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Duo" });
    defer app.destroy();
    var state: Duo = .{};
    _ = try app.newWindow(.{ .title = "Duo", .width = 900, .height = 600, .full_bleed = true, .content = .{ .view = .init(&state, Duo.view) } });
    try app.run();
}
