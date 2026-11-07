//! The scope analyzer's tree walk: enters functions and blocks, resolves identifiers,
//! and treats pseudo-variables (this, arguments, new.target) that arrows capture.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const Scope = ast.Scope;
const Var = ast.Var;
const FuncInfo = ast.FuncInfo;
const JSString = @import("string.zig").JSString;
const scope = @import("scope.zig");
const Analyzer = scope.Analyzer;

fn isFunctionLevel(k: ast.ScopeKind) bool {
    return k == .function or k == .script or k == .eval or k == .module;
}

pub fn topLevel(an: *Analyzer, prog: *ast.Program, mode: scope.Mode) Error!void {
    const f = prog.func;
    const fi = try an.a.create(FuncInfo);
    fi.* = .{ .func = f, .parent = null };
    f.info = fi;
    an.fi = fi;
    const kind: ast.ScopeKind = switch (mode) {
        .script => .script,
        .eval => .eval,
        .module => .module,
    };
    const s = try an.a.create(Scope);
    s.* = .{ .kind = kind, .parent = null, .func = fi };
    try an.all_scopes.append(an.a, s);
    fi.scope = s;
    an.scope = s;
    for (prog.imports, 0..) |imp, i| {
        if (s.lookupHere(imp.local) != null) return an.alreadyDeclared(imp.local, 0);
        const v = try an.declare(s, imp.local, .import);
        v.import_index = @intCast(i);
    }
    if (mode == .module) {
        // The hidden binding behind `export default <expr>`.
        for (f.body) |st| {
            if (st.data == .export_default) {
                const v = try an.declare(s, st.data.export_default.binding.name, .let);
                v.needs_tdz = true;
            }
        }
    }
    try an.declareLexicals(s, f.body, true);
    try an.hoistVars(s, f.body, 0);
    for (f.body) |st| try stmt(an, st);
    an.assignSlots(fi);
}

/// Finds a variable by name from the current scope. Null means global.
fn resolve(an: *Analyzer, name: *JSString, pos: u32, is_decl: bool) Error!?*Var {
    var s: ?*Scope = an.scope;
    an.with_seen.clearRetainingCapacity();
    while (s) |sc| : (s = sc.parent) {
        if (sc.kind == .with_body) {
            const h = sc.vars.items[0];
            _ = try touch(an, h);
            try an.with_seen.append(an.a, h);
            continue;
        }
        var found = sc.lookupHere(name);
        if (found == null and sc.kind == .function) {
            const f = sc.func.func;
            if (name == an.vm.k.arguments.atom() and !f.is_arrow) {
                if (f.is_class_init) return an.fail("'{s}' is not allowed in class field initializer or static initialization block", "arguments", pos);
                const v = try an.declare(sc, name, .pseudo);
                sc.func.arguments_var = v;
                found = v;
            } else if (f.is_expr and f.name == name and !f.is_arrow) {
                const v = try an.declare(sc, name, .fn_name);
                sc.func.fn_name_var = v;
                found = v;
            }
        }
        if (found) |v| {
            v.used = true;
            const crossing = v.scope.func != an.fi;
            if (crossing) v.captured = true;
            if (!is_decl and (v.kind == .let or v.kind == .@"const" or v.kind == .class)) {
                if (crossing or pos < v.init_end) v.needs_tdz = true;
            }
            return v;
        }
    }
    return null;
}

/// The nearest function that has its own `this`.
fn thisFunction(an: *Analyzer) *FuncInfo {
    var fi = an.fi;
    while (fi.func.is_arrow) fi = fi.parent.?;
    return fi;
}

const Pseudo = enum { this, new_target, home, func };

/// Resolves a pseudo-variable. Direct uses in the owning function need no Var
/// (the frame has them), except `this` in a derived constructor, which starts empty.
fn resolvePseudo(an: *Analyzer, id: *ast.Ident, which: Pseudo) Error!void {
    const owner = thisFunction(an);
    const slot: *?*Var = switch (which) {
        .this => &owner.this_var,
        .new_target => &owner.new_target_var,
        .home => &owner.home_var,
        .func => &owner.func_var,
    };
    if (which == .this) owner.uses_this = true;
    const direct = owner == an.fi;
    const derived_this = which == .this and owner.func.is_derived;
    if (direct and !derived_this and slot.* == null) return;
    if (slot.* == null) {
        const v = try an.declare(owner.scope.?, id.name, .pseudo);
        v.needs_tdz = derived_this;
        slot.* = v;
    }
    const v = slot.*.?;
    if (!direct) v.captured = true;
    id.binding = v;
}

/// Derived constructors always keep `this` in a variable; declare it up front so
/// direct uses before a nested arrow's still agree.
fn enterFunc(an: *Analyzer, f: *ast.Func) Error!*FuncInfo {
    const fi = try an.a.create(FuncInfo);
    fi.* = .{ .func = f, .parent = an.fi };
    f.info = fi;
    fi.nlocals = scope.rawParamCount(f);
    return fi;
}

pub fn function(an: *Analyzer, f: *ast.Func) Error!void {
    try an.vm.checkNativeStack();
    const saved_fi = an.fi;
    const saved_scope = an.scope;
    defer {
        an.fi = saved_fi;
        an.scope = saved_scope;
    }
    const fi = try enterFunc(an, f);
    an.fi = fi;
    const s = try an.newScope(.function);
    fi.scope = s;
    an.scope = s;
    if (f.is_derived or f.is_class_ctor) {
        // Pre-declare so every `this` in the constructor resolves the same way.
        if (f.is_derived) {
            const v = try an.declare(s, an.vm.k.this.atom(), .pseudo);
            v.needs_tdz = true;
            fi.this_var = v;
            fi.uses_this = true;
        }
    }
    for (f.params) |param| try an.declarePattern(s, param, .param, 0);
    if (f.is_class_init) {
        for (f.init_class.?.members) |*m| {
            if (m.kind == .static_block and f.init_static) try an.hoistVars(s, m.value.?.data.block.body, 1);
        }
        try classInit(an, f);
    } else {
        try an.declareLexicals(s, f.body, true);
        try an.hoistVars(s, f.body, 0);
        for (f.params) |param| try binding(an, param);
        for (f.body) |st| try stmt(an, st);
        if (f.expr_body) |e| try expr(an, e);
    }
    an.assignSlots(fi);
}

fn classInit(an: *Analyzer, f: *ast.Func) Error!void {
    const c = f.init_class.?;
    for (c.members) |*m| {
        if (m.is_static != f.init_static) continue;
        switch (m.kind) {
            .field => {
                if (m.private_var) |pv| _ = try touch(an, pv);
                if (m.hidden) |h| _ = try touch(an, h);
                if (m.value) |v| try expr(an, v);
            },
            .static_block => try stmt(an, m.value.?),
            else => {
                // Instance private methods are installed by this function.
                if (m.is_private and !m.is_static) {
                    _ = try touch(an, m.private_var.?);
                    if (m.hidden) |h| _ = try touch(an, h);
                }
            },
        }
    }
}

/// Marks a variable as read from the current function.
fn touch(an: *Analyzer, v: *Var) Error!*Var {
    v.used = true;
    if (v.scope.func != an.fi) v.captured = true;
    return v;
}

/// A binding position: the leaf initializes rather than reads, so no TDZ marking.
pub fn binding(an: *Analyzer, n: *Node) Error!void {
    switch (n.data) {
        .ident => |id| id.binding = try resolve(an, id.name, n.pos, true),
        .array => |items| for (items) |it| {
            if (it) |e| try binding(an, e);
        },
        .object => |props| for (props) |prop| {
            if (prop.key) |k| try expr(an, k);
            try binding(an, prop.value);
        },
        .assign => |a| {
            try binding(an, a.target);
            try expr(an, a.value);
        },
        .spread => |s| try binding(an, s),
        else => try expr(an, n),
    }
}

fn exprs(an: *Analyzer, list: []const *Node) Error!void {
    for (list) |e| try expr(an, e);
}

pub fn expr(an: *Analyzer, n0: *Node) Error!void {
    try an.vm.checkNativeStack();
    var n = n0;
    // Long left-leaning operator chains walk the spine without recursing.
    while (true) {
        switch (n.data) {
            .binary => |b| {
                try expr(an, b.r);
                n = b.l;
                continue;
            },
            .logical => |b| {
                try expr(an, b.r);
                n = b.l;
                continue;
            },
            else => break,
        }
    }
    switch (n.data) {
        .num, .str, .bigint, .regex, .null_lit, .true_lit, .false_lit, .import_meta => {},
        .template => |t| try exprs(an, t.exprs),
        .tagged => |t| {
            try expr(an, t.tag);
            try exprs(an, t.tmpl.exprs);
        },
        .ident => |id| {
            id.binding = try resolve(an, id.name, n.pos, false);
            if (an.with_seen.items.len != 0) id.with_chain = try an.a.dupe(*Var, an.with_seen.items);
        },
        .this => |id| try resolvePseudo(an, id, .this),
        .new_target => |id| try resolvePseudo(an, id, .new_target),
        .array => |items| for (items) |it| {
            if (it) |e| try expr(an, e);
        },
        .object => |props| for (props) |prop| {
            if (prop.key) |k| try expr(an, k);
            try expr(an, prop.value);
        },
        .function => |f| try function(an, f),
        .class => |c| try class(an, c),
        .unary => |u| try expr(an, u.arg),
        .update => |u| try expr(an, u.arg),
        .binary, .logical => unreachable,
        .assign => |a| {
            try expr(an, a.target);
            try expr(an, a.value);
        },
        .cond => |c| {
            try expr(an, c.t);
            try expr(an, c.a);
            try expr(an, c.b);
        },
        .call => |c| {
            try expr(an, c.callee);
            try exprs(an, c.args);
        },
        .new => |c| {
            try expr(an, c.callee);
            try exprs(an, c.args);
        },
        .member => |m| try expr(an, m.obj),
        .index => |m| {
            try expr(an, m.obj);
            try expr(an, m.idx);
        },
        .private_member => |m| {
            try expr(an, m.obj);
            try privateName(an, m.name, n.pos);
        },
        .private_in => |m| {
            try privateName(an, m.name, n.pos);
            try expr(an, m.r);
        },
        .super_member => |m| {
            try checkSuper(an, n.pos);
            try resolvePseudo(an, m.this, .this);
            try resolvePseudo(an, m.home, .home);
            thisFunction(an).uses_super = true;
        },
        .super_index => |m| {
            try checkSuper(an, n.pos);
            try resolvePseudo(an, m.this, .this);
            try resolvePseudo(an, m.home, .home);
            thisFunction(an).uses_super = true;
            try expr(an, m.idx);
        },
        .super_call => |c| {
            const owner = thisFunction(an);
            if (!owner.func.is_derived) return an.fail("'{s}' keyword unexpected here", "super", n.pos);
            try exprs(an, c.args);
            try resolvePseudo(an, c.this, .this);
            try resolvePseudo(an, c.func, .func);
            try resolvePseudo(an, c.new_target, .new_target);
        },
        .spread => |s| try expr(an, s),
        .seq => |list| try exprs(an, list),
        .yield => |y| {
            if (y.arg) |a| try expr(an, a);
        },
        .await => |a| try expr(an, a),
        .opt_chain => |e| try expr(an, e),
        .import_call => |e| try expr(an, e),
        else => unreachable,
    }
}

fn checkSuper(an: *Analyzer, pos: u32) Error!void {
    const f = thisFunction(an).func;
    if (!f.is_method and !f.is_class_ctor and !f.is_class_init) {
        return an.fail("'{s}' keyword unexpected here", "super", pos);
    }
}

fn privateName(an: *Analyzer, id: *ast.Ident, pos: u32) Error!void {
    id.binding = try resolve(an, id.name, pos, true);
    if (id.binding == null) {
        return an.fail("Private field '{s}' must be declared in an enclosing class", try id.name.flat(an.vm), pos);
    }
}

pub fn class(an: *Analyzer, c: *ast.Class) Error!void {
    const saved = an.scope;
    defer an.scope = saved;
    const s = try an.newScope(.class);
    c.scope = s;
    an.scope = s;
    if (c.name) |name| {
        const v = try an.declare(s, name, .@"const");
        v.init_end = c.end;
        c.name_var = v;
    }
    // All private names exist before any member is looked at.
    for (c.members) |*m| {
        if (!m.is_private) continue;
        const name = m.key_atom.?;
        const pk: ast.PrivateKind = switch (m.kind) {
            .get => .getter,
            .set => .setter,
            .method => .method,
            else => .field,
        };
        if (s.lookupHere(name)) |ex| {
            const pair = (ex.private_kind == .getter and pk == .setter) or (ex.private_kind == .setter and pk == .getter);
            if (!pair or ex.is_static_private != m.is_static) return an.alreadyDeclared(name, c.start);
            ex.private_kind = .accessor;
            m.private_var = ex;
        } else {
            const v = try an.declare(s, name, .private);
            v.private_kind = pk;
            v.is_static_private = m.is_static;
            m.private_var = v;
        }
    }
    if (c.parent) |parent| try expr(an, parent);
    var hidden_count: u32 = 0;
    for (c.members) |*m| {
        if (m.key) |k| try expr(an, k);
        const is_private_method = m.is_private and m.kind != .field and !m.is_static;
        if ((m.kind == .field and m.computed) or is_private_method) {
            var b: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&b, "%hidden{d}", .{hidden_count}) catch unreachable;
            hidden_count += 1;
            const name = try @import("string.zig").intern(an.vm, t);
            m.hidden = try an.declare(s, name, .hidden);
        }
        if (m.kind != .field and m.kind != .static_block) try expr(an, m.value.?);
    }
    if (c.ctor) |ctor| try function(an, ctor);
    if (c.instance_init) |f| try function(an, f);
    if (c.static_init) |f| try function(an, f);
}

fn blockBody(an: *Analyzer, body: []const *Node, out_scope: *?*Scope, kind: ast.ScopeKind) Error!void {
    var needs = kind == .switch_body;
    for (body) |st0| {
        var st = st0;
        while (st.data == .labeled) st = st.data.labeled.body;
        switch (st.data) {
            .class_decl, .func_decl => needs = true,
            .var_decl => |d| if (d.kind != .@"var") {
                needs = true;
            },
            else => {},
        }
    }
    const saved = an.scope;
    defer an.scope = saved;
    if (needs) {
        const s = try an.newScope(kind);
        out_scope.* = s;
        an.scope = s;
        try an.declareLexicals(s, body, false);
        for (s.hoisted.items) |st| an.annexBTarget(s, st.data.func_decl);
    }
    for (body) |st| try stmt(an, st);
}

/// Rejects `var x` hoisting past a `let x` in an enclosing block.
fn checkVarConflict(an: *Analyzer, n: *Node) Error!void {
    switch (n.data) {
        .ident => |id| {
            var s: ?*Scope = an.scope;
            while (s) |sc| : (s = sc.parent) {
                if (isFunctionLevel(sc.kind)) return;
                if (sc.lookupHere(id.name)) |v| {
                    if (v.kind == .let or v.kind == .@"const" or v.kind == .class or v.kind == .function) {
                        return an.alreadyDeclared(id.name, n.pos);
                    }
                }
            }
        },
        .array => |items| for (items) |it| {
            if (it) |e| try checkVarConflict(an, e);
        },
        .object => |props| for (props) |prop| try checkVarConflict(an, prop.value),
        .assign => |a| try checkVarConflict(an, a.target),
        .spread => |sp| try checkVarConflict(an, sp),
        else => {},
    }
}

fn varDecl(an: *Analyzer, kind: ast.VarKind, decls: []ast.Decl) Error!void {
    for (decls) |d| {
        if (kind == .@"var") try checkVarConflict(an, d.target);
        try binding(an, d.target);
        if (d.init) |i| try expr(an, i);
    }
}

/// Declares a for-loop's let/const in a new scope and returns it; null for var or an expression.
fn loopScope(an: *Analyzer, left: *Node, out: *?*Scope) Error!void {
    if (left.data != .var_decl) return;
    const d = left.data.var_decl;
    if (d.kind == .@"var") return;
    const s = try an.newScope(.for_loop);
    out.* = s;
    an.scope = s;
    for (d.decls) |decl| {
        const end = if (decl.init) |i| i.end else decl.target.end;
        try an.declarePattern(s, decl.target, d.kind, end);
    }
}

fn stmt(an: *Analyzer, n: *Node) Error!void {
    try an.vm.checkNativeStack();
    switch (n.data) {
        .var_decl => |d| try varDecl(an, d.kind, d.decls),
        .func_decl => |f| try function(an, f),
        .class_decl => |c| {
            if (an.scope.lookupHere(c.name.?)) |v| {
                v.used = true;
                c.outer_binding = v;
            }
            try class(an, c);
        },
        .expr_stmt => |e| try expr(an, e),
        .block => |*b| try blockBody(an, b.body, &b.scope, .block),
        .if_stmt => |i| {
            try expr(an, i.t);
            try stmt(an, i.a);
            if (i.b) |b| try stmt(an, b);
        },
        .for_stmt => |*f| {
            const saved = an.scope;
            defer an.scope = saved;
            if (f.init) |i| {
                try loopScope(an, i, &f.scope);
                try stmt(an, i);
            }
            if (f.t) |t| try expr(an, t);
            if (f.update) |u| try expr(an, u);
            try stmt(an, f.body);
        },
        .for_in => |*f| {
            const saved = an.scope;
            defer an.scope = saved;
            try expr(an, f.right);
            try forTarget(an, f.left, &f.scope);
            try stmt(an, f.body);
        },
        .for_of => |*f| {
            const saved = an.scope;
            defer an.scope = saved;
            try expr(an, f.right);
            try forTarget(an, f.left, &f.scope);
            try stmt(an, f.body);
        },
        .while_stmt => |w| {
            try expr(an, w.t);
            try stmt(an, w.body);
        },
        .with_stmt => |*w| {
            try expr(an, w.obj);
            const saved = an.scope;
            defer an.scope = saved;
            const s = try an.newScope(.with_body);
            w.scope = s;
            an.scope = s;
            w.hidden = try an.declare(s, an.vm.empty, .hidden);
            try stmt(an, w.body);
        },
        .do_while => |w| {
            try stmt(an, w.body);
            try expr(an, w.t);
        },
        .return_stmt => |r| if (r) |e| try expr(an, e),
        .throw_stmt => |e| try expr(an, e),
        .try_stmt => |*t| {
            an.fi.has_try = true;
            try stmt(an, t.block);
            if (t.handler) |h| {
                const saved = an.scope;
                defer an.scope = saved;
                if (t.param) |param| {
                    const s = try an.newScope(.catch_clause);
                    t.catch_scope = s;
                    an.scope = s;
                    try an.declarePattern(s, param, .catch_param, 0);
                    try binding(an, param);
                }
                try stmt(an, h);
            }
            if (t.finalizer) |f| try stmt(an, f);
        },
        .switch_stmt => |*sw| {
            try expr(an, sw.disc);
            const saved = an.scope;
            defer an.scope = saved;
            const s = try an.newScope(.switch_body);
            sw.scope = s;
            an.scope = s;
            for (sw.cases) |c| try an.declareLexicals(s, c.body, false);
            for (s.hoisted.items) |st| an.annexBTarget(s, st.data.func_decl);
            for (sw.cases) |c| {
                if (c.t) |t| try expr(an, t);
                for (c.body) |st| try stmt(an, st);
            }
        },
        .labeled => |l| try stmt(an, l.body),
        .export_default => |d| {
            d.binding.binding = try resolve(an, d.binding.name, n.pos, true);
            try expr(an, d.value);
        },
        .break_stmt, .continue_stmt, .empty, .debugger => {},
        else => try expr(an, n),
    }
}

fn forTarget(an: *Analyzer, left: *Node, out: *?*Scope) Error!void {
    if (left.data == .var_decl) {
        try loopScope(an, left, out);
        const d = left.data.var_decl;
        try varDecl(an, d.kind, d.decls);
    } else {
        try expr(an, left);
    }
}
