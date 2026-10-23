//! Text cut in its middle, letter spacing, the rounded face, a turned
//! symbol, and an app whose controls keep the arrow.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const path = "/Users/someone/Library/Application Support/Somewhere/deep/down/report-final.pdf";

const Row = struct {
    turned: bool = false,
    fn view(r: *Row, c: *ui.Context) void {
        ui.row(c, .{ .width = .{ .px = 140 } });
        ui.text(c, path, .{ .size = 13, .truncate_middle = true });
        ui.end(c);
        ui.row(c, .{});
        ui.icon(c, "chevron.right", .{ .size = 13, .frame = 20, .rotation = if (r.turned) std.math.pi / 2.0 else 0 });
        ui.end(c);
        const b = c.open(.{ .width = .{ .px = 60 }, .height = .{ .px = 30 } }, "button");
        _ = c.interact(b, .{});
        c.end();
    }
};

fn textNode(t: *ui.Tester, prefix: []const u8) ?struct { str: []const u8, w: f32 } {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, prefix)) return .{ .str = tx.str, .w = n.rect.w },
        else => {},
    };
    return null;
}

test "truncate_middle keeps the head and the tail around an ellipsis, and fits" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{});
    defer t.deinit();
    const n = textNode(&t, "/Users").?;
    const cut = std.mem.indexOf(u8, n.str, "…").?;
    try testing.expect(cut > 0);
    try testing.expect(std.mem.endsWith(u8, path, n.str[cut + "…".len ..]));
    try testing.expect(std.mem.endsWith(u8, n.str, ".pdf"));
    try testing.expect(t.text.width(n.str, .{ .size = 13 }) <= 140.5);
}

test "tracking adds its points after every character" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{});
    defer t.deinit();
    const plain = t.text.width("PINS", .{ .size = 11 });
    try testing.expectApproxEqAbs(plain + 4 * 0.6, t.text.width("PINS", .{ .size = 11, .tracking = 0.6 }), 0.01);
    const l = t.text.layout("PINS", .{ .size = 11, .tracking = 0.6 });
    try testing.expectApproxEqAbs(t.text.layout("PINS", .{ .size = 11 }).glyphs[3].x + 3 * 0.6, l.glyphs[3].x, 0.01);
}

test "rounded is its own face where the system has one" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{});
    defer t.deinit();
    const w = t.text.width("Return ⌘", .{ .size = 12, .rounded = true });
    try testing.expect(w > 0);
    if (!@import("text.zig").portable)
        try testing.expect(@abs(w - t.text.width("Return ⌘", .{ .size = 12 })) > 0.01);
}

test "a quarter turn sets xf rotation on the same centre" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{});
    defer t.deinit();
    const before = glyph(&t) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(f32, 0), before.xf[0]);
    r.turned = true;
    t.frame();
    const after = glyph(&t).?;
    try testing.expectApproxEqAbs(std.math.pi / 2.0, after.xf[0], 0.001);
    try testing.expectApproxEqAbs(before.rect[0] + before.rect[2] / 2, after.xf[2], 0.51);
    try testing.expectApproxEqAbs(before.rect[1] + before.rect[3] / 2, after.xf[3], 0.51);
    try testing.expectEqualSlices(f32, &before.uv, &after.uv);
}

/// The one symbol's quad: the text-kind instance in the icon's row.
fn glyph(t: *ui.Tester) ?@TypeOf(t.instances.items[0]) {
    for (t.instances.items) |i| if (i.kind == @import("gpu.zig").Kind.text and i.rect[1] < 60 and i.rect[1] > 10) return i;
    return null;
}

test "hand_cursor false keeps the arrow over what is clickable" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{});
    defer t.deinit();
    var box: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| if (n.interactive) {
        box = n.rect;
    };
    const b = box.?;
    t.moveTo(b.x + 5, b.y + 5);
    try testing.expect(t.ctx.cursor_hand);
    t.ctx.hand_cursor = false;
    t.frame();
    try testing.expect(!t.ctx.cursor_hand);
}

const Marked = struct {
    fn view(_: *Marked, c: *ui.Context) void {
        const pill = c.open(.{ .direction = .row, .width = .{ .px = 200 }, .height = .{ .px = 30 }, .padding = .xy(10, 7) }, "pill");
        defer c.end();
        _ = c.interact(pill, .{});
        c.help(pill, "Tab");
        const dot = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, "dot");
        c.help(dot, "Recording");
        c.end();
    }
};

test "a quiet marker's tooltip wins inside the box it is drawn in" {
    var m: Marked = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, Marked.view), .{});
    defer t.deinit();
    t.moveTo(18, 15);
    try testing.expectEqualStrings("Recording", t.ctx.hotHelp().?);
    t.moveTo(150, 15);
    try testing.expectEqualStrings("Tab", t.ctx.hotHelp().?);
}

const Field = struct {
    buf: ui.TextBuffer = .{},
    fn view(f: *Field, c: *ui.Context) void {
        _ = ui.textField(c, &f.buf, .{ .bare = true, .color = .{ .r = 0.5, .g = 0.25, .a = 1 } });
        _ = ui.textArea(c, &f.buf, .{ .color = .{ .r = 0.5, .g = 0.25, .a = 1 } });
    }
};

test "a field's typed text wears the color asked for" {
    var f: Field = .{};
    defer f.buf.deinit();
    f.buf.set("typed");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Field.view), .{});
    defer t.deinit();
    var n: usize = 0;
    for (t.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "typed")) {
            try testing.expectEqual(@as(f32, 0.25), tx.color.g);
            n += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), n);
}
