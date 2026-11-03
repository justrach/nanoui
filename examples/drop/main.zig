//! Native drag and drop: opt a box in with acceptDrop, then read one drop's
//! URLs with dropAt. Run with `zig build run-drop` and drop files on the box.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Drop = struct {
    count: usize = 0,
    first: [2048]u8 = undefined,
    first_len: usize = 0,

    fn view(s: *Drop, c: *ui.Context) void {
        const box = ui.div(c).column().center().sizeFull().gap(12).p(24);
        defer box.end();
        c.acceptDrop(box.index);
        if (c.dropAt(box.index)) |d| {
            s.count = d.urls.len;
            s.first_len = 0;
            if (d.urls.len > 0) {
                // A drop's URLs last for its frame; keep a copy to show later.
                s.first_len = @min(s.first.len, d.urls[0].len);
                @memcpy(s.first[0..s.first_len], d.urls[0][0..s.first_len]);
            }
        }
        ui.text(c, "Drop files here", .{ .size = 28, .weight = .semibold });
        ui.textf(c, .{ .color = c.theme.muted }, "{d} file(s) in the last drop", .{s.count});
        if (s.first_len > 0) ui.text(c, s.first[0..s.first_len], .{ .size = 12, .wrap = true });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Drop" });
    defer app.destroy();
    var state: Drop = .{};
    _ = try app.newWindow(.{
        .title = "nanoui file drop",
        .width = 640,
        .height = 360,
        .content = .{ .view = .init(&state, Drop.view) },
    });
    try app.run();
}
