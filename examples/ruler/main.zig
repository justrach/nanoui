//! Native interactive example. The replay uses exactly the same view.
const std = @import("std");
const nanoui = @import("nanoui");
const Demo = @import("view.zig").Demo;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Fluid ruler" });
    defer app.destroy();
    var demo: Demo = .{};
    _ = try app.newWindow(.{
        .title = "Fluid ruler · nanoui",
        .width = 600,
        .height = 600,
        .content = .{ .view = .init(&demo, Demo.draw) },
    });
    try app.run();
}
