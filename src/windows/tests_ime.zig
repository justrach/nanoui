//! The input method's tests: the decode, the caret mapping, the ops each
//! message produces, the `lParam` mask, and the whole chain into a real
//! `textField` through `ui.Tester`.
//!
//! Apart from `ime.zig` so that it stays within the line limit; every symbol
//! reached here is the one the window procedure calls.

const std = @import("std");
const testing = std.testing;
const ctx_mod = @import("../ui/context.zig");
const ime = @import("ime.zig");

const State = ime.State;
const ops = ime.ops;
const end = ime.end;
const decode = ime.decode;
const byteOfUnit = ime.byteOfUnit;
const clearCompositionBit = ime.clearCompositionBit;
const ISC_SHOWUICOMPOSITIONWINDOW = ime.ISC_SHOWUICOMPOSITIONWINDOW;
// `WM_IME_SETCONTEXT`'s lParam: only the composition bit goes, and only that
// bit. Sign-extending the mask would clear the upper 32 bits too.
test "only the composition bit leaves lParam" {
    // The flags a real message carries: the composition window and a candidate
    // list, plus a bit above 32 that must survive.
    const composition: usize = ISC_SHOWUICOMPOSITIONWINDOW;
    const candidate: usize = 1;
    const high: usize = if (@bitSizeOf(usize) > 32) @as(usize, 1) << 40 else 0;
    const lp: isize = @bitCast(composition | candidate | high);

    const got: usize = @bitCast(clearCompositionBit(lp));
    try testing.expectEqual(@as(usize, 0), got & composition);
    try testing.expectEqual(@as(usize, candidate), got & candidate);
    // The whole point: a bit above 32 is not ours to drop.
    try testing.expectEqual(high, got & high);
}

test "clearing the composition bit twice changes nothing" {
    const lp: isize = @bitCast(@as(usize, ISC_SHOWUICOMPOSITIONWINDOW));
    const once = clearCompositionBit(lp);
    try testing.expectEqual(@as(isize, 0), once);
    try testing.expectEqual(once, clearCompositionBit(once));
}

test "a caret in UTF-16 units maps to bytes, surrogate pairs included" {
    // "a中𝄞": 1 unit + 1 unit + 2 units; 1 + 3 + 4 bytes.
    var units = [_]u16{ 'a', 0x4E2D, 0xD834, 0xDD1E };
    try testing.expectEqual(@as(usize, 0), byteOfUnit(&units, 0));
    try testing.expectEqual(@as(usize, 1), byteOfUnit(&units, 1));
    try testing.expectEqual(@as(usize, 4), byteOfUnit(&units, 2));
    // Between the halves of the pair counts as after the character: four bytes.
    try testing.expectEqual(@as(usize, 8), byteOfUnit(&units, 3));
    try testing.expectEqual(@as(usize, 8), byteOfUnit(&units, 4));
}

test "an empty composition does not eat a selection, one that has text does" {
    var s: State = .{};
    var out: [2]ctx_mod.TextOp = undefined;
    // Nothing marked: an empty composition is the IME saying nothing.
    try testing.expectEqual(@as(usize, 0), ops(&s, .{ .composition = "" }, &out).len);
    // Something marked: the empty composition clears it.
    s.marked = true;
    const cleared = ops(&s, .{ .composition = "" }, &out);
    try testing.expectEqual(@as(usize, 1), cleared.len);
    try testing.expectEqualStrings("", cleared[0].set_marked.text);
    try testing.expect(!s.marked);
}

test "a commit is one insert and replaces the marked text" {
    var s: State = .{ .marked = true };
    var out: [2]ctx_mod.TextOp = undefined;
    const n = ops(&s, .{ .result = "你" }, &out);
    try testing.expectEqual(@as(usize, 1), n.len);
    try testing.expectEqualStrings("你", n[0].insert);
    // The mark is gone: the insert replaced it.
    try testing.expect(!s.marked);
}

test "a commit and a composition in one message are two ops, in that order" {
    var s: State = .{};
    var out: [2]ctx_mod.TextOp = undefined;
    const n = ops(&s, .{ .result = "好", .composition = "ni", .caret = 2 }, &out);
    try testing.expectEqual(@as(usize, 2), n.len);
    try testing.expectEqualStrings("好", n[0].insert);
    try testing.expectEqualStrings("ni", n[1].set_marked.text);
    try testing.expectEqual(@as(usize, 2), n[1].set_marked.sel_start);
}

test "the end of a composition unmarks only when something was marked" {
    var s: State = .{ .composing = true, .marked = false };
    var out: [1]ctx_mod.TextOp = undefined;
    try testing.expectEqual(@as(usize, 0), end(&s, &out).len);
    try testing.expect(!s.composing);

    s = .{ .composing = true, .marked = true };
    const t = end(&s, &out);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expect(t[0] == .unmark);
    try testing.expect(!s.marked);
}

test "UTF-16 becomes UTF-8, and a bad sequence changes nothing" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const units = [_]u16{ 'a', 0x4E2D };
    const text = decode(gpa, &out, &units).?;
    try std.testing.expectEqualStrings("a中", text);
    // A lone high surrogate is not UTF-16: null, and `out` is left empty.
    const bad = [_]u16{0xD834};
    try std.testing.expect(decode(gpa, &out, &bad) == null);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

/// One field, for the end-to-end test: the composition has to reach a real
/// `textField` through the same `TextOps` macOS uses.
const Field = struct {
    buf: @import("../ui/ui.zig").TextBuffer = .{},

    fn view(s: *Field, c: *ctx_mod.Context) void {
        _ = @import("../ui/ui.zig").textField(c, &s.buf, .{ .placeholder = "Type", .width = .{ .px = 160 } });
    }
};

test "a composition reaches a text field through its ops" {
    const ui = @import("../ui/ui.zig");
    const gpa = std.testing.allocator;
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    try std.testing.expect(t.ctx.focused_text != null);

    var st: State = .{};
    defer st.deinit(gpa);
    var out: [2]ctx_mod.TextOp = undefined;

    // The IME composes にほん, its caret after に: the field shows the
    // composition, marked, with the caret inside it.
    const units = [_]u16{ 0x306B, 0x307B, 0x3093 };
    const text = decode(gpa, &st.composition, &units).?;
    t.textOps(ops(&st, .{ .composition = text, .caret = byteOfUnit(&units, 1) }, &out));
    try std.testing.expectEqualStrings("にほん", s.buf.text());
    const f = t.ctx.focused_text.?;
    try std.testing.expect(f.marked != null);
    try std.testing.expectEqual(@as(usize, 0), f.marked.?[0]);
    try std.testing.expectEqual(@as(usize, 3), f.caret);

    // It commits 日本 in place of the composition: the marked text is replaced,
    // not appended after ("sa d'sa d'萨达" was that bug).
    const commit = [_]u16{ 0x65E5, 0x672C };
    t.textOps(ops(&st, .{ .result = decode(gpa, &st.result, &commit).? }, &out));
    try std.testing.expectEqualStrings("日本", s.buf.text());
    try std.testing.expect(t.ctx.focused_text.?.marked == null);
    try std.testing.expectEqual(@as(usize, 6), t.ctx.focused_text.?.caret);
}

test "a composition is visible while typing and gone after it commits" {
    const ui = @import("../ui/ui.zig");
    const gpa = std.testing.allocator;
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");

    var st: State = .{};
    defer st.deinit(gpa);
    var out: [2]ctx_mod.TextOp = undefined;

    // Typed "n" then "i": the field holds the pinyin, underlined.
    t.textOps(ops(&st, .{ .composition = "n" }, &out));
    t.textOps(ops(&st, .{ .composition = "ni" }, &out));
    try std.testing.expectEqualStrings("ni", s.buf.text());
    try std.testing.expect(t.ctx.focused_text.?.marked != null);

    // Space picks 你: the pinyin is replaced, not left in front of it.
    t.textOps(ops(&st, .{ .result = "你" }, &out));
    try std.testing.expectEqualStrings("你", s.buf.text());
    try std.testing.expect(t.ctx.focused_text.?.marked == null);
}

// The `State` buffers are the only memory the input method holds; a leak here
// is every composition string the user ever typed. `std.testing.allocator`
// fails a test that leaves an allocation behind, so reaching deinit of every
// buffer is the check.
test "the input method's buffers are all given back" {
    var st: State = .{};
    defer st.deinit(std.testing.allocator);
    var out: [2]ctx_mod.TextOp = undefined;

    // Growing strings the way typing does: each one resizes `wide` and the
    // UTF-8 buffer it decodes into.
    for ([_]usize{ 1, 2, 3, 5, 8, 13 }) |n| {
        const units = try std.testing.allocator.alloc(u16, n);
        defer std.testing.allocator.free(units);
        for (units, 0..) |*u, i| u.* = @intCast('a' + @as(u8, @intCast(i % 26)));
        st.wide.clearRetainingCapacity();
        try st.wide.appendSlice(std.testing.allocator, units);
        const text = decode(std.testing.allocator, &st.composition, st.wide.items).?;
        _ = ops(&st, .{ .composition = text, .caret = text.len }, &out);
    }
    // A commit, and the end of the composition.
    _ = ops(&st, .{ .result = "你好" }, &out);
    var one: [1]ctx_mod.TextOp = undefined;
    _ = end(&st, &one);
}

test "deinit leaves nothing behind, twice over" {
    var st: State = .{};
    const gpa = std.testing.allocator;
    // Read something so all three buffers have allocated.
    _ = decode(gpa, &st.result, &[_]u16{ 'a', 'b' });
    _ = decode(gpa, &st.composition, &[_]u16{ 'c', 'd' });
    try st.wide.appendSlice(gpa, &[_]u16{ 'e', 'f' });
    st.deinit(gpa);
    // A second deinit is a no-op, not a double free: `deinit` resets the state.
    st.deinit(gpa);
}

/// A stand-in for the surface, with just what `ime.handle` reaches: the state,
/// the context (held the way `Surface` holds it, by value), the scale, the
/// allocator, and a frame that records the ops it was handed rather than
/// building a view.
const FakeSurface = struct {
    ime: ime.State = .{},
    ts: @import("../ui/text.zig").TextSystem,
    ctx: ctx_mod.Context,
    gpa: std.mem.Allocator,
    scale: f32 = 2,
    frames: u32 = 0,
    seen_first: ?ctx_mod.TextOp = null,
    seen_len: usize = 0,

    pub fn frame(self: *FakeSurface) void {
        self.frames += 1;
        self.seen_len = self.ctx.input.ops.len;
        // Copied, not pointed at: the ops live in the caller's stack frame,
        // which is gone by the time the test looks.
        if (self.seen_len > 0) self.seen_first = self.ctx.input.ops[0];
    }
};

test "losing the keyboard (WM_IME_SETCONTEXT, wParam 0) ends a marked composition" {
    const w = @import("win32.zig");
    const gpa = std.testing.allocator;
    var fs: FakeSurface = .{ .ts = undefined, .ctx = undefined, .gpa = gpa };
    fs.ts = .init(gpa);
    fs.ctx = .init(gpa, &fs.ts);
    defer {
        fs.ctx.deinit();
        fs.ts.deinit();
    }
    fs.ime.composing = true;
    fs.ime.marked = true;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const hwnd = w.CreateWindowExW(0, class, class, 0, 0, 0, 8, 8, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = w.DestroyWindow(hwnd);
    _ = ime.handle(&fs, hwnd, w.WM_IME_SETCONTEXT, 0, 0);
    // A field left `composing` would swallow the next keystroke; one left
    // `marked` keeps its underline for nothing. Both go.
    try testing.expect(!fs.ime.composing);
    try testing.expect(!fs.ime.marked);
    try testing.expectEqual(@as(u32, 1), fs.frames);
    try testing.expectEqual(@as(usize, 1), fs.seen_len);
    try testing.expect(fs.seen_first.? == .unmark);
}

test "WM_IME_REQUEST answers a whole COMPOSITIONFORM at the caret" {
    const ui = @import("../ui/ui.zig");
    const gpa = std.testing.allocator;
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    // The buffer is the form, not eight bytes of it: the style, the point and
    // the area all arrive, or the IME reads garbage where they were.
    var form: ime.COMPOSITIONFORM = undefined;
    const r = ime.request(&t.ctx, 2, ime.IMR_COMPOSITIONWINDOW, @bitCast(@intFromPtr(&form)));
    try testing.expectEqual(@as(isize, 1), r);
    const f = t.ctx.focused_text.?;
    try testing.expectEqual(@as(u32, ime.CFS_FORCE_POSITION), form.dwStyle);
    try testing.expectEqual(@as(i32, @intFromFloat(f.caret_rect.x * 2)), form.ptCurrentPos.x);
    try testing.expectEqual(@as(i32, @intFromFloat(f.caret_rect.y * 2)), form.ptCurrentPos.y);
    // The caret's own line, not a square the size of the caret.
    try testing.expect(form.rcArea.bottom > form.rcArea.top);
}

test "WM_IME_REQUEST keeps the candidate list the query was about" {
    const ui = @import("../ui/ui.zig");
    const gpa = std.testing.allocator;
    var s: Field = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Type");
    // The index of the list lives in the form the IME hands over, preset;
    // filling the answer must not take it back out, or list 3's window goes
    // where list 0's belonged.
    var form: ime.CANDIDATEFORM = .{ .dwIndex = 3 };
    const r = ime.request(&t.ctx, 2, ime.IMR_CANDIDATEWINDOW, @bitCast(@intFromPtr(&form)));
    try testing.expectEqual(@as(isize, 1), r);
    try testing.expectEqual(@as(u32, 3), form.dwIndex);
    try testing.expectEqual(@as(u32, ime.CFS_EXCLUDE), form.dwStyle);
    try testing.expect(form.rcArea.bottom > form.rcArea.top);
}
