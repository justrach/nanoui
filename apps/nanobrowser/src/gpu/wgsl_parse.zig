//! WGSL's declarations and statements, by recursive descent.
const std = @import("std");
const ast = @import("wgsl_ast.zig");
const lex = @import("wgsl_lex.zig");
const pe = @import("wgsl_parse_expr.zig");
const Allocator = std.mem.Allocator;
const Error = lex.Error;
const Stmt = ast.Stmt;
const Expr = ast.Expr;

pub const Parser = struct {
    arena: Allocator,
    sink: *lex.Sink,
    lexer: lex.Lexer,
    tok: lex.Token = .{ .tag = .eof, .text = "", .pos = .{} },
    /// Inside a template's arguments a `>` closes it, until a bracket opens.
    no_gt: bool = false,

    pub fn advance(p: *Parser) Error!void {
        p.tok = try p.lexer.next();
    }

    pub fn splitGt(p: *Parser, rest: lex.Tag) void {
        p.tok.tag = rest;
        p.tok.text = p.tok.text[1..];
        p.tok.pos.col += 1;
        p.tok.pos.offset += 1;
        p.tok.pos.len -= 1;
    }

    pub fn accept(p: *Parser, tag: lex.Tag) Error!bool {
        if (p.tok.tag != tag) return false;
        try p.advance();
        return true;
    }

    pub fn expect(p: *Parser, tag: lex.Tag) Error!void {
        if (p.tok.tag != tag) return p.sink.fail(p.tok.pos, "expected '{s}', found '{s}'", .{ tagText(tag), if (p.tok.tag == .eof) "the end of the file" else p.tok.text });
        try p.advance();
    }

    fn isKw(p: *const Parser, k: []const u8) bool {
        return p.tok.tag == .keyword and std.mem.eql(u8, p.tok.text, k);
    }

    fn acceptKw(p: *Parser, k: []const u8) Error!bool {
        if (!p.isKw(k)) return false;
        try p.advance();
        return true;
    }

    fn expectKw(p: *Parser, k: []const u8) Error!void {
        if (!try p.acceptKw(k)) return p.sink.fail(p.tok.pos, "expected '{s}', found '{s}'", .{ k, p.tok.text });
    }

    fn ident(p: *Parser, what: []const u8) Error!lex.Token {
        const t = p.tok;
        if (t.tag != .ident) return p.sink.fail(t.pos, "expected {s}, found '{s}'", .{ what, if (t.tag == .eof) "the end of the file" else t.text });
        try p.advance();
        return t;
    }
};

fn tagText(tag: lex.Tag) []const u8 {
    return switch (tag) {
        .lparen => "(",
        .rparen => ")",
        .lbrace => "{",
        .rbrace => "}",
        .rbracket => "]",
        .semicolon => ";",
        .colon => ":",
        .comma => ",",
        .eq => "=",
        .lt => "<",
        .gt => ">",
        else => @tagName(tag),
    };
}

fn attrExpr(p: *Parser) Error!*Expr {
    try p.expect(.lparen);
    const e = try pe.expression(p);
    _ = try p.accept(.comma);
    try p.expect(.rparen);
    return e;
}

fn attrName(p: *Parser, what: []const u8) Error!lex.Token {
    try p.expect(.lparen);
    const t = try p.ident(what);
    _ = try p.accept(.comma);
    try p.expect(.rparen);
    return t;
}

fn attributes(p: *Parser) Error!ast.Attrs {
    var a: ast.Attrs = .{ .pos = p.tok.pos };
    while (try p.accept(.at)) {
        const t = p.tok;
        if (t.tag == .keyword and std.mem.eql(u8, t.text, "diagnostic")) {
            try p.advance();
            var depth: u32 = 0;
            while (true) {
                if (p.tok.tag == .lparen) depth += 1;
                if (p.tok.tag == .rparen) depth -= 1;
                if (p.tok.tag == .eof) return p.sink.fail(p.tok.pos, "unterminated @diagnostic", .{});
                try p.advance();
                if (depth == 0) break;
            }
            continue;
        }
        if (t.tag != .ident) return p.sink.fail(t.pos, "expected an attribute's name, found '{s}'", .{t.text});
        try p.advance();
        const n = t.text;
        if (std.mem.eql(u8, n, "builtin")) {
            const b = try attrName(p, "a builtin's name");
            a.builtin = b.text;
            a.builtin_pos = b.pos;
        } else if (std.mem.eql(u8, n, "location")) {
            a.location = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "align")) {
            a.align_ = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "size")) {
            a.size = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "group")) {
            a.group = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "binding")) {
            a.binding = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "id")) {
            a.id = try attrExpr(p);
        } else if (std.mem.eql(u8, n, "invariant")) {
            a.invariant = true;
        } else if (std.mem.eql(u8, n, "must_use")) {
            a.must_use = true;
        } else if (std.mem.eql(u8, n, "vertex")) {
            a.stage = .vertex;
        } else if (std.mem.eql(u8, n, "fragment")) {
            a.stage = .fragment;
        } else if (std.mem.eql(u8, n, "compute")) {
            a.stage = .compute;
        } else if (std.mem.eql(u8, n, "interpolate")) {
            try p.expect(.lparen);
            var it: ast.Interp = .{ .kind = (try p.ident("an interpolation type")).text };
            if (try p.accept(.comma)) {
                if (p.tok.tag == .ident) it.sampling = (try p.ident("an interpolation sampling")).text;
                _ = try p.accept(.comma);
            }
            try p.expect(.rparen);
            a.interpolate = it;
        } else if (std.mem.eql(u8, n, "workgroup_size")) {
            try p.expect(.lparen);
            var dims: [3]?*Expr = .{ null, null, null };
            var i: usize = 0;
            while (p.tok.tag != .rparen) : (i += 1) {
                if (i == 3) return p.sink.fail(p.tok.pos, "@workgroup_size takes at most three values", .{});
                dims[i] = try pe.expression(p);
                if (!try p.accept(.comma)) break;
            }
            if (i == 0 and dims[0] == null) return p.sink.fail(p.tok.pos, "@workgroup_size needs a value", .{});
            try p.expect(.rparen);
            a.workgroup_size = dims;
        } else {
            return p.sink.fail(t.pos, "the attribute '@{s}' is not supported", .{n});
        }
    }
    return a;
}

fn block(p: *Parser) Error![]const *Stmt {
    try p.expect(.lbrace);
    var list: std.ArrayList(*Stmt) = .empty;
    while (p.tok.tag != .rbrace) {
        if (p.tok.tag == .eof) return p.sink.fail(p.tok.pos, "expected '}}', found the end of the file", .{});
        if (try p.accept(.semicolon)) continue;
        try list.append(p.arena, try statement(p));
    }
    try p.advance();
    return list.items;
}

fn make(p: *Parser, pos: ast.Pos, k: Stmt.Kind) Error!*Stmt {
    const s = try p.arena.create(Stmt);
    s.* = .{ .pos = pos, .k = k };
    return s;
}

/// `let`, `const` or `var` with no semicolon.
fn localVar(p: *Parser) Error!?*Stmt {
    const t = p.tok;
    const kind: ast.VarKind = if (p.isKw("var")) .var_ else if (p.isKw("let")) .let else if (p.isKw("const")) .const_ else return null;
    try p.advance();
    if (kind == .var_ and p.tok.tag == .lt) {
        try p.advance();
        const space = try p.ident("an address space");
        if (!std.mem.eql(u8, space.text, "function")) return p.sink.fail(space.pos, "a variable in a function is in 'function' space, not '{s}'", .{space.text});
        try p.expect(.gt);
    }
    const n = try p.ident("a variable's name");
    const ty: ?*Expr = if (try p.accept(.colon)) try pe.typeExpr(p) else null;
    const init_expr: ?*Expr = if (try p.accept(.eq)) try pe.expression(p) else null;
    if (kind != .var_ and init_expr == null) return p.sink.fail(n.pos, "'{s}' needs a value", .{n.text});
    if (kind == .var_ and ty == null and init_expr == null) return p.sink.fail(n.pos, "'{s}' needs a type or a value", .{n.text});
    return try make(p, t.pos, .{ .decl = .{ .kind = kind, .name = n.text, .name_pos = n.pos, .ty = ty, .init = init_expr } });
}

/// An assignment, an increment or a call, with no semicolon.
fn simple(p: *Parser) Error!*Stmt {
    const t = p.tok;
    if (t.tag == .ident and std.mem.eql(u8, t.text, "_")) {
        try p.advance();
        try p.expect(.eq);
        return make(p, t.pos, .{ .assign = .{ .lhs = null, .op = null, .rhs = try pe.expression(p) } });
    }
    const lhs = try pe.unary(p);
    if (p.tok.tag == .plusplus or p.tok.tag == .minusminus) {
        const inc = p.tok.tag == .plusplus;
        try p.advance();
        return make(p, t.pos, .{ .incdec = .{ .lhs = lhs, .inc = inc } });
    }
    const op: ?ast.BinOp = switch (p.tok.tag) {
        .eq => null,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .mod,
        .amp_eq => .band,
        .pipe_eq => .bor,
        .caret_eq => .bxor,
        .shl_eq => .shl,
        .shr_eq => .shr,
        else => {
            if (lhs.k == .call) return make(p, t.pos, .{ .call = lhs });
            return p.sink.fail(p.tok.pos, "expected an assignment, found '{s}'", .{if (p.tok.tag == .eof) "the end of the file" else p.tok.text});
        },
    };
    try p.advance();
    return make(p, t.pos, .{ .assign = .{ .lhs = lhs, .op = op, .rhs = try pe.expression(p) } });
}

fn ifStmt(p: *Parser) Error!*Stmt {
    const t = p.tok;
    try p.expectKw("if");
    const cond = try pe.expression(p);
    const then = try block(p);
    var els: ?*Stmt = null;
    if (try p.acceptKw("else")) {
        if (p.isKw("if")) {
            els = try ifStmt(p);
        } else {
            const pos = p.tok.pos;
            els = try make(p, pos, .{ .block = try block(p) });
        }
    }
    return make(p, t.pos, .{ .if_ = .{ .cond = cond, .then = then, .els = els } });
}

fn forStmt(p: *Parser, pos: ast.Pos) Error!*Stmt {
    try p.expect(.lparen);
    var init_s: ?*Stmt = null;
    if (p.tok.tag != .semicolon) init_s = (try localVar(p)) orelse try simple(p);
    try p.expect(.semicolon);
    const cond: ?*Expr = if (p.tok.tag != .semicolon) try pe.expression(p) else null;
    try p.expect(.semicolon);
    const update: ?*Stmt = if (p.tok.tag != .rparen) try simple(p) else null;
    try p.expect(.rparen);
    return make(p, pos, .{ .for_ = .{ .init = init_s, .cond = cond, .update = update, .body = try block(p) } });
}

fn loopStmt(p: *Parser, pos: ast.Pos) Error!*Stmt {
    try p.expect(.lbrace);
    var list: std.ArrayList(*Stmt) = .empty;
    var continuing: ?[]const *Stmt = null;
    var break_if: ?*Expr = null;
    while (p.tok.tag != .rbrace) {
        if (p.tok.tag == .eof) return p.sink.fail(p.tok.pos, "expected '}}', found the end of the file", .{});
        if (try p.accept(.semicolon)) continue;
        if (try p.acceptKw("continuing")) {
            try p.expect(.lbrace);
            var cs: std.ArrayList(*Stmt) = .empty;
            while (p.tok.tag != .rbrace) {
                if (p.tok.tag == .eof) return p.sink.fail(p.tok.pos, "expected '}}', found the end of the file", .{});
                if (try p.accept(.semicolon)) continue;
                if (p.isKw("break")) {
                    try p.advance();
                    try p.expectKw("if");
                    break_if = try pe.expression(p);
                    try p.expect(.semicolon);
                    if (p.tok.tag != .rbrace) return p.sink.fail(p.tok.pos, "'break if' must come last in 'continuing'", .{});
                    break;
                }
                try cs.append(p.arena, try statement(p));
            }
            try p.expect(.rbrace);
            continuing = cs.items;
            if (p.tok.tag != .rbrace) return p.sink.fail(p.tok.pos, "'continuing' must come last in 'loop'", .{});
            break;
        }
        try list.append(p.arena, try statement(p));
    }
    try p.expect(.rbrace);
    return make(p, pos, .{ .loop = .{ .body = list.items, .continuing = continuing, .break_if = break_if } });
}

fn switchStmt(p: *Parser, pos: ast.Pos) Error!*Stmt {
    const sel = try pe.expression(p);
    try p.expect(.lbrace);
    var cases: std.ArrayList(ast.Case) = .empty;
    while (p.tok.tag != .rbrace) {
        const cpos = p.tok.pos;
        var sels: std.ArrayList(?*Expr) = .empty;
        if (try p.acceptKw("default")) {
            try sels.append(p.arena, null);
        } else {
            try p.expectKw("case");
            while (true) {
                if (try p.acceptKw("default")) {
                    try sels.append(p.arena, null);
                } else {
                    try sels.append(p.arena, try pe.expression(p));
                }
                if (!try p.accept(.comma)) break;
                if (p.tok.tag == .colon or p.tok.tag == .lbrace) break;
            }
        }
        _ = try p.accept(.colon);
        try cases.append(p.arena, .{ .pos = cpos, .selectors = sels.items, .body = try block(p) });
    }
    try p.advance();
    return make(p, pos, .{ .switch_ = .{ .sel = sel, .cases = cases.items } });
}

fn statement(p: *Parser) Error!*Stmt {
    const t = p.tok;
    if (t.tag == .at) {
        // Only `@diagnostic` means anything before a statement, and it changes no code.
        const a = try attributes(p);
        if (a.stage != null or a.builtin != null or a.location != null or a.group != null) return p.sink.fail(a.pos, "this attribute doesn't belong before a statement", .{});
        return statement(p);
    }
    if (t.tag == .lbrace) return make(p, t.pos, .{ .block = try block(p) });
    if (t.tag == .keyword) {
        if (std.mem.eql(u8, t.text, "if")) return ifStmt(p);
        if (std.mem.eql(u8, t.text, "for")) {
            try p.advance();
            return forStmt(p, t.pos);
        }
        if (std.mem.eql(u8, t.text, "while")) {
            try p.advance();
            const cond = try pe.expression(p);
            return make(p, t.pos, .{ .while_ = .{ .cond = cond, .body = try block(p) } });
        }
        if (std.mem.eql(u8, t.text, "loop")) {
            try p.advance();
            return loopStmt(p, t.pos);
        }
        if (std.mem.eql(u8, t.text, "switch")) {
            try p.advance();
            return switchStmt(p, t.pos);
        }
    }
    const s: *Stmt = blk: {
        if (t.tag == .keyword) {
            if (std.mem.eql(u8, t.text, "return")) {
                try p.advance();
                const v: ?*Expr = if (p.tok.tag != .semicolon) try pe.expression(p) else null;
                break :blk try make(p, t.pos, .{ .ret = v });
            }
            if (std.mem.eql(u8, t.text, "break")) {
                try p.advance();
                break :blk try make(p, t.pos, .brk);
            }
            if (std.mem.eql(u8, t.text, "continue")) {
                try p.advance();
                break :blk try make(p, t.pos, .cont);
            }
            if (std.mem.eql(u8, t.text, "discard")) {
                try p.advance();
                break :blk try make(p, t.pos, .discard);
            }
            if (std.mem.eql(u8, t.text, "const_assert")) {
                try p.advance();
                break :blk try make(p, t.pos, .{ .const_assert = try pe.expression(p) });
            }
            if (try localVar(p)) |d| break :blk d;
            return p.sink.fail(t.pos, "expected a statement, found '{s}'", .{t.text});
        }
        break :blk try simple(p);
    };
    try p.expect(.semicolon);
    return s;
}

fn structDecl(p: *Parser) Error!*ast.Struct {
    const n = try p.ident("a struct's name");
    try p.expect(.lbrace);
    var members: std.ArrayList(ast.Member) = .empty;
    while (p.tok.tag != .rbrace) {
        const a = try attributes(p);
        const m = try p.ident("a member's name");
        try p.expect(.colon);
        try members.append(p.arena, .{ .name = m.text, .pos = m.pos, .ty = try pe.typeExpr(p), .attrs = a });
        if (!try p.accept(.comma)) break;
    }
    try p.expect(.rbrace);
    if (members.items.len == 0) return p.sink.fail(n.pos, "the struct '{s}' has no members", .{n.text});
    const s = try p.arena.create(ast.Struct);
    s.* = .{ .name = n.text, .pos = n.pos, .members = members.items };
    return s;
}

fn funcDecl(p: *Parser, attrs: ast.Attrs) Error!*ast.Func {
    const n = try p.ident("a function's name");
    try p.expect(.lparen);
    var params: std.ArrayList(ast.Param) = .empty;
    while (p.tok.tag != .rparen) {
        const a = try attributes(p);
        const m = try p.ident("a parameter's name");
        try p.expect(.colon);
        try params.append(p.arena, .{ .name = m.text, .pos = m.pos, .ty = try pe.typeExpr(p), .attrs = a });
        if (!try p.accept(.comma)) break;
    }
    try p.expect(.rparen);
    var ret: ?*Expr = null;
    var ret_attrs: ast.Attrs = .{};
    if (try p.accept(.arrow)) {
        ret_attrs = try attributes(p);
        ret = try pe.typeExpr(p);
    }
    const body = try block(p);
    const f = try p.arena.create(ast.Func);
    f.* = .{ .name = n.text, .pos = n.pos, .params = params.items, .ret = ret, .ret_attrs = ret_attrs, .body = body, .attrs = attrs, .end_pos = p.tok.pos };
    return f;
}

fn globalVar(p: *Parser, attrs: ast.Attrs) Error!*ast.Global {
    var space: ?[]const u8 = null;
    var access: ?[]const u8 = null;
    if (try p.accept(.lt)) {
        space = (try p.ident("an address space")).text;
        if (try p.accept(.comma)) {
            if (p.tok.tag == .ident) access = (try p.ident("an access mode")).text;
            _ = try p.accept(.comma);
        }
        try p.expect(.gt);
    }
    const n = try p.ident("a variable's name");
    const ty: ?*Expr = if (try p.accept(.colon)) try pe.typeExpr(p) else null;
    const v: ?*Expr = if (try p.accept(.eq)) try pe.expression(p) else null;
    try p.expect(.semicolon);
    const g = try p.arena.create(ast.Global);
    g.* = .{ .name = n.text, .pos = n.pos, .ty = ty, .init = v, .space = space, .access = access, .attrs = attrs };
    return g;
}

fn directive(p: *Parser) Error!bool {
    const t = p.tok;
    if (t.tag != .keyword) return false;
    if (std.mem.eql(u8, t.text, "enable")) {
        try p.advance();
        const f = try p.ident("an extension's name");
        return p.sink.fail(f.pos, "the extension '{s}' is not supported", .{f.text});
    }
    if (std.mem.eql(u8, t.text, "requires") or std.mem.eql(u8, t.text, "diagnostic")) {
        const is_requires = t.text[0] == 'r';
        try p.advance();
        if (is_requires) {
            const f = try p.ident("a language feature's name");
            return p.sink.fail(f.pos, "the language feature '{s}' is not supported", .{f.text});
        }
        while (p.tok.tag != .semicolon) {
            if (p.tok.tag == .eof) return p.sink.fail(p.tok.pos, "expected ';', found the end of the file", .{});
            try p.advance();
        }
        try p.advance();
        return true;
    }
    return false;
}

pub fn parse(arena: Allocator, sink: *lex.Sink, src: []const u8) Error!ast.Module {
    var p: Parser = .{ .arena = arena, .sink = sink, .lexer = .{ .src = src, .sink = sink } };
    try p.advance();
    var decls: std.ArrayList(ast.Decl) = .empty;
    while (p.tok.tag != .eof) {
        if (try p.accept(.semicolon)) continue;
        if (try directive(&p)) continue;
        const attrs = try attributes(&p);
        const t = p.tok;
        const none = attrs.builtin == null and attrs.location == null and attrs.stage == null;
        if (p.isKw("struct")) {
            try p.advance();
            try decls.append(arena, .{ .strct = try structDecl(&p) });
        } else if (p.isKw("fn")) {
            try p.advance();
            try decls.append(arena, .{ .func = try funcDecl(&p, attrs) });
        } else if (p.isKw("var")) {
            try p.advance();
            try decls.append(arena, .{ .global = try globalVar(&p, attrs) });
        } else if (p.isKw("alias") and none) {
            try p.advance();
            const n = try p.ident("an alias's name");
            try p.expect(.eq);
            const a = try arena.create(ast.Alias);
            a.* = .{ .name = n.text, .pos = n.pos, .ty = try pe.typeExpr(&p) };
            try p.expect(.semicolon);
            try decls.append(arena, .{ .alias = a });
        } else if (p.isKw("const") and none) {
            try p.advance();
            const n = try p.ident("a constant's name");
            const ty: ?*Expr = if (try p.accept(.colon)) try pe.typeExpr(&p) else null;
            try p.expect(.eq);
            const c = try arena.create(ast.Const);
            c.* = .{ .name = n.text, .pos = n.pos, .ty = ty, .init = try pe.expression(&p) };
            try p.expect(.semicolon);
            try decls.append(arena, .{ .constant = c });
        } else if (p.isKw("override")) {
            try p.advance();
            const n = try p.ident("an override's name");
            const ty: ?*Expr = if (try p.accept(.colon)) try pe.typeExpr(&p) else null;
            const v: ?*Expr = if (try p.accept(.eq)) try pe.expression(&p) else null;
            try p.expect(.semicolon);
            const o = try arena.create(ast.Override);
            o.* = .{ .name = n.text, .pos = n.pos, .ty = ty, .init = v, .attrs = attrs };
            try decls.append(arena, .{ .override = o });
        } else if (p.isKw("const_assert")) {
            try p.advance();
            try decls.append(arena, .{ .assert = try pe.expression(&p) });
            try p.expect(.semicolon);
        } else {
            return sink.fail(t.pos, "expected a declaration, found '{s}'", .{t.text});
        }
    }
    return .{ .decls = decls.items };
}
