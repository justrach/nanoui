//! WGSL's expressions, by its own grammar: bitwise operators and `&&`/`||` don't mix
//! with others without parentheses. A `<` opens a template only after a name that
//! takes one, which stands in for the specification's template discovery.
const std = @import("std");
const ast = @import("wgsl_ast.zig");
const lex = @import("wgsl_lex.zig");
const Parser = @import("wgsl_parse.zig").Parser;
const Expr = ast.Expr;
const Error = lex.Error;

fn takesTemplate(name: []const u8) bool {
    const fixed = [_][]const u8{ "vec2", "vec3", "vec4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4", "array", "ptr", "atomic", "bitcast" };
    for (fixed) |f| if (std.mem.eql(u8, f, name)) return true;
    return std.mem.startsWith(u8, name, "texture_");
}

fn make(p: *Parser, pos: ast.Pos, k: Expr.Kind) Error!*Expr {
    const e = try p.arena.create(Expr);
    e.* = .{ .pos = pos, .k = k };
    return e;
}

fn binary(p: *Parser, op: ast.BinOp, l: *Expr, r: *Expr) Error!*Expr {
    return make(p, l.pos, .{ .binary = .{ .op = op, .l = l, .r = r } });
}

/// Closes a template: `>>`, `>=` and `>>=` lose their first `>`.
fn closeTemplate(p: *Parser) Error!void {
    switch (p.tok.tag) {
        .gt => try p.advance(),
        .shr => p.splitGt(.gt),
        .ge => p.splitGt(.eq),
        .shr_eq => p.splitGt(.ge),
        else => return p.sink.fail(p.tok.pos, "expected '>' to close a template, found '{s}'", .{p.tok.text}),
    }
}

/// `<a, b, >` after a name, each a type or an expression.
pub fn templateArgs(p: *Parser) Error![]const *Expr {
    try p.expect(.lt);
    var args: std.ArrayList(*Expr) = .empty;
    const saved = p.no_gt;
    p.no_gt = true;
    defer p.no_gt = saved;
    while (true) {
        if (p.tok.tag == .gt or p.tok.tag == .shr or p.tok.tag == .ge or p.tok.tag == .shr_eq) break;
        try args.append(p.arena, try expression(p));
        if (!try p.accept(.comma)) break;
    }
    try closeTemplate(p);
    return args.items;
}

/// A type: a name, with a template if it takes one.
pub fn typeExpr(p: *Parser) Error!*Expr {
    const t = p.tok;
    if (t.tag != .ident) return p.sink.fail(t.pos, "expected a type, found '{s}'", .{t.text});
    try p.advance();
    if (p.tok.tag == .lt and takesTemplate(t.text)) {
        return make(p, t.pos, .{ .tmpl = .{ .name = t.text, .args = try templateArgs(p) } });
    }
    return make(p, t.pos, .{ .ident = t.text });
}

pub fn callArgs(p: *Parser) Error![]const *Expr {
    try p.expect(.lparen);
    const saved = p.no_gt;
    p.no_gt = false;
    defer p.no_gt = saved;
    var args: std.ArrayList(*Expr) = .empty;
    while (p.tok.tag != .rparen) {
        try args.append(p.arena, try expression(p));
        if (!try p.accept(.comma)) break;
    }
    try p.expect(.rparen);
    return args.items;
}

fn parseInt(p: *Parser, t: lex.Token) Error!*Expr {
    var text = t.text;
    var suffix: u8 = 0;
    const last = text[text.len - 1];
    if (last == 'i' or last == 'u') {
        suffix = last;
        text = text[0 .. text.len - 1];
    }
    const hex = text.len > 2 and text[1] != 0 and (text[1] == 'x' or text[1] == 'X');
    const v = std.fmt.parseInt(i64, if (hex) text[2..] else text, if (hex) 16 else 10) catch
        return p.sink.fail(t.pos, "integer literal '{s}' is out of range", .{t.text});
    return make(p, t.pos, .{ .int = .{ .value = v, .suffix = suffix } });
}

fn parseFloat(p: *Parser, t: lex.Token) Error!*Expr {
    var text = t.text;
    var suffix: u8 = 0;
    const is_hex = text.len > 2 and (text[1] == 'x' or text[1] == 'X');
    if (text[text.len - 1] == 'f') {
        suffix = 'f';
        text = text[0 .. text.len - 1];
    }
    // Zig's parser wants the digit each side of the point that WGSL lets go.
    var buf: [128]u8 = undefined;
    if (text.len + 8 >= buf.len) return p.sink.fail(t.pos, "float literal is too long", .{});
    const fixed = fix: {
        var w: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '.' and (i == 0 or !std.ascii.isHex(text[i - 1]) or (is_hex and i == 2))) {
                buf[w] = '0';
                w += 1;
            }
            buf[w] = c;
            w += 1;
            if (c == '.' and (i + 1 == text.len or !std.ascii.isHex(text[i + 1]) or (!is_hex and (text[i + 1] == 'e' or text[i + 1] == 'E')))) {
                buf[w] = '0';
                w += 1;
            }
        }
        // A hexadecimal float may leave out its exponent.
        if (is_hex and std.mem.indexOfAny(u8, text, "pP") == null) {
            @memcpy(buf[w..][0..2], "p0");
            w += 2;
        }
        break :fix buf[0..w];
    };
    const v = std.fmt.parseFloat(f64, fixed) catch return p.sink.fail(t.pos, "bad float literal '{s}'", .{t.text});
    if (std.math.isInf(v) or @abs(v) > std.math.floatMax(f32) * 1.0000001) return p.sink.fail(t.pos, "float literal '{s}' doesn't fit an f32", .{t.text});
    return make(p, t.pos, .{ .float = .{ .value = v, .suffix = suffix } });
}

fn primary(p: *Parser) Error!*Expr {
    const t = p.tok;
    switch (t.tag) {
        .int => {
            try p.advance();
            return parseInt(p, t);
        },
        .float => {
            try p.advance();
            return parseFloat(p, t);
        },
        .keyword => {
            if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                try p.advance();
                return make(p, t.pos, .{ .boolean = t.text[0] == 't' });
            }
            return p.sink.fail(t.pos, "expected an expression, found '{s}'", .{t.text});
        },
        .lparen => {
            try p.advance();
            const saved = p.no_gt;
            p.no_gt = false;
            defer p.no_gt = saved;
            const e = try expression(p);
            try p.expect(.rparen);
            return e;
        },
        .ident => {
            try p.advance();
            var callee = try make(p, t.pos, .{ .ident = t.text });
            if (p.tok.tag == .lt and takesTemplate(t.text)) {
                callee = try make(p, t.pos, .{ .tmpl = .{ .name = t.text, .args = try templateArgs(p) } });
            }
            if (p.tok.tag == .lparen) return make(p, t.pos, .{ .call = .{ .callee = callee, .args = try callArgs(p) } });
            return callee;
        },
        else => return p.sink.fail(t.pos, "expected an expression, found '{s}'", .{if (t.tag == .eof) "the end of the file" else t.text}),
    }
}

fn postfix(p: *Parser, first: *Expr) Error!*Expr {
    var e = first;
    while (true) {
        switch (p.tok.tag) {
            .dot => {
                try p.advance();
                const n = p.tok;
                if (n.tag != .ident) return p.sink.fail(n.pos, "expected a member's name, found '{s}'", .{n.text});
                try p.advance();
                e = try make(p, e.pos, .{ .member = .{ .base = e, .name = n.text, .name_pos = n.pos } });
            },
            .lbracket => {
                try p.advance();
                const saved = p.no_gt;
                p.no_gt = false;
                const i = try expression(p);
                p.no_gt = saved;
                try p.expect(.rbracket);
                e = try make(p, e.pos, .{ .index = .{ .base = e, .i = i } });
            },
            else => return e,
        }
    }
}

pub fn unary(p: *Parser) Error!*Expr {
    const t = p.tok;
    const op: ?ast.UnOp = switch (t.tag) {
        .minus => .neg,
        .bang => .not,
        .tilde => .bitnot,
        .star => .deref,
        .amp => .addr,
        else => null,
    };
    if (op) |o| {
        try p.advance();
        return make(p, t.pos, .{ .unary = .{ .op = o, .e = try unary(p) } });
    }
    if (t.tag == .andand) return p.sink.fail(t.pos, "'&&' can't start an expression", .{});
    return postfix(p, try primary(p));
}

fn multFrom(p: *Parser, first: *Expr) Error!*Expr {
    var e = first;
    while (true) {
        const op: ast.BinOp = switch (p.tok.tag) {
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            else => return e,
        };
        try p.advance();
        e = try binary(p, op, e, try unary(p));
    }
}

fn addFrom(p: *Parser, first: *Expr) Error!*Expr {
    var e = try multFrom(p, first);
    while (true) {
        const op: ast.BinOp = switch (p.tok.tag) {
            .plus => .add,
            .minus => .sub,
            else => return e,
        };
        try p.advance();
        e = try binary(p, op, e, try multFrom(p, try unary(p)));
    }
}

fn shiftFrom(p: *Parser, first: *Expr) Error!*Expr {
    if (p.tok.tag == .shl or (p.tok.tag == .shr and !p.no_gt)) {
        const op: ast.BinOp = if (p.tok.tag == .shl) .shl else .shr;
        try p.advance();
        return binary(p, op, first, try unary(p));
    }
    return addFrom(p, first);
}

fn relationalFrom(p: *Parser, first: *Expr) Error!*Expr {
    const l = try shiftFrom(p, first);
    const op: ast.BinOp = switch (p.tok.tag) {
        .eqeq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => if (p.no_gt) return l else .gt,
        .ge => if (p.no_gt) return l else .ge,
        else => return l,
    };
    try p.advance();
    return binary(p, op, l, try shiftFrom(p, try unary(p)));
}

fn bitwise(p: *Parser, first: *Expr, tag: lex.Tag, op: ast.BinOp) Error!*Expr {
    var e = first;
    while (p.tok.tag == tag) {
        try p.advance();
        e = try binary(p, op, e, try unary(p));
    }
    return e;
}

pub fn expression(p: *Parser) Error!*Expr {
    const first = try unary(p);
    switch (p.tok.tag) {
        .amp => return bitwise(p, first, .amp, .band),
        .pipe => return bitwise(p, first, .pipe, .bor),
        .caret => return bitwise(p, first, .caret, .bxor),
        else => {},
    }
    var e = try relationalFrom(p, first);
    if (p.tok.tag == .andand or p.tok.tag == .oror) {
        const tag = p.tok.tag;
        const op: ast.BinOp = if (tag == .andand) .land else .lor;
        while (p.tok.tag == tag) {
            try p.advance();
            e = try binary(p, op, e, try relationalFrom(p, try unary(p)));
        }
        if (p.tok.tag == .andand or p.tok.tag == .oror) return p.sink.fail(p.tok.pos, "'&&' and '||' can't mix without parentheses", .{});
    }
    return e;
}
