//! A window packs pictures straight into the GPU's atlas (`Images.sink`).
//! Pictures packed before it had one (its very first frame) are in the
//! CPU's copy; one packed after must not be drawn over by that copy.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const text = @import("text.zig");

const Pictures = struct {
    a: []const u8,
    b: []const u8,
    show_b: bool = false,
    fn view(p: *Pictures, c: *ui.Context) void {
        const root = ui.div(c).row().p(10).gap(10);
        defer root.end();
        _ = ui.image(c, .{ .key = "first", .bytes = p.a, .radius = 0, .scale = 1 });
        if (p.show_b) _ = ui.image(c, .{ .key = "later", .bytes = p.b, .radius = 0, .scale = 1 });
    }
};

fn solid(gpa: std.mem.Allocator, b: u8, g: u8, r: u8) ![]u8 {
    var px: [32 * 32 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < px.len) : (i += 4) px[i..][0..4].* = .{ b, g, r, 255 };
    return @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 32, .height = 32 });
}

test "a picture packed once the window draws straight to the GPU isn't drawn over by the CPU's copy" {
    if (text.portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    const a = try solid(gpa, 255, 0, 0);
    defer gpa.free(a);
    const b = try solid(gpa, 0, 0, 255);
    defer gpa.free(b);
    var p: Pictures = .{ .a = a, .b = b };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&p, Pictures.view), .{ .width = 120, .height = 60, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    // As a window after its first frame: pictures go to the GPU from now.
    t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    p.show_b = true;
    t.settle(1);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    // The middle of the second picture: red, not the background.
    const x: usize = 10 + 32 + 10 + 16;
    const y: usize = 10 + 16;
    const at = px.bytes[(y * px.width + x) * 4 ..][0..4];
    try testing.expect(at[2] > 200 and at[0] < 60);
}
