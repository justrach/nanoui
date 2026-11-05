//! Turns an inline formatting context's entries into pieces: text cut at its
//! break opportunities, whitespace collapsed across inline boundaries, each
//! word measured once. Line breaking only ever walks the result.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const Box = box.Box;
const Piece = box.Piece;
const Entry = box.Entry;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

const Builder = struct {
    c: *Ctx,
    root: *Box,
    out: std.ArrayList(Piece) = .empty,
    /// The last thing kept was a collapsible space (or nothing yet): the next is dropped.
    after_space: bool = true,
    /// `capitalize` is at the start of a word.
    word_start: bool = true,
};

/// Builds `root.lay.pieces` from `root.lay.entries`.
pub fn build(c: *Ctx, root: *Box) Error!void {
    var b: Builder = .{ .c = c, .root = root };
    try walk(&b, root.lay.entries, root);
    root.lay.pieces = b.out.items;
}

fn walk(b: *Builder, entries: []const Entry, owner: *Box) Error!void {
    for (entries) |e| switch (e.tag) {
        .text => try addText(b, e.text, e.node, e.style orelse owner.style, owner),
        .generated => try addText(b, e.text, null, e.style orelse owner.style, owner),
        .br => {
            try b.out.append(b.c.arena, .{ .tag = .newline, .box = owner, .style = e.style orelse owner.style });
            b.after_space = true;
        },
        .wbr => try b.out.append(b.c.arena, .{ .tag = .opp, .box = owner, .style = owner.style }),
        .bullet => {
            try b.out.append(b.c.arena, .{ .tag = .bullet, .box = owner, .style = e.style orelse owner.style });
            b.after_space = false;
        },
        .box => {
            const k = e.box.?;
            const s = k.style;
            if (s.isOutOfFlow()) {
                try b.out.append(b.c.arena, .{ .tag = .abs, .box = k, .style = s });
            } else if (s.float != .none) {
                try b.out.append(b.c.arena, .{ .tag = .float, .box = k, .style = s });
            } else if (k.kind == .inline_box) {
                try b.out.append(b.c.arena, .{ .tag = .open, .box = k, .style = s });
                try walk(b, k.lay.entries, k);
                try b.out.append(b.c.arena, .{ .tag = .close, .box = k, .style = s });
            } else {
                try b.out.append(b.c.arena, .{ .tag = .atom, .box = k, .style = s });
                b.after_space = false;
                b.word_start = true;
            }
        },
    };
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c;
}

fn addText(b: *Builder, raw: []const u8, node: ?*@import("../dom.zig").Node, s: *const css.Style, owner: *Box) Error!void {
    if (raw.len == 0) return;
    const c = b.c;
    const data = if (s.text_transform == .none) raw else try transformed(c, raw, s.text_transform, &b.word_start);
    const plain = node != null and data.ptr == raw.ptr;
    const font = box.fontOf(s);
    const wrap_mode = s.white_space;
    const nowrap_hint = b.root.lay.nowrap;
    const wraps = (wrap_mode == .normal or wrap_mode == .pre_wrap or wrap_mode == .pre_line) and !nowrap_hint;
    const collapse = wrap_mode == .normal or wrap_mode == .nowrap or wrap_mode == .pre_line;
    const keep_lf = wrap_mode == .pre or wrap_mode == .pre_wrap or wrap_mode == .pre_line;
    const space_w = c.width(" ", font) + ctx.clean(s.word_spacing) + ctx.clean(s.letter_spacing);

    var i: usize = 0;
    while (i < data.len) {
        const ch = data[i];
        if (isSpace(ch) and !(keep_lf and ch == '\n') and collapse) {
            var j = i + 1;
            while (j < data.len and isSpace(data[j]) and !(keep_lf and data[j] == '\n')) j += 1;
            if (!b.after_space) {
                const single = j == i + 1 and ch == ' ';
                try b.out.append(c.arena, .{
                    .tag = .space,
                    .text = if (single) data[i .. i + 1] else " ",
                    .w = space_w,
                    .box = owner,
                    .node = node,
                    .style = s,
                    .font = font,
                    .start = @intCast(i),
                    .plain = plain and single,
                    .wraps = wraps,
                    .sliced = single,
                });
                b.after_space = true;
            }
            i = j;
            continue;
        }
        if (ch == '\n' and keep_lf) {
            try b.out.append(c.arena, .{ .tag = .newline, .box = owner, .node = node, .style = s, .font = font });
            b.after_space = collapse;
            i += 1;
            continue;
        }
        if (ch == '\r') {
            i += 1;
            continue;
        }
        if (ch == '\t') {
            try b.out.append(c.arena, .{ .tag = .tab, .box = owner, .node = node, .style = s, .font = font, .w = c.width(" ", font) * @max(1, ctx.clean(s.tab_size)), .wraps = wraps });
            b.after_space = false;
            i += 1;
            continue;
        }
        if (ch == ' ' or ch == 0x0c) {
            // A preserved space: `pre` keeps it on the line; `pre-wrap` may break after.
            if (wraps) {
                try b.out.append(c.arena, .{ .tag = .space, .text = data[i .. i + 1], .w = space_w, .box = owner, .node = node, .style = s, .font = font, .start = @intCast(i), .plain = plain, .preserved = true, .wraps = true, .sliced = true });
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < data.len and data[j] == ' ') j += 1;
            const count: f32 = @floatFromInt(j - i);
            try b.out.append(c.arena, .{ .tag = .word, .text = data[i..j], .w = space_w * count, .box = owner, .node = node, .style = s, .font = font, .start = @intCast(i), .plain = plain });
            b.after_space = false;
            i = j;
            continue;
        }
        i = try addWord(b, data, i, node, s, owner, font, plain, wraps);
        b.after_space = false;
    }
}

/// Adds the text from `from` up to its next whitespace, cut after hyphens and
/// around CJK characters; the index after it.
fn addWord(b: *Builder, data: []const u8, from: usize, node: ?*@import("../dom.zig").Node, s: *const css.Style, owner: *Box, font: box.Font, plain: bool, wraps: bool) Error!usize {
    const c = b.c;
    const spacing = ctx.clean(s.letter_spacing);
    var i = from;
    var start = from;
    var chars: f32 = 0;
    while (i < data.len and !isSpace(data[i])) {
        const n = seqLen(data, i);
        const cp = decode(data[i .. i + n]);
        chars += 1;
        const next = i + n;
        var cut = false;
        var drop: usize = 0;
        if (cp == 0x200B or cp == 0xAD) {
            cut = true;
            drop = n;
            chars -= 1;
        } else if (cp == '-' or cp == 0x2010) {
            cut = next < data.len and !isSpace(data[next]) and !std.ascii.isDigit(data[next]) and i > start;
        } else if (isCjk(cp)) {
            cut = next >= data.len or !isCloser(decode(data[next..@min(next + seqLen(data, next), data.len)]));
        } else if (next < data.len) {
            const nn = seqLen(data, next);
            cut = isCjk(decode(data[next .. next + nn])) and !isCloser(decode(data[next .. next + nn]));
        }
        i = next;
        if (cut and wraps or drop > 0) {
            const stop = i - drop;
            if (stop > start) try wordPiece(b, data[start..stop], start, node, s, owner, font, plain, spacing * chars, wraps and cut);
            if (drop > 0 and wraps) try b.out.append(c.arena, .{ .tag = .opp, .box = owner, .style = s });
            start = i;
            chars = 0;
        }
    }
    if (i > start) try wordPiece(b, data[start..i], start, node, s, owner, font, plain, spacing * chars, false);
    return i;
}

/// A word follows a space of its own font: the space's advance takes in the kerning
/// with the letters on each side, as one shaped run has it, so words summed come to
/// what is painted (`Ta To` is narrower in many fonts than `Ta` and `To` set apart).
fn kernSpace(b: *Builder, text: []const u8, font: box.Font) Error!void {
    const n = b.out.items.len;
    if (n < 2) return;
    const sp = &b.out.items[n - 1];
    const before = b.out.items[n - 2];
    if (sp.tag != .space or before.tag != .word or before.text.len == 0 or !sameFont(sp.font, font) or !sameFont(before.font, font)) return;
    var buf: [10]u8 = undefined;
    const first = seqLen(text, 0);
    var last = before.text.len - 1;
    while (last > 0 and before.text[last] & 0xC0 == 0x80) last -= 1;
    const tail = before.text[last..];
    if (tail.len + first + 1 > buf.len) return;
    @memcpy(buf[0..tail.len], tail);
    buf[tail.len] = ' ';
    @memcpy(buf[tail.len + 1 ..][0..first], text[0..first]);
    const pair = b.c.width(buf[0 .. tail.len + 1 + first], font);
    const alone = b.c.width(tail, font) + b.c.width(text[0..first], font) + b.c.width(" ", font);
    // Letter and word spacing are in `w` and stay.
    sp.w += pair - alone;
}

fn sameFont(a: box.Font, f: box.Font) bool {
    return a.size == f.size and a.weight == f.weight and a.italic == f.italic and a.stretch == f.stretch and a.tabular == f.tabular and a.ligatures == f.ligatures and (a.family.ptr == f.family.ptr or std.mem.eql(u8, a.family, f.family));
}

fn wordPiece(b: *Builder, text: []const u8, start: usize, node: ?*@import("../dom.zig").Node, s: *const css.Style, owner: *Box, font: box.Font, plain: bool, extra: f32, brk: bool) Error!void {
    try kernSpace(b, text, font);
    try b.out.append(b.c.arena, .{
        .tag = .word,
        .text = text,
        .w = b.c.width(text, font) + extra,
        .box = owner,
        .node = node,
        .style = s,
        .font = font,
        .start = @intCast(start),
        .plain = plain,
        .brk = brk,
    });
}

/// The bytes of the UTF-8 sequence at `i`; 1 for anything malformed.
pub fn seqLen(data: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(data[i]) catch return 1;
    if (i + n > data.len) return 1;
    return n;
}

fn decode(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    return std.unicode.utf8Decode(bytes) catch bytes[0];
}

/// Ideographs, kana, hangul and fullwidth forms: a line may break around each.
pub fn isCjk(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFFEF) or
        (cp >= 0x20000 and cp <= 0x2FFFF);
}

/// Punctuation that does not start a line.
fn isCloser(cp: u21) bool {
    return switch (cp) {
        0x3001, 0x3002, 0xFF0C, 0xFF0E, 0xFF09, 0x300D, 0x300F, 0x3011, 0x300B, 0xFF1F, 0xFF01, 0xFF1A, 0xFF1B, 0x3009 => true,
        else => false,
    };
}

/// Applies `text-transform` to a text. Case mapping covers ASCII and the
/// two-byte Latin, Greek and Cyrillic letters whose cases keep their length.
fn transformed(c: *Ctx, raw: []const u8, t: css.TextTransform, word_start: *bool) Error![]const u8 {
    const out = try c.arena.dupe(u8, raw);
    var i: usize = 0;
    while (i < out.len) {
        const n = seqLen(out, i);
        const bytes = out[i .. i + n];
        const upper = switch (t) {
            .uppercase => true,
            .lowercase => false,
            .capitalize => word_start.*,
            .none => false,
        };
        if (t != .capitalize or upper) {
            const cp = decode(bytes);
            const mapped = if (upper) toUpper(cp) else toLower(cp);
            if (mapped != cp) {
                var buf: [4]u8 = undefined;
                const m = std.unicode.utf8Encode(mapped, &buf) catch 0;
                if (m == n) @memcpy(bytes, buf[0..m]);
            }
        }
        word_start.* = isSpace(out[i]) or out[i] == '-' or out[i] == '(' or out[i] == '"' or out[i] == '\'' and word_start.*;
        i += n;
    }
    return out;
}

fn toUpper(cp: u21) u21 {
    if (cp < 128) return std.ascii.toUpper(@intCast(cp));
    if ((cp >= 0xE0 and cp <= 0xFE and cp != 0xF7) or (cp >= 0x3B1 and cp <= 0x3C9 and cp != 0x3C2) or (cp >= 0x430 and cp <= 0x44F)) return cp - 32;
    if (cp >= 0x450 and cp <= 0x45F) return cp - 80;
    return cp;
}

fn toLower(cp: u21) u21 {
    if (cp < 128) return std.ascii.toLower(@intCast(cp));
    if ((cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) or (cp >= 0x391 and cp <= 0x3A9) or (cp >= 0x410 and cp <= 0x42F)) return cp + 32;
    if (cp >= 0x400 and cp <= 0x40F) return cp + 80;
    return cp;
}

/// The next character boundary at or before `i`.
pub fn charFloor(data: []const u8, i_in: usize) usize {
    var i = @min(i_in, data.len);
    while (i > 0 and i < data.len and (data[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

/// Counts characters: what `letter-spacing` multiplies.
pub fn charCount(data: []const u8) f32 {
    var n: f32 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += seqLen(data, i)) n += 1;
    return n;
}
