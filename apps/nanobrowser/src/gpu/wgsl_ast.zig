//! What the parser builds: everything lives in the translation's arena.
const lex = @import("wgsl_lex.zig");
pub const Pos = lex.Pos;

pub const UnOp = enum { neg, not, bitnot, deref, addr };
pub const BinOp = enum { add, sub, mul, div, mod, band, bor, bxor, shl, shr, land, lor, eq, ne, lt, le, gt, ge };

pub const Expr = struct {
    pos: Pos,
    k: Kind,

    pub const Kind = union(enum) {
        /// suffix: 0, 'i' or 'u'.
        int: struct { value: i64, suffix: u8 },
        /// suffix: 0 or 'f'.
        float: struct { value: f64, suffix: u8 },
        boolean: bool,
        ident: []const u8,
        /// `vec3<f32>` as a type, or before the call's arguments.
        tmpl: struct { name: []const u8, args: []const *Expr },
        call: struct { callee: *Expr, args: []const *Expr },
        member: struct { base: *Expr, name: []const u8, name_pos: Pos },
        index: struct { base: *Expr, i: *Expr },
        unary: struct { op: UnOp, e: *Expr },
        binary: struct { op: BinOp, l: *Expr, r: *Expr },
    };
};

pub const Interp = struct { kind: []const u8, sampling: ?[]const u8 = null };
pub const Stage = enum { vertex, fragment, compute };

pub const Attrs = struct {
    pos: Pos = .{},
    builtin: ?[]const u8 = null,
    builtin_pos: Pos = .{},
    location: ?*Expr = null,
    interpolate: ?Interp = null,
    invariant: bool = false,
    align_: ?*Expr = null,
    size: ?*Expr = null,
    group: ?*Expr = null,
    binding: ?*Expr = null,
    id: ?*Expr = null,
    stage: ?Stage = null,
    workgroup_size: ?[3]?*Expr = null,
    must_use: bool = false,
};

pub const VarKind = enum { var_, let, const_ };

pub const LocalVar = struct { kind: VarKind, name: []const u8, name_pos: Pos, ty: ?*Expr, init: ?*Expr };

pub const Case = struct { pos: Pos, selectors: []const ?*Expr, body: []const *Stmt };

pub const Stmt = struct {
    pos: Pos,
    k: Kind,

    pub const Kind = union(enum) {
        block: []const *Stmt,
        decl: LocalVar,
        /// `lhs == null`: the phony `_ = rhs`. `op == null`: plain `=`.
        assign: struct { lhs: ?*Expr, op: ?BinOp, rhs: *Expr },
        incdec: struct { lhs: *Expr, inc: bool },
        call: *Expr,
        if_: struct { cond: *Expr, then: []const *Stmt, els: ?*Stmt },
        while_: struct { cond: *Expr, body: []const *Stmt },
        for_: struct { init: ?*Stmt, cond: ?*Expr, update: ?*Stmt, body: []const *Stmt },
        loop: struct { body: []const *Stmt, continuing: ?[]const *Stmt, break_if: ?*Expr },
        switch_: struct { sel: *Expr, cases: []const Case },
        ret: ?*Expr,
        brk,
        cont,
        discard,
        const_assert: *Expr,
    };
};

pub const Member = struct { name: []const u8, pos: Pos, ty: *Expr, attrs: Attrs };
pub const Struct = struct { name: []const u8, pos: Pos, members: []const Member };
pub const Alias = struct { name: []const u8, pos: Pos, ty: *Expr };
pub const Const = struct { name: []const u8, pos: Pos, ty: ?*Expr, init: *Expr };
pub const Override = struct { name: []const u8, pos: Pos, ty: ?*Expr, init: ?*Expr, attrs: Attrs };
pub const Global = struct { name: []const u8, pos: Pos, ty: ?*Expr, init: ?*Expr, space: ?[]const u8, access: ?[]const u8, attrs: Attrs };
pub const Param = struct { name: []const u8, pos: Pos, ty: *Expr, attrs: Attrs };
pub const Func = struct {
    name: []const u8,
    pos: Pos,
    params: []const Param,
    ret: ?*Expr,
    ret_attrs: Attrs,
    body: []const *Stmt,
    attrs: Attrs,
    end_pos: Pos,
};

pub const Decl = union(enum) {
    strct: *Struct,
    alias: *Alias,
    constant: *Const,
    override: *Override,
    global: *Global,
    func: *Func,
    assert: *Expr,
};

pub const Module = struct { decls: []const Decl };
