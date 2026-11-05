//! Puts a broken line's pieces in their places: the line's height and
//! baseline from its inline boxes, alignment, runs, fragments and atoms.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const inl = @import("inline.zig");
const Box = box.Box;
const Piece = box.Piece;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

pub const OutRun = struct { owner: *Box, run: box.TextRun };
pub const OutFrag = struct { box: *Box, rect: box.Rect };

/// An inline box on the current line. `raise` is how far its baseline is above
/// the line's; `a` and `d` its extent around that with half-leading added.
pub const Frame = struct {
    box: *Box,
    style: *const css.Style,
    raise: f32 = 0,
    a: f32,
    d: f32,
    asc: f32,
    desc: f32,
    x_height: f32,
    /// The left of its fragment on this line.
    left: f32 = 0,
    opened: bool = false,
};

pub fn frameOf(c: *Ctx, b: *Box, s: *const css.Style, parent: ?*const Frame) Frame {
    const m = c.metrics(box.fontOf(s));
    const lh = c.lineHeight(s);
    // Whole pixels above the text, as Chromium's half-leading, the rest below.
    const half = @floor((lh - m.ascent - m.descent) / 2 + 0.001);
    var f: Frame = .{ .box = b, .style = s, .a = m.ascent + half, .d = lh - m.ascent - half, .asc = m.ascent, .desc = m.descent, .x_height = if (m.x_height > 0) m.x_height else ctx.clean(s.font_size) * 0.5 };
    if (parent) |q| f.raise = raiseOf(s.vertical_align, q, f.a, f.d);
    return f;
}

fn raiseOf(v: css.VerticalAlign, q: *const Frame, a: f32, d: f32) f32 {
    const size = ctx.clean(q.style.font_size);
    return switch (v) {
        .baseline, .top, .bottom => q.raise,
        // Blink's: a fifth or a third of the size, and a pixel.
        .sub => q.raise - (size / 5 + 1),
        .super => q.raise + size / 3 + 1,
        .middle => q.raise + q.x_height / 2 - (a - d) / 2,
        .text_top => q.raise + q.asc - a,
        .text_bottom => q.raise - q.desc + d,
    };
}

fn isAligned(v: css.VerticalAlign) bool {
    return v == .top or v == .bottom;
}

const Extent = struct {
    up: f32 = 0,
    down: f32 = 0,
    aligned: f32 = 0,

    fn add(e: *Extent, f: *const Frame) void {
        if (isAligned(f.style.vertical_align) and f.box.kind == .inline_box) {
            e.aligned = @max(e.aligned, f.a + f.d);
            return;
        }
        e.up = @max(e.up, f.raise + f.a);
        e.down = @max(e.down, f.d - f.raise);
    }
};

/// An atom's baseline from its margin box's top.
fn atomAscent(b: *const Box) f32 {
    const whole = b.h + b.margin.vertical();
    if (b.kind == .replaced) return whole;
    if (b.kind == .block and b.style.clips()) return whole;
    const base = if (b.kind == .block) b.lay.last_baseline else b.lay.first_baseline;
    if (base) |v| return b.margin.top + v;
    return whole;
}

fn measure(l: *inl.Lay, line: inl.Line) Error!Extent {
    const c = l.c;
    var e: Extent = .{};
    l.tmp.clearRetainingCapacity();
    try l.tmp.appendSlice(c.arena, l.stack.items);
    if (!line.has) return e;
    if (!c.quirks) for (l.tmp.items) |*f| e.add(f);
    var i = line.start.i;
    while (i < line.end_i) : (i += 1) {
        const p = &l.pieces[i];
        const top = &l.tmp.items[l.tmp.items.len - 1];
        switch (p.tag) {
            .open => {
                const f = frameOf(c, p.box, p.style, top);
                try l.tmp.append(c.arena, f);
                if (!c.quirks or p.w > 0 or ctx.bpV(p.box) > 0) e.add(&f);
            },
            .close => if (l.tmp.items.len > 1) {
                l.tmp.items.len -= 1;
            },
            .word, .tab, .newline, .bullet => e.add(top),
            .space => if (i < line.content_end) e.add(top),
            .atom => {
                const b = p.box;
                const whole = b.h + b.margin.vertical();
                const a = atomAscent(b);
                const d = whole - a;
                const v = b.style.vertical_align;
                if (isAligned(v)) {
                    e.aligned = @max(e.aligned, whole);
                } else {
                    const r = raiseOf(v, top, a, d);
                    e.up = @max(e.up, r + a);
                    e.down = @max(e.down, d - r);
                }
            },
            else => {},
        }
    }
    return e;
}

const Writer = struct {
    l: *inl.Lay,
    cur: ?OutRun = null,
    cur_plain: bool = false,

    fn flush(w: *Writer) Error!void {
        if (w.cur) |r| try w.l.runs.append(w.l.c.arena, r);
        w.cur = null;
    }

    /// Adds text at `x`, to the run in progress when it follows on in the same text.
    fn text(w: *Writer, p: *const Piece, bytes: []const u8, start: ?u32, x: f32, adv: f32, f: *const Frame, base: f32, extra: f32, line_top: f32, line_h: f32) Error!void {
        const owner = p.box;
        if (w.cur) |*r| {
            const end = r.run.text.ptr + r.run.text.len;
            if (r.owner == owner and r.run.node == p.node and end == bytes.ptr and r.run.style == p.style) {
                r.run.text = r.run.text.ptr[0 .. r.run.text.len + bytes.len];
                r.run.w += adv;
                return;
            }
        }
        try w.flush();
        w.cur = .{ .owner = owner, .run = .{
            .text = bytes,
            .node = p.node,
            .start = start,
            .x = x,
            .baseline = base - f.raise,
            .w = adv,
            .font = p.font,
            .style = p.style,
            .line_top = line_top,
            .line_h = line_h,
            .spacing = ctx.clean(p.style.letter_spacing),
            .word_spacing = ctx.clean(p.style.word_spacing) + extra,
        } };
    }
};

fn alignOf(p: *const Box) css.TextAlign {
    return p.lay.text_align orelse p.style.text_align;
}

/// Whether nothing with a width follows this point.
fn nothingAfter(l: *const inl.Lay) bool {
    var i = l.at.i;
    if (l.at.off > 0) return false;
    while (i < l.pieces.len) : (i += 1) switch (l.pieces[i].tag) {
        .word, .atom, .newline, .tab, .bullet => return false,
        .open, .close => if (l.pieces[i].w > 0) return false,
        else => {},
    };
    return true;
}

pub fn placeLine(l: *inl.Lay, line: inl.Line) Error!void {
    const c = l.c;
    const e = try measure(l, line);
    const natural = e.up + e.down;
    const h = if (line.has) @max(natural, e.aligned) else 0;
    const base = l.y + e.up + l.tb;
    const line_top = l.y + l.tb;

    // Alignment.
    const avail = l.x1 - l.x0;
    const free = avail - line.w;
    const last = line.forced or nothingAfter(l);
    var a = alignOf(l.p);
    const rtl = l.p.style.rtl;
    if (a == .start) a = if (rtl) .right else .left;
    if (a == .end) a = if (rtl) .left else .right;
    if (a == .justify and last) a = if (rtl) .right else .left;
    var pen = l.x0 + l.bl + (if (l.first) l.indent else 0);
    if (a == .right and (free > 0 or rtl)) pen += free;
    if (a == .center and free > 0) pen += free / 2;
    var extra: f32 = 0;
    if (a == .justify and free > 0) {
        var spaces: f32 = 0;
        var i = line.start.i;
        var seen = false;
        while (i < line.content_end and i < line.end_i) : (i += 1) {
            const t = l.pieces[i].tag;
            if (t == .word or t == .atom) seen = true;
            if (t == .space and seen) spaces += 1;
        }
        if (spaces > 0) extra = free / spaces;
    }

    for (l.stack.items) |*f| {
        f.left = pen;
        f.opened = false;
    }
    // Inline boxes still open: their raises may differ on this line only when
    // aligned to it, which is worked out from this line's extent.
    for (l.stack.items, 0..) |*f, idx| if (idx > 0) {
        f.raise = raiseFor(f, &l.stack.items[idx - 1], e, h);
    };

    var w: Writer = .{ .l = l };
    var seen = false;
    const runs_from = l.runs.items.len;
    var i = line.start.i;
    while (i < line.end_i) : (i += 1) {
        const p = &l.pieces[i];
        const top = &l.stack.items[l.stack.items.len - 1];
        switch (p.tag) {
            .open => {
                var f = frameOf(c, p.box, p.style, top);
                f.raise = raiseFor(&f, top, e, h);
                f.left = pen + p.box.margin.left;
                f.opened = true;
                try l.stack.append(c.arena, f);
                pen += p.w;
            },
            .close => if (l.stack.items.len > 1) {
                const f = l.stack.pop().?;
                try frag(l, &f, pen + p.box.border.right + p.box.padding.right, base, line.has);
                pen += p.w;
            },
            .word => {
                const from = if (i == line.start.i) line.start.off else 0;
                const to: u32 = if (i + 1 == line.end_i and line.end_off > 0) line.end_off else @intCast(p.text.len);
                const whole = from == 0 and to == p.text.len;
                const adv = if (whole) p.w else inl.partWidth(c, p, from, to);
                try w.text(p, p.text[from..to], if (p.plain) p.start + from else null, pen, adv, top, base, extra, line_top, h);
                pen += adv;
                seen = true;
            },
            .space => {
                if (!p.preserved and !seen) continue;
                if (i >= line.content_end and !p.preserved) continue;
                if (i >= line.content_end) continue;
                const adv = p.w + extra;
                const decorated = p.style.underline or p.style.line_through or p.style.overline;
                if (p.sliced or decorated) {
                    try w.text(p, p.text, if (p.plain) p.start else null, pen, adv, top, base, extra, line_top, h);
                } else try w.flush();
                pen += adv;
            },
            .tab => {
                try w.flush();
                const from = pen - l.x0 - l.bl;
                pen += if (p.w > 0) p.w - @rem(from, p.w) else 0;
                seen = true;
            },
            .newline => try w.flush(),
            .bullet => {
                try w.flush();
                const size = ctx.clean(p.style.font_size) * 0.35;
                const b = l.p;
                b.marker = .{ .x = pen, .y = base - top.raise - top.asc * 0.5 - size / 2, .w = size, .h = size };
                pen += p.w;
                seen = true;
            },
            .atom => {
                try w.flush();
                const b = p.box;
                const whole = b.h + b.margin.vertical();
                const v = b.style.vertical_align;
                const ma = atomAscent(b);
                const y_top = switch (v) {
                    .top => line_top,
                    .bottom => line_top + h - whole,
                    else => base - raiseOf(v, top, ma, whole - ma) - ma,
                };
                b.x = pen + b.margin.left;
                b.y = y_top + b.margin.top;
                pen += p.w;
                seen = true;
            },
            .abs => {
                // A box that was block-level would start a line of its own.
                if (p.box.style.was_block and seen) {
                    p.box.x = l.x0 + l.bl;
                    p.box.y = line_top + h;
                } else {
                    p.box.x = pen;
                    p.box.y = line_top;
                }
            },
            .float, .opp => {},
        }
    }
    try w.flush();
    for (l.stack.items[1..]) |*f| try frag(l, f, pen, base, line.has);

    if (line.has) {
        l.res.lines += 1;
        const b0 = base - l.stack.items[0].raise;
        if (l.first_base == null) l.first_base = b0;
        l.last_base = b0;
        if (line.w > avail) try ellipsis(l, runs_from);
    }
    l.y += h;
}

fn raiseFor(f: *const Frame, parent: *const Frame, e: Extent, h: f32) f32 {
    return switch (f.style.vertical_align) {
        .top => e.up - f.a,
        .bottom => f.d - (h - e.up),
        else => raiseOf(f.style.vertical_align, parent, f.a, f.d),
    };
}

fn frag(l: *inl.Lay, f: *const Frame, right: f32, base: f32, has_line: bool) Error!void {
    const b = f.box;
    // On a line with nothing on it, it has no height either.
    if (!has_line and right <= f.left) {
        try l.frags.append(l.c.arena, .{ .box = b, .rect = .{ .x = f.left, .y = base, .w = 0, .h = 0 } });
        return;
    }
    const top = base - f.raise - f.asc - b.border.top - b.padding.top;
    const h = f.asc + f.desc + ctx.bpV(b);
    try l.frags.append(l.c.arena, .{ .box = b, .rect = .{ .x = f.left, .y = top, .w = @max(0, right - f.left), .h = h } });
}

/// `text-overflow: ellipsis`: the line's last run cut where the "…" fits.
fn ellipsis(l: *inl.Lay, from: usize) Error!void {
    const p = l.p;
    if (!p.style.text_overflow_ellipsis or !p.style.clips()) return;
    const c = l.c;
    const dots = "\u{2026}";
    var i = l.runs.items.len;
    while (i > from) {
        i -= 1;
        const r = &l.runs.items[i].run;
        const limit = l.bl + l.x1 - c.width(dots, r.font);
        if (r.x >= limit) {
            if (i > from) {
                l.runs.items.len = i;
                continue;
            }
        }
        var lo: usize = 0;
        var hi: usize = r.text.len;
        while (hi - lo > 1) {
            const mid = @import("text.zig").charFloor(r.text, (lo + hi) / 2);
            if (mid <= lo) break;
            if (r.x + c.width(r.text[0..mid], r.font) <= limit) lo = mid else hi = mid;
        }
        const kept = r.text[0..lo];
        const text = try c.arena.alloc(u8, kept.len + dots.len);
        @memcpy(text[0..kept.len], kept);
        @memcpy(text[kept.len..], dots);
        r.w = c.width(text, r.font);
        r.text = text;
        r.start = null;
        return;
    }
}

/// Hands the runs and fragments out to the boxes they are in.
pub fn finish(l: *inl.Lay) Error!void {
    const a = l.c.arena;
    for (l.runs.items) |*o| o.owner.lay.run_count += 1;
    for (l.frags.items) |*o| o.box.lay.frag_count += 1;
    for (l.runs.items) |*o| {
        const b = o.owner;
        if (b.runs.len == 0 and b.lay.run_count > 0) {
            const buf = try a.alloc(box.TextRun, b.lay.run_count);
            b.runs = buf[0..0];
            b.lay.run_count = 0;
        }
        const buf: [*]box.TextRun = @constCast(b.runs.ptr);
        buf[b.runs.len] = o.run;
        b.runs = buf[0 .. b.runs.len + 1];
    }
    for (l.frags.items) |*o| {
        const b = o.box;
        if (b.frags.len == 0 and b.lay.frag_count > 0) {
            const buf = try a.alloc(box.Rect, b.lay.frag_count);
            b.frags = buf[0..0];
            b.lay.frag_count = 0;
        }
        const buf: [*]box.Rect = @constCast(b.frags.ptr);
        buf[b.frags.len] = o.rect;
        b.frags = buf[0 .. b.frags.len + 1];
    }
    // The inline boxes' unions.
    for (l.pieces) |*pc| if (pc.tag == .open) {
        const b = pc.box;
        if (b.frags.len == 0) {
            b.x = l.bl;
            b.y = l.tb;
            b.w = 0;
            b.h = 0;
            continue;
        }
        var x0 = b.frags[0].x;
        var y0 = b.frags[0].y;
        var x1 = x0 + b.frags[0].w;
        var y1 = y0 + b.frags[0].h;
        for (b.frags[1..]) |r| {
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + r.w);
            y1 = @max(y1, r.y + r.h);
        }
        b.x = x0;
        b.y = y0;
        b.w = x1 - x0;
        b.h = y1 - y0;
    };
}
