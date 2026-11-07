//! Compiles statements: declarations, control flow with its unwinding of environments,
//! iterators and finally blocks, and completion values for scripts.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const compiler = @import("compiler.zig");
const C = compiler.C;
const Control = compiler.Control;
const cexpr = @import("compiler_expr.zig");
const expr = cexpr.expr;
const exprVoid = cexpr.exprVoid;
const cassign = @import("compiler_assign.zig");
const cclass = @import("compiler_class.zig");
const JSString = @import("string.zig").JSString;

pub fn statements(c: *C, list: []const *Node) Error!void {
    for (list) |st| try statement(c, st);
}

fn takeLabels(c: *C) []const *JSString {
    const l = c.labels.items;
    c.labels = .empty;
    return l;
}

pub fn statement(c: *C, n: *Node) Error!void {
    try c.vm.checkNativeStack();
    switch (n.data) {
        .expr_stmt => |e| {
            if (c.completion) |slot| {
                try expr(c, e);
                try c.opU16(.put_loc, slot);
            } else {
                try exprVoid(c, e);
            }
        },
        .var_decl => |d| try varDecl(c, d.kind, d.decls),
        .func_decl => |f| {
            // Hoisted at scope entry; here only the Annex B copy to the function-level var.
            if (f.decl_binding) |v| {
                if (f.annex_b_var) |target| {
                    if (target != v) {
                        try c.getVar(v);
                        try c.initVar(target);
                    }
                } else if (f.annex_b_global) {
                    try c.getVar(v);
                    try c.opU32(.put_global, try c.icAtom(f.name.?));
                    try c.op(.pop);
                }
            }
        },
        .class_decl => |cl| {
            try cclass.class(c, cl, null);
            if (cl.outer_binding) |v| {
                try c.initVar(v);
            } else {
                try c.opU32(.init_global_lex, try c.icAtom(cl.name.?));
            }
        },
        .block => |b| {
            const label_entry = c.labels.items.len != 0;
            if (label_entry) try pushLabel(c);
            if (b.scope) |s| {
                const saved = c.scope;
                try c.enterScope(s);
                try statements(c, b.body);
                try c.exitScope(s);
                c.scope = saved;
            } else {
                try statements(c, b.body);
            }
            if (label_entry) popLabel(c);
        },
        .if_stmt => |i| {
            const label_entry = c.labels.items.len != 0;
            if (label_entry) try pushLabel(c);
            try expr(c, i.t);
            const else_at = try c.jump(.jump_false);
            try statement(c, i.a);
            if (i.b) |b| {
                const end = try c.jump(.jump);
                c.patch(else_at);
                try statement(c, b);
                c.patch(end);
            } else c.patch(else_at);
            if (label_entry) popLabel(c);
        },
        .for_stmt => |f| try forStatement(c, f.init, f.t, f.update, f.body, f.scope),
        .for_in => |f| try forIn(c, f.left, f.right, f.body, f.scope),
        .for_of => |f| try forOf(c, f.left, f.right, f.body, f.scope, f.is_await),
        .with_stmt => |w| {
            const label_entry = c.labels.items.len != 0;
            if (label_entry) try pushLabel(c);
            try expr(c, w.obj);
            try c.op(.to_object);
            const saved = c.scope;
            try c.enterScope(w.scope.?);
            try c.initVar(w.hidden.?);
            try statement(c, w.body);
            try c.exitScope(w.scope.?);
            c.scope = saved;
            if (label_entry) popLabel(c);
        },
        .while_stmt => |w| {
            try beginLoop(c);
            const top = c.pc();
            try expr(c, w.t);
            const end = try c.jump(.jump_false);
            try statement(c, w.body);
            patchContinues(c);
            try c.loopTo(top);
            c.patch(end);
            endLoop(c);
        },
        .do_while => |w| {
            try beginLoop(c);
            const top = c.pc();
            try statement(c, w.body);
            patchContinues(c);
            try expr(c, w.t);
            const end = try c.jump(.jump_false);
            try c.loopTo(top);
            c.patch(end);
            endLoop(c);
        },
        .return_stmt => |r| {
            if (r) |e| try expr(c, e) else try c.op(.undef);
            if (c.func.is_async and c.func.is_generator) {
                try c.op(.await_);
                try c.op(.resume_throw);
            }
            try emitReturn(c);
        },
        .break_stmt => |label| try breakContinue(c, n, label, true),
        .continue_stmt => |label| try breakContinue(c, n, label, false),
        .throw_stmt => |e| {
            try expr(c, e);
            try c.mark(n.pos);
            try c.op(.throw_);
        },
        .try_stmt => try tryStatement(c, n),
        .switch_stmt => try switchStatement(c, n),
        .labeled => |l| {
            for (c.labels.items) |ex| {
                if (ex == l.label) return c.vm.throwError(.SyntaxError, "Label has already been declared");
            }
            try c.labels.append(c.a, l.label);
            switch (l.body.data) {
                .for_stmt, .for_in, .for_of, .while_stmt, .do_while, .block, .if_stmt, .switch_stmt, .with_stmt, .labeled => try statement(c, l.body),
                else => {
                    try pushLabel(c);
                    try statement(c, l.body);
                    popLabel(c);
                },
            }
            c.labels = .empty;
        },
        .export_default => |d| {
            try cexpr.exprNamed(c, d.value, c.vm.k.default.atom());
            try c.initVar(d.binding.binding.?);
        },
        .empty, .debugger => {},
        else => return c.vm.throwError(.SyntaxError, "Internal: expression in statement position"),
    }
}

fn pushLabel(c: *C) Error!void {
    try c.control.append(c.a, .{ .kind = .label, .labels = takeLabels(c) });
}

fn popLabel(c: *C) void {
    var e = c.control.pop().?;
    c.patchAll(e.breaks.items);
    e.breaks = .empty;
}

fn varDecl(c: *C, kind: ast.VarKind, decls: []const ast.Decl) Error!void {
    const mode: cassign.BindMode = if (kind == .@"var") .init else .init_lex;
    for (decls) |d| {
        if (d.init) |i| {
            if (d.target.data == .ident) {
                try cexpr.exprNamed(c, i, d.target.data.ident.name);
            } else {
                try expr(c, i);
            }
            try cassign.bindPattern(c, d.target, if (kind == .@"var" and d.target.data == .ident) .init else mode);
        } else if (kind != .@"var") {
            try c.op(.undef);
            try cassign.bindPattern(c, d.target, mode);
        }
    }
}

fn beginLoop(c: *C) Error!void {
    try c.control.append(c.a, .{ .kind = .loop, .labels = takeLabels(c) });
}

fn patchContinues(c: *C) void {
    const e = &c.control.items[c.control.items.len - 1];
    c.patchAll(e.continues.items);
}

fn endLoop(c: *C) void {
    const e = c.control.pop().?;
    c.patchAll(e.breaks.items);
}

fn forStatement(c: *C, init: ?*Node, t: ?*Node, update: ?*Node, body: *Node, scope: ?*ast.Scope) Error!void {
    const labels = takeLabels(c);
    const saved = c.scope;
    if (scope) |s| try c.enterScope(s);
    if (init) |i| {
        switch (i.data) {
            .var_decl => |d| try varDecl(c, d.kind, d.decls),
            else => try exprVoid(c, i),
        }
    }
    try c.control.append(c.a, .{ .kind = .loop, .labels = labels });
    const top = c.pc();
    var end_at: ?u32 = null;
    if (t) |x| {
        try expr(c, x);
        end_at = try c.jump(.jump_false);
    }
    try statement(c, body);
    patchContinues(c);
    if (scope) |s| {
        if (s.env_size > 0) try c.op(.clone_env);
    }
    if (update) |u| try exprVoid(c, u);
    try c.loopTo(top);
    if (end_at) |e| c.patch(e);
    endLoop(c);
    if (scope) |s| try c.exitScope(s);
    c.scope = saved;
}

/// Consumes the value on the stack: the loop variable's assignment each iteration.
fn bindLoopVar(c: *C, left: *Node) Error!void {
    if (left.data == .var_decl) {
        const d = left.data.var_decl;
        try cassign.bindPattern(c, d.decls[0].target, if (d.kind == .@"var") .init else .init_lex);
    } else {
        try cassign.bindPattern(c, left, .assign);
    }
}

fn forIn(c: *C, left: *Node, right: *Node, body: *Node, scope: ?*ast.Scope) Error!void {
    const labels = takeLabels(c);
    const saved = c.scope;
    const keys = c.tempLocal();
    const idx = c.tempLocal();
    // Annex B: `for (var x = 1 in o)` runs the initializer first.
    if (left.data == .var_decl) {
        if (left.data.var_decl.decls[0].init) |i| {
            try expr(c, i);
            try cassign.bindPattern(c, left.data.var_decl.decls[0].target, .init);
        }
    }
    try expr(c, right);
    try c.mark(right.pos);
    try c.op(.for_in_start);
    try c.opU16(.put_loc, keys);
    try c.op(.int8);
    try c.byte(0);
    try c.opU16(.put_loc, idx);
    try c.control.append(c.a, .{ .kind = .loop, .labels = labels });
    const top = c.pc();
    try c.opU16(.for_in_next, keys);
    try c.u16le(idx);
    const done = c.pc();
    try c.u32le(0);
    if (scope) |s| try c.enterScope(s);
    try bindLoopVar(c, left);
    try statement(c, body);
    if (scope) |s| {
        try c.exitScope(s);
        c.scope = saved;
    }
    patchContinues(c);
    try c.loopTo(top);
    c.patch(done);
    endLoop(c);
}

fn forOf(c: *C, left: *Node, right: *Node, body: *Node, scope: ?*ast.Scope, is_await: bool) Error!void {
    const labels = takeLabels(c);
    const saved = c.scope;
    try expr(c, right);
    try c.mark(right.pos);
    try c.op(if (is_await) .async_iter_init else .iter_init);
    try c.control.append(c.a, .{ .kind = if (is_await) .for_await else .for_of, .labels = labels });
    const top = c.pc();
    var done: u32 = 0;
    if (is_await) {
        try c.mark(right.pos);
        try c.op(.async_iter_call);
        try c.op(.await_);
        try c.op(.resume_throw);
        done = try c.jump(.iter_result);
    } else {
        try c.mark(right.pos);
        done = try c.jump(.iter_next);
    }
    const body_depth = c.depth;
    if (scope) |s| try c.enterScope(s);
    try bindLoopVar(c, left);
    try statement(c, body);
    if (scope) |s| {
        try c.exitScope(s);
        c.scope = saved;
    }
    patchContinues(c);
    try c.loopTo(top);
    c.patch(done);
    c.depth = body_depth - 1;
    try c.op(.iter_drop);
    const e = c.control.pop().?;
    c.patchAll(e.breaks.items);
}

/// Emits what leaving a control entry takes, on a path that jumps past it.
fn exitEntry(c: *C, e: *Control) Error!void {
    switch (e.kind) {
        .env => {
            try c.op(.pop_env);
            c.depth += 0;
        },
        .label, .loop => {},
        .for_of, .iter_guard => {
            const d = c.depth;
            try c.op(.iter_close);
            c.depth = d;
        },
        .for_await => {
            const d = c.depth;
            try c.op(.async_iter_close);
            try c.op(.await_);
            try c.op(.resume_throw);
            try c.op(.pop);
            c.depth = d;
        },
        .catch_guard => {
            const d = c.depth;
            try c.op(.pop_try);
            c.depth = d;
        },
        .finally_guard => {
            const d = c.depth;
            try c.op(.pop_try);
            try c.op(.undef);
            try c.op(.gosub);
            try e.gosubs.?.append(c.a, c.pc());
            try c.u32le(0);
            c.adj(2);
            try c.op(.pop);
            c.depth = d;
        },
        .finally_body => {
            const d = c.depth;
            try c.op(.pop);
            try c.op(.pop);
            c.depth = d;
        },
    }
}

fn breakContinue(c: *C, n: *Node, label: ?*JSString, is_break: bool) Error!void {
    const items = c.control.items;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const e = &items[i];
        const is_loop = e.kind == .loop or e.kind == .for_of or e.kind == .for_await;
        var hit = false;
        if (label) |l| {
            for (e.labels) |x| {
                if (x == l) hit = true;
            }
            if (hit and !is_break and !is_loop) return fail(c, n, "Illegal continue statement: not a loop label");
        } else {
            hit = is_loop or (is_break and e.switch_target);
        }
        if (hit) {
            if (is_break) try exitEntry(c, e);
            const at = try c.jump(.jump);
            const list = if (is_break) &e.breaks else &e.continues;
            try list.append(c.a, at);
            return;
        }
        try exitEntry(c, e);
    }
    return fail(c, n, if (is_break) (if (label != null) "Undefined label" else "Illegal break statement") else "Illegal continue statement");
}

fn fail(c: *C, n: *Node, msg: []const u8) Error {
    const lc = try c.source.lineCol(c.vm.gpa, n.pos);
    var b: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "{s} ({d}:{d})", .{ msg, lc.line, lc.col }) catch msg;
    return c.vm.throwError(.SyntaxError, m);
}

/// Returns the value on top of the stack, unwinding whatever needs unwinding first.
pub fn emitReturn(c: *C) Error!void {
    const f = c.func;
    var needs_unwind = false;
    for (c.control.items) |e| {
        if (e.kind != .env and e.kind != .label and e.kind != .loop) needs_unwind = true;
    }
    const d = c.depth;
    if (needs_unwind) {
        const slot = c.tempLocal();
        try c.opU16(.put_loc, slot);
        var i = c.control.items.len;
        while (i > 0) {
            i -= 1;
            try exitEntry(c, &c.control.items[i]);
        }
        try c.opU16(.get_loc, slot);
    }
    if (f.is_derived) {
        const obj = try c.jump(.ctor_ret_check);
        try c.getVar(c.fi.this_var.?);
        c.patch(obj);
    }
    try c.op(.ret);
    c.depth = d - 1;
}

fn tryStatement(c: *C, n: *Node) Error!void {
    const t = n.data.try_stmt;
    const base = c.depth;
    var gosubs: std.ArrayList(u32) = .empty;
    var finally_exc: u32 = 0;
    if (t.finalizer != null) {
        finally_exc = try c.jump(.push_try);
        try c.control.append(c.a, .{ .kind = .finally_guard, .gosubs = &gosubs });
    }
    if (t.handler) |h| {
        const catch_at = try c.jump(.push_try);
        try c.control.append(c.a, .{ .kind = .catch_guard });
        try statement(c, t.block);
        _ = c.control.pop();
        try c.op(.pop_try);
        const after = try c.jump(.jump);
        c.patch(catch_at);
        c.depth = base + (if (t.finalizer != null) @as(i32, 2) else 0) + 1;
        // The exception is on the stack.
        const saved = c.scope;
        if (t.catch_scope) |s| {
            try c.enterScope(s);
            try cassign.bindPattern(c, t.param.?, .init);
        } else {
            try c.op(.pop);
        }
        try statement(c, h);
        if (t.catch_scope) |s| {
            try c.exitScope(s);
            c.scope = saved;
        }
        c.patch(after);
    } else {
        try statement(c, t.block);
    }
    if (t.finalizer) |fin| {
        _ = c.control.pop();
        try c.op(.pop_try);
        try c.op(.undef);
        try c.op(.gosub);
        try gosubs.append(c.a, c.pc());
        try c.u32le(0);
        c.adj(1);
        try c.op(.pop);
        const end = try c.jump(.jump);
        // An exception: run finally, then rethrow.
        c.patch(finally_exc);
        c.depth = base + 1;
        try c.op(.gosub);
        try gosubs.append(c.a, c.pc());
        try c.u32le(0);
        try c.op(.throw_);
        // The finally subroutine: [value return-address] on the stack.
        c.patchAll(gosubs.items);
        c.depth = base + 2;
        if (c.depth > c.max_depth) c.max_depth = c.depth;
        try c.control.append(c.a, .{ .kind = .finally_body });
        const saved_completion = c.completion;
        c.completion = null;
        try statement(c, fin);
        c.completion = saved_completion;
        _ = c.control.pop();
        try c.op(.ret_sub);
        c.patch(end);
        c.depth = base;
    }
}

fn switchStatement(c: *C, n: *Node) Error!void {
    const sw = n.data.switch_stmt;
    const labels = takeLabels(c);
    const tmp = c.tempLocal();
    try expr(c, sw.disc);
    try c.opU16(.put_loc, tmp);
    const saved = c.scope;
    if (sw.scope) |s| try c.enterScope(s);
    try c.control.append(c.a, .{ .kind = .label, .labels = labels, .switch_target = true });
    const jumps = try c.a.alloc(u32, sw.cases.len);
    var default_index: ?usize = null;
    for (sw.cases, 0..) |cs, i| {
        if (cs.t) |x| {
            try c.opU16(.get_loc, tmp);
            try expr(c, x);
            try c.op(.seq);
            jumps[i] = try c.jump(.jump_true);
        } else default_index = i;
    }
    const to_default = try c.jump(.jump);
    for (sw.cases, 0..) |cs, i| {
        if (cs.t != null) {
            c.patch(jumps[i]);
        } else {
            c.patch(to_default);
        }
        try statements(c, cs.body);
    }
    if (default_index == null) c.patch(to_default);
    const e = c.control.pop().?;
    c.patchAll(e.breaks.items);
    if (sw.scope) |s| try c.exitScope(s);
    c.scope = saved;
}
