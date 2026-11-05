//! Min-content and max-content widths, memoized on each box: they do not
//! depend on the width available, so one walk answers every question and deep
//! nesting costs no more than its size. Percentages count as auto here.
const std = @import("std");
const box = @import("box.zig");
const ctx = @import("ctx.zig");
const flex = @import("flex.zig");
const grid = @import("grid.zig");
const table = @import("table.zig");
const replaced = @import("replaced.zig");
const multicol = @import("multicol.zig");
const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

pub const Sizes = struct { min: f32 = 0, max: f32 = 0 };

/// The box's border-box widths, its own `width`, `min-width` and `max-width`
/// included when they are lengths.
pub fn of(c: *Ctx, b: *Box) Error!Sizes {
    const n = &b.lay;
    if (n.intrinsic_known) return .{ .min = n.min_w, .max = n.max_w };
    const s = b.style;
    const e = ctx.edgesOf(s, 0);
    const bp = e.border.horizontal() + e.padding.horizontal();
    var out: Sizes = switch (b.kind) {
        .replaced => try replaced.intrinsic(c, b),
        .control => try replaced.controlIntrinsic(c, b),
        .table => try table.intrinsic(c, b),
        .flex => try flex.intrinsic(c, b),
        .grid => try grid.intrinsic(c, b),
        else => if (n.inline_root) try inlineSizes(c, b) else try blockSizes(c, b),
    };
    if (b.kind == .block and (s.column_count > 0 or s.column_width > 0)) out = multicol.intrinsic(s, out);
    // `contain: size` or `inline-size`: what's inside asks for nothing.
    if ((s.contain_size or s.contain_inline_size) and b.kind != .replaced) out = .{};
    if (b.kind != .replaced and b.kind != .control and b.kind != .table) {
        out.min += bp;
        out.max += bp;
    }
    n.content_min = out.min;
    n.content_max = out.max;
    // A height and a shape say the width, whatever's inside.
    if (b.kind != .replaced and s.aspect_ratio > 0 and s.width.kind == .auto) if (fixed(s.height, s.box_sizing == .border_box, ctx_bpv(e))) |h| {
        const ratio = ctx.clean(s.aspect_ratio);
        const v = if (s.box_sizing == .border_box) h * ratio else (h - ctx_bpv(e)) * ratio + bp;
        out = .{ .min = @max(v, out.min), .max = @max(v, out.min) };
    };
    if (b.kind != .replaced) {
        if (fixed(s.width, s.box_sizing == .border_box, bp)) |v| {
            // A table never gets narrower than its content.
            const least = if (b.kind == .table) out.min else 0;
            out = .{ .min = @max(v, least), .max = @max(v, least) };
        }
    }
    if (fixed(s.max_width, s.box_sizing == .border_box, bp)) |v| {
        out.min = @min(out.min, v);
        out.max = @min(out.max, v);
    }
    if (fixed(s.min_width, s.box_sizing == .border_box, bp)) |v| {
        out.min = @max(out.min, v);
        out.max = @max(out.max, v);
    }
    out.min = ctx.clean(out.min);
    out.max = @max(ctx.clean(out.max), out.min);
    n.intrinsic_known = true;
    n.min_w = out.min;
    n.max_w = out.max;
    return out;
}

fn ctx_bpv(e: ctx.EdgeSet) f32 {
    return e.border.vertical() + e.padding.vertical();
}

/// A length with no percentage, as a border-box size.
fn fixed(l: ctx.Len, border_box: bool, bp: f32) ?f32 {
    if (l.kind != .length or l.hasPct()) return null;
    const v = @max(0, ctx.clean(l.px));
    return if (border_box) @max(v, bp) else v + bp;
}

/// With the box's margins, as its parent sees it.
pub fn outer(c: *Ctx, b: *Box) Error!Sizes {
    const i = try of(c, b);
    const e = ctx.edgesOf(b.style, 0);
    const m = e.margin.horizontal();
    return .{ .min = @max(0, i.min + m), .max = @max(0, i.max + m) };
}

fn blockSizes(c: *Ctx, b: *Box) Error!Sizes {
    var out: Sizes = .{};
    var float_max: f32 = 0;
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.style.isOutOfFlow()) continue;
        const i = try outer(c, x);
        out.min = @max(out.min, i.min);
        if (x.style.float != .none) {
            if (x.style.clear != .none) {
                out.max = @max(out.max, float_max);
                float_max = 0;
            }
            float_max += i.max;
        } else {
            out.max = @max(out.max, float_max + (if (ctx.isBfcRoot(x)) i.max else 0));
            if (x.style.clear != .none) float_max = 0;
            out.max = @max(out.max, i.max);
        }
    }
    out.max = @max(out.max, float_max);
    return out;
}

const Tally = struct {
    /// The longest line, and the widest thing that cannot break.
    out: Sizes = .{},
    line: f32 = 0,
    word: f32 = 0,
    tail: f32 = 0,
    floats: f32 = 0,

    fn endWord(t: *Tally) void {
        t.out.min = @max(t.out.min, t.word);
        t.word = 0;
    }

    fn endLine(t: *Tally) void {
        t.endWord();
        t.out.max = @max(t.out.max, t.line);
        t.line = 0;
        t.tail = 0;
    }
};

/// Word by word: the pieces are measured already.
fn inlineSizes(c: *Ctx, b: *Box) Error!Sizes {
    var t: Tally = .{};
    t.line = @max(0, ctx.len(b.style.text_indent, 0));
    t.word = t.line;
    for (b.lay.pieces) |*p| switch (p.tag) {
        .word => {
            t.line += t.tail + p.w;
            t.tail = 0;
            if (p.style.word_break_all or p.style.line_break_anywhere or p.style.overflow_wrap_anywhere) {
                const chars = @import("text.zig").charCount(p.text);
                t.endWord();
                t.out.min = @max(t.out.min, p.w / @max(1, chars));
            } else {
                t.word += p.w;
                if (p.brk) t.endWord();
            }
        },
        .space => {
            if (t.line > 0 or p.preserved) t.tail += p.w;
            if (p.wraps) t.endWord() else if (t.word > 0) t.word += p.w;
        },
        .tab => {
            t.line += t.tail + p.w;
            t.tail = 0;
            t.word += p.w;
        },
        .bullet => {
            t.line += t.tail + ctx.clean(p.style.font_size) * 0.85;
            t.tail = 0;
        },
        .opp => t.endWord(),
        .newline => t.endLine(),
        .open => {
            const e = ctx.edgesOf(p.box.style, 0);
            const w = e.margin.left + e.border.left + e.padding.left;
            t.line += t.tail + w;
            t.tail = 0;
            t.word += w;
        },
        .close => {
            const e = ctx.edgesOf(p.box.style, 0);
            const w = e.margin.right + e.border.right + e.padding.right;
            t.line += w;
            t.word += w;
        },
        .atom => {
            const i = try outer(c, p.box);
            const ws = if (p.box.parent) |q| q.style.white_space else .normal;
            const wraps = (ws == .normal or ws == .pre_wrap or ws == .pre_line) and !b.lay.nowrap;
            t.line += t.tail + i.max;
            t.tail = 0;
            if (wraps) {
                t.endWord();
                t.out.min = @max(t.out.min, i.min);
            } else t.word += i.min;
        },
        .float => {
            const i = try outer(c, p.box);
            t.out.min = @max(t.out.min, i.min);
            t.floats += i.max;
        },
        .abs => {},
    };
    t.endLine();
    t.out.max += t.floats;
    return t.out;
}
