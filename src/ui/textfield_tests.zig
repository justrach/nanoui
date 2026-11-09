//! The text field's editing core, tested without a view: the buffer's
//! edits and boundaries, composition, selection and commands through
//! `apply`, a suggestion taken at the end, and `Options.filter`
//! (`textfield.zig`).
const std = @import("std");
const tf = @import("textfield.zig");
const textedit = @import("textedit.zig");
const EditState = @import("context.zig").EditState;
const TextBuffer = tf.TextBuffer;
const Result = tf.Result;
const Options = tf.Options;
const apply = tf.apply;
const prevBoundary = tf.prevBoundary;
const nextBoundary = tf.nextBoundary;
const prevWord = textedit.prevWord;
const nextWord = textedit.nextWord;

test "buffer edits" {
    var b: TextBuffer = .{};
    defer b.deinit();
    b.set("hllo");
    _ = b.insert(1, "e");
    try std.testing.expectEqualStrings("hello", b.text());
    b.remove(0, 1);
    try std.testing.expectEqualStrings("ello", b.text());
    _ = b.replace(1, 3, "XYZ");
    try std.testing.expectEqualStrings("eXYZo", b.text());
    b.set("añb");
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(b.text(), 3));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(b.text(), 1));
    try std.testing.expectEqual(@as(usize, 0), prevWord("foo bar", 3));
    try std.testing.expectEqual(@as(usize, 7), nextWord("foo bar", 3));
}

fn noClip(_: ?*anyopaque, _: []const u8) void {}

test "composition, selection, commands" {
    var b: TextBuffer = .{};
    defer b.deinit();
    var e: EditState = .{};
    var r: Result = .{};
    apply(&b, &e, .{ .insert = "hello world" }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .select_word_left }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqual(@as(usize, 6), @min(e.caret, e.anchor));
    apply(&b, &e, .{ .insert = "Zig" }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello Zig", b.text());
    // An input method composes "日本", then commits it.
    apply(&b, &e, .{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }, .{}, .{ .write = noClip }, &r);
    try std.testing.expect(e.marked != null);
    apply(&b, &e, .{ .set_marked = .{ .text = "日本", .sel_start = 6, .sel_len = 0 } }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .insert = "日本" }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello Zig日本", b.text());
    try std.testing.expect(e.marked == null);
    apply(&b, &e, .{ .command = .delete_word_backward }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("hello ", b.text());
    apply(&b, &e, .{ .command = .select_all }, .{}, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .delete_backward }, .{}, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("", b.text());
}

test "a suggestion is taken with → at the end" {
    var b: TextBuffer = .{};
    defer b.deinit();
    var e: EditState = .{};
    var r: Result = .{};
    const opts: Options = .{ .suggestion = "status" };
    apply(&b, &e, .{ .insert = "git " }, opts, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .command = .move_left }, opts, .{ .write = noClip }, &r);
    // Not at the end: → only moves.
    apply(&b, &e, .{ .command = .move_right }, opts, .{ .write = noClip }, &r);
    try std.testing.expect(!r.accepted);
    try std.testing.expectEqualStrings("git ", b.text());
    apply(&b, &e, .{ .command = .move_right }, opts, .{ .write = noClip }, &r);
    try std.testing.expect(r.accepted);
    try std.testing.expectEqualStrings("git status", b.text());
    try std.testing.expectEqual(@as(usize, 10), e.caret);
}
/// A timecode field's filter: digits kept, full-width digits made ASCII.
fn digits(cp: u21) ?u21 {
    if (cp >= '0' and cp <= '9') return cp;
    if (cp >= 0xFF10 and cp <= 0xFF19) return cp - 0xFF10 + '0';
    return null;
}

test "a filter maps or drops typed, pasted and committed text" {
    var b: TextBuffer = .{};
    defer b.deinit();
    var e: EditState = .{};
    var r: Result = .{};
    const opts: Options = .{ .filter = digits };
    apply(&b, &e, .{ .insert = "12:3４" }, opts, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("1234", b.text());
    // A key it drops entirely leaves the text and the selection alone.
    apply(&b, &e, .{ .command = .select_all }, opts, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .insert = "x" }, opts, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("1234", b.text());
    try std.testing.expectEqual(@as(usize, 4), @max(e.caret, e.anchor) - @min(e.caret, e.anchor));
    // A composition committed as full-width digits lands as ASCII.
    apply(&b, &e, .{ .command = .move_right }, opts, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .set_marked = .{ .text = "５", .sel_start = 3, .sel_len = 0 } }, opts, .{ .write = noClip }, &r);
    apply(&b, &e, .{ .insert = "５６" }, opts, .{ .write = noClip }, &r);
    try std.testing.expectEqualStrings("123456", b.text());
    try std.testing.expect(e.marked == null);
}
