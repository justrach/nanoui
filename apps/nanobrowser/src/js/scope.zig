//! Scope analysis. Walks the AST once after parsing: declares every binding with
//! hoisting and Annex B rules, resolves every identifier to its Var, and decides which
//! variables are captured (they live in an Env) and which need temporal-dead-zone checks.
//! A null binding means a global. The walking itself is in scope_walk.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const Scope = ast.Scope;
const Var = ast.Var;
const FuncInfo = ast.FuncInfo;
const JSString = @import("string.zig").JSString;
const walk = @import("scope_walk.zig");

pub const Mode = enum { script, eval, module };

pub const Analyzer = struct {
    vm: *Vm,
    a: Allocator,
    source: []const u8,
    scope: *Scope = undefined,
    fi: *FuncInfo = undefined,
    all_scopes: std.ArrayList(*Scope) = .empty,
    /// Top-level `var` and function names of a script or eval: they become globals.
    global_vars: std.ArrayList(*JSString) = .empty,
    /// Top-level let/const/class of a script.
    global_lex: std.ArrayList(GlobalLex) = .empty,
    /// Hidden `with` variables the latest resolve walked past.
    with_seen: std.ArrayList(*Var) = .empty,

    pub const GlobalLex = struct { name: *JSString, is_const: bool };

    pub fn fail(an: *Analyzer, comptime fmt: []const u8, name: []const u8, pos: u32) Error {
        var line: u32 = 1;
        for (an.source[0..@min(pos, an.source.len)]) |c| {
            if (c == '\n') line += 1;
        }
        var b: [200]u8 = undefined;
        const m = std.fmt.bufPrint(&b, fmt ++ " ({d})", .{ name[0..@min(name.len, 80)], line }) catch fmt;
        return an.vm.throwError(.SyntaxError, m);
    }

    pub fn alreadyDeclared(an: *Analyzer, name: *JSString, pos: u32) Error {
        return an.fail("Identifier '{s}' has already been declared", try name.flat(an.vm), pos);
    }

    pub fn newScope(an: *Analyzer, kind: ast.ScopeKind) Error!*Scope {
        const s = try an.a.create(Scope);
        s.* = .{ .kind = kind, .parent = an.scope, .func = an.fi };
        try an.all_scopes.append(an.a, s);
        return s;
    }

    pub fn declare(an: *Analyzer, s: *Scope, name: *JSString, kind: ast.VarKind) Error!*Var {
        const v = try an.a.create(Var);
        v.* = .{ .name = name, .kind = kind, .scope = s };
        // Variables in a switch body can be jumped over, and a module's are all exported.
        if (kind == .let or kind == .@"const" or kind == .class) {
            if (s.kind == .switch_body) v.needs_tdz = true;
        }
        if (s.kind == .module) {
            v.captured = true;
            if (kind == .let or kind == .@"const" or kind == .class or kind == .import) v.needs_tdz = true;
        }
        try s.vars.append(an.a, v);
        return v;
    }

    /// Declares every name a binding pattern introduces.
    pub fn declarePattern(an: *Analyzer, s: *Scope, n: *Node, kind: ast.VarKind, init_end: u32) Error!void {
        switch (n.data) {
            .ident => |id| {
                if (s.kind == .script and (kind == .let or kind == .@"const")) {
                    for (an.global_lex.items) |g| {
                        if (g.name == id.name) return an.alreadyDeclared(id.name, n.pos);
                    }
                    try an.global_lex.append(an.a, .{ .name = id.name, .is_const = kind == .@"const" });
                    return;
                }
                if (s.lookupHere(id.name)) |ex| {
                    const redeclarable = (kind == .@"var" or kind == .param) and (ex.kind == .@"var" or ex.kind == .param or ex.kind == .function);
                    if (!redeclarable) return an.alreadyDeclared(id.name, n.pos);
                    return;
                }
                const v = try an.declare(s, id.name, kind);
                v.init_end = init_end;
            },
            .array => |items| for (items) |it| {
                if (it) |e| try an.declarePattern(s, e, kind, init_end);
            },
            .object => |props| for (props) |prop| try an.declarePattern(s, prop.value, kind, init_end),
            .assign => |a| try an.declarePattern(s, a.target, kind, init_end),
            .spread => |sp| try an.declarePattern(s, sp, kind, init_end),
            else => {},
        }
    }

    /// Declares let/const/class and function declarations directly in a statement list.
    pub fn declareLexicals(an: *Analyzer, s: *Scope, body: []const *Node, is_top: bool) Error!void {
        for (body) |st0| {
            var st = st0;
            while (st.data == .labeled) st = st.data.labeled.body;
            switch (st.data) {
                .var_decl => |d| {
                    if (d.kind == .@"var") continue;
                    for (d.decls) |decl| {
                        const end = if (decl.init) |i| i.end else decl.target.end;
                        try an.declarePattern(s, decl.target, d.kind, end);
                    }
                },
                .class_decl => |c| {
                    if (s.kind == .script) {
                        for (an.global_lex.items) |g| {
                            if (g.name == c.name.?) return an.alreadyDeclared(c.name.?, st.pos);
                        }
                        try an.global_lex.append(an.a, .{ .name = c.name.?, .is_const = false });
                        continue;
                    }
                    if (s.lookupHere(c.name.?) != null) return an.alreadyDeclared(c.name.?, st.pos);
                    const v = try an.declare(s, c.name.?, .class);
                    v.init_end = c.end;
                },
                .func_decl => |f| {
                    try s.hoisted.append(an.a, st);
                    const name = f.name.?;
                    if (s.kind == .script or s.kind == .eval) {
                        try an.addGlobalVar(name);
                        continue;
                    }
                    if (s.lookupHere(name)) |ex| {
                        if (is_top) {
                            if (ex.kind == .let or ex.kind == .@"const" or ex.kind == .class) return an.alreadyDeclared(name, st.pos);
                            ex.kind = if (ex.kind == .param) .param else .function;
                            f.decl_binding = ex;
                            continue;
                        }
                        // Sloppy blocks allow duplicate plain functions.
                        if (ex.kind != .function or f.strict or f.is_async or f.is_generator) return an.alreadyDeclared(name, st.pos);
                        f.decl_binding = ex;
                        continue;
                    }
                    f.decl_binding = try an.declare(s, name, .function);
                },
                else => {},
            }
        }
    }

    pub fn addGlobalVar(an: *Analyzer, name: *JSString) Error!void {
        for (an.global_vars.items) |g| {
            if (g == name) return;
        }
        try an.global_vars.append(an.a, name);
    }

    /// Hoists `var` names (and Annex B block functions) to the function scope.
    pub fn hoistVars(an: *Analyzer, s: *Scope, body: []const *Node, depth: u32) Error!void {
        for (body) |st| try an.hoistStmt(s, st, depth);
    }

    fn hoistPattern(an: *Analyzer, s: *Scope, n: *Node) Error!void {
        switch (n.data) {
            .ident => |id| {
                if (s.kind == .script or s.kind == .eval) return an.addGlobalVar(id.name);
                if (s.lookupHere(id.name)) |ex| {
                    if (ex.kind == .let or ex.kind == .@"const" or ex.kind == .class) return an.alreadyDeclared(id.name, n.pos);
                    return;
                }
                _ = try an.declare(s, id.name, .@"var");
            },
            .array => |items| for (items) |it| {
                if (it) |e| try an.hoistPattern(s, e);
            },
            .object => |props| for (props) |prop| try an.hoistPattern(s, prop.value),
            .assign => |a| try an.hoistPattern(s, a.target),
            .spread => |sp| try an.hoistPattern(s, sp),
            else => {},
        }
    }

    fn hoistStmt(an: *Analyzer, s: *Scope, st: *Node, depth: u32) Error!void {
        switch (st.data) {
            .var_decl => |d| if (d.kind == .@"var") {
                for (d.decls) |decl| try an.hoistPattern(s, decl.target);
            },
            .block => |b| try an.hoistVars(s, b.body, depth + 1),
            .if_stmt => |i| {
                try an.hoistStmt(s, i.a, depth + 1);
                if (i.b) |b| try an.hoistStmt(s, b, depth + 1);
            },
            .for_stmt => |f| {
                if (f.init) |i| try an.hoistStmt(s, i, depth + 1);
                try an.hoistStmt(s, f.body, depth + 1);
            },
            .for_in => |f| {
                try an.hoistStmt(s, f.left, depth + 1);
                try an.hoistStmt(s, f.body, depth + 1);
            },
            .for_of => |f| {
                try an.hoistStmt(s, f.left, depth + 1);
                try an.hoistStmt(s, f.body, depth + 1);
            },
            .while_stmt => |w| try an.hoistStmt(s, w.body, depth + 1),
            .with_stmt => |w| try an.hoistStmt(s, w.body, depth + 1),
            .do_while => |w| try an.hoistStmt(s, w.body, depth + 1),
            .labeled => |l| try an.hoistStmt(s, l.body, depth),
            .try_stmt => |t| {
                try an.hoistStmt(s, t.block, depth + 1);
                if (t.handler) |h| try an.hoistStmt(s, h, depth + 1);
                if (t.finalizer) |f| try an.hoistStmt(s, f, depth + 1);
            },
            .switch_stmt => |sw| {
                for (sw.cases) |c| try an.hoistVars(s, c.body, depth + 1);
            },
            .func_decl => |f| {
                // Annex B: a sloppy block function also makes a function-level var.
                if (depth > 0 and !f.strict and !f.is_async and !f.is_generator) {
                    const name = f.name.?;
                    if (s.kind == .script or s.kind == .eval) {
                        try an.addGlobalVar(name);
                    } else if (s.lookupHere(name) == null) {
                        _ = try an.declare(s, name, .@"var");
                    }
                }
            },
            else => {},
        }
    }

    /// The var an Annex B function assigns, unless a lexical binding in between forbids it.
    pub fn annexBTarget(_: *Analyzer, block: *Scope, f: *ast.Func) void {
        if (f.strict or f.is_async or f.is_generator) return;
        const name = f.name.?;
        var s = block.parent;
        while (s) |sc| : (s = sc.parent) {
            if (sc.func != block.func) return;
            const here = sc.lookupHere(name);
            const is_func_level = sc.kind == .function or sc.kind == .script or sc.kind == .eval or sc.kind == .module;
            if (is_func_level) {
                if (sc.kind == .script or sc.kind == .eval) {
                    if (here == null) f.annex_b_global = true;
                } else if (here) |v| {
                    if (v.kind == .@"var" or v.kind == .function) f.annex_b_var = v;
                }
                return;
            }
            if (here) |v| {
                if (v.kind == .let or v.kind == .@"const" or v.kind == .class or v.kind == .function) return;
            }
        }
    }

    /// Numbers a function's variables once everything inside it has been resolved.
    pub fn assignSlots(an: *Analyzer, fi: *FuncInfo) void {
        for (an.all_scopes.items) |s| {
            if (s.func != fi) continue;
            for (s.vars.items) |v| {
                if (v.captured) {
                    v.index = s.env_size;
                    s.env_size += 1;
                } else if (v.kind == .param and rawParamIndex(fi.func, v.name) != null) {
                    v.index = rawParamIndex(fi.func, v.name).?;
                } else {
                    v.index = fi.nlocals;
                    fi.nlocals += 1;
                }
            }
        }
    }
};

/// A simple parameter shares its raw argument slot; with duplicates, the last one wins.
pub fn rawParamIndex(f: *const ast.Func, name: *JSString) ?u32 {
    var found: ?u32 = null;
    for (f.params, 0..) |param, i| {
        if (param.data == .ident and param.data.ident.name == name) found = @intCast(i);
    }
    return found;
}

pub fn rawParamCount(f: *const ast.Func) u32 {
    var n: u32 = 0;
    for (f.params) |param| {
        if (param.data != .spread) n += 1;
    }
    return n;
}

pub const Result = struct {
    global_vars: []*JSString,
    global_lex: []Analyzer.GlobalLex,
};

/// Analyzes a whole program. The top function gets a script, eval or module scope.
pub fn analyze(vm: *Vm, a: Allocator, prog: *ast.Program, source: []const u8, mode: Mode) Error!Result {
    var an = Analyzer{ .vm = vm, .a = a, .source = source };
    try walk.topLevel(&an, prog, mode);
    return .{ .global_vars = an.global_vars.items, .global_lex = an.global_lex.items };
}
