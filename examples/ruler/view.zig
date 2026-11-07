const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Demo = struct {
    ruler: ui.RulerPicker = .{},

    pub fn draw(s: *Demo, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().center().bg(.hex(0xf9f9f9));
        defer root.end();
        _ = s.ruler.draw(c, .{ .width = @min(c.size.w, c.size.h), .label = "Ruler value" });
    }
};
