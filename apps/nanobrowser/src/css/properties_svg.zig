//! SVG's properties: paints, strokes, and what an element's `clip-path` and
//! `mask` name. On an element of the SVG namespace `mask` and `transform` are
//! these rather than the box's. Returns null for anything else.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");
const tk = @import("tokenizer.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const SvgPaint = style.SvgPaint;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = &ctx.style.svg;
    return switch (p) {
        .fill => setPaint(ctx, &s.fill, t),
        .stroke => setPaint(ctx, &s.stroke, t),
        .stop_color => stopColor(ctx, t),
        .fill_opacity => setUnit(ctx, &s.fill_opacity, t),
        .stroke_opacity => setUnit(ctx, &s.stroke_opacity, t),
        .stop_opacity => setUnit(ctx, &s.stop_opacity, t),
        .fill_rule => setRule(&s.fill_evenodd, t),
        .clip_rule => setRule(&s.clip_evenodd, t),
        .stroke_width => setLength(ctx, &s.stroke_width, t),
        .stroke_dashoffset => setLength(ctx, &s.dash_offset, t),
        .stroke_miterlimit => blk: {
            const n = values.numberOf(ctx, t) orelse break :blk false;
            s.miter_limit = @max(1, n);
            break :blk true;
        },
        .stroke_linecap => blk: {
            s.cap = values.keywordOf(style.SvgCap, t) orelse break :blk false;
            break :blk true;
        },
        .stroke_linejoin => blk: {
            s.join = values.keywordOf(style.SvgJoin, t) orelse (if (isIdent(t, "miter-clip") or isIdent(t, "arcs")) style.SvgJoin.miter else break :blk false);
            break :blk true;
        },
        .stroke_dasharray => dashes(ctx, t),
        .paint_order => blk: {
            var c = Cur.of(t);
            const first = c.peek() orelse break :blk false;
            s.stroke_first = first.isIdent("stroke");
            break :blk true;
        },
        .vector_effect => blk: {
            s.non_scaling_stroke = isIdent(t, "non-scaling-stroke");
            break :blk true;
        },
        // A shape is for `properties_effects.zig`; an SVG `<clipPath>` by address is here.
        .clip_path => blk: {
            s.clip_path = "";
            for (t) |k| if (k.kind == .url) break :blk urlOrNone(&s.clip_path, t);
            break :blk null;
        },
        .mask, .mask_image => if (onSvg(ctx)) urlOrNone(&s.mask, t) else null,
        .transform => blk: {
            // Kept as words too, and the box's reading of it goes on.
            if (onSvg(ctx)) s.transform = tk.serialize(ctx.arena, t) catch "";
            break :blk null;
        },
        else => null,
    };
}

fn onSvg(ctx: *const Ctx) bool {
    const n = ctx.node orelse return false;
    return n.ns == .svg;
}

fn isIdent(t: []const Token, word: []const u8) bool {
    const w = values.ident(t) orelse return false;
    return std.ascii.eqlIgnoreCase(w, word);
}

/// `#a`'s id, from a `url()` token of whatever address it was joined to.
fn idOf(text: []const u8) ?[]const u8 {
    const hash = std.mem.lastIndexOfScalar(u8, text, '#') orelse return null;
    return text[hash + 1 ..];
}

fn setPaint(ctx: *Ctx, out: *SvgPaint, t: []const Token) bool {
    out.* = readPaint(ctx, t) orelse return false;
    return true;
}

fn stopColor(ctx: *Ctx, t: []const Token) bool {
    const p = readPaint(ctx, t) orelse return false;
    if (p.kind == .url or p.kind == .none) return false;
    ctx.style.svg.stop_color = p;
    return true;
}

fn readPaint(ctx: *Ctx, t: []const Token) ?SvgPaint {
    var c = Cur.of(t);
    const first = c.peek() orelse return null;
    if (first.isIdent("none")) return .{};
    if (first.isIdent("context-fill") or first.isIdent("context-stroke")) return .{};
    if (first.kind == .url) {
        c.i += 1;
        c.skipWs();
        var out: SvgPaint = .{ .kind = .url, .url = idOf(first.text) orelse "" };
        // The fallback that follows; `none` leaves none.
        const rest = t[c.i..];
        if (rest.len > 0 and !isIdent(rest, "none")) {
            if (isIdent(rest, "currentcolor")) {
                out.url_fallback = ctx.style.color;
            } else out.url_fallback = colors.of(ctx, rest);
        }
        return out;
    }
    if (first.isIdent("currentcolor")) return .{ .kind = .current };
    if (colors.of(ctx, t)) |k| return .{ .kind = .color, .color = k };
    return null;
}

fn setUnit(ctx: *Ctx, out: *f32, t: []const Token) bool {
    if (values.single(t)) |a| if (a.kind == .percentage) {
        out.* = std.math.clamp(a.num / 100, 0, 1);
        return true;
    };
    const n = values.numberOf(ctx, t) orelse return false;
    out.* = std.math.clamp(n, 0, 1);
    return true;
}

fn setRule(out: *bool, t: []const Token) bool {
    if (isIdent(t, "evenodd")) {
        out.* = true;
        return true;
    }
    if (isIdent(t, "nonzero")) {
        out.* = false;
        return true;
    }
    return false;
}

/// A length or a bare number, which SVG's attributes and properties take alike.
fn setLength(ctx: *Ctx, out: *f32, t: []const Token) bool {
    if (values.numberOf(ctx, t)) |n| {
        out.* = n;
        return true;
    }
    const l = values.lengthOf(ctx, t) orelse return false;
    if (!l.isLength() or l.pct != 0) return false;
    out.* = l.px;
    return true;
}

fn dashes(ctx: *Ctx, t: []const Token) bool {
    if (isIdent(t, "none")) {
        ctx.style.svg.dash = &.{};
        return true;
    }
    var list: std.ArrayList(f32) = .empty;
    var c = Cur.of(t);
    while (!c.atEnd()) {
        _ = c.takeComma();
        if (c.atEnd()) break;
        const k = c.peek() orelse break;
        if (k.kind == .number) {
            c.i += 1;
            list.append(ctx.arena, k.num) catch return false;
        } else {
            const px = values.pxAt(ctx, &c) orelse return false;
            list.append(ctx.arena, px) catch return false;
        }
        c.skipWs();
    }
    for (list.items) |x| if (x < 0) return false;
    ctx.style.svg.dash = list.items;
    return true;
}

fn urlOrNone(out: *[]const u8, t: []const Token) bool {
    var c = Cur.of(t);
    const k = c.peek() orelse return false;
    if (k.kind == .url) {
        out.* = idOf(k.text) orelse "";
        return true;
    }
    // Basic shapes aren't drawn here: as if none were asked.
    out.* = "";
    return true;
}
