//! Compiles assignments, update expressions and destructuring patterns.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const compiler = @import("compiler.zig");
const C = compiler.C;
const cexpr = @import("compiler_expr.zig");
const expr = cexpr.expr;
const Value = @import("value.zig").Value;

/// How a pattern's leaf stores: an assignment, a var-style initialization, or a
/// let/const initialization (which at script level goes to the global lexical record).
pub const BindMode = enum { assign, init, init_lex };

fn putIdent(c: *C, id: *ast.Ident, mode: BindMode) Error!void {
    if (mode == .assign and id.with_chain.len != 0) return assignIdentKeep(c, id, false);
    if (id.binding) |v| {
        if (mode == .assign) return c.assignVar(v);
        return c.initVar(v);
    }
    if (mode == .init_lex) {
        try c.opU32(.init_global_lex, try c.icAtom(id.name));
    } else {
        try c.opU32(.put_global, try c.icAtom(id.name));
        try c.op(.pop);
    }
}

/// Consumes the value on the stack, storing it through the pattern.
pub fn bindPattern(c: *C, n: *Node, mode: BindMode) Error!void {
    switch (n.data) {
        .ident => |id| try putIdent(c, id, mode),
        .member => |m| {
            try expr(c, m.obj);
            try c.op(.swap);
            try c.mark(n.pos);
            try c.opU32(.put_field, try c.icAtom(m.name));
            try c.op(.pop);
        },
        .index => |m| {
            try expr(c, m.obj);
            try expr(c, m.idx);
            try c.op(.rot3l);
            try c.mark(n.pos);
            try c.op(.put_elem);
            try c.op(.pop);
        },
        .private_member => |m| {
            try expr(c, m.obj);
            try c.getVar(m.name.binding.?);
            try c.op(.rot3l);
            try c.mark(n.pos);
            try c.op(.put_private);
            try c.op(.pop);
        },
        .super_member => |m| {
            try superRef(c, m.this, m.home);
            try c.pushStr(m.name);
            try superPutShuffle(c);
            try c.op(.pop);
        },
        .super_index => |m| {
            try superRef(c, m.this, m.home);
            try expr(c, m.idx);
            try c.op(.to_propkey);
            try superPutShuffle(c);
            try c.op(.pop);
        },
        .assign => |a| {
            try defaultValue(c, a.value, a.target);
            try bindPattern(c, a.target, mode);
        },
        .array => |items| try arrayPattern(c, items, mode),
        .object => |ps| try objectPattern(c, n, ps, mode),
        else => return c.vm.throwError(.SyntaxError, "Invalid destructuring target"),
    }
}

/// [val this home key] -> [val]... super_put wants [this home key val].
fn superPutShuffle(c: *C) Error!void {
    // Stack is value this home key; bring value to the top by a temporary local.
    const t = c.tempLocal();
    const t2 = c.tempLocal();
    const t3 = c.tempLocal();
    try c.opU16(.put_loc, t3);
    try c.opU16(.put_loc, t2);
    try c.op(.swap);
    try c.opU16(.put_loc, t);
    try c.opU16(.get_loc, t);
    try c.op(.swap);
    try c.opU16(.get_loc, t2);
    try c.op(.swap);
    try c.opU16(.get_loc, t3);
    try c.op(.swap);
    try c.op(.super_put);
}

fn superRef(c: *C, this: *ast.Ident, home: *ast.Ident) Error!void {
    try cexpr.pseudo(c, this, .this);
    try cexpr.pseudo(c, home, .home);
}

/// Top of stack is a value: replaces undefined with the default.
fn defaultValue(c: *C, value: *Node, target: *Node) Error!void {
    const at = try c.jump(.jump_not_undef);
    if (target.data == .ident) {
        try cexpr.exprNamed(c, value, target.data.ident.name);
    } else {
        try expr(c, value);
    }
    c.patch(at);
}

fn arrayPattern(c: *C, items: []const ?*Node, mode: BindMode) Error!void {
    try c.op(.iter_init);
    try c.control.append(c.a, .{ .kind = .iter_guard });
    for (items) |item| {
        const it = item orelse {
            try c.op(.iter_step);
            try c.op(.pop);
            continue;
        };
        if (it.data == .spread) {
            try c.op(.iter_rest);
            try bindPattern(c, it.data.spread, mode);
        } else {
            try c.op(.iter_step);
            try bindPattern(c, it, mode);
        }
    }
    _ = c.control.pop();
    try c.op(.iter_close);
}

fn objectPattern(c: *C, n: *Node, ps: []const ast.Prop, mode: BindMode) Error!void {
    try c.mark(n.pos);
    try c.op(.check_coercible);
    // Computed keys are remembered in temporaries when a rest element must exclude them.
    const has_rest = ps.len != 0 and ps[ps.len - 1].kind == .spread;
    var computed_slots: std.ArrayList(u32) = .empty;
    for (ps) |p| {
        if (p.kind == .spread) {
            try c.op(.dup);
            var count: u32 = 0;
            var ci: usize = 0;
            for (ps) |q| {
                if (q.kind == .spread) continue;
                if (q.computed) {
                    try c.opU16(.get_loc, computed_slots.items[ci]);
                    ci += 1;
                } else {
                    try c.pushStr(q.key_atom.?);
                }
                count += 1;
            }
            try c.opU16(.object_rest, count);
            c.adj(-@as(i32, @intCast(count)));
            try bindPattern(c, p.value, mode);
            continue;
        }
        try c.op(.dup);
        if (p.computed) {
            try expr(c, p.key.?);
            try c.op(.to_propkey);
            if (has_rest) {
                const t = c.tempLocal();
                try computed_slots.append(c.a, t);
                try c.opU16(.set_loc, t);
            }
            try c.op(.get_elem);
        } else {
            try c.mark(n.pos);
            try c.opU32(.get_field, try c.icAtom(p.key_atom.?));
        }
        try bindPattern(c, p.value, mode);
    }
    try c.op(.pop);
}

/// Stores the top of stack into a simple reference, keeping the value there.
fn assignIdentKeep(c: *C, id: *ast.Ident, keep: bool) Error!void {
    if (id.with_chain.len != 0) {
        var found: std.ArrayList(u32) = .empty;
        try cexpr.withLookup(c, id, .with_put, &found);
        const saved = id.with_chain;
        id.with_chain = &.{};
        try assignIdentKeep(c, id, keep);
        id.with_chain = saved;
        const d = c.depth;
        const end = try c.jump(.jump);
        c.patchAll(found.items);
        c.depth = if (keep) d else d + 1;
        if (!keep) try c.op(.pop);
        c.patch(end);
        return;
    }
    if (id.binding) |v| {
        if (keep) try c.op(.dup);
        try c.assignVar(v);
    } else {
        try c.opU32(.put_global, try c.icAtom(id.name));
        if (!keep) try c.op(.pop);
    }
}

pub fn assign(c: *C, n: *Node, keep: bool) Error!void {
    const a = n.data.assign;
    if (a.log) |log| return logicalAssign(c, n, log, a.target, a.value, keep);
    switch (a.target.data) {
        .ident => |id| {
            if (a.op) |op| {
                try expr(c, a.target);
                try expr(c, a.value);
                try c.mark(n.pos);
                try c.op(cexpr.binOpcode(op));
            } else {
                try cexpr.exprNamed(c, a.value, id.name);
            }
            try assignIdentKeep(c, id, keep);
            return;
        },
        .member => |m| {
            try expr(c, m.obj);
            if (a.op) |op| {
                try c.op(.dup);
                try c.mark(a.target.pos);
                try c.opU32(.get_field, try c.icAtom(m.name));
                try expr(c, a.value);
                try c.mark(n.pos);
                try c.op(cexpr.binOpcode(op));
            } else {
                try expr(c, a.value);
            }
            try c.mark(a.target.pos);
            try c.opU32(.put_field, try c.icAtom(m.name));
        },
        .index => |m| {
            try expr(c, m.obj);
            try expr(c, m.idx);
            if (a.op) |op| {
                try c.op(.to_propkey);
                try c.op(.dup2);
                try c.mark(a.target.pos);
                try c.op(.get_elem);
                try expr(c, a.value);
                try c.mark(n.pos);
                try c.op(cexpr.binOpcode(op));
            } else {
                try expr(c, a.value);
            }
            try c.mark(a.target.pos);
            try c.op(.put_elem);
        },
        .private_member => |m| {
            try expr(c, m.obj);
            try c.getVar(m.name.binding.?);
            if (a.op) |op| {
                try c.op(.dup2);
                try c.mark(a.target.pos);
                try c.op(.get_private);
                try expr(c, a.value);
                try c.op(cexpr.binOpcode(op));
            } else {
                try expr(c, a.value);
            }
            try c.mark(a.target.pos);
            try c.op(.put_private);
        },
        .super_member, .super_index => {
            try superTarget(c, a.target);
            if (a.op) |op| {
                try superReadKeep(c);
                try expr(c, a.value);
                try c.op(cexpr.binOpcode(op));
            } else {
                try expr(c, a.value);
            }
            try c.mark(a.target.pos);
            try c.op(.super_put);
        },
        .array, .object => {
            try expr(c, a.value);
            if (keep) try c.op(.dup);
            try bindPattern(c, a.target, .assign);
            return;
        },
        else => return c.vm.throwError(.SyntaxError, "Invalid left-hand side in assignment"),
    }
    if (!keep) try c.op(.pop);
}

/// Pushes [this home key] for a super member target.
fn superTarget(c: *C, t: *Node) Error!void {
    switch (t.data) {
        .super_member => |m| {
            try superRef(c, m.this, m.home);
            try c.pushStr(m.name);
        },
        .super_index => |m| {
            try superRef(c, m.this, m.home);
            try expr(c, m.idx);
            try c.op(.to_propkey);
        },
        else => unreachable,
    }
}

/// [this home key] -> [this home key value], reading through super.
fn superReadKeep(c: *C) Error!void {
    const t = c.tempLocal();
    const h = c.tempLocal();
    const k = c.tempLocal();
    try c.opU16(.put_loc, k);
    try c.opU16(.put_loc, h);
    try c.opU16(.put_loc, t);
    for ([_]u32{ t, h, k, t, h, k }) |s| try c.opU16(.get_loc, s);
    try c.op(.super_get);
}

fn logicalAssign(c: *C, n: *Node, log: ast.LogOp, target: *Node, value: *Node, keep: bool) Error!void {
    const test_op: @import("bytecode.zig").Op = switch (log) {
        .land => .jump_false_keep,
        .lor => .jump_true_keep,
        .nullish => .jump_notnull_keep,
    };
    switch (target.data) {
        .ident => |id| {
            try expr(c, target);
            const at = try c.jump(test_op);
            try cexpr.exprNamed(c, value, id.name);
            try assignIdentKeep(c, id, true);
            c.patch(at);
        },
        .member => |m| {
            try expr(c, m.obj);
            try c.op(.dup);
            try c.mark(target.pos);
            try c.opU32(.get_field, try c.icAtom(m.name));
            const short = try c.jump(test_op);
            const d = c.depth;
            try expr(c, value);
            try c.mark(n.pos);
            try c.opU32(.put_field, try c.icAtom(m.name));
            const end = try c.jump(.jump);
            c.patch(short);
            c.depth = d + 1;
            try c.op(.nip);
            c.patch(end);
        },
        .index => |m| {
            try expr(c, m.obj);
            try expr(c, m.idx);
            try c.op(.to_propkey);
            try c.op(.dup2);
            try c.mark(target.pos);
            try c.op(.get_elem);
            const short = try c.jump(test_op);
            const d = c.depth;
            try expr(c, value);
            try c.mark(n.pos);
            try c.op(.put_elem);
            const end = try c.jump(.jump);
            c.patch(short);
            c.depth = d + 1;
            try c.op(.nip);
            try c.op(.nip);
            c.patch(end);
        },
        .private_member => |m| {
            try expr(c, m.obj);
            try c.getVar(m.name.binding.?);
            try c.op(.dup2);
            try c.op(.get_private);
            const short = try c.jump(test_op);
            const d = c.depth;
            try expr(c, value);
            try c.op(.put_private);
            const end = try c.jump(.jump);
            c.patch(short);
            c.depth = d + 1;
            try c.op(.nip);
            try c.op(.nip);
            c.patch(end);
        },
        else => return c.vm.throwError(.SyntaxError, "Invalid left-hand side in assignment"),
    }
    if (!keep) try c.op(.pop);
}

pub fn update(c: *C, is_inc: bool, prefix: bool, arg: *Node) Error!void {
    const step: @import("bytecode.zig").Op = if (is_inc) .inc else .dec;
    switch (arg.data) {
        .ident => |id| {
            try expr(c, arg);
            if (prefix) {
                try c.op(step);
                try assignIdentKeep(c, id, true);
            } else {
                try c.op(.to_numeric);
                try c.op(.dup);
                try c.op(step);
                try assignIdentKeep(c, id, false);
            }
        },
        .member => |m| {
            try expr(c, m.obj);
            try c.op(.dup);
            try c.mark(arg.pos);
            try c.opU32(.get_field, try c.icAtom(m.name));
            if (prefix) {
                try c.op(step);
                try c.opU32(.put_field, try c.icAtom(m.name));
            } else {
                try c.op(.to_numeric);
                try c.op(.insert2);
                try c.op(step);
                try c.opU32(.put_field, try c.icAtom(m.name));
                try c.op(.pop);
            }
        },
        .index => |m| {
            try expr(c, m.obj);
            try expr(c, m.idx);
            try c.op(.to_propkey);
            try c.op(.dup2);
            try c.mark(arg.pos);
            try c.op(.get_elem);
            if (prefix) {
                try c.op(step);
                try c.op(.put_elem);
            } else {
                try c.op(.to_numeric);
                try c.op(.insert3);
                try c.op(step);
                try c.op(.put_elem);
                try c.op(.pop);
            }
        },
        .private_member => |m| {
            try expr(c, m.obj);
            try c.getVar(m.name.binding.?);
            try c.op(.dup2);
            try c.mark(arg.pos);
            try c.op(.get_private);
            if (prefix) {
                try c.op(step);
                try c.op(.put_private);
            } else {
                try c.op(.to_numeric);
                try c.op(.insert3);
                try c.op(step);
                try c.op(.put_private);
                try c.op(.pop);
            }
        },
        .super_member, .super_index => {
            try superTarget(c, arg);
            try superReadKeep(c);
            if (!prefix) try c.op(.to_numeric);
            try c.op(step);
            try c.op(.super_put);
        },
        else => return c.vm.throwError(.SyntaxError, "Invalid left-hand side expression in postfix operation"),
    }
}
