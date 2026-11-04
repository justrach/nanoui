//! Compiles class definitions and the synthetic functions that run field
//! initializers and static blocks.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const compiler = @import("compiler.zig");
const C = compiler.C;
const cexpr = @import("compiler_expr.zig");
const expr = cexpr.expr;
const cstmt = @import("compiler_stmt.zig");
const JSString = @import("string.zig").JSString;

/// Leaves the class constructor on the stack.
pub fn class(c: *C, cl: *ast.Class, hint: ?*JSString) Error!void {
    const saved_scope = c.scope;
    const s = cl.scope.?;
    try c.enterScope(s);
    // Private names are made fresh each time the class definition runs.
    var i: usize = 0;
    while (i < s.vars.items.len) : (i += 1) {
        const v = s.vars.items[i];
        if (v.kind == .private) {
            try c.opU32(.new_private, try c.atomIdx(v.name));
            try c.initVar(v);
        }
    }
    if (cl.parent) |parent| try expr(c, parent);
    const ctor = cl.ctor.?;
    const name_for_ctor = cl.name orelse hint;
    const saved_name = ctor.name;
    ctor.name = null;
    const proto = try compiler.compileFunction(c, ctor, name_for_ctor);
    ctor.name = saved_name;
    const idx: u32 = @intCast(c.protos.items.len);
    try c.protos.append(c.a, proto);
    try c.opU32(.make_class, idx);
    try c.byte(@intFromBool(cl.parent != null));
    c.adj(if (cl.parent != null) 1 else 2);
    // Stack from here on: ctor proto.
    for (cl.members) |*m| try member(c, m);
    if (cl.instance_init) |f| {
        try c.closure(f, null);
        try c.op(.set_fields);
    }
    if (cl.name_var) |v| {
        try c.op(.swap);
        try c.op(.dup);
        try c.initVar(v);
        try c.op(.swap);
    }
    if (cl.static_init) |f| {
        try c.closure(f, null);
        try c.op(.run_static);
    }
    try c.op(.pop);
    try c.exitScope(s);
    c.scope = saved_scope;
}

fn pushKey(c: *C, m: *ast.ClassMember) Error!void {
    if (m.computed) {
        try expr(c, m.key.?);
        try c.op(.to_propkey);
    } else {
        try c.pushStr(m.key_atom.?);
    }
}

fn member(c: *C, m: *ast.ClassMember) Error!void {
    switch (m.kind) {
        .field => {
            if (m.computed) {
                try expr(c, m.key.?);
                try c.op(.to_propkey);
                try c.initVar(m.hidden.?);
            }
        },
        .static_block => {},
        .method, .get, .set => {
            const kind: u8 = switch (m.kind) {
                .get => 1,
                .set => 2,
                else => 0,
            };
            const f = m.value.?.data.function;
            if (m.is_private) {
                const name_hint = m.key_atom;
                if (m.is_static) {
                    // [ctor proto] -> define on ctor.
                    try c.op(.swap);
                    try c.getVar(m.private_var.?);
                    try c.closure(f, name_hint);
                    try c.op(.define_private_method);
                    try c.byte(kind);
                    try c.op(.swap);
                } else {
                    // The closure waits in a hidden variable for each instance's init to install it.
                    try c.op(.dup);
                    try c.closure(f, name_hint);
                    try c.op(.home_set);
                    try c.op(.nip);
                    try c.initVar(m.hidden.?);
                }
                return;
            }
            if (m.is_static) {
                try c.op(.swap);
                try pushKey(c, m);
                try c.closure(f, if (m.computed) null else m.key_atom);
                try c.op(.define_method);
                try c.byte(kind);
                try c.op(.swap);
            } else {
                try pushKey(c, m);
                try c.closure(f, if (m.computed) null else m.key_atom);
                try c.op(.define_method);
                try c.byte(kind);
            }
        },
    }
}

/// The body of a class's field-initializer or static-init function.
pub fn classInitBody(c: *C) Error!void {
    const f = c.func;
    const cl = f.init_class.?;
    if (!f.init_static) {
        // Private methods first, so field initializers can call them.
        for (cl.members) |*m| {
            if (!m.is_private or m.is_static or m.kind == .field or m.kind == .static_block) continue;
            const kind: u8 = switch (m.kind) {
                .get => 1,
                .set => 2,
                else => 0,
            };
            try c.op(.this);
            try c.getVar(m.private_var.?);
            try c.getVar(m.hidden.?);
            try c.op(.define_private_method);
            try c.byte(kind);
            try c.op(.pop);
        }
    }
    for (cl.members) |*m| {
        if (m.is_static != f.init_static) continue;
        switch (m.kind) {
            .field => try field(c, m),
            .static_block => try cstmt.statement(c, m.value.?),
            else => {},
        }
    }
}

fn field(c: *C, m: *ast.ClassMember) Error!void {
    try c.op(.this);
    if (m.is_private) {
        try c.getVar(m.private_var.?);
        try fieldValue(c, m, m.key_atom);
        try c.op(.define_private);
    } else if (m.computed) {
        try c.getVar(m.hidden.?);
        if (m.value) |v| {
            try expr(c, v);
            if (cexpr.isAnonymousFn(v)) try c.op(.set_fn_name);
        } else {
            try c.op(.undef);
        }
        try c.op(.define_elem);
    } else {
        try fieldValue(c, m, m.key_atom);
        try c.opU32(.define_field, try c.icAtom(m.key_atom.?));
    }
    try c.op(.pop);
}

fn fieldValue(c: *C, m: *ast.ClassMember, name: ?*JSString) Error!void {
    if (m.value) |v| {
        if (name) |n| {
            try cexpr.exprNamed(c, v, n);
        } else {
            try expr(c, v);
        }
    } else {
        try c.op(.undef);
    }
}
