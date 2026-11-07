//! Primary expressions: literals, array and object literals, templates, parentheses
//! (which may turn out to be arrow parameters), and function expressions.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const lexer = @import("lexer.zig");
const T = lexer.T;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const expr = @import("parser_expr.zig");
const stmt = @import("parser_stmt.zig");
const classes = @import("parser_class.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const conv = @import("conv.zig");

pub fn primary(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    switch (p.t()) {
        .num => {
            const v = p.tok().num;
            if (p.tok().legacy_octal and p.strict) return p.fail("Octal literals are not allowed in strict mode.");
            try p.next();
            return p.node(.{ .num = v }, pos);
        },
        .string => {
            const s = p.tok().atom.?;
            if (p.tok().legacy_octal and p.strict) return p.fail("Octal escape sequences are not allowed in strict mode.");
            try p.next();
            return p.node(.{ .str = s }, pos);
        },
        .bigint => {
            const s = p.tok().atom.?;
            try p.next();
            return p.node(.{ .bigint = s }, pos);
        },
        .template => {
            const tmpl = try templateParts(p, false);
            return p.node(.{ .template = tmpl }, pos);
        },
        .slash, .div_assign => {
            try p.l.rescanRegex();
            const pattern = p.tok().atom.?;
            const flags = p.tok().atom2.?;
            try p.next();
            return p.node(.{ .regex = .{ .pattern = pattern, .flags = flags } }, pos);
        },
        .ident => {
            const name = p.tok().atom.?;
            if (p.isWord(p.vm.k.async)) {
                const nx = try p.peek();
                if (nx.t == .kw_function and !nx.nl_before) {
                    try p.next();
                    return functionExpr(p, pos, true);
                }
            }
            try p.checkReserved(name);
            try p.next();
            return p.node(.{ .ident = try p.ident(name) }, pos);
        },
        .kw_this => {
            try p.next();
            return p.node(.{ .this = try p.ident(p.vm.k.this.atom()) }, pos);
        },
        .kw_null => {
            try p.next();
            return p.node(.null_lit, pos);
        },
        .kw_true => {
            try p.next();
            return p.node(.true_lit, pos);
        },
        .kw_false => {
            try p.next();
            return p.node(.false_lit, pos);
        },
        .kw_function => return functionExpr(p, pos, false),
        .kw_class => return classes.classExpr(p),
        .lbracket => return arrayLiteral(p),
        .lbrace => return objectLiteral(p),
        .lparen => return parenthesized(p),
        else => return p.unexpected(),
    }
}

fn parenthesized(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const saved_cover = p.cover_init;
    const items = try parenCover(p);
    if (p.t() == .arrow and !p.tok().nl_before) {
        p.cover_init = saved_cover;
        return arrowFunction(p, items, pos, false);
    }
    if (items.len == 0) return p.unexpected();
    for (items) |it| {
        if (it.data == .spread) return p.failAt("Unexpected token '...'", it.pos);
    }
    if (items.len == 1) {
        items[0].paren = true;
        return items[0];
    }
    const n = try p.node(.{ .seq = items }, pos);
    n.paren = true;
    return n;
}

/// Parses `( a, b = 1, ...rest )`, current token `(`, consuming `)`. The result is
/// either arrow parameters or a parenthesized expression; the caller decides.
pub fn parenCover(p: *Parser) Error![]*Node {
    try p.expect(.lparen);
    const saved = p.no_in;
    p.no_in = false;
    defer p.no_in = saved;
    var list: std.ArrayList(*Node) = .empty;
    while (p.t() != .rparen) {
        if (p.t() == .ellipsis) {
            const pos = p.tok().pos;
            try p.next();
            const target = try bindingTarget(p);
            try list.append(p.a, try p.node(.{ .spread = target }, pos));
        } else {
            try list.append(p.a, try expr.assignment(p));
        }
        if (p.t() != .rparen) try p.expect(.comma);
    }
    try p.expect(.rparen);
    return list.items;
}

/// A binding identifier or destructuring pattern, no initializer.
pub fn bindingTarget(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    if (p.t() == .lbracket or p.t() == .lbrace) {
        const saved = p.cover_init;
        const n = if (p.t() == .lbracket) try arrayLiteral(p) else try objectLiteral(p);
        p.cover_init = saved;
        try checkBinding(p, n);
        return n;
    }
    const name = try p.bindingName();
    return p.node(.{ .ident = try p.ident(name) }, pos);
}

/// A binding element: target with an optional `= default`.
pub fn bindingElement(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const target = try bindingTarget(p);
    if (try p.eat(.assign)) {
        const saved = p.no_in;
        p.no_in = false;
        const value = try expr.assignment(p);
        p.no_in = saved;
        return p.node(.{ .assign = .{ .target = target, .value = value } }, pos);
    }
    return target;
}

/// A pattern in a binding position may only bind identifiers, not members.
pub fn checkBinding(p: *Parser, n: *Node) Error!void {
    switch (n.data) {
        .ident => |id| {
            if (p.strict and (id.name == p.vm.k.eval.atom() or id.name == p.vm.k.arguments.atom())) {
                return p.failAt("Unexpected eval or arguments in strict mode", n.pos);
            }
        },
        .array => |items| {
            for (items, 0..) |it, i| {
                const e = it orelse continue;
                if (e.data == .spread and i + 1 != items.len) return p.failAt("Rest element must be last element", e.pos);
                try checkBinding(p, e);
            }
        },
        .object => |props| {
            for (props, 0..) |prop, i| {
                switch (prop.kind) {
                    .init, .shorthand, .proto => try checkBinding(p, prop.value),
                    .spread => {
                        if (i + 1 != props.len) return p.failAt("Rest element must be last element", n.pos);
                        try checkBinding(p, prop.value);
                    },
                    else => return p.failAt("Invalid destructuring target", n.pos),
                }
            }
        },
        .assign => |a| {
            if (a.op != null or a.log != null) return p.failAt("Invalid destructuring target", n.pos);
            try checkBinding(p, a.target);
        },
        .spread => |s| try checkBinding(p, s),
        else => return p.failAt("Invalid destructuring target", n.pos),
    }
}

/// The parameters are parsed; the current token is `=>`.
pub fn arrowFunction(p: *Parser, params: []*Node, start: u32, is_async: bool) Error!*Node {
    for (params) |param| try checkBinding(p, param);
    try p.expect(.arrow);
    const f = try p.a.create(ast.Func);
    f.* = .{ .is_arrow = true, .is_async = is_async, .is_expr = true, .start = start, .params = params };
    f.simple_params = allSimple(params);
    const saved = FnContext.enter(p, is_async, false);
    defer saved.leave(p);
    if (p.t() == .lbrace) {
        const no_in = p.no_in;
        p.no_in = false;
        try functionBody(p, f);
        p.no_in = no_in;
    } else {
        const body = try expr.assignment(p);
        f.expr_body = body;
        f.strict = p.strict;
        f.end = p.prev_end;
    }
    return p.node(.{ .function = f }, start);
}

pub fn allSimple(params: []const *Node) bool {
    for (params) |param| {
        if (param.data != .ident) return false;
    }
    return true;
}

/// Everything about the grammar context that a function resets.
pub const FnContext = struct {
    strict: bool,
    in_function: bool,
    in_generator: bool,
    in_async: bool,
    in_class_init: bool,
    no_in: bool,
    cover_init: u32,

    pub fn enter(p: *Parser, is_async: bool, is_generator: bool) FnContext {
        const s = FnContext{
            .strict = p.strict,
            .in_function = p.in_function,
            .in_generator = p.in_generator,
            .in_async = p.in_async,
            .in_class_init = p.in_class_init,
            .no_in = p.no_in,
            .cover_init = p.cover_init,
        };
        p.in_function = true;
        p.in_generator = is_generator;
        p.in_async = is_async;
        p.in_class_init = false;
        p.no_in = false;
        p.cover_init = 0;
        return s;
    }
    pub fn leave(s: FnContext, p: *Parser) void {
        p.strict = s.strict;
        p.in_function = s.in_function;
        p.in_generator = s.in_generator;
        p.in_async = s.in_async;
        p.in_class_init = s.in_class_init;
        p.no_in = s.no_in;
        p.cover_init = s.cover_init;
    }
};

/// Parses `(params)` into f; the current token is `(`.
pub fn formalParams(p: *Parser, f: *ast.Func) Error!void {
    try p.expect(.lparen);
    var list: std.ArrayList(*Node) = .empty;
    while (p.t() != .rparen) {
        if (p.t() == .ellipsis) {
            const pos = p.tok().pos;
            try p.next();
            const target = try bindingTarget(p);
            try list.append(p.a, try p.node(.{ .spread = target }, pos));
            if (p.t() != .rparen) return p.fail("Rest parameter must be last formal parameter");
            break;
        }
        try list.append(p.a, try bindingElement(p));
        if (p.t() != .rparen) try p.expect(.comma);
    }
    try p.expect(.rparen);
    f.params = list.items;
    f.simple_params = allSimple(list.items);
}

/// Parses `{ body }` into f, handling the directive prologue; sets f.end.
pub fn functionBody(p: *Parser, f: *ast.Func) Error!void {
    try p.expect(.lbrace);
    var body: std.ArrayList(*Node) = .empty;
    try stmt.directives(p, f, &body);
    while (p.t() != .rbrace) {
        if (p.t() == .eof) return p.unexpected();
        try body.append(p.a, try stmt.statementListItem(p));
    }
    f.body = body.items;
    f.strict = p.strict;
    f.end = p.tok().end;
    try p.next();
}

/// Parses after the `function` keyword position; `is_async` has consumed `async`.
fn functionExpr(p: *Parser, start: u32, is_async: bool) Error!*Node {
    try p.expect(.kw_function);
    const is_gen = try p.eat(.star);
    const f = try p.a.create(ast.Func);
    f.* = .{ .is_async = is_async, .is_generator = is_gen, .is_expr = true, .start = start };
    const saved = FnContext.enter(p, is_async, is_gen);
    defer saved.leave(p);
    if (p.t() == .ident) f.name = try p.bindingName();
    try formalParams(p, f);
    try functionBody(p, f);
    return p.node(.{ .function = f }, start);
}

fn arrayLiteral(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    const saved = p.no_in;
    p.no_in = false;
    defer p.no_in = saved;
    var list: std.ArrayList(?*Node) = .empty;
    while (p.t() != .rbracket) {
        if (p.t() == .comma) {
            try p.next();
            try list.append(p.a, null);
            continue;
        }
        if (p.t() == .ellipsis) {
            const sp = p.tok().pos;
            try p.next();
            try list.append(p.a, try p.node(.{ .spread = try expr.assignment(p) }, sp));
        } else {
            try list.append(p.a, try expr.assignment(p));
        }
        if (p.t() != .rbracket) try p.expect(.comma);
    }
    try p.next();
    return p.node(.{ .array = list.items }, pos);
}

/// A property name: fills in key_atom, or key for a computed one.
pub fn propertyName(p: *Parser, out: *ast.Prop) Error!void {
    switch (p.t()) {
        .string => out.key_atom = p.tok().atom,
        .num => {
            const v = conv.numberToString(p.vm, p.tok().num) catch |e| return e;
            out.key_atom = try str.internString(p.vm, v);
        },
        .bigint => {
            const big = @import("b_bigint.zig");
            out.key_atom = try str.internString(p.vm, try big.literalToDecimal(p.vm, p.tok().atom.?));
        },
        .lbracket => {
            try p.next();
            const saved = p.no_in;
            p.no_in = false;
            out.key = try expr.assignment(p);
            p.no_in = saved;
            out.computed = true;
            try p.expect(.rbracket);
            return;
        },
        else => {
            if (p.t() != .ident and !p.t().isKeyword()) return p.unexpected();
            out.key_atom = p.tok().atom;
        },
    }
    try p.next();
}

/// Whether the current token ends a property name, so `get`/`async`/... were the name itself.
fn endsName(t: T) bool {
    return switch (t) {
        .colon, .comma, .rbrace, .lparen, .assign => true,
        else => false,
    };
}

/// Parses a method's `(params) { body }`; the current token is `(`.
pub fn methodFunction(p: *Parser, start: u32, is_async: bool, is_gen: bool) Error!*ast.Func {
    const f = try p.a.create(ast.Func);
    f.* = .{ .is_async = is_async, .is_generator = is_gen, .is_method = true, .start = start, .is_expr = true };
    const saved = FnContext.enter(p, is_async, is_gen);
    defer saved.leave(p);
    try formalParams(p, f);
    try functionBody(p, f);
    return f;
}

fn objectLiteral(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    const saved = p.no_in;
    p.no_in = false;
    defer p.no_in = saved;
    var list: std.ArrayList(ast.Prop) = .empty;
    while (p.t() != .rbrace) {
        try list.append(p.a, try objectProperty(p));
        if (p.t() != .rbrace) try p.expect(.comma);
    }
    try p.next();
    return p.node(.{ .object = list.items }, pos);
}

fn objectProperty(p: *Parser) Error!ast.Prop {
    const start = p.tok().pos;
    var prop = ast.Prop{ .kind = .init, .value = undefined };
    if (p.t() == .ellipsis) {
        try p.next();
        prop.kind = .spread;
        prop.value = try expr.assignment(p);
        return prop;
    }
    var is_async = false;
    var is_gen = false;
    var accessor: ?ast.PropKind = null;
    if (p.t() == .ident and !p.tok().escaped) {
        const k = &p.vm.k;
        const a = p.tok().atom.?;
        if (a == k.get.atom() or a == k.set.atom() or a == k.async.atom()) {
            const nx = try p.peek();
            if (!endsName(nx.t) and !(a == k.async.atom() and nx.nl_before)) {
                if (a == k.get.atom()) {
                    accessor = .get;
                } else if (a == k.set.atom()) {
                    accessor = .set;
                } else is_async = true;
                try p.next();
            }
        }
    }
    if (try p.eat(.star)) is_gen = true;
    const was_ident = p.t() == .ident;
    const name_tok = p.tok().*;
    const name_pos = p.tok().pos;
    try propertyName(p, &prop);
    if (accessor) |ak| {
        const f = try methodFunction(p, start, false, false);
        f.is_getter = ak == .get;
        f.is_setter = ak == .set;
        prop.kind = ak;
        prop.value = try p.node(.{ .function = f }, start);
        return prop;
    }
    if (is_async or is_gen or p.t() == .lparen) {
        if (p.t() != .lparen) return p.unexpected();
        const f = try methodFunction(p, start, is_async, is_gen);
        prop.kind = .method;
        prop.value = try p.node(.{ .function = f }, start);
        return prop;
    }
    if (try p.eat(.colon)) {
        prop.value = try expr.assignment(p);
        if (!prop.computed and prop.key_atom == p.vm.k.__proto__.atom()) prop.kind = .proto;
        return prop;
    }
    // Shorthand: {a} or the cover form {a = 1}.
    if (!was_ident or prop.computed) return p.unexpected();
    try p.checkReserved(name_tok.atom.?);
    const id = try p.node(.{ .ident = try p.ident(name_tok.atom.?) }, name_pos);
    prop.kind = .shorthand;
    if (p.t() == .assign) {
        const eq_pos = p.tok().pos;
        try p.next();
        const saved_cover = p.cover_init;
        const value = try expr.assignment(p);
        p.cover_init = if (saved_cover != 0) saved_cover else eq_pos;
        prop.value = try p.node(.{ .assign = .{ .target = id, .value = value } }, name_pos);
        return prop;
    }
    prop.value = id;
    return prop;
}

/// Parses a template starting at its first chunk (the current token).
pub fn templateParts(p: *Parser, tagged: bool) Error!*ast.Template {
    var cooked: std.ArrayList(?*JSString) = .empty;
    var raw: std.ArrayList(*JSString) = .empty;
    var exprs: std.ArrayList(*Node) = .empty;
    while (true) {
        const tk = p.tok();
        if (tk.atom == null and !tagged) return p.fail("Invalid escape sequence in template");
        try cooked.append(p.a, tk.atom);
        try raw.append(p.a, tk.atom2.?);
        if (tk.tail) break;
        try p.next();
        const saved = p.no_in;
        p.no_in = false;
        try exprs.append(p.a, try expr.expression(p));
        p.no_in = saved;
        if (p.t() != .rbrace) return p.unexpected();
        try p.l.rescanTemplate();
    }
    try p.next();
    const t = try p.a.create(ast.Template);
    t.* = .{ .cooked = cooked.items, .raw = raw.items, .exprs = exprs.items };
    return t;
}
