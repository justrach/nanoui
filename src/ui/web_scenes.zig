//! Extra parity scenes shared by browser and native renderer tests.
const ui = @import("ui.zig");
const stops = [_]ui.GradientStop{
    .{ .at = 0, .color = .hex(0x10cc30) },
    .{ .at = 0.35, .color = .hex(0xee3344) },
    .{ .at = 1, .color = .hex(0x2255ee) },
};
pub const Effects = struct {
    pub fn view(_: *Effects, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().bg(.hex(0xe4e8f0));
        defer root.end();
        ui.div(c).absolute().offset(10, 10).w(90).h(120).rounded(15).bg(.white).gradientStops(&stops, null).end();
        {
            _ = c.open(.{ .absolute = true, .offset = .{ .x = 120, .y = 10 }, .width = .{ .px = 160 }, .height = .{ .px = 100 }, .opacity = 0.5, .group = true }, "group");
            defer c.end();
            ui.div(c).absolute().offset(0, 0).w(100).h(70).rounded(12).bg(.hex(0xff1122)).end();
            ui.div(c).absolute().offset(45, 25).w(100).h(70).rounded(12).bg(.hex(0x1144ee)).end();
        }
        {
            const box = ui.div(c).absolute().offset(15, 160).w(130).h(100);
            defer box.end();
            _ = ui.hole(c, "hole", 22);
            ui.div(c).absolute().offset(12, 12).w(32).h(26).rounded(5).bg(.hex(0xffcc00)).end();
        }
        {
            _ = c.open(.{ .absolute = true, .transform = .{ .a = 0.8, .b = 0.15, .c = 0.25, .d = 0.9, .e = 40, .f = -40 } }, "plane");
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 30, .y = 260 }, .width = .{ .px = 65 }, .height = .{ .px = 22 }, .radius = 8, .corner_circular = true, .background = .hex(0x22cc44) }, .none, null);
            c.end();
        }
        ui.div(c).absolute().offset(220, 170).w(70).h(70).rounded(14).bg(.hex(0x9933ff)).rotate(0.37).end();
        {
            const group = ui.div(c).absolute().offset(300, 20).size(48, 180).opacity(0.65);
            c.node(group.index).style.group = true;
            defer group.end();
            const scroll = ui.div(c).size(48, 180).scrollY().scrollEdgeFade(24).hideScrollBar();
            defer scroll.end();
            const content = ui.div(c).size(48, 300).bg(.hex(0x00ff00));
            defer content.end();
            const nested = ui.div(c).absolute().size(36, 300).opacity(0.7);
            c.node(nested.index).style.group = true;
            defer nested.end();
            ui.div(c).size(36, 300).bg(.hex(0xff0000)).end();
        }
    }
};
