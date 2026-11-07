//! Statements and declarations, including the for-statement forms and the directive
//! prologue. Sub-statement function declarations (Annex B) are wrapped in a block.

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
const classes = @import("parser_class.zig");
const modules = @import("parser_module.zig");

/// Parses leading string-literal statements, turning on strict mode for "use strict".
pub fn directives(p: *Parser, f: *ast.Func, body: *std.ArrayList(*Node)) Error!void {
    while (p.t() == .string) {
        const tk = p.tok().*;
        const raw = p.l.src[tk.pos + 1 .. tk.end - 1];
        const s = try statementListItem(p);
        try body.append(p.a, s);
        const is_dir = s.data == .expr_stmt and s.data.expr_stmt.data == .str and !s.data.expr_stmt.paren;
        if (!is_dir) break;
        if (std.mem.eql(u8, raw, "use strict")) {
            if (!f.simple_params) return p.failAt("Illegal 'use strict' directive in function with non-simple parameter list", tk.pos);
            p.strict = true;
            f.has_use_strict = true;
        }
    }
}

fn isLetDecl(p: *Parser) Error!bool {
    if (!p.isWord(p.vm.k.let)) return false;
    const nx = try p.peek();
    return switch (nx.t) {
        .lbrace, .lbracket => true,
        .ident => true,
        else => false,
    };
}

pub fn statementListItem(p: *Parser) Error!*Node {
    try p.checkStack();
    switch (p.t()) {
        .kw_const => return lexicalDecl(p, .@"const"),
        .kw_class => return classes.classDecl(p),
        .kw_function => return functionDecl(p, p.tok().pos, false),
        .kw_import => {
            const nx = try p.peek();
            if (nx.t != .lparen and nx.t != .dot) return modules.importDecl(p);
        },
        .kw_export => return modules.exportDecl(p),
        .ident => {
            if (try isLetDecl(p)) return lexicalDecl(p, .let);
            if (p.isWord(p.vm.k.async)) {
                const nx = try p.peek();
                if (nx.t == .kw_function and !nx.nl_before) {
                    const pos = p.tok().pos;
                    try p.next();
                    return functionDecl(p, pos, true);
                }
            }
        },
        else => {},
    }
    return statement(p);
}

/// Parses `function [*] name (params) { body }`; `async` is already consumed.
pub fn functionDecl(p: *Parser, start: u32, is_async: bool) Error!*Node {
    try p.expect(.kw_function);
    const is_gen = try p.eat(.star);
    const f = try p.a.create(ast.Func);
    f.* = .{ .is_async = is_async, .is_generator = is_gen, .is_decl = true, .start = start };
    f.name = try p.bindingName();
    const saved = literal.FnContext.enter(p, is_async, is_gen);
    defer saved.leave(p);
    try literal.formalParams(p, f);
    try literal.functionBody(p, f);
    return p.node(.{ .func_decl = f }, start);
}

fn lexicalDecl(p: *Parser, kind: ast.VarKind) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    const decls = try declList(p, kind, true);
    try p.semicolon();
    return p.node(.{ .var_decl = .{ .kind = kind, .decls = decls } }, pos);
}

pub fn declList(p: *Parser, kind: ast.VarKind, need_init: bool) Error![]ast.Decl {
    var list: std.ArrayList(ast.Decl) = .empty;
    while (true) {
        const target = try literal.bindingTarget(p);
        if (target.data == .ident and target.data.ident.name == p.vm.k.let.atom() and kind != .@"var") {
            return p.failAt("let is disallowed as a lexically bound name", target.pos);
        }
        var init: ?*Node = null;
        if (try p.eat(.assign)) {
            init = try expr.assignmentChecked(p);
        } else if (need_init) {
            if (target.data != .ident) return p.fail("Missing initializer in destructuring declaration");
            if (kind == .@"const") return p.fail("Missing initializer in const declaration");
        }
        try list.append(p.a, .{ .target = target, .init = init });
        if (!try p.eat(.comma)) break;
    }
    return list.items;
}

/// The body of if/loops/labels: a function declaration here becomes a one-item block.
fn subStatement(p: *Parser) Error!*Node {
    if (p.t() == .kw_function) {
        if (p.strict) return p.fail("In strict mode code, functions can only be declared at top level or inside a block.");
        const pos = p.tok().pos;
        const d = try functionDecl(p, pos, false);
        const list = try p.a.alloc(*Node, 1);
        list[0] = d;
        return p.node(.{ .block = .{ .body = list } }, pos);
    }
    if (p.t() == .kw_class) return p.unexpected();
    if (p.t() == .kw_const) return p.unexpected();
    return statement(p);
}

pub fn blockStatement(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.expect(.lbrace);
    var list: std.ArrayList(*Node) = .empty;
    while (p.t() != .rbrace) {
        if (p.t() == .eof) return p.unexpected();
        try list.append(p.a, try statementListItem(p));
    }
    try p.next();
    return p.node(.{ .block = .{ .body = list.items } }, pos);
}

fn parenExpr(p: *Parser) Error!*Node {
    try p.expect(.lparen);
    const e = try expr.expression(p);
    try p.expect(.rparen);
    return e;
}

pub fn statement(p: *Parser) Error!*Node {
    try p.checkStack();
    const pos = p.tok().pos;
    switch (p.t()) {
        .lbrace => return blockStatement(p),
        .semi => {
            try p.next();
            return p.node(.empty, pos);
        },
        .kw_var => {
            try p.next();
            const decls = try declList(p, .@"var", true);
            try p.semicolon();
            return p.node(.{ .var_decl = .{ .kind = .@"var", .decls = decls } }, pos);
        },
        .kw_if => {
            try p.next();
            const c = try parenExpr(p);
            const a = try subStatement(p);
            var b: ?*Node = null;
            if (try p.eat(.kw_else)) b = try subStatement(p);
            return p.node(.{ .if_stmt = .{ .t = c, .a = a, .b = b } }, pos);
        },
        .kw_for => return forStatement(p),
        .kw_while => {
            try p.next();
            const c = try parenExpr(p);
            const body = try subStatement(p);
            return p.node(.{ .while_stmt = .{ .t = c, .body = body } }, pos);
        },
        .kw_do => {
            try p.next();
            const body = try subStatement(p);
            try p.expect(.kw_while);
            const c = try parenExpr(p);
            _ = try p.eat(.semi);
            return p.node(.{ .do_while = .{ .t = c, .body = body } }, pos);
        },
        .kw_continue, .kw_break => {
            const is_break = p.t() == .kw_break;
            try p.next();
            var label: ?*@import("string.zig").JSString = null;
            if (p.t() == .ident and !p.tok().nl_before) {
                label = p.tok().atom;
                try p.next();
            }
            try p.semicolon();
            return p.node(if (is_break) .{ .break_stmt = label } else .{ .continue_stmt = label }, pos);
        },
        .kw_return => {
            if (!p.in_function) return p.fail("Illegal return statement");
            try p.next();
            var arg: ?*Node = null;
            if (p.t() != .semi and p.t() != .rbrace and p.t() != .eof and !p.tok().nl_before) {
                arg = try expr.expressionChecked(p);
            }
            try p.semicolon();
            return p.node(.{ .return_stmt = arg }, pos);
        },
        .kw_with => {
            if (p.strict) return p.fail("Strict mode code may not include a with statement");
            try p.next();
            const obj = try parenExpr(p);
            const body = try subStatement(p);
            return p.node(.{ .with_stmt = .{ .obj = obj, .body = body } }, pos);
        },
        .kw_throw => {
            try p.next();
            if (p.tok().nl_before) return p.fail("Illegal newline after throw");
            const e = try expr.expressionChecked(p);
            try p.semicolon();
            return p.node(.{ .throw_stmt = e }, pos);
        },
        .kw_try => return tryStatement(p),
        .kw_switch => return switchStatement(p),
        .kw_debugger => {
            try p.next();
            try p.semicolon();
            return p.node(.debugger, pos);
        },
        .kw_function => return p.fail("In strict mode code, functions can only be declared at top level or inside a block."),
        .kw_class => return p.unexpected(),
        .kw_import => {
            const nx = try p.peek();
            if (nx.t != .lparen and nx.t != .dot) return p.fail("Cannot use import statement outside a module");
        },
        .kw_export => return p.unexpected(),
        else => {},
    }
    const e = try expr.expressionChecked(p);
    if (p.t() == .colon and e.data == .ident and !e.paren) {
        const label = e.data.ident.name;
        try p.next();
        const body = try subStatement(p);
        return p.node(.{ .labeled = .{ .label = label, .body = body } }, pos);
    }
    try p.semicolon();
    return p.node(.{ .expr_stmt = e }, pos);
}

fn forStatement(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    var is_await = false;
    if (p.isWord(p.vm.k.await)) {
        if (!p.in_async and !p.is_module) return p.unexpected();
        if (!p.in_function) p.has_tla = true;
        is_await = true;
        try p.next();
    }
    try p.expect(.lparen);
    var init: ?*Node = null;
    if (p.t() != .semi) {
        const ipos = p.tok().pos;
        p.no_in = true;
        var kind: ?ast.VarKind = null;
        if (p.t() == .kw_var) {
            kind = .@"var";
        } else if (p.t() == .kw_const) {
            kind = .@"const";
        } else if (p.isWord(p.vm.k.let)) {
            const nx = try p.peek();
            if (nx.t == .ident or nx.t == .lbracket or nx.t == .lbrace) {
                // `for (let of x)` is not a declaration; `for (let of of x)` is.
                kind = .let;
            }
        }
        if (kind) |k| {
            try p.next();
            const decls = try declList(p, k, false);
            init = try p.node(.{ .var_decl = .{ .kind = k, .decls = decls } }, ipos);
        } else {
            init = try expr.expression(p);
        }
        p.no_in = false;
        const is_of = p.isWord(p.vm.k.of);
        if (is_of or p.t() == .kw_in) {
            return forInOf(p, pos, init.?, is_of, is_await);
        }
        if (kind == null and p.cover_init != 0) return p.failAt("Invalid shorthand property initializer", p.cover_init);
        if (kind) |k| {
            for (init.?.data.var_decl.decls) |d| {
                if (d.init == null and (k == .@"const" or d.target.data != .ident)) return p.fail("Missing initializer in declaration");
            }
        }
    }
    if (is_await) return p.unexpected();
    try p.expect(.semi);
    var c: ?*Node = null;
    if (p.t() != .semi) c = try expr.expression(p);
    try p.expect(.semi);
    var update: ?*Node = null;
    if (p.t() != .rparen) update = try expr.expression(p);
    try p.expect(.rparen);
    const body = try subStatement(p);
    return p.node(.{ .for_stmt = .{ .init = init, .t = c, .update = update, .body = body } }, pos);
}

fn forInOf(p: *Parser, pos: u32, left: *Node, is_of: bool, is_await: bool) Error!*Node {
    if (left.data == .var_decl) {
        const ds = left.data.var_decl.decls;
        if (ds.len != 1) return p.failAt("Invalid left-hand side in for-loop", left.pos);
        if (ds[0].init != null and (is_of or p.strict or left.data.var_decl.kind != .@"var")) {
            return p.failAt("for-loop variable declaration may not have an initializer.", left.pos);
        }
    } else {
        p.cover_init = 0;
        try expr.checkTarget(p, left, true);
    }
    try p.next();
    const right = if (is_of) try expr.assignment(p) else try expr.expression(p);
    try p.expect(.rparen);
    const body = try subStatement(p);
    if (is_of) {
        return p.node(.{ .for_of = .{ .left = left, .right = right, .body = body, .is_await = is_await } }, pos);
    }
    if (is_await) return p.failAt("Unexpected token 'in' after for await", pos);
    return p.node(.{ .for_in = .{ .left = left, .right = right, .body = body } }, pos);
}

fn tryStatement(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    const block = try blockStatement(p);
    var param: ?*Node = null;
    var handler: ?*Node = null;
    var finalizer: ?*Node = null;
    if (try p.eat(.kw_catch)) {
        if (try p.eat(.lparen)) {
            param = try literal.bindingTarget(p);
            try p.expect(.rparen);
        }
        handler = try blockStatement(p);
    }
    if (try p.eat(.kw_finally)) finalizer = try blockStatement(p);
    if (handler == null and finalizer == null) return p.fail("Missing catch or finally after try");
    return p.node(.{ .try_stmt = .{ .block = block, .param = param, .handler = handler, .finalizer = finalizer } }, pos);
}

fn switchStatement(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    try p.next();
    const disc = try parenExpr(p);
    try p.expect(.lbrace);
    var cases: std.ArrayList(ast.Case) = .empty;
    var seen_default = false;
    while (p.t() != .rbrace) {
        var c: ?*Node = null;
        if (try p.eat(.kw_default)) {
            if (seen_default) return p.fail("More than one default clause in switch statement");
            seen_default = true;
        } else {
            try p.expect(.kw_case);
            c = try expr.expression(p);
        }
        try p.expect(.colon);
        var body: std.ArrayList(*Node) = .empty;
        while (p.t() != .kw_case and p.t() != .kw_default and p.t() != .rbrace) {
            if (p.t() == .eof) return p.unexpected();
            try body.append(p.a, try statementListItem(p));
        }
        try cases.append(p.a, .{ .t = c, .body = body.items });
    }
    try p.next();
    return p.node(.{ .switch_stmt = .{ .disc = disc, .cases = cases.items } }, pos);
}
