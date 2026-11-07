//! Classes: heritage, methods, accessors, fields, private names and static blocks,
//! and the `super` forms.

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
const literal = @import("parser_literal.zig");
const stmt = @import("parser_stmt.zig");

pub fn classExpr(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const c = try parseClass(p, false);
    return p.node(.{ .class = c }, pos);
}

pub fn classDecl(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const c = try parseClass(p, true);
    return p.node(.{ .class_decl = c }, pos);
}

pub fn parseClass(p: *Parser, need_name: bool) Error!*ast.Class {
    const start = p.tok().pos;
    try p.expect(.kw_class);
    const saved_strict = p.strict;
    p.strict = true;
    defer p.strict = saved_strict;
    const c = try p.a.create(ast.Class);
    c.* = .{ .name = null, .parent = null, .ctor = null, .members = &.{}, .start = start, .end = start };
    if (p.t() == .ident) {
        c.name = try p.bindingName();
    } else if (need_name) return p.unexpected();
    if (try p.eat(.kw_extends)) c.parent = try expr.leftHandSidePublic(p);
    try p.expect(.lbrace);
    var members: std.ArrayList(ast.ClassMember) = .empty;
    var needs_instance_init = false;
    var needs_static_init = false;
    while (p.t() != .rbrace) {
        if (try p.eat(.semi)) continue;
        const m = try classMember(p, c);
        if (m) |mem| {
            if (mem.kind == .field or mem.kind == .static_block) {
                if (mem.is_static) needs_static_init = true else needs_instance_init = true;
            } else if (mem.is_private and !mem.is_static) needs_instance_init = true;
            try members.append(p.a, mem);
        }
    }
    c.end = p.tok().end;
    try p.next();
    c.members = members.items;
    if (c.ctor == null) {
        const f = try p.a.create(ast.Func);
        f.* = .{ .is_class_ctor = true, .is_default_ctor = true, .is_derived = c.parent != null, .is_method = true, .strict = true, .is_expr = true };
        c.ctor = f;
    }
    c.ctor.?.start = c.start;
    c.ctor.?.end = c.end;
    if (needs_instance_init) c.instance_init = try initFunc(p, c, false);
    if (needs_static_init) c.static_init = try initFunc(p, c, true);
    return c;
}

fn initFunc(p: *Parser, c: *ast.Class, is_static: bool) Error!*ast.Func {
    const f = try p.a.create(ast.Func);
    f.* = .{
        .is_method = true,
        .is_class_init = true,
        .is_expr = true,
        .strict = true,
        .init_class = c,
        .init_static = is_static,
        .start = c.start,
        .end = c.start,
    };
    return f;
}

fn endsMemberName(t: T) bool {
    return switch (t) {
        .lparen, .assign, .semi, .rbrace, .eof => true,
        else => false,
    };
}

fn classMember(p: *Parser, c: *ast.Class) Error!?ast.ClassMember {
    var start = p.tok().pos;
    const k = &p.vm.k;
    var m = ast.ClassMember{ .kind = .method, .is_static = false };
    if (p.isWord(k.static)) {
        const nx = try p.peek();
        if (nx.t == .lbrace) {
            try p.next();
            return try staticBlock(p);
        }
        if (!endsMemberName(nx.t)) {
            m.is_static = true;
            try p.next();
            start = p.tok().pos;
        }
    }
    var is_async = false;
    var is_gen = false;
    if (p.t() == .ident and !p.tok().escaped) {
        const a = p.tok().atom.?;
        if (a == k.get.atom() or a == k.set.atom() or a == k.async.atom()) {
            const nx = try p.peek();
            const line_break_ends = nx.nl_before and (a == k.async.atom() or nx.t == .star);
            if (!endsMemberName(nx.t) and !line_break_ends) {
                if (a == k.get.atom()) {
                    m.kind = .get;
                } else if (a == k.set.atom()) {
                    m.kind = .set;
                } else is_async = true;
                try p.next();
            }
        }
    }
    if (try p.eat(.star)) is_gen = true;
    var prop = ast.Prop{ .kind = .init, .value = undefined };
    if (p.t() == .private_name) {
        m.is_private = true;
        m.key_atom = p.tok().atom;
        if (m.key_atom.? == k.@"#constructor".atom()) return p.fail("Classes may not have a private field named '#constructor'");
        try p.next();
    } else {
        try literal.propertyName(p, &prop);
        m.key_atom = prop.key_atom;
        m.key = prop.key;
        m.computed = prop.computed;
    }
    if (p.t() == .lparen) {
        const f = try literal.methodFunction(p, start, is_async, is_gen);
        f.strict = true;
        f.is_getter = m.kind == .get;
        f.is_setter = m.kind == .set;
        m.value = try p.node(.{ .function = f }, start);
        const is_ctor_name = !m.computed and !m.is_private and m.key_atom == k.constructor.atom();
        if (is_ctor_name and !m.is_static) {
            if (m.kind != .method or is_async or is_gen) return p.failAt("Class constructor may not be an accessor, generator or async", start);
            if (c.ctor != null) return p.failAt("A class may only have one constructor", start);
            f.is_class_ctor = true;
            f.is_derived = c.parent != null;
            c.ctor = f;
            return null;
        }
        if (is_ctor_name == false and !m.computed and !m.is_private and m.is_static and m.key_atom == k.prototype.atom()) {
            return p.failAt("Classes may not have a static property named 'prototype'", start);
        }
        return m;
    }
    if (m.kind != .method or is_async or is_gen) return p.unexpected();
    m.kind = .field;
    if (!m.computed and !m.is_private and m.key_atom == k.constructor.atom()) {
        return p.failAt("Classes may not have a field named 'constructor'", start);
    }
    if (try p.eat(.assign)) {
        const saved = literal.FnContext.enter(p, false, false);
        defer saved.leave(p);
        p.in_class_init = true;
        m.value = try expr.assignment(p);
    }
    try p.semicolon();
    return m;
}

fn staticBlock(p: *Parser) Error!ast.ClassMember {
    const saved = literal.FnContext.enter(p, false, false);
    defer saved.leave(p);
    p.in_class_init = true;
    const block = try stmt.blockStatement(p);
    return .{ .kind = .static_block, .is_static = true, .value = block };
}

/// super(args), super.name, super[expr]; the current token is `super`.
pub fn superExpr(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    const k = &p.vm.k;
    try p.next();
    const this_id = try p.ident(k.this.atom());
    switch (p.t()) {
        .lparen => {
            try p.next();
            var has_spread = false;
            const args = try expr.arguments(p, &has_spread);
            return p.node(.{ .super_call = .{
                .args = args,
                .has_spread = has_spread,
                .this = this_id,
                .func = try p.ident(k.@"%func".atom()),
                .new_target = try p.ident(k.@"new.target".atom()),
            } }, pos);
        },
        .dot => {
            try p.next();
            if (p.t() != .ident and !p.t().isKeyword()) return p.unexpected();
            const name = p.tok().atom.?;
            try p.next();
            return p.node(.{ .super_member = .{ .this = this_id, .home = try p.ident(k.@"%home".atom()), .name = name } }, pos);
        },
        .lbracket => {
            try p.next();
            const saved = p.no_in;
            p.no_in = false;
            const idx = try expr.expression(p);
            p.no_in = saved;
            try p.expect(.rbracket);
            return p.node(.{ .super_index = .{ .this = this_id, .home = try p.ident(k.@"%home".atom()), .idx = idx } }, pos);
        },
        else => return p.fail("'super' keyword unexpected here"),
    }
}
