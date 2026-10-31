//! What VoiceOver reads in a nanoui app, on iOS and macOS alike: run it
//! with VoiceOver on (⌘F5 on the Mac, triple-click on an iPhone).
const std = @import("std");
const nanoui = @import("nanoui");
const Demo = @import("view.zig").Demo;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Access" });
    defer app.destroy();
    var state: Demo = .{};
    _ = try app.newWindow(.{
        .title = "Access",
        .width = 480,
        .height = 720,
        .content = .{ .view = .init(&state, Demo.view) },
    });
    try app.run();
}

test {
    _ = @import("tests.zig");
}
