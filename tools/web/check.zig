//! Compile-only foundation for the browser renderer. The exported probe
//! exercises layout, input, painting and CPU readback without App/Window.
//! It can also be invoked by a WASI reactor host; zero means success.
const std = @import("std");
const ui = @import("nanoui").ui;

const Counter = struct {
    value: u32 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12) });
        defer ui.end(c);
        ui.text(c, "Web renderer probe", .{});
        if (ui.button(c, "Increment", .{}).clicked) s.value += 1;
    }
};

export fn nanoui_web_check() u32 {
    return check() catch 1;
}

fn check() !u32 {
    const gpa = std.heap.wasm_allocator;
    var state: Counter = .{};
    var t: ui.Tester = undefined;
    // Enough pixels to exercise the rasterizer's threaded-band decision.
    try t.init(gpa, .init(&state, Counter.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    try t.clickText("Increment");
    if (state.value != 1 or t.instances.items.len == 0) return 2;
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
    if (pixels.width != 720 or pixels.height != 600) return 3;
    return 0;
}
