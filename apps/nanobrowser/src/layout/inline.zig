//! The inline formatting context: greedy line breaking over a block's pieces,
//! beside the floats of its block formatting context. Where each thing goes
//! on its line is `inline_place.zig`'s.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const floats_mod = @import("floats.zig");
const sizing = @import("sizing.zig");
const place = @import("inline_place.zig");
const text_mod = @import("text.zig");
const Box = box.Box;
const Piece = box.Piece;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Floats = floats_mod.Floats;

pub const Result = struct { h: f32 = 0, lines: u32 = 0 };
pub const Cursor = struct { i: u32 = 0, off: u32 = 0 };

/// The pieces of one line. The first starts `start.off` bytes in; when
/// `end_off` is set, the last stops that many bytes in.
pub const Line = struct {
    start: Cursor,
    end_i: u32,
    end_off: u32 = 0,
    /// Up to the end of its content, without what hangs over.
    w: f32 = 0,
    /// Something that gives it height; otherwise it is no line at all.
    has: bool = false,
    forced: bool = false,
    /// The pieces from here to `end_i` are trailing spaces.
    content_end: u32,
};

pub const Lay = struct {
    c: *Ctx,
    p: *Box,
    pieces: []Piece,
    cw: f32,
    /// The content box's left in the formatting context, the top of its
    /// inline content there, and the offsets of the content box in the border box.
    cx: f32,
    t: f32,
    tb: f32,
    bl: f32,
    floats: *Floats,
    ch: ?f32,
    /// The current line's top, from the top of the content box.
    y: f32 = 0,
    at: Cursor = .{},
    /// The room on the current line, content box relative.
    x0: f32 = 0,
    x1: f32 = 0,
    indent: f32 = 0,
    first: bool = true,
    strut_h: f32 = 0,
    /// `text-wrap: balance`: lines break as if the room stopped here.
    wrap_w: f32 = std.math.inf(f32),
    res: Result = .{},
    first_base: ?f32 = null,
    last_base: ?f32 = null,
    runs: std.ArrayList(place.OutRun) = .empty,
    frags: std.ArrayList(place.OutFrag) = .empty,
    stack: std.ArrayList(place.Frame) = .empty,
    tmp: std.ArrayList(place.Frame) = .empty,
    deferred: std.ArrayList(*Box) = .empty,

    pub fn band(l: *Lay) void {
        if (!l.floats.any()) {
            l.x0 = 0;
            l.x1 = l.cw;
            return;
        }
        const b = l.floats.band(l.t + l.y, l.strut_h, l.cx, l.cw);
        l.x0 = b.x0 - l.cx;
        l.x1 = b.x1 - l.cx;
    }

    fn placeFloat(l: *Lay, k: *Box) Error!void {
        const pos = try l.floats.place(l.c.arena, k.style.float == .left, k.style.clear, k.w + k.margin.horizontal(), k.h + k.margin.vertical(), l.t + l.y, l.cx, l.cw);
        k.x = pos.x - l.cx + l.bl + k.margin.left;
        k.y = pos.y - l.t + l.tb + k.margin.top;
    }
};

/// Lays out `p`'s inline content in a content box `cw` wide whose top is `t`
/// in the formatting context. Sets runs and frags on the boxes, atoms' and
/// floats' places relative to `p`.
pub fn layout(c: *Ctx, p: *Box, cw: f32, cx: f32, t: f32, floats: *Floats, ch: ?f32) Error!Result {
    var l: Lay = .{
        .c = c,
        .p = p,
        .pieces = p.lay.pieces,
        .cw = cw,
        .cx = cx,
        .t = t,
        .tb = ctx.bpTop(p),
        .bl = ctx.bpLeft(p),
        .floats = floats,
        .ch = ch,
    };
    p.lay.run_count = 0;
    p.marker = null;
    p.lay.first_baseline = null;
    p.lay.last_baseline = null;
    p.runs = &.{};
    try prepare(&l);
    try l.stack.append(c.arena, place.frameOf(c, p, p.style, null));
    l.strut_h = c.lineHeight(p.style);
    l.indent = ctx.len(p.style.text_indent, cw);

    if (p.style.text_balance and !floats.any()) try balance(&l);
    const n: u32 = @intCast(l.pieces.len);
    while (l.at.i < n) {
        const line = try buildLine(&l);
        try place.placeLine(&l, line);
        l.first = l.first and !line.has;
        if (l.deferred.items.len > 0) {
            for (l.deferred.items) |k| try l.placeFloat(k);
            l.deferred.clearRetainingCapacity();
        }
    }
    try place.finish(&l);
    p.lay.first_baseline = l.first_base;
    p.lay.last_baseline = l.last_base;
    l.res.h = l.y;
    return l.res;
}

/// Sizes what is not text. Each box is laid out once per pass over the block.
fn prepare(l: *Lay) Error!void {
    const c = l.c;
    for (l.pieces) |*pc| switch (pc.tag) {
        .open => {
            const b = pc.box;
            ctx.setEdges(b, l.cw);
            b.lay.run_count = 0;
            b.lay.frag_count = 0;
            b.runs = &.{};
            b.frags = &.{};
            pc.w = b.margin.left + ctx.bpLeft(b);
        },
        .close => {
            const b = pc.box;
            pc.w = b.margin.right + b.border.right + b.padding.right;
        },
        .atom => {
            const b = pc.box;
            ctx.setEdges(b, l.cw);
            const w = try sizing.fitWidth(c, b, l.cw, l.ch);
            _ = try sizing.place(c, b, w, l.ch, null);
            pc.w = b.w + b.margin.horizontal();
        },
        .float => try sizing.floatSize(c, pc.box, l.cw, l.ch),
        .bullet => pc.w = ctx.clean(pc.style.font_size) * 0.85,
        else => {},
    };
}

/// The most lines `text-wrap: balance` looks at, as in Chromium.
const balance_lines = 10;

/// How many lines the content takes at the width being tried, past the limit
/// reported as more than it. Nothing is placed.
fn countLines(l: *Lay) Error!u32 {
    const n: u32 = @intCast(l.pieces.len);
    var lines: u32 = 0;
    l.at = .{};
    while (l.at.i < n and lines <= balance_lines) {
        const line = try buildLine(l);
        if (line.has) lines += 1;
    }
    l.at = .{};
    return lines;
}

/// The narrowest width that takes no more lines than the full width does.
fn balance(l: *Lay) Error!void {
    for (l.pieces) |*pc| if (pc.tag == .float or pc.tag == .newline) return;
    const want = try countLines(l);
    if (want < 2 or want > balance_lines) return;
    var lo: f32 = 0;
    var hi: f32 = l.cw;
    var tries: u8 = 0;
    while (tries < 12 and hi - lo > 1) : (tries += 1) {
        const mid = (lo + hi) / 2;
        l.wrap_w = mid;
        if (try countLines(l) <= want) hi = mid else lo = mid;
    }
    l.wrap_w = hi;
}

const Brk = struct { at: Cursor, w: f32, content_end: u32 };

fn buildLine(l: *Lay) Error!Line {
    const c = l.c;
    const n: u32 = @intCast(l.pieces.len);
    l.band();
    var line: Line = .{ .start = l.at, .end_i = n, .content_end = l.at.i };
    var i = l.at.i;
    var off = l.at.off;
    var w: f32 = if (l.first) l.indent else 0;
    var tail: f32 = 0;
    var brk: ?Brk = null;
    while (i < n) {
        const p = &l.pieces[i];
        const avail = @min(l.x1 - l.x0, l.wrap_w);
        switch (p.tag) {
            .abs => i += 1,
            .opp => {
                if (line.has) brk = .{ .at = .{ .i = i + 1 }, .w = w, .content_end = line.content_end };
                i += 1;
            },
            .float => {
                const fw = p.box.w + p.box.margin.horizontal();
                if (!line.has or w + tail + fw <= avail) {
                    try l.placeFloat(p.box);
                    l.band();
                } else try l.deferred.append(c.arena, p.box);
                i += 1;
            },
            .open, .close => {
                if (p.w > 0) {
                    w += tail + p.w;
                    tail = 0;
                    line.content_end = i + 1;
                    line.has = true;
                }
                if (p.box.border.top > 0 or p.box.padding.top > 0) line.has = true;
                i += 1;
            },
            .newline => {
                line.has = true;
                line.forced = true;
                line.w = w;
                line.end_i = i + 1;
                l.at = .{ .i = i + 1 };
                return line;
            },
            .space => {
                if (!p.preserved and !line.has) {
                    i += 1;
                    continue;
                }
                if (p.preserved) line.has = true;
                if (p.wraps and line.has) brk = .{ .at = .{ .i = i + 1 }, .w = w, .content_end = line.content_end };
                tail += p.w;
                i += 1;
            },
            .tab => {
                const stop = p.w;
                const pen = w + tail;
                const adv = if (stop > 0) stop - @rem(pen, stop) else 0;
                if (pen + adv > avail + 0.001 and p.wraps) if (brk) |b| return endAt(l, &line, b);
                w = pen + adv;
                tail = 0;
                line.has = true;
                line.content_end = i + 1;
                i += 1;
            },
            .bullet => {
                w += tail + p.w;
                tail = 0;
                line.has = true;
                line.content_end = i + 1;
                i += 1;
            },
            .atom => {
                const parent_ws = if (p.box.parent) |q| q.style.white_space else css.WhiteSpace.normal;
                const wrappy = (parent_ws == .normal or parent_ws == .pre_wrap or parent_ws == .pre_line) and !l.p.lay.nowrap;
                if (wrappy and line.has) brk = .{ .at = .{ .i = i }, .w = w, .content_end = line.content_end };
                if (w + tail + p.w > avail + 0.001) {
                    if (!line.has and moveDown(l, avail)) continue;
                    if (brk) |b| if (b.at.i > line.start.i or b.at.off > line.start.off) return endAt(l, &line, b);
                }
                w += tail + p.w;
                tail = 0;
                line.has = true;
                line.content_end = i + 1;
                i += 1;
                if (wrappy) brk = .{ .at = .{ .i = i }, .w = w, .content_end = line.content_end };
            },
            .word => {
                const s = p.style;
                const pw = if (off > 0) restWidth(c, p, off) else p.w;
                if (w + tail + pw > avail + 0.001) {
                    if (!line.has and moveDown(l, avail)) continue;
                    const breaks_anywhere = s.word_break_all or s.line_break_anywhere or (s.overflow_wrap_anywhere and brk == null);
                    if (breaks_anywhere and s.white_space != .nowrap and s.white_space != .pre) {
                        const room = avail - w - tail;
                        const cut = cutWord(c, p, off, room);
                        if (cut > off or !line.has) {
                            const take = if (cut > off) cut else off + @as(u32, @intCast(text_mod.seqLen(p.text, off)));
                            if (take < p.text.len) {
                                line.w = w + tail + partWidth(c, p, off, take);
                                line.has = true;
                                line.end_i = i + 1;
                                line.end_off = take;
                                line.content_end = i + 1;
                                l.at = .{ .i = i, .off = take };
                                return line;
                            }
                        } else {
                            line.w = w;
                            line.end_i = i;
                            l.at = .{ .i = i, .off = off };
                            return line;
                        }
                    } else if (brk) |b| return endAt(l, &line, b);
                }
                w += tail + pw;
                tail = 0;
                off = 0;
                line.has = true;
                line.content_end = i + 1;
                i += 1;
                if (p.brk) brk = .{ .at = .{ .i = i }, .w = w, .content_end = line.content_end };
            },
        }
    }
    line.w = w;
    l.at = .{ .i = n };
    return line;
}

fn endAt(l: *Lay, line: *Line, b: Brk) Line {
    line.w = b.w;
    line.end_i = b.at.i;
    line.content_end = b.content_end;
    l.at = b.at;
    return line.*;
}

/// Floats narrow this line and what comes first does not fit: tries lower.
fn moveDown(l: *Lay, avail: f32) bool {
    if (avail >= l.cw) return false;
    const next = l.floats.nextBelow(l.t + l.y) orelse return false;
    l.y = next - l.t;
    l.band();
    return true;
}

fn spaced(p: *const Piece, bytes: []const u8, w: f32) f32 {
    if (p.style.letter_spacing == 0) return w;
    return w + ctx.clean(p.style.letter_spacing) * text_mod.charCount(bytes);
}

/// A part of a word's advance. Used only by words being cut.
pub fn partWidth(c: *Ctx, p: *const Piece, from: u32, to: u32) f32 {
    const bytes = p.text[from..to];
    return spaced(p, bytes, c.width(bytes, p.font));
}

/// What is left of a cut word. Very long words estimate, not to measure a
/// megabyte for each of its lines; the estimate only decides whether to cut again.
fn restWidth(c: *Ctx, p: *const Piece, off: u32) f32 {
    const left = p.text.len - off;
    if (left > 512) return p.w * @as(f32, @floatFromInt(left)) / @as(f32, @floatFromInt(p.text.len));
    return partWidth(c, p, off, @intCast(p.text.len));
}

/// The most of a word from `off` that fits in `room`; `off` for none.
fn cutWord(c: *Ctx, p: *const Piece, off: u32, room: f32) u32 {
    if (room <= 0) return off;
    const len: usize = p.text.len;
    const per = @max(0.01, p.w / @as(f32, @floatFromInt(@max(len, 1))));
    var hi: usize = @min(len, off + @as(usize, @intFromFloat(@min(room / per * 2 + 8, 1e9))));
    var lo: usize = off;
    while (hi - lo > 1) {
        const mid = text_mod.charFloor(p.text, (lo + hi) / 2);
        if (mid <= lo) {
            hi = lo + text_mod.seqLen(p.text, lo);
            break;
        }
        if (partWidth(c, p, off, @intCast(mid)) <= room) lo = mid else hi = mid;
    }
    hi = text_mod.charFloor(p.text, hi);
    if (hi > lo and partWidth(c, p, off, @intCast(hi)) <= room) lo = hi;
    return @intCast(lo);
}
