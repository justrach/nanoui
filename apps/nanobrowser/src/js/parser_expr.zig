//! Expressions: assignment and arrows, the operator ladder, unary and update,
//! calls and member access including optional chains.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const lexer = @import("lexer.zig");
const T = lexer.T;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const literal = @import("parser_literal.zig");
const classes = @import("parser_class.zig");

/// A comma expression.
pub fn expression(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const first = try assignment(p);
    if (p.t() != .comma) return first;
    var list: std.ArrayList(*Node) = .empty;
    try list.append(p.a, first);
    while (try p.eat(.comma)) {
        try list.append(p.a, try assignment(p));
    }
    return p.node(.{ .seq = list.items }, pos);
}

/// An expression with no pending `{a = 1}` cover; for statement level.
pub fn expressionChecked(p: *Parser) Error!*Node {
    const n = try expression(p);
    if (p.cover_init != 0) return p.failAt("Invalid shorthand property initializer", p.cover_init);
    return n;
}

pub fn assignmentChecked(p: *Parser) Error!*Node {
    const n = try assignment(p);
    if (p.cover_init != 0) return p.failAt("Invalid shorthand property initializer", p.cover_init);
    return n;
}

fn assignOpOf(t: T) ?ast.BinOp {
    return switch (t) {
        .add_assign => .add,
        .sub_assign => .sub,
        .mul_assign => .mul,
        .div_assign => .div,
        .mod_assign => .mod,
        .pow_assign => .pow,
        .shl_assign => .shl,
        .sar_assign => .sar,
        .shr_assign => .shr,
        .and_assign => .bit_and,
        .or_assign => .bit_or,
        .xor_assign => .bit_xor,
        else => null,
    };
}

fn logOpOf(t: T) ?ast.LogOp {
    return switch (t) {
        .land_assign => .land,
        .lor_assign => .lor,
        .nullish_assign => .nullish,
        else => null,
    };
}

pub fn assignment(p: *Parser) Error!*Node {
    try p.checkStack();
    const pos = p.tok().pos;
    if (p.t() == .ident) {
        if (p.in_generator and p.isWord(p.vm.k.yield)) return yieldExpr(p);
        if (p.isWord(p.vm.k.async)) {
            if (try asyncArrow(p)) |a| return a;
        }
        // x => ...
        if (try p.arrowFollows()) {
            const name = try p.bindingName();
            const id = try p.ident(name);
            const param = try p.node(.{ .ident = id }, pos);
            return literal.arrowFunction(p, try oneParam(p, param), pos, false);
        }
    }
    const saved_cover = p.cover_init;
    p.cover_init = 0;
    const left = try conditional(p);
    switch (p.t()) {
        .assign => {
            try checkTarget(p, left, true);
            p.cover_init = saved_cover;
            try p.next();
            const value = try assignment(p);
            return p.node(.{ .assign = .{ .target = left, .value = value } }, pos);
        },
        .add_assign, .sub_assign, .mul_assign, .div_assign, .mod_assign, .pow_assign, .shl_assign, .sar_assign, .shr_assign, .and_assign, .or_assign, .xor_assign => |tk| {
            try checkTarget(p, left, false);
            try p.next();
            const value = try assignment(p);
            return p.node(.{ .assign = .{ .op = assignOpOf(tk), .target = left, .value = value } }, pos);
        },
        .land_assign, .lor_assign, .nullish_assign => |tk| {
            try checkTarget(p, left, false);
            try p.next();
            const value = try assignment(p);
            return p.node(.{ .assign = .{ .log = logOpOf(tk), .target = left, .value = value } }, pos);
        },
        else => {},
    }
    if (saved_cover != 0) p.cover_init = saved_cover;
    return left;
}

pub fn oneParam(p: *Parser, n: *Node) Error![]*Node {
    const list = try p.a.alloc(*Node, 1);
    list[0] = n;
    return list;
}

/// Tries `async x => ...` and `async (...) => ...`; resets if it's neither.
fn asyncArrow(p: *Parser) Error!?*Node {
    const pos = p.tok().pos;
    const m = p.mark();
    const nx = try p.peek();
    if (nx.nl_before) return null;
    if (nx.t == .ident) {
        try p.next();
        const name_pos = p.tok().pos;
        const nn = try p.peek();
        if (nn.t != .arrow) {
            p.reset(m);
            return null;
        }
        const saved = p.in_async;
        p.in_async = true;
        const name = p.bindingName();
        p.in_async = saved;
        const param = try p.node(.{ .ident = try p.ident(try name) }, name_pos);
        return try literal.arrowFunction(p, try oneParam(p, param), pos, true);
    }
    if (nx.t == .lparen) {
        // Parse the parenthesis as a cover to see whether `=>` follows, then decide.
        try p.next();
        const saved_cover = p.cover_init;
        const list = literal.parenCover(p) catch |e| {
            if (e != error.Thrown) return e;
            // Not an arrow's parameter list after all (or truly invalid): let the call path report.
            p.vm.exception = @import("value.zig").Value.undefined;
            p.reset(m);
            p.cover_init = saved_cover;
            return null;
        };
        if (p.t() == .arrow and !p.tok().nl_before) {
            p.cover_init = saved_cover;
            return try literal.arrowFunction(p, list, pos, true);
        }
        p.cover_init = saved_cover;
        p.reset(m);
        return null;
    }
    return null;
}

fn yieldExpr(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    if (p.in_class_init) return p.fail("Unexpected 'yield'");
    try p.next();
    if (p.tok().nl_before) return p.node(.{ .yield = .{ .arg = null, .delegate = false } }, pos);
    if (try p.eat(.star)) {
        const arg = try assignment(p);
        return p.node(.{ .yield = .{ .arg = arg, .delegate = true } }, pos);
    }
    switch (p.t()) {
        .rparen, .rbracket, .rbrace, .comma, .semi, .colon, .eof, .kw_in => return p.node(.{ .yield = .{ .arg = null, .delegate = false } }, pos),
        else => {},
    }
    const arg = try assignment(p);
    return p.node(.{ .yield = .{ .arg = arg, .delegate = false } }, pos);
}

/// Validates an assignment target; `pattern_ok` allows [a] = and {a} = forms.
pub fn checkTarget(p: *Parser, n: *Node, pattern_ok: bool) Error!void {
    switch (n.data) {
        .ident => |id| {
            if (p.strict and (id.name == p.vm.k.eval.atom() or id.name == p.vm.k.arguments.atom())) {
                return p.failAt("Unexpected eval or arguments in strict mode", n.pos);
            }
        },
        .member, .index, .private_member, .super_member, .super_index => {},
        .array => |items| {
            if (!pattern_ok or n.paren) return p.failAt("Invalid destructuring assignment target", n.pos);
            for (items, 0..) |it, i| {
                const e = it orelse continue;
                switch (e.data) {
                    .spread => |s| {
                        if (i + 1 != items.len) return p.failAt("Rest element must be last element", e.pos);
                        try checkTarget(p, s, true);
                    },
                    .assign => |a| {
                        if (a.op != null or a.log != null) return p.failAt("Invalid destructuring assignment target", e.pos);
                        try checkTarget(p, a.target, true);
                    },
                    else => try checkTarget(p, e, true),
                }
            }
        },
        .object => |props| {
            if (!pattern_ok or n.paren) return p.failAt("Invalid destructuring assignment target", n.pos);
            for (props, 0..) |prop, i| {
                switch (prop.kind) {
                    .spread => {
                        if (i + 1 != props.len) return p.failAt("Rest element must be last element", n.pos);
                        try checkTarget(p, prop.value, false);
                    },
                    .init, .shorthand, .proto => switch (prop.value.data) {
                        .assign => |a| {
                            if (a.op != null or a.log != null) return p.failAt("Invalid destructuring assignment target", n.pos);
                            try checkTarget(p, a.target, true);
                        },
                        else => try checkTarget(p, prop.value, true),
                    },
                    else => return p.failAt("Invalid destructuring assignment target", n.pos),
                }
            }
        },
        else => return p.failAt("Invalid left-hand side in assignment", n.pos),
    }
}

fn conditional(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const c = try binary(p, 1);
    if (p.t() != .question) return c;
    try p.next();
    const saved = p.no_in;
    p.no_in = false;
    const a = try assignment(p);
    p.no_in = saved;
    try p.expect(.colon);
    const b = try assignment(p);
    return p.node(.{ .cond = .{ .t = c, .a = a, .b = b } }, pos);
}

const OpInfo = struct { prec: u8, bin: ?ast.BinOp = null, log: ?ast.LogOp = null };

fn opInfo(t: T) ?OpInfo {
    return switch (t) {
        .nullish => .{ .prec = 1, .log = .nullish },
        .lor => .{ .prec = 2, .log = .lor },
        .land => .{ .prec = 3, .log = .land },
        .pipe => .{ .prec = 4, .bin = .bit_or },
        .caret => .{ .prec = 5, .bin = .bit_xor },
        .amp => .{ .prec = 6, .bin = .bit_and },
        .eq => .{ .prec = 7, .bin = .eq },
        .ne => .{ .prec = 7, .bin = .ne },
        .seq => .{ .prec = 7, .bin = .seq },
        .sne => .{ .prec = 7, .bin = .sne },
        .lt => .{ .prec = 8, .bin = .lt },
        .gt => .{ .prec = 8, .bin = .gt },
        .le => .{ .prec = 8, .bin = .le },
        .ge => .{ .prec = 8, .bin = .ge },
        .kw_instanceof => .{ .prec = 8, .bin = .instanceof },
        .kw_in => .{ .prec = 8, .bin = .in },
        .shl => .{ .prec = 9, .bin = .shl },
        .sar => .{ .prec = 9, .bin = .sar },
        .shr => .{ .prec = 9, .bin = .shr },
        .plus => .{ .prec = 10, .bin = .add },
        .minus => .{ .prec = 10, .bin = .sub },
        .star => .{ .prec = 11, .bin = .mul },
        .slash => .{ .prec = 11, .bin = .div },
        .percent => .{ .prec = 11, .bin = .mod },
        .pow => .{ .prec = 12, .bin = .pow },
        else => null,
    };
}

fn binary(p: *Parser, min_prec: u8) Error!*Node {
    const pos = p.tok().pos;
    var left: *Node = undefined;
    if (p.t() == .private_name) {
        // #x in obj
        const name = p.tok().atom.?;
        try p.next();
        if (p.t() != .kw_in or p.no_in) return p.unexpected();
        try p.next();
        const r = try binary(p, 9);
        left = try p.node(.{ .private_in = .{ .name = try p.ident(name), .r = r } }, pos);
    } else {
        left = try unary(p);
    }
    while (true) {
        const tk = p.t();
        const info = opInfo(tk) orelse return left;
        if (info.prec < min_prec) return left;
        if (tk == .kw_in and p.no_in) return left;
        if (tk == .pow) {
            switch (left.data) {
                .unary, .await => if (!left.paren) return p.fail("Unary operator used immediately before exponentiation expression. Parenthesis must be used to disambiguate operator precedence"),
                else => {},
            }
        }
        try p.next();
        const right = try binary(p, if (tk == .pow) info.prec else info.prec + 1);
        if (info.log) |op| {
            left = try p.node(.{ .logical = .{ .op = op, .l = left, .r = right } }, pos);
        } else {
            left = try p.node(.{ .binary = .{ .op = info.bin.?, .l = left, .r = right } }, pos);
        }
    }
}

fn unary(p: *Parser) Error!*Node {
    try p.checkStack();
    const pos = p.tok().pos;
    const op: ?ast.UnOp = switch (p.t()) {
        .minus => .neg,
        .plus => .plus,
        .bang => .not,
        .tilde => .bit_not,
        .kw_typeof => .typeof,
        .kw_void => .void,
        .kw_delete => .delete,
        else => null,
    };
    if (op) |o| {
        try p.next();
        const arg = try unary(p);
        if (o == .delete) {
            switch (arg.data) {
                .ident => if (p.strict) return p.failAt("Delete of an unqualified identifier in strict mode.", pos),
                .private_member => return p.failAt("Private fields can not be deleted", pos),
                else => {},
            }
        }
        return p.node(.{ .unary = .{ .op = o, .arg = arg } }, pos);
    }
    if (p.t() == .inc or p.t() == .dec) {
        const is_inc = p.t() == .inc;
        try p.next();
        const arg = try unary(p);
        try checkTarget(p, arg, false);
        return p.node(.{ .update = .{ .inc = is_inc, .prefix = true, .arg = arg } }, pos);
    }
    if (p.t() == .ident and p.isWord(p.vm.k.await) and (p.in_async or p.is_module)) {
        if (p.in_class_init) return p.fail("Unexpected reserved word 'await'");
        if (!p.in_function) p.has_tla = true;
        try p.next();
        const arg = try unary(p);
        return p.node(.{ .await = arg }, pos);
    }
    return postfix(p);
}

fn postfix(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const e = try leftHandSide(p);
    if ((p.t() == .inc or p.t() == .dec) and !p.tok().nl_before) {
        try checkTarget(p, e, false);
        const is_inc = p.t() == .inc;
        try p.next();
        return p.node(.{ .update = .{ .inc = is_inc, .prefix = false, .arg = e } }, pos);
    }
    return e;
}

/// Parses call arguments after `(`, consuming `)`. Reports whether any is a spread.
pub fn arguments(p: *Parser, has_spread: *bool) Error![]*Node {
    var list: std.ArrayList(*Node) = .empty;
    const saved = p.no_in;
    p.no_in = false;
    defer p.no_in = saved;
    while (p.t() != .rparen) {
        if (p.t() == .ellipsis) {
            const pos = p.tok().pos;
            try p.next();
            has_spread.* = true;
            try list.append(p.a, try p.node(.{ .spread = try assignment(p) }, pos));
        } else {
            try list.append(p.a, try assignment(p));
        }
        if (p.t() != .rparen) try p.expect(.comma);
    }
    try p.expect(.rparen);
    return list.items;
}

fn newExpr(p: *Parser) Error!*Node {
    try p.checkStack();
    const pos = p.tok().pos;
    try p.next(); // new
    if (p.t() == .dot) {
        try p.next();
        if (!p.isWord(p.vm.k.target)) return p.unexpected();
        if (!p.in_function) return p.failAt("new.target expression is not allowed here", pos);
        try p.next();
        return p.node(.{ .new_target = try p.ident(p.vm.k.@"new.target".atom()) }, pos);
    }
    var callee: *Node = if (p.t() == .kw_new) try newExpr(p) else if (p.t() == .kw_import) return p.fail("Cannot use new with import") else try literal.primary(p);
    callee = try memberChain(p, callee, false, false);
    var has_spread = false;
    var args: []*Node = &.{};
    if (try p.eat(.lparen)) args = try arguments(p, &has_spread);
    return p.node(.{ .new = .{ .callee = callee, .args = args, .has_spread = has_spread } }, pos);
}

pub const leftHandSidePublic = leftHandSide;

fn leftHandSide(p: *Parser) Error!*Node {
    var e: *Node = undefined;
    if (p.t() == .kw_new) {
        e = try newExpr(p);
    } else if (p.t() == .kw_super) {
        e = try classes.superExpr(p);
    } else if (p.t() == .kw_import) {
        e = try importExpr(p);
    } else {
        e = try literal.primary(p);
    }
    return memberChain(p, e, true, true);
}

fn importExpr(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    if (try p.eat(.dot)) {
        if (!p.isWord(p.vm.k.meta)) return p.unexpected();
        if (!p.is_module) return p.failAt("Cannot use 'import.meta' outside a module", pos);
        try p.next();
        return p.node(.import_meta, pos);
    }
    try p.expect(.lparen);
    const saved = p.no_in;
    p.no_in = false;
    const arg = try assignment(p);
    p.no_in = saved;
    if (try p.eat(.comma)) {
        if (p.t() != .rparen) {
            _ = try assignment(p);
            _ = try p.eat(.comma);
        }
    }
    try p.expect(.rparen);
    return p.node(.{ .import_call = arg }, pos);
}

/// Member accesses, and calls when allowed; wraps an optional chain at its end.
fn memberChain(p: *Parser, start: *Node, allow_call: bool, allow_opt: bool) Error!*Node {
    var e = start;
    var in_chain = false;
    const pos = start.pos;
    while (true) {
        switch (p.t()) {
            .dot => {
                try p.next();
                if (p.t() == .private_name) {
                    const name = p.tok().atom.?;
                    try p.next();
                    e = try p.node(.{ .private_member = .{ .obj = e, .name = try p.ident(name) } }, pos);
                } else {
                    if (p.t() != .ident and !p.t().isKeyword()) return p.unexpected();
                    const name = p.tok().atom.?;
                    const mp = p.tok().pos;
                    try p.next();
                    e = try p.node(.{ .member = .{ .obj = e, .name = name } }, mp);
                }
            },
            .lbracket => {
                const mp = p.tok().pos;
                try p.next();
                const saved = p.no_in;
                p.no_in = false;
                const idx = try expression(p);
                p.no_in = saved;
                try p.expect(.rbracket);
                e = try p.node(.{ .index = .{ .obj = e, .idx = idx } }, mp);
            },
            .lparen => {
                if (!allow_call) break;
                const cp = p.tok().pos;
                try p.next();
                var has_spread = false;
                const args = try arguments(p, &has_spread);
                e = try p.node(.{ .call = .{ .callee = e, .args = args, .has_spread = has_spread } }, cp);
            },
            .qdot => {
                if (!allow_opt) return p.fail("Invalid optional chain from new expression");
                in_chain = true;
                const mp = p.tok().pos;
                try p.next();
                if (p.t() == .lparen) {
                    try p.next();
                    var has_spread = false;
                    const args = try arguments(p, &has_spread);
                    e = try p.node(.{ .call = .{ .callee = e, .args = args, .has_spread = has_spread, .optional = true } }, mp);
                } else if (p.t() == .lbracket) {
                    try p.next();
                    const saved = p.no_in;
                    p.no_in = false;
                    const idx = try expression(p);
                    p.no_in = saved;
                    try p.expect(.rbracket);
                    e = try p.node(.{ .index = .{ .obj = e, .idx = idx, .optional = true } }, mp);
                } else if (p.t() == .private_name) {
                    const name = p.tok().atom.?;
                    try p.next();
                    e = try p.node(.{ .private_member = .{ .obj = e, .name = try p.ident(name), .optional = true } }, mp);
                } else {
                    if (p.t() != .ident and !p.t().isKeyword()) return p.unexpected();
                    const name = p.tok().atom.?;
                    try p.next();
                    e = try p.node(.{ .member = .{ .obj = e, .name = name, .optional = true } }, mp);
                }
            },
            .template => {
                if (in_chain) return p.fail("Invalid tagged template on optional chain");
                const tmpl = try literal.templateParts(p, true);
                e = try p.node(.{ .tagged = .{ .tag = e, .tmpl = tmpl } }, pos);
            },
            else => break,
        }
    }
    if (in_chain) return p.node(.{ .opt_chain = e }, pos);
    return e;
}
