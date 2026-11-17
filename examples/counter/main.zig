//! A window of native UI: a view is a Zig function of the app's state.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        ui.row(c, .{ .gap = 8 });
        defer ui.end(c);
        if (ui.button(c, "−", .{ .size = 16 }).clicked) s.n -= 1;
        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 16 }).clicked) s.n += 1;
        if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 16, .disabled = s.n == 0 }).clicked) s.n = 0;
    }
};

// Browser smoke tests also pin the state kept on main's suspended stack.
var web_counter: ?*Counter = null;
export fn counter_value() i64 {
    return if (web_counter) |state| state.n else -1;
}

pub fn main(init: std.process.Init) !void {
    var state: Counter = .{};
    if (comptime @import("builtin").os.tag == .wasi) {
        web_counter = &state;
        _ = nanoui.web.registerBundledFonts();
        _ = try nanoui.web.mount(.init(&state, Counter.view), .{});
        nanoui.web.run();
    }
    const app = try nanoui.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Counter",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, Counter.view) },
    });
    try app.run();
}
