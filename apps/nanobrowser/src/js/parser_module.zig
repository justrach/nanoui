//! Module syntax: every import and export form, recorded on the parser for the
//! module loader. Export declarations also produce ordinary declaration statements.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const expr = @import("parser_expr.zig");
const literal = @import("parser_literal.zig");
const stmt = @import("parser_stmt.zig");
const classes = @import("parser_class.zig");
const JSString = @import("string.zig").JSString;

fn request(p: *Parser, spec: *JSString) Error!u32 {
    for (p.requests.items, 0..) |r, i| {
        if (r == spec) return @intCast(i);
    }
    try p.requests.append(p.a, spec);
    return @intCast(p.requests.items.len - 1);
}

fn moduleName(p: *Parser) Error!*JSString {
    if (p.t() != .ident and !p.t().isKeyword() and p.t() != .string) return p.unexpected();
    const a = p.tok().atom.?;
    try p.next();
    return a;
}

fn fromClause(p: *Parser) Error!u32 {
    if (!p.isWord(p.vm.k.from)) return p.unexpected();
    try p.next();
    if (p.t() != .string) return p.unexpected();
    const r = try request(p, p.tok().atom.?);
    try p.next();
    try skipAttributes(p);
    return r;
}

fn skipAttributes(p: *Parser) Error!void {
    if (p.t() != .kw_with) return;
    try p.next();
    try p.expect(.lbrace);
    while (p.t() != .rbrace) {
        if (p.t() == .eof) return p.unexpected();
        try p.next();
    }
    try p.next();
}

pub fn importDecl(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    if (!p.is_module or p.in_function) return p.fail("Cannot use import statement outside a module");
    try p.next();
    if (p.t() == .string) {
        _ = try request(p, p.tok().atom.?);
        try p.next();
        try skipAttributes(p);
        try p.semicolon();
        return p.node(.empty, pos);
    }
    const first = p.imports.items.len;
    var more = true;
    if (p.t() == .ident) {
        const local = try p.bindingName();
        try p.imports.append(p.a, .{ .imported = p.vm.k.default.atom(), .local = local, .request = 0 });
        more = try p.eat(.comma);
    }
    if (more) {
        if (try p.eat(.star)) {
            if (!p.isWord(p.vm.k.as)) return p.unexpected();
            try p.next();
            const local = try p.bindingName();
            try p.imports.append(p.a, .{ .imported = null, .local = local, .request = 0 });
        } else {
            try p.expect(.lbrace);
            while (p.t() != .rbrace) {
                const is_str = p.t() == .string;
                const name = try moduleName(p);
                var local = name;
                if (p.isWord(p.vm.k.as)) {
                    try p.next();
                    local = try p.bindingName();
                } else if (is_str) return p.unexpected();
                try p.imports.append(p.a, .{ .imported = name, .local = local, .request = 0 });
                if (p.t() != .rbrace) try p.expect(.comma);
            }
            try p.next();
        }
    }
    const r = try fromClause(p);
    for (p.imports.items[first..]) |*e| e.request = r;
    try p.semicolon();
    return p.node(.empty, pos);
}

/// Adds an export for each name a pattern binds.
fn exportBound(p: *Parser, n: *Node) Error!void {
    switch (n.data) {
        .ident => |id| try p.exports.append(p.a, .{ .exported = id.name, .local = id.name }),
        .array => |items| for (items) |it| {
            if (it) |e| try exportBound(p, e);
        },
        .object => |props| for (props) |prop| try exportBound(p, prop.value),
        .assign => |a| try exportBound(p, a.target),
        .spread => |s| try exportBound(p, s),
        else => {},
    }
}

pub fn exportDecl(p: *Parser) Error!*Node {
    const pos = p.tok().pos;
    if (!p.is_module or p.in_function) return p.fail("Unexpected token 'export'");
    try p.next();
    const k = &p.vm.k;
    switch (p.t()) {
        .star => {
            try p.next();
            var exported: ?*JSString = null;
            if (p.isWord(k.as)) {
                try p.next();
                exported = try moduleName(p);
            }
            const r = try fromClause(p);
            try p.exports.append(p.a, .{ .exported = exported, .request = r });
            try p.semicolon();
            return p.node(.empty, pos);
        },
        .lbrace => {
            try p.next();
            const first = p.exports.items.len;
            while (p.t() != .rbrace) {
                const local = try moduleName(p);
                var exported = local;
                if (p.isWord(k.as)) {
                    try p.next();
                    exported = try moduleName(p);
                }
                try p.exports.append(p.a, .{ .exported = exported, .local = local });
                if (p.t() != .rbrace) try p.expect(.comma);
            }
            try p.next();
            if (p.isWord(k.from)) {
                const r = try fromClause(p);
                for (p.exports.items[first..]) |*e| {
                    e.imported = e.local;
                    e.local = null;
                    e.request = r;
                }
            }
            try p.semicolon();
            return p.node(.empty, pos);
        },
        .kw_default => return exportDefault(p, pos),
        .kw_var, .kw_const => {
            const d = try stmt.statementListItem(p);
            for (d.data.var_decl.decls) |decl| try exportBound(p, decl.target);
            return d;
        },
        .kw_function, .kw_class => {
            const d = try stmt.statementListItem(p);
            const name = if (d.data == .func_decl) d.data.func_decl.name.? else d.data.class_decl.name.?;
            try p.exports.append(p.a, .{ .exported = name, .local = name });
            return d;
        },
        else => {
            const d = try stmt.statementListItem(p);
            switch (d.data) {
                .var_decl => |v| for (v.decls) |decl| try exportBound(p, decl.target),
                .func_decl => |f| try p.exports.append(p.a, .{ .exported = f.name.?, .local = f.name.? }),
                else => return p.failAt("Unexpected token after export", d.pos),
            }
            return d;
        },
    }
}

fn exportDefault(p: *Parser, pos: u32) Error!*Node {
    const k = &p.vm.k;
    try p.next();
    const def = k.default.atom();
    const hidden = k.@"*default*".atom();
    var is_async_fn = false;
    if (p.isWord(k.async)) {
        const nx = try p.peek();
        is_async_fn = nx.t == .kw_function and !nx.nl_before;
    }
    if (p.t() == .kw_function or is_async_fn) {
        const start = p.tok().pos;
        if (is_async_fn) try p.next();
        const is_named = blk: {
            const nx = try p.peek();
            if (nx.t == .ident) break :blk true;
            if (nx.t == .star) {
                const m = p.mark();
                defer p.reset(m);
                try p.next();
                break :blk (try p.peek()).t == .ident;
            }
            break :blk false;
        };
        if (is_named) {
            const d = try stmt.functionDecl(p, start, is_async_fn);
            try p.exports.append(p.a, .{ .exported = def, .local = d.data.func_decl.name.? });
            return d;
        }
        // Anonymous: a hoisted declaration of the hidden binding, named "default".
        try p.expect(.kw_function);
        const is_gen = try p.eat(.star);
        const f = try p.a.create(ast.Func);
        f.* = .{ .is_async = is_async_fn, .is_generator = is_gen, .is_decl = true, .start = start, .name = hidden };
        const saved = literal.FnContext.enter(p, is_async_fn, is_gen);
        defer saved.leave(p);
        try literal.formalParams(p, f);
        try literal.functionBody(p, f);
        try p.exports.append(p.a, .{ .exported = def, .local = hidden });
        return p.node(.{ .func_decl = f }, start);
    }
    if (p.t() == .kw_class) {
        const nx = try p.peek();
        if (nx.t == .ident) {
            const d = try classes.classDecl(p);
            try p.exports.append(p.a, .{ .exported = def, .local = d.data.class_decl.name.? });
            return d;
        }
    }
    const value = try expr.assignmentChecked(p);
    if (value.data != .class or value.pos != p.prev_end) try p.semicolon();
    try p.exports.append(p.a, .{ .exported = def, .local = hidden });
    return p.node(.{ .export_default = .{ .value = value, .binding = try p.ident(hidden) } }, pos);
}
