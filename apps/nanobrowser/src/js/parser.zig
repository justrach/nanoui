//! The parser's shared state and helpers, and the entry points. It builds the AST
//! recursively, tracking only what the grammar needs (strictness, generator and async
//! context, the `in` restriction); names are resolved afterwards by scope.zig. The
//! grammar itself lives in parser_expr, parser_literal, parser_stmt, parser_class and
//! parser_module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const T = lexer.T;
const JSString = @import("string.zig").JSString;
const stmt = @import("parser_stmt.zig");

pub const Parser = struct {
    vm: *Vm,
    a: Allocator,
    l: Lexer,
    strict: bool = false,
    in_function: bool = false,
    in_generator: bool = false,
    in_async: bool = false,
    in_class_init: bool = false,
    is_module: bool = false,
    no_in: bool = false,
    /// Where a shorthand `{a = 1}` waits to become a pattern; 0 when none.
    cover_init: u32 = 0,
    /// Reserved words can't appear as identifiers here.
    imports: std.ArrayList(ast.ImportEntry) = .empty,
    exports: std.ArrayList(ast.ExportEntry) = .empty,
    requests: std.ArrayList(*JSString) = .empty,
    has_tla: bool = false,
    prev_end: u32 = 0,

    pub inline fn tok(p: *Parser) *lexer.Token {
        return &p.l.tok;
    }
    pub inline fn t(p: *Parser) T {
        return p.l.tok.t;
    }
    pub inline fn next(p: *Parser) Error!void {
        p.prev_end = p.l.tok.end;
        return p.l.next();
    }
    /// Whether the identifier just lexed is followed by `=>`, without lexing further.
    pub fn arrowFollows(p: *Parser) Error!bool {
        const s = p.l.src;
        var i: usize = p.l.i;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i + 1 >= s.len) return false;
        if (s[i] == '=') return s[i + 1] == '>';
        if (s[i] != '/') return false;
        const nx = try p.peek();
        return nx.t == .arrow and !nx.nl_before;
    }
    pub fn fail(p: *Parser, msg: []const u8) Error {
        return p.l.fail(msg, p.l.tok.pos);
    }
    pub fn failAt(p: *Parser, msg: []const u8, pos: u32) Error {
        return p.l.fail(msg, pos);
    }
    pub fn unexpected(p: *Parser) Error {
        if (p.t() == .eof) return p.fail("Unexpected end of input");
        var b: [160]u8 = undefined;
        const s = p.l.src[p.tok().pos..p.tok().end];
        const m = std.fmt.bufPrint(&b, "Unexpected token '{s}'", .{s[0..@min(s.len, 64)]}) catch "Unexpected token";
        return p.fail(m);
    }
    pub inline fn eat(p: *Parser, want: T) Error!bool {
        if (p.t() != want) return false;
        try p.next();
        return true;
    }
    pub fn expect(p: *Parser, want: T) Error!void {
        if (p.t() != want) return p.unexpected();
        try p.next();
    }
    /// Automatic semicolon insertion.
    pub fn semicolon(p: *Parser) Error!void {
        if (p.t() == .semi) return p.next();
        if (p.t() == .rbrace or p.t() == .eof or p.tok().nl_before) return;
        return p.unexpected();
    }
    /// Whether the current token is the contextual keyword held in `key`.
    pub inline fn isWord(p: *Parser, key: anytype) bool {
        return p.t() == .ident and p.tok().atom.? == key.atom() and !p.tok().escaped;
    }
    pub fn node(p: *Parser, data: ast.Data, pos: u32) Error!*Node {
        const n = try p.a.create(Node);
        n.* = .{ .data = data, .pos = pos, .end = p.lastEnd() };
        return n;
    }
    /// End offset of the most recently consumed token, approximately the node's end.
    pub fn lastEnd(p: *Parser) u32 {
        return p.prev_end;
    }
    pub fn ident(p: *Parser, name: *JSString) Error!*ast.Ident {
        const i = try p.a.create(ast.Ident);
        i.* = .{ .name = name };
        return i;
    }
    /// The bindable identifier at the current token, consuming it.
    pub fn bindingName(p: *Parser) Error!*JSString {
        if (p.t() != .ident) return p.unexpected();
        const name = p.tok().atom.?;
        if (p.strict and (name == p.vm.k.eval.atom() or name == p.vm.k.arguments.atom())) {
            return p.fail("Unexpected eval or arguments in strict mode");
        }
        try p.checkReserved(name);
        try p.next();
        return name;
    }
    /// await/yield/strict-mode words can't be identifiers in their contexts.
    pub fn checkReserved(p: *Parser, name: *JSString) Error!void {
        const k = &p.vm.k;
        if (name == k.await.atom() and (p.in_async or p.is_module)) return p.fail("Unexpected reserved word 'await'");
        if (name == k.yield.atom() and (p.in_generator or p.strict)) return p.fail("Unexpected strict mode reserved word");
        if (p.strict and (name == k.let.atom() or name == k.static.atom() or name == k.implements.atom() or
            name == k.interface.atom() or name == k.package.atom() or name == k.private.atom() or
            name == k.protected.atom() or name == k.public.atom()))
        {
            return p.fail("Unexpected strict mode reserved word");
        }
    }

    /// Saved lexer state for short lookaheads.
    pub const Mark = struct { i: u32, tok: lexer.Token, prev_end: u32 };
    pub fn mark(p: *Parser) Mark {
        return .{ .i = p.l.i, .tok = p.l.tok, .prev_end = p.prev_end };
    }
    pub fn reset(p: *Parser, m: Mark) void {
        p.l.i = m.i;
        p.l.tok = m.tok;
        p.prev_end = m.prev_end;
    }
    /// The token after the current one, without consuming anything.
    pub fn peek(p: *Parser) Error!lexer.Token {
        const m = p.mark();
        defer p.reset(m);
        try p.l.next();
        return p.l.tok;
    }
    pub fn checkStack(p: *Parser) Error!void {
        return p.vm.checkNativeStack();
    }
};

pub const Options = struct {
    is_module: bool = false,
    is_eval: bool = false,
    /// Source is a function body for `new Function`: `return` is allowed.
    strict: bool = false,
};

/// Parses a whole script or module. All nodes live in `arena`.
pub fn parseProgram(vm: *Vm, arena: Allocator, source: []const u8, opts: Options) Error!ast.Program {
    var p = Parser{
        .vm = vm,
        .a = arena,
        .l = .{ .vm = vm, .src = source, .is_module = opts.is_module },
        .is_module = opts.is_module,
        .strict = opts.is_module or opts.strict,
        .in_async = opts.is_module,
    };
    defer p.l.deinit();
    try p.next();
    const func = try arena.create(ast.Func);
    func.* = .{ .start = 0, .end = @intCast(source.len), .name = null };
    var body: std.ArrayList(*Node) = .empty;
    try stmt.directives(&p, func, &body);
    while (p.t() != .eof) {
        try body.append(arena, try stmt.statementListItem(&p));
    }
    func.strict = p.strict;
    func.body = body.items;
    func.is_async = opts.is_module;
    return .{
        .func = func,
        .is_module = opts.is_module,
        .imports = p.imports.items,
        .exports = p.exports.items,
        .requests = p.requests.items,
        .has_tla = p.has_tla,
    };
}

/// Parses "(params) { body }" source given by `new Function`, returning the function expression.
pub fn parseFunctionSource(vm: *Vm, arena: Allocator, source: []const u8) Error!ast.Program {
    return parseProgram(vm, arena, source, .{});
}
