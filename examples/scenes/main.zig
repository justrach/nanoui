//! Several windows of one app. On an iPad each sits beside the others, in a
//! scene of its own, and the system's New Window makes another; on a phone they
//! stack; on the desktop they're ordinary windows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Note = struct {
    app: *nanoui.App,
    window: ?*nanoui.Window = null,
    number: u32,
    taps: u32 = 0,

    fn view(n: *Note, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(16).bg(c.theme.background);
        defer root.end();
        ui.text(c, c.print("Window {d}", .{n.number}), .{ .size = 28, .weight = .bold });
        ui.text(c, c.print("Tapped {d} times, here only", .{n.taps}), .{ .size = 15, .color = c.theme.muted });
        if (ui.button(c, "Tap", .{ .size = 16 }).clicked) n.taps += 1;
        if (ui.button(c, "New window", .{ .variant = .primary, .size = 16 }).clicked) open(n.app);
        if (n.number > 1 and ui.button(c, "Close", .{ .variant = .ghost, .size = 16 }).clicked) if (n.window) |w| w.close();
    }
};

var opened: u32 = 0;

fn open(app: *nanoui.App) void {
    opened += 1;
    const note = std.heap.smp_allocator.create(Note) catch return;
    note.* = .{ .app = app, .number = opened };
    note.window = app.newWindow(.{
        .title = "Note",
        .width = 420,
        .height = 360,
        .own_scene = opened > 1,
        .content = .{ .view = .init(note, Note.view) },
    }) catch null;
}

fn newWindow(_: *anyopaque, app: *nanoui.App) void {
    open(app);
}

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Scenes" });
    defer app.destroy();
    app.onNewWindow(app, newWindow);
    open(app);
    try app.run();
}
