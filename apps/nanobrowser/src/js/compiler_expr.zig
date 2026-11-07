//! Compiles expressions to bytecode. Each emits code that leaves exactly one value
//! on the stack; exprVoid leaves none and avoids temporaries where it can.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const compiler = @import("compiler.zig");
const C = compiler.C;
const Value = @import("value.zig").Value;
const str = @import("string.zig");
const JSString = str.JSString;
const cassign = @import("compiler_assign.zig");
const ccall = @import("compiler_call.zig");
const cclass = @import("compiler_class.zig");
const objmod = @import("object.zig");
const props = @import("props.zig");
const big = @import("b_bigint.zig");
const shape = @import("shape.zig");

pub fn binOpcode(op: ast.BinOp) Op {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .shl => .shl,
        .sar => .sar,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .eq => .eq,
        .ne => .ne,
        .seq => .seq,
        .sne => .sne,
        .in => .in_,
        .instanceof => .instanceof_,
    };
}

/// Compiles n, giving an anonymous function or class this name.
pub fn exprNamed(c: *C, n: *Node, name: *JSString) Error!void {
    switch (n.data) {
        .function => |f| if (f.name == null) return c.closure(f, name),
        .class => |cl| if (cl.name == null) return cclass.class(c, cl, name),
        else => {},
    }
    return expr(c, n);
}

pub fn isAnonymousFn(n: *const Node) bool {
    return switch (n.data) {
        .function => |f| f.name == null,
        .class => |cl| cl.name == null,
        else => false,
    };
}

/// Compiles for effect only.
pub fn exprVoid(c: *C, n: *Node) Error!void {
    switch (n.data) {
        .update => |u| {
            if (u.arg.data == .ident and u.arg.data.ident.with_chain.len == 0) {
                if (u.arg.data.ident.binding) |v| {
                    try c.getVar(v);
                    try c.op(if (u.inc) .inc else .dec);
                    try c.assignVar(v);
                    return;
                }
            }
        },
        .assign => return cassign.assign(c, n, false),
        else => {},
    }
    try expr(c, n);
    try c.op(.pop);
}

pub fn expr(c: *C, n: *Node) Error!void {
    try c.vm.checkNativeStack();
    switch (n.data) {
        .num => |v| try c.pushNumber(v),
        .str => |s| try c.pushStr(s),
        .bigint => |s| try c.pushConst(try big.fromLiteral(c.vm, s)),
        .template => |t| try template(c, t),
        .tagged => |t| try tagged(c, n, t.tag, t.tmpl),
        .regex => |r| {
            try c.mark(n.pos);
            try c.op(.new_regexp);
            try c.u32le(try c.atomIdx(r.pattern));
            try c.u32le(try c.atomIdx(r.flags));
        },
        .ident => |id| {
            var found: std.ArrayList(u32) = .empty;
            try withLookup(c, id, .with_get, &found);
            try identPlain(c, n, id);
            c.patchAll(found.items);
        },
        .this => |id| {
            if (id.binding) |v| return c.getVar(v);
            try c.op(.this);
        },
        .new_target => |id| {
            if (id.binding) |v| return c.getVar(v);
            try c.op(.new_target);
        },
        .null_lit => try c.op(.null_),
        .true_lit => try c.op(.true_),
        .false_lit => try c.op(.false_),
        .array => |items| try arrayLiteral(c, items),
        .object => |ps| try objectLiteral(c, ps),
        .function => |f| try c.closure(f, null),
        .class => |cl| try cclass.class(c, cl, null),
        .unary => |u| try unary(c, n, u.op, u.arg),
        .update => |u| try cassign.update(c, u.inc, u.prefix, u.arg),
        .binary => try binaryChain(c, n),
        .logical => |l| try logical(c, l.op, l.l, l.r),
        .assign => try cassign.assign(c, n, true),
        .cond => |x| {
            try expr(c, x.t);
            const else_at = try c.jump(.jump_false);
            const d = c.depth;
            try expr(c, x.a);
            const end_at = try c.jump(.jump);
            c.patch(else_at);
            c.depth = d;
            try expr(c, x.b);
            c.patch(end_at);
        },
        .call => try ccall.call(c, n),
        .new => |x| try ccall.newExpr(c, n, x.callee, x.args, x.has_spread),
        .member => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try c.mark(n.pos);
            if (m.name == c.vm.k.length.atom()) {
                try c.opU32(.get_length, try c.icAtom(m.name));
            } else {
                try c.opU32(.get_field, try c.icAtom(m.name));
            }
        },
        .index => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try expr(c, m.idx);
            try c.mark(n.pos);
            try c.op(.get_elem);
        },
        .private_member => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try c.getVar(m.name.binding.?);
            try c.mark(n.pos);
            try c.op(.get_private);
        },
        .private_in => |m| {
            try c.getVar(m.name.binding.?);
            try expr(c, m.r);
            try c.mark(n.pos);
            try c.op(.has_private);
        },
        .super_member => |m| {
            try pseudo(c, m.this, .this);
            try pseudo(c, m.home, .home);
            try c.pushStr(m.name);
            try c.mark(n.pos);
            try c.op(.super_get);
        },
        .super_index => |m| {
            try pseudo(c, m.this, .this);
            try pseudo(c, m.home, .home);
            try expr(c, m.idx);
            try c.op(.to_propkey);
            try c.mark(n.pos);
            try c.op(.super_get);
        },
        .super_call => |s| try ccall.superCall(c, n, s.args, s.has_spread, s.this, s.func, s.new_target),
        .spread => return c.vm.throwError(.SyntaxError, "Unexpected spread element"),
        .seq => |list| {
            for (list[0 .. list.len - 1]) |e| try exprVoid(c, e);
            try expr(c, list[list.len - 1]);
        },
        .yield => |y| try ccall.yieldExpr(c, y.arg, y.delegate),
        .await => |a| {
            try expr(c, a);
            try c.mark(n.pos);
            try c.op(.await_);
            try c.op(.resume_throw);
        },
        .opt_chain => |e| {
            var patches: std.ArrayList(u32) = .empty;
            const saved = c.chain;
            c.chain = &patches;
            try expr(c, e);
            c.chain = saved;
            c.patchAll(patches.items);
        },
        .import_meta => try c.op(.import_meta),
        .import_call => |e| {
            try expr(c, e);
            try c.mark(n.pos);
            try c.op(.dynamic_import);
        },
        else => return c.vm.throwError(.SyntaxError, "Internal: statement in expression position"),
    }
}

fn identPlain(c: *C, n: *Node, id: *ast.Ident) Error!void {
    if (id.binding) |v| return c.getVar(v);
    if (id.name == c.vm.k.undefined.atom()) {
        try c.op(.undef);
        return;
    }
    try c.mark(n.pos);
    try c.opU32(.get_global, try c.icAtom(id.name));
}

/// Asks each enclosing `with` object for the name; a hit jumps to the patches in `found`.
pub fn withLookup(c: *C, id: *ast.Ident, op: Op, found: *std.ArrayList(u32)) Error!void {
    for (id.with_chain) |w| {
        try c.getVar(w);
        try c.op(op);
        try c.u32le(try c.atomIdx(id.name));
        try found.append(c.a, c.pc());
        try c.u32le(0);
    }
}

const PseudoOp = enum { this, home, callee, new_target };

pub fn pseudo(c: *C, id: *ast.Ident, which: PseudoOp) Error!void {
    if (id.binding) |v| return c.getVar(v);
    try c.op(switch (which) {
        .this => .this,
        .home => .home,
        .callee => .callee,
        .new_target => .new_target,
    });
}

/// Short-circuits the current optional chain when the top of stack is nullish.
pub fn optCheck(c: *C, extra: u8) Error!void {
    try c.op(.opt_chain);
    const at = c.pc();
    try c.u32le(0);
    try c.byte(extra);
    if (c.chain) |ch| try ch.append(c.a, at);
}

fn binaryChain(c: *C, n: *Node) Error!void {
    // Iterates down the left spine so long a+b+c+... chains don't recurse.
    var spine: std.ArrayList(*Node) = .empty;
    var cur = n;
    while (cur.data == .binary and !(cur != n and cur.paren and false)) {
        try spine.append(c.a, cur);
        cur = cur.data.binary.l;
    }
    try expr(c, cur);
    var i = spine.items.len;
    while (i > 0) {
        i -= 1;
        const b = spine.items[i];
        try expr(c, b.data.binary.r);
        try c.mark(b.pos);
        try c.op(binOpcode(b.data.binary.op));
    }
}

fn logical(c: *C, op: ast.LogOp, l: *Node, r: *Node) Error!void {
    try expr(c, l);
    const at = try c.jump(switch (op) {
        .land => .jump_false_keep,
        .lor => .jump_true_keep,
        .nullish => .jump_notnull_keep,
    });
    try expr(c, r);
    c.patch(at);
}

fn unary(c: *C, n: *Node, op: ast.UnOp, arg: *Node) Error!void {
    switch (op) {
        .neg => {
            if (arg.data == .num) return c.pushNumber(-arg.data.num);
            try expr(c, arg);
            try c.op(.neg);
        },
        .plus => {
            try expr(c, arg);
            try c.op(.plus);
        },
        .not => {
            try expr(c, arg);
            try c.op(.not);
        },
        .bit_not => {
            try expr(c, arg);
            try c.op(.bit_not);
        },
        .void => {
            try exprVoid(c, arg);
            try c.op(.undef);
        },
        .typeof => {
            if (arg.data == .ident and arg.data.ident.binding == null) {
                var found: std.ArrayList(u32) = .empty;
                try withLookup(c, arg.data.ident, .with_get, &found);
                try c.opU32(.get_global_typeof, try c.icAtom(arg.data.ident.name));
                c.patchAll(found.items);
            } else {
                try expr(c, arg);
            }
            try c.op(.typeof_);
        },
        .delete => try deleteExpr(c, n, arg),
    }
}

fn deleteExpr(c: *C, n: *Node, arg: *Node) Error!void {
    switch (arg.data) {
        .member => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try c.pushStr(m.name);
            try c.mark(n.pos);
            try c.op(.delete_elem);
        },
        .index => |m| {
            try expr(c, m.obj);
            if (m.optional) try optCheck(c, 0);
            try expr(c, m.idx);
            try c.mark(n.pos);
            try c.op(.delete_elem);
        },
        .opt_chain => |e| {
            var patches: std.ArrayList(u32) = .empty;
            const saved = c.chain;
            c.chain = &patches;
            try deleteExpr(c, n, e);
            c.chain = saved;
            // A short-circuited delete evaluates to true, not undefined.
            const over = try c.jump(.jump);
            c.patchAll(patches.items);
            try c.op(.pop);
            try c.op(.true_);
            c.patch(over);
        },
        .ident => |id| {
            var found: std.ArrayList(u32) = .empty;
            try withLookup(c, id, .with_delete, &found);
            if (id.binding != null) {
                try c.op(.false_);
            } else {
                try c.opU32(.delete_global, try c.atomIdx(id.name));
            }
            c.patchAll(found.items);
        },
        .super_member, .super_index => return c.vm.throwError(.ReferenceError, "Unsupported reference to super"),
        else => {
            try exprVoid(c, arg);
            try c.op(.true_);
        },
    }
}

fn template(c: *C, t: *ast.Template) Error!void {
    try c.pushStr(t.cooked[0].?);
    for (t.exprs, 0..) |e, i| {
        try expr(c, e);
        try c.op(.to_str);
        try c.op(.add);
        const chunk = t.cooked[i + 1].?;
        if (chunk.byte_len != 0) {
            try c.pushStr(chunk);
            try c.op(.add);
        }
    }
}

/// The frozen strings array for a tagged template; one per site, made at compile time.
fn templateObject(c: *C, t: *ast.Template) Error!Value {
    const vm = c.vm;
    const cooked = try objmod.newArray(vm, &.{});
    const raw = try objmod.newArray(vm, &.{});
    for (t.cooked, t.raw) |ck, r| {
        try objmod.arrayPush(vm, cooked, if (ck) |s| Value.fromString(s) else Value.undefined);
        try objmod.arrayPush(vm, raw, Value.fromString(r));
    }
    try @import("props_define.zig").setIntegrityFast(vm, raw, true);
    try props.addProp(vm, cooked, vm.k.raw, raw.value(), shape.PropFlags.readonly);
    try @import("props_define.zig").setIntegrityFast(vm, cooked, true);
    return cooked.value();
}

fn tagged(c: *C, n: *Node, tag: *Node, t: *ast.Template) Error!void {
    try ccall.calleeWithThis(c, tag);
    try c.pushConst(try templateObject(c, t));
    for (t.exprs) |e| try expr(c, e);
    try c.mark(n.pos);
    const argc: u32 = @intCast(t.exprs.len + 1);
    try c.opU16(.call, argc);
    c.adj(-@as(i32, @intCast(argc + 1)));
}

fn arrayLiteral(c: *C, items: []const ?*Node) Error!void {
    var prefix: usize = 0;
    while (prefix < items.len and prefix < 64) : (prefix += 1) {
        const it = items[prefix] orelse {
            try c.op(.hole);
            continue;
        };
        if (it.data == .spread) break;
        try expr(c, it);
    }
    try c.opU32(.array_from, @intCast(prefix));
    c.adj(1 - @as(i32, @intCast(prefix)));
    for (items[prefix..]) |item| {
        const it = item orelse {
            try c.op(.hole);
            try c.op(.array_append);
            continue;
        };
        if (it.data == .spread) {
            try expr(c, it.data.spread);
            try c.op(.array_spread);
        } else {
            try expr(c, it);
            try c.op(.array_append);
        }
    }
}

fn objectLiteral(c: *C, ps: []const ast.Prop) Error!void {
    try c.op(.new_object);
    for (ps) |p| {
        switch (p.kind) {
            .spread => {
                try expr(c, p.value);
                try c.op(.object_spread);
            },
            .proto => {
                try expr(c, p.value);
                try c.op(.set_proto);
            },
            .init, .shorthand => {
                if (p.computed) {
                    try expr(c, p.key.?);
                    try c.op(.to_propkey);
                    try expr(c, p.value);
                    if (isAnonymousFn(p.value)) try c.op(.set_fn_name);
                    try c.op(.define_elem);
                } else {
                    try exprNamed(c, p.value, p.key_atom.?);
                    try c.opU32(.define_field, try c.icAtom(p.key_atom.?));
                }
            },
            .method, .get, .set => {
                if (p.computed) {
                    try expr(c, p.key.?);
                    try c.op(.to_propkey);
                } else {
                    try c.pushStr(p.key_atom.?);
                }
                try c.closure(p.value.data.function, if (p.computed) null else p.key_atom);
                const kind: u8 = switch (p.kind) {
                    .get => 1,
                    .set => 2,
                    else => 0,
                };
                try c.op(.define_method);
                try c.byte(kind | 4);
            },
        }
    }
}
