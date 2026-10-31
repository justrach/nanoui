//! A to-do list for a phone, after the "Productivity Todo List" design by
//! @marten_maxxx (via CollectUI): a week of progress rings, today's plan
//! as cards, and a floating tab bar. Checking a task fills its box at once,
//! greys it, and then slides it under the ones still to do, the rest
//! moving up to close the gap; today's ring fills as the day gets done.
//!
//! `zig build run-todo`, or in the iOS Simulator:
//! `zig build $(sh tools/ios/zig-lib.sh) run-todo -Dtarget=aarch64-ios-simulator`.
const std = @import("std");
const nanoui = @import("nanoui");
const Todo = @import("todo.zig").Todo;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Todo" });
    defer app.destroy();
    var t: Todo = .{};
    _ = try app.newWindow(.{
        .title = "To-do list",
        .width = 402,
        .height = 874,
        .min_width = 340,
        .min_height = 600,
        .title_bar = .hidden,
        // Drawn under the status bar and the home indicator: the tab bar
        // floats over the list, which scrolls on under it.
        .full_bleed = true,
        // The design is a light one.
        .theme = nanoui.ui.Theme.light,
        .content = .{ .view = .init(&t, Todo.view) },
    });
    try app.run();
}
