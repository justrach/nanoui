//! Opt-in text parity controls: no windows, no user files or state.
const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const text = @import("text.zig");
const ui = @import("ui.zig");
const fixture = @import("tests_font_fixture.zig");

fn nothing(_: *u8, _: *ui.Context) void {}

test "system font shaping has a distinct cache key on every backend" {
    if (comptime !@hasField(types.TextStyle, "system_font")) return testing.expect(false);
    const normal: types.TextStyle = .{ .size = 13 };
    const system: types.TextStyle = .{ .size = 13, .system_font = true };
    try testing.expect(text.TextSystem.key("label", normal, 1) != text.TextSystem.key("label", system, 1));
    try testing.expect(@import("text_tt.zig").TextSystem.key("label", normal, 1) != @import("text_tt.zig").TextSystem.key("label", system, 1));
}

test "system font bypasses the proportional theme but preserves its mono family" {
    if (comptime !@hasField(types.TextStyle, "system_font")) return testing.expect(false);
    const tt = @import("text_tt.zig");
    const default_bytes = fixture.make(400);
    const theme_bytes = fixture.make(900);
    var ts = tt.TextSystem.init(testing.allocator);
    defer ts.deinit();
    // Only these made-up faces. Name the default Inter so the portable
    // default-family lookup finds it without scanning any font folders.
    ts.db.scanned = true;
    ts.db.bundled = @import("font_registry.zig").registered().len;
    ts.db.addMemory(&default_bytes);
    ts.db.addMemory(&theme_bytes);
    try testing.expectEqual(@as(usize, 2), ts.db.faces.items.len);
    @memcpy(ts.db.faces.items[0].style.family[0..5], "Inter");
    ts.db.faces.items[0].style.family_len = 5;
    ts.setFamilies(fixture.family, fixture.family);
    const normal: types.TextStyle = .{ .size = 20 };
    const system: types.TextStyle = .{ .size = 20, .system_font = true };
    const mono: types.TextStyle = .{ .size = 20, .mono = true, .system_font = true };
    try testing.expectApproxEqAbs(@as(f32, 18), ts.width("A", normal), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), ts.width("A", system), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 18), ts.width("A", mono), 0.001);
    // Requesting both paths in either order must not reuse the first font.
    try testing.expectApproxEqAbs(@as(f32, 18), ts.width("A", normal), 0.001);
    try testing.expectEqual(@as(usize, 3), ts.fonts.count());
}

test "CoreText separates system and themed font tables" {
    if (comptime !@hasField(types.TextStyle, "system_font")) return testing.expect(false);
    if (text.portable) return error.SkipZigTest;
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&page, nothing), .{});
    defer t.deinit();
    t.text.setFamilies("No Such Parity Family", null);
    _ = t.text.layout("label", .{ .size = 13 });
    _ = t.text.layout("label", .{ .size = 13, .system_font = true });
    try testing.expectEqual(@as(usize, 2), t.text.fonts.count());
    try testing.expectEqual(@as(usize, 2), t.text.tables.count());
}

test "glyph position wrapping keeps empty paragraphs and trailing newline" {
    if (comptime !@hasField(text.TextSystem, "wrap_rule")) return testing.expect(false);
    if (text.portable) return error.SkipZigTest;
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&page, nothing), .{});
    defer t.deinit();
    t.text.wrap_rule = .glyph_positions;
    const s = "alpha beta\r\n\nγδ epsilon\n";
    const lines = t.text.wrap(s, .{ .size = 13 }, 1000);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("alpha beta", s[lines[0].start..lines[0].end]);
    try testing.expectEqual(lines[1].start, lines[1].end);
    try testing.expectEqualStrings("γδ epsilon", s[lines[2].start..lines[2].end]);
    try testing.expectEqual(s.len, lines[3].start);
    try testing.expectEqual(s.len, lines[3].end);
}

test "changing the wrap rule does not reuse the other rule's cache" {
    if (comptime !@hasField(text.TextSystem, "wrap_rule")) return testing.expect(false);
    if (text.portable) return error.SkipZigTest;
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&page, nothing), .{});
    defer t.deinit();
    const s = "a short line";
    const normal = t.text.wrap(s, .{ .size = 13 }, 1000);
    t.text.wrap_rule = .glyph_positions;
    const parity = t.text.wrap(s, .{ .size = 13 }, 1000);
    try testing.expect(normal.ptr != parity.ptr);
    try testing.expectEqualSlices(text.Line, normal, parity);
}

test "glyph position wrapping uses styled fonts and tracking without cutting UTF-8" {
    if (comptime !@hasField(text.TextSystem, "wrap_rule")) return testing.expect(false);
    if (text.portable) return error.SkipZigTest;
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&page, nothing), .{});
    defer t.deinit();
    t.text.wrap_rule = .glyph_positions;
    const s = "héllo world again";
    const style: types.TextStyle = .{ .size = 13, .tracking = 0.5 };
    const spans: [1]types.Span = .{.{ .start = 0, .end = s.len, .mono = true }};
    const room = text.rich.layout(&t.text, "héllo world", style, &spans, 0).width + 1;
    const lines = t.text.wrapAttributed(s, style, &spans, room);
    try testing.expect(lines.len > 1);
    for (lines) |line| {
        try testing.expect(line.start <= line.end and line.end <= s.len);
        try testing.expect(std.unicode.utf8ValidateSlice(s[line.start..line.end]));
        try testing.expect(line.width >= 0);
    }
    // The plain-text path's newer tracking option must still affect its
    // paragraph positions under this opt-in rule.
    const tracked = try t.text.breakAtGlyphs("ABCD", .{ .size = 13, .tracking = 2 }, &.{}, 1000);
    defer testing.allocator.free(tracked);
    try testing.expectApproxEqAbs(t.text.width("ABCD", .{ .size = 13, .tracking = 2 }), tracked[0].width, 0.01);
}
