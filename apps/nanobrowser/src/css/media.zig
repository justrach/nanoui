//! Media queries: parsing and evaluation against the viewport. Handles media
//! types, `not`, `only`, `and`, `or`, comma lists, `min-`/`max-` features,
//! range syntax and `prefers-color-scheme`. The device is assumed a screen
//! with a mouse, color, and no reduced motion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const values = @import("values.zig");
const tk = @import("tokenizer.zig");
const sheet = @import("sheet.zig");

const Token = tk.Token;
const Cur = values.Cur;

pub const Viewport = struct { width: f32, height: f32, dark: bool = false };

const Feature = enum { width, height, aspect_ratio, orientation, color_scheme, reduced_motion, hover, pointer, always_true, always_false, resolution };
const Op = enum { exists, eq, lt, le, gt, ge };

const Test = struct { feature: Feature, op: Op = .exists, num: f32 = 0, word: []const u8 = "" };

pub const Cond = union(enum) {
    all: []const Cond,
    any: []const Cond,
    not: *const Cond,
    feature: Test,
    /// Grammar the parser could not read: false.
    unknown,

    pub fn matches(c: *const Cond, v: Viewport) bool {
        return switch (c.*) {
            .all => |l| blk: {
                for (l) |*x| if (!x.matches(v)) break :blk false;
                break :blk true;
            },
            .any => |l| blk: {
                for (l) |*x| if (x.matches(v)) break :blk true;
                break :blk false;
            },
            .not => |x| !x.matches(v),
            .feature => |*t| evalTest(t, v),
            .unknown => false,
        };
    }
};

pub const Query = struct {
    negate: bool = false,
    /// Screen counts as true, print and unknown as false.
    type_ok: bool = true,
    cond: ?*const Cond = null,

    fn matches(q: *const Query, v: Viewport) bool {
        var r = q.type_ok;
        if (r) if (q.cond) |c| {
            r = c.matches(v);
        };
        return r != q.negate;
    }
};

pub const List = struct {
    queries: []const Query = &.{},

    /// True when any query is; an empty list is all media.
    pub fn matches(l: *const List, v: Viewport) bool {
        if (l.queries.len == 0) return true;
        for (l.queries) |*q| if (q.matches(v)) return true;
        return false;
    }
};

fn compare(a: f32, op: Op, b: f32) bool {
    return switch (op) {
        .exists => a != 0,
        .eq => a == b,
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
    };
}

fn evalTest(t: *const Test, v: Viewport) bool {
    return switch (t.feature) {
        .width => compare(v.width, t.op, t.num),
        .height => compare(v.height, t.op, t.num),
        .aspect_ratio => compare(if (v.height > 0) v.width / v.height else 0, t.op, t.num),
        .orientation => if (t.op == .exists) true else if (std.ascii.eqlIgnoreCase(t.word, "landscape")) v.width > v.height else v.width <= v.height,
        .color_scheme => if (t.op == .exists) true else if (std.ascii.eqlIgnoreCase(t.word, "dark")) v.dark else !v.dark,
        .reduced_motion => t.op != .exists and std.ascii.eqlIgnoreCase(t.word, "no-preference"),
        .hover => t.op == .exists or std.ascii.eqlIgnoreCase(t.word, "hover"),
        .pointer => t.op == .exists or std.ascii.eqlIgnoreCase(t.word, "fine"),
        .resolution => compare(1, t.op, t.num),
        .always_true => !isNone(t.word),
        // A feature this device lacks: its "off" value is what is true.
        .always_false => isNone(t.word),
    };
}

fn isNone(w: []const u8) bool {
    return std.ascii.eqlIgnoreCase(w, "none") or std.ascii.eqlIgnoreCase(w, "no-preference") or std.ascii.eqlIgnoreCase(w, "standalone") or std.ascii.eqlIgnoreCase(w, "fullscreen");
}

const Parser = struct {
    arena: Allocator,
    depth: u32 = 0,

    fn list(p: *Parser, toks: []const Token) Allocator.Error!*const List {
        var out: std.ArrayList(Query) = .empty;
        var c = Cur.of(toks);
        while (!c.atEnd()) {
            const part = c.untilComma();
            try out.append(p.arena, try p.query(part));
        }
        const l = try p.arena.create(List);
        l.* = .{ .queries = out.items };
        return l;
    }

    fn query(p: *Parser, toks: []const Token) Allocator.Error!Query {
        var q: Query = .{};
        var c = Cur.of(toks);
        const first = c.peek() orelse return .{ .type_ok = false };
        if (first.isIdent("not") or first.isIdent("only") or (first.kind == .ident and !first.isIdent("and") and !first.isIdent("or"))) {
            if (first.isIdent("not")) {
                c.i += 1;
                // `not (width > 1px)`: a condition, not a type.
                if (c.peek()) |n| if (n.kind == .lparen or n.kind == .function) {
                    q.cond = try p.condition(toks);
                    return q;
                };
                q.negate = true;
            } else if (first.isIdent("only")) {
                c.i += 1;
            }
            const ty = c.next() orelse return .{ .type_ok = false };
            if (ty.kind != .ident) return .{ .type_ok = false };
            q.type_ok = ty.isIdent("screen") or ty.isIdent("all");
            if (c.atEnd()) return q;
            if (!c.takeIdent("and")) return .{ .type_ok = false };
            q.cond = try p.condition(c.t[c.i..]);
            return q;
        }
        q.cond = try p.condition(toks);
        return q;
    }

    /// `(a) and (b)`, `(a) or (b)`, `not (a)`.
    fn condition(p: *Parser, toks: []const Token) Allocator.Error!*const Cond {
        var c = Cur.of(toks);
        const out = try p.arena.create(Cond);
        if (c.takeIdent("not")) {
            const inner = try p.inParens(&c);
            out.* = .{ .not = inner };
            return out;
        }
        const first = try p.inParens(&c);
        if (c.atEnd()) return first;
        var items: std.ArrayList(Cond) = .empty;
        try items.append(p.arena, first.*);
        const is_and = c.peek().?.isIdent("and");
        if (!is_and and !c.peek().?.isIdent("or")) {
            out.* = .unknown;
            return out;
        }
        while (!c.atEnd()) {
            if (!c.takeIdent(if (is_and) "and" else "or")) {
                out.* = .unknown;
                return out;
            }
            try items.append(p.arena, (try p.inParens(&c)).*);
        }
        out.* = if (is_and) .{ .all = items.items } else .{ .any = items.items };
        return out;
    }

    fn inParens(p: *Parser, c: *Cur) Allocator.Error!*const Cond {
        const out = try p.arena.create(Cond);
        if (p.depth > 32) {
            out.* = .unknown;
            return out;
        }
        p.depth += 1;
        defer p.depth -= 1;
        const t = c.next() orelse {
            out.* = .unknown;
            return out;
        };
        if (t.kind == .function) {
            _ = c.body();
            out.* = .unknown;
            return out;
        }
        if (t.kind != .lparen) {
            out.* = .unknown;
            return out;
        }
        const inner = c.body();
        var ic = Cur.of(inner);
        const head = ic.peek() orelse {
            out.* = .unknown;
            return out;
        };
        // A nested condition.
        if (head.kind == .lparen or head.isIdent("not")) return p.condition(inner);
        out.* = try feature(p.arena, inner);
        return out;
    }
};

fn feature(arena: Allocator, toks: []const Token) Allocator.Error!Cond {
    var c = Cur.of(toks);
    const a = c.next() orelse return .unknown;
    // `(name)`, `(name: value)`, `(name <= value)`.
    if (a.kind == .ident) {
        const n = c.peek() orelse return plain(a.text, .exists, null);
        if (n.kind == .colon) {
            c.i += 1;
            return plain(a.text, .eq, &c);
        }
        const op = rangeOp(&c) orelse return .unknown;
        return ranged(a.text, op, &c);
    }
    // `(value <= name)`, `(value <= name <= value)`.
    c.i -= 1;
    const low = number(&c) orelse return .unknown;
    const op1 = rangeOp(&c) orelse return .unknown;
    const name = c.next() orelse return .unknown;
    if (name.kind != .ident) return .unknown;
    const left = testFor(name.text, flip(op1), low) orelse return .unknown;
    if (c.atEnd()) return left;
    const op2 = rangeOp(&c) orelse return .unknown;
    const right = number(&c) orelse return .unknown;
    const r = testFor(name.text, op2, right) orelse return .unknown;
    const both = try arena.alloc(Cond, 2);
    both[0] = left;
    both[1] = r;
    return .{ .all = both };
}

fn flip(o: Op) Op {
    return switch (o) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        else => o,
    };
}

fn rangeOp(c: *Cur) ?Op {
    const t = c.peek() orelse return null;
    if (t.kind != .delim) return null;
    c.i += 1;
    const eq_next = blk: {
        if (c.i < c.t.len and c.t[c.i].isDelim('=')) {
            c.i += 1;
            break :blk true;
        }
        break :blk false;
    };
    return switch (t.delim) {
        '<' => if (eq_next) .le else .lt,
        '>' => if (eq_next) .ge else .gt,
        '=' => .eq,
        else => null,
    };
}

/// A length, ratio or resolution as a number in its canonical unit.
fn number(c: *Cur) ?f32 {
    const t = c.next() orelse return null;
    switch (t.kind) {
        .number => {
            if (c.peek()) |n| if (n.isDelim('/')) {
                c.i += 1;
                const d = c.next() orelse return null;
                if (d.kind != .number or d.num == 0) return null;
                return t.num / d.num;
            };
            return t.num;
        },
        .dimension => {
            if (std.ascii.eqlIgnoreCase(t.text, "px")) return t.num;
            if (std.ascii.eqlIgnoreCase(t.text, "em") or std.ascii.eqlIgnoreCase(t.text, "rem")) return t.num * 16;
            if (std.ascii.eqlIgnoreCase(t.text, "dppx") or std.ascii.eqlIgnoreCase(t.text, "x")) return t.num;
            if (std.ascii.eqlIgnoreCase(t.text, "dpi")) return t.num / 96;
            if (std.ascii.eqlIgnoreCase(t.text, "dpcm")) return t.num * 2.54 / 96;
            if (std.ascii.eqlIgnoreCase(t.text, "pt")) return t.num * 96 / 72;
            if (std.ascii.eqlIgnoreCase(t.text, "cm")) return t.num * 96 / 2.54;
            if (std.ascii.eqlIgnoreCase(t.text, "mm")) return t.num * 96 / 25.4;
            if (std.ascii.eqlIgnoreCase(t.text, "in")) return t.num * 96;
            return null;
        },
        else => return null,
    }
}

fn ranged(name: []const u8, op: Op, c: *Cur) Cond {
    const v = number(c) orelse return .unknown;
    return testFor(name, op, v) orelse .unknown;
}

/// `name: value`, with `min-`/`max-` prefixes.
fn plain(raw: []const u8, op_in: Op, c: ?*Cur) Cond {
    var name = raw;
    var op = op_in;
    if (std.ascii.startsWithIgnoreCase(name, "min-")) {
        name = name[4..];
        op = .ge;
    } else if (std.ascii.startsWithIgnoreCase(name, "max-")) {
        name = name[4..];
        op = .le;
    }
    if (std.ascii.startsWithIgnoreCase(name, "-webkit-") or std.ascii.startsWithIgnoreCase(name, "-moz-")) {
        // `-webkit-min-device-pixel-ratio` and its kin.
        const rest = name[std.mem.indexOfScalarPos(u8, name, 1, '-').? + 1 ..];
        return plain(rest, op, c);
    }
    const f = featureId(name) orelse return .unknown;
    const cur = c orelse return .{ .feature = .{ .feature = f } };
    const t = cur.peek() orelse return .unknown;
    if (t.kind == .ident) return .{ .feature = .{ .feature = f, .op = .eq, .word = t.text } };
    const v = number(cur) orelse return .unknown;
    return .{ .feature = .{ .feature = f, .op = op, .num = v } };
}

fn testFor(name: []const u8, op: Op, v: f32) ?Cond {
    const f = featureId(name) orelse return null;
    return .{ .feature = .{ .feature = f, .op = op, .num = v } };
}

fn featureId(name: []const u8) ?Feature {
    const map = std.StaticStringMap(Feature).initComptime(.{
        .{ "width", .width },                               .{ "height", .height },                     .{ "device-width", .width },
        .{ "device-height", .height },                      .{ "aspect-ratio", .aspect_ratio },         .{ "device-aspect-ratio", .aspect_ratio },
        .{ "orientation", .orientation },                   .{ "prefers-color-scheme", .color_scheme }, .{ "prefers-reduced-motion", .reduced_motion },
        .{ "hover", .hover },                               .{ "any-hover", .hover },                   .{ "pointer", .pointer },
        .{ "any-pointer", .pointer },                       .{ "resolution", .resolution },             .{ "device-pixel-ratio", .resolution },
        .{ "color", .always_true },                         .{ "color-gamut", .always_true },           .{ "display-mode", .always_true },
        .{ "scripting", .always_true },                     .{ "update", .always_true },                .{ "overflow-block", .always_true },
        .{ "overflow-inline", .always_true },               .{ "monochrome", .always_false },           .{ "grid", .always_false },
        .{ "forced-colors", .always_false },                .{ "prefers-contrast", .always_false },     .{ "inverted-colors", .always_false },
        .{ "prefers-reduced-transparency", .always_false }, .{ "prefers-reduced-data", .always_false },
        .{ "inline-size", .width },                         .{ "block-size", .height },
    });
    var buf: [40]u8 = undefined;
    if (name.len > buf.len) return null;
    return map.get(std.ascii.lowerString(&buf, name));
}

/// Parses a media query list from tokens.
pub fn parseList(arena: Allocator, toks: []const Token) Allocator.Error!*const List {
    var p: Parser = .{ .arena = arena };
    return p.list(toks);
}

/// `@container`'s prelude: an optional name, then a condition.
pub fn parseContainer(arena: Allocator, toks: []const Token) Allocator.Error!sheet.ContainerCond {
    var c = Cur.of(toks);
    var out: sheet.ContainerCond = .{};
    if (c.peek()) |t| if (t.kind == .ident and !t.isIdent("not")) {
        out.name = t.text;
        c.i += 1;
    };
    if (!c.atEnd()) {
        var p: Parser = .{ .arena = arena };
        out.query = try p.condition(c.t[c.i..]);
    }
    return out;
}

/// Parses a media query list from text, for `<link media>` and `<style media>`.
pub fn parseText(arena: Allocator, text: []const u8) Allocator.Error!*const List {
    var tz: tk.Tokenizer = .{ .arena = arena, .src = text };
    var toks: std.ArrayList(Token) = .empty;
    while (true) {
        const t = try tz.next();
        if (t.kind == .eof) break;
        try toks.append(arena, t);
    }
    return parseList(arena, toks.items);
}
