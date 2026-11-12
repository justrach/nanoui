//! Compiles calls, `new`, `super(...)` and `yield`, the expression forms with the most
//! stack choreography.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const compiler = @import("compiler.zig");
const C = compiler.C;
const cexpr = @import("compiler_expr.zig");
const expr = cexpr.expr;
const pseudo = cexpr.pseudo;
const optCheck = cexpr.optCheck;
const cstmt = @import("compiler_stmt.zig");

/// Pushes [this, function] for a call to this callee.
pub fn calleeWithThis(c: *C, callee: *Node) Error!void {
    switch (callee.data) {
        .member => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try c.mark(callee.pos);
            try c.opU32(.get_field2, try c.icAtom(m.name));
        },
        .index => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try expr(c, m.idx);
            try c.mark(callee.pos);
            try c.op(.get_elem2);
        },
        .private_member => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try c.op(.dup);
            try c.getVar(m.name.binding.?);
            try c.mark(callee.pos);
            try c.op(.get_private);
        },
        .super_member => |m| {
            try pseudo(c, m.this, .this);
            try c.op(.dup);
            try pseudo(c, m.home, .home);
            try c.pushStr(m.name);
            try c.mark(callee.pos);
            try c.op(.super_get);
        },
        .super_index => |m| {
            try pseudo(c, m.this, .this);
            try c.op(.dup);
            try pseudo(c, m.home, .home);
            try expr(c, m.idx);
            try c.op(.to_propkey);
            try c.mark(callee.pos);
            try c.op(.super_get);
        },
        .ident => |id| {
            // In a `with`, a function found on the object gets that object as `this`.
            var found: std.ArrayList(u32) = .empty;
            try cexpr.withLookup(c, id, .with_get_call, &found);
            try c.op(.undef);
            const saved = id.with_chain;
            id.with_chain = &.{};
            try expr(c, callee);
            id.with_chain = saved;
            c.patchAll(found.items);
        },
        else => {
            try c.op(.undef);
            try expr(c, callee);
        },
    }
}

/// Pushes one array holding the arguments, for spread calls.
fn argsArray(c: *C, args: []const *Node) Error!void {
    try c.opU32(.array_from, 0);
    c.adj(1);
    for (args) |a| {
        if (a.data == .spread) {
            try expr(c, a.data.spread);
            try c.op(.array_spread);
        } else {
            try expr(c, a);
            try c.op(.array_append);
        }
    }
}

pub fn call(c: *C, n: *Node) Error!void {
    const x = n.data.call;
    if (!x.optional and !x.has_spread and x.args.len == 2 and x.callee.data == .member and !x.callee.data.member.optional) {
        if (c.lazyArgsIdent(x.args[1])) |v| {
            const m = x.callee.data.member;
            if (m.name.is_ascii and !m.name.is_rope and std.mem.eql(u8, m.name.ptr[0..m.name.byte_len], "apply")) {
                try calleeWithThis(c, x.callee);
                try expr(c, x.args[0]);
                try c.mark(n.pos);
                try c.opU16(.args_apply, v.index);
                return;
            }
        }
    }
    try calleeWithThis(c, x.callee);
    if (x.optional) try optCheck(c, 1);
    if (x.has_spread) {
        try argsArray(c, x.args);
        try c.mark(n.pos);
        try c.op(.apply);
        return;
    }
    for (x.args) |a| try expr(c, a);
    try c.mark(n.pos);
    const argc: u32 = @intCast(x.args.len);
    try c.opU16(.call, argc);
    c.adj(-@as(i32, @intCast(argc + 1)));
}

pub fn newExpr(c: *C, n: *Node, callee: *Node, args: []const *Node, has_spread: bool) Error!void {
    try c.op(.undef);
    try expr(c, callee);
    if (has_spread) {
        try argsArray(c, args);
        try c.mark(n.pos);
        try c.op(.apply_new);
        return;
    }
    for (args) |a| try expr(c, a);
    try c.mark(n.pos);
    const argc: u32 = @intCast(args.len);
    try c.opU16(.new_, argc);
    c.adj(-@as(i32, @intCast(argc + 1)));
}

pub fn superCall(c: *C, n: *Node, args: []const *Node, has_spread: bool, this: *ast.Ident, func: *ast.Ident, nt: *ast.Ident) Error!void {
    try pseudo(c, nt, .new_target);
    try pseudo(c, func, .callee);
    try c.op(.get_super_ctor);
    if (has_spread) {
        try argsArray(c, args);
        try c.mark(n.pos);
        try c.op(.super_apply);
    } else {
        for (args) |a| try expr(c, a);
        try c.mark(n.pos);
        const argc: u32 = @intCast(args.len);
        try c.opU16(.super_call, argc);
        c.adj(-@as(i32, @intCast(argc + 1)));
    }
    // A second super() must throw even though the first's value is already there.
    const v = this.binding.?;
    if (v.captured) {
        const saved = v.needs_tdz;
        v.needs_tdz = false;
        try c.getVar(v);
        v.needs_tdz = saved;
    } else {
        try c.opU16(.get_loc, v.index);
    }
    try c.op(.check_super_once);
    try c.op(.dup);
    try c.initVar(v);
    try c.op(.dup);
    try pseudo(c, func, .callee);
    try c.op(.run_fields);
}

pub fn yieldExpr(c: *C, arg: ?*Node, delegate: bool) Error!void {
    const is_async = c.func.is_async;
    if (delegate) return yieldStar(c, arg.?, is_async);
    if (arg) |a| try expr(c, a) else try c.op(.undef);
    if (is_async) {
        try c.op(.await_);
        try c.op(.resume_throw);
    }
    try c.op(.yield_);
    const cont = try c.jump(.resume_next);
    try resumeReturn(c, is_async);
    c.patch(cont);
    c.adj(1);
}

/// gen.return(v) resumed here: behave as `return v`, running finally blocks.
fn resumeReturn(c: *C, is_async: bool) Error!void {
    if (is_async) {
        try c.op(.await_);
        try c.op(.resume_throw);
    }
    try cstmt.emitReturn(c);
}

fn yieldStar(c: *C, arg: *Node, is_async: bool) Error!void {
    const mode = c.tempLocal();
    try expr(c, arg);
    try c.op(.delegate_get_iter);
    try c.byte(@intFromBool(is_async));
    try c.op(.int8);
    try c.byte(0);
    c.adj(1);
    try c.opU16(.put_loc, mode);
    c.adj(-1);
    try c.op(.undef);
    const top = c.pc();
    try c.opU16(.delegate_call, mode);
    const ret_at = c.pc();
    try c.u32le(0);
    const base = c.depth;
    if (is_async) {
        try c.op(.await_);
        try c.op(.resume_throw);
    }
    const done_at = try c.jump(.delegate_done);
    if (is_async) {
        try c.opU32(.get_field, try c.icAtom(c.vm.k.value.atom()));
        try c.op(.yield_);
    } else {
        try c.op(.yield_raw);
    }
    try c.opU16(.put_loc, mode);
    try c.loopTo(top);
    c.depth = base;
    // Done: [iter next value].
    c.patch(done_at);
    try c.op(.nip);
    try c.op(.nip);
    try c.opU16(.get_loc, mode);
    try c.op(.int8);
    try c.byte(2);
    try c.op(.seq);
    const not_ret = try c.jump(.jump_false);
    try cstmt.emitReturn(c);
    c.depth = base - 2;
    // Return with no iterator method: [iter next recv].
    c.patch(ret_at);
    c.depth = base;
    try c.op(.nip);
    try c.op(.nip);
    try resumeReturn(c, is_async);
    c.patch(not_ret);
    c.depth = base - 2;
}
