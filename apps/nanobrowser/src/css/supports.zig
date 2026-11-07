//! `@supports`: a declaration is supported if the engine knows the property
//! and can read the value, which it finds out by applying it to a scratch style.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tk = @import("tokenizer.zig");
const prop = @import("prop.zig");
const style = @import("style.zig");
const values = @import("values.zig");
const properties = @import("properties.zig");
const selectors = @import("selectors.zig");

const Token = tk.Token;
const Cur = values.Cur;

/// Evaluates a whole condition: `(a: b) and not (c: d)`.
pub fn evaluate(arena: Allocator, toks: []const Token) bool {
    return evaluateDeep(arena, toks, 0);
}

fn evaluateDeep(arena: Allocator, toks: []const Token, depth: u32) bool {
    if (depth > 32) return false;
    var c = Cur.of(toks);
    if (c.takeIdent("not")) return !term(arena, &c, depth);
    var r = term(arena, &c, depth);
    while (!c.atEnd()) {
        if (c.takeIdent("and")) {
            r = term(arena, &c, depth) and r;
        } else if (c.takeIdent("or")) {
            r = term(arena, &c, depth) or r;
        } else return false;
    }
    return r;
}

fn term(arena: Allocator, c: *Cur, depth: u32) bool {
    const t = c.next() orelse return false;
    if (t.kind == .lparen) {
        const inner = c.body();
        var ic = Cur.of(inner);
        const head = ic.peek() orelse return false;
        // `((a) or (b))`, and `(a: b)`.
        if (head.kind == .lparen or head.kind == .function or head.isIdent("not")) return evaluateDeep(arena, inner, depth + 1);
        return declaration(arena, inner);
    }
    if (t.isFunction("selector")) {
        var p: selectors.Parser = .{ .arena = arena };
        const list = p.parseList(c.body()) catch return false;
        return list != null;
    }
    if (t.kind == .function) {
        _ = c.body();
        return false;
    }
    return false;
}

/// `name: value`.
pub fn declaration(arena: Allocator, toks: []const Token) bool {
    var c = Cur.of(toks);
    const n = c.next() orelse return false;
    if (n.kind != .ident) return false;
    if (!c.takeColon()) return false;
    if (n.text.len > 2 and std.mem.startsWith(u8, n.text, "--")) return true;
    var buf: [48]u8 = undefined;
    if (n.text.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, n.text);
    const p = prop.lookup(low) orelse return false;
    const value = c.t[c.i..];
    if (c.atEnd()) return false;
    for (value) |t| if (t.isFunction("var")) return true;
    if (values.ident(value)) |w| {
        const wide = [_][]const u8{ "inherit", "initial", "unset", "revert", "revert-layer" };
        for (wide) |x| if (std.ascii.eqlIgnoreCase(w, x)) return true;
    }
    var s: style.Style = .{};
    const base: style.Style = .{};
    var ctx: values.Ctx = .{ .style = &s, .parent = &base, .base = &base, .arena = arena };
    return properties.apply(&ctx, p, value);
}
