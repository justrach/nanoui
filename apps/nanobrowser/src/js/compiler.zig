//! The bytecode compiler's core: per-function state, emission helpers, variable
//! access, scope entry and exit, function prologues, and the program entry point.
//! Expressions, assignment and patterns, statements and classes are in their own files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const ast = @import("ast.zig");
const Node = ast.Node;
const Scope = ast.Scope;
const Var = ast.Var;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const str = @import("string.zig");
const JSString = str.JSString;
const scope_mod = @import("scope.zig");
const cexpr = @import("compiler_expr.zig");
const cassign = @import("compiler_assign.zig");
const cstmt = @import("compiler_stmt.zig");
const cclass = @import("compiler_class.zig");

pub const ControlKind = enum { env, label, loop, for_of, for_await, catch_guard, finally_guard, finally_body, iter_guard };

pub const Control = struct {
    kind: ControlKind,
    labels: []const *JSString = &.{},
    breaks: std.ArrayList(u32) = .empty,
    continues: std.ArrayList(u32) = .empty,
    /// finally_guard: gosub operands to patch once the finally block's address is known.
    gosubs: ?*std.ArrayList(u32) = null,
    /// A switch body: an unlabeled break stops here.
    switch_target: bool = false,
};

pub const C = struct {
    vm: *Vm,
    a: Allocator,
    parent: ?*C,
    func: *ast.Func,
    fi: *ast.FuncInfo,
    source: *bc.Source,
    code: std.ArrayList(u8) = .empty,
    constants: std.ArrayList(Value) = .empty,
    const_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    protos: std.ArrayList(*bc.FuncProto) = .empty,
    ics: std.ArrayList(bc.IC) = .empty,
    lines: std.ArrayList(bc.LineEntry) = .empty,
    control: std.ArrayList(Control) = .empty,
    scope: *Scope,
    depth: i32 = 0,
    max_depth: i32 = 0,
    /// Patches for the innermost optional chain's short-circuit.
    chain: ?*std.ArrayList(u32) = null,
    /// Script/eval only: the local that collects the completion value.
    completion: ?u32 = null,
    labels: std.ArrayList(*JSString) = .empty,
    module_mode: bool = false,

    pub inline fn adj(c: *C, n: i32) void {
        c.depth += n;
        if (c.depth > c.max_depth) c.max_depth = c.depth;
    }
    pub inline fn pc(c: *C) u32 {
        return @intCast(c.code.items.len);
    }
    pub inline fn byte(c: *C, b: u8) Error!void {
        try c.code.append(c.a, b);
    }
    pub fn op(c: *C, o: Op) Error!void {
        try c.byte(@backingInt(o));
        c.adj(bc.effect(o));
    }
    pub fn u16le(c: *C, v: u32) Error!void {
        if (v > 0xFFFF) return c.vm.throwError(.SyntaxError, "Function too large: too many locals or arguments");
        try c.code.appendSlice(c.a, &std.mem.toBytes(@as(u16, @intCast(v))));
    }
    pub fn u32le(c: *C, v: u32) Error!void {
        try c.code.appendSlice(c.a, &std.mem.toBytes(v));
    }
    pub fn opU16(c: *C, o: Op, v: u32) Error!void {
        try c.op(o);
        try c.u16le(v);
    }
    pub fn opU32(c: *C, o: Op, v: u32) Error!void {
        try c.op(o);
        try c.u32le(v);
    }
    pub fn mark(c: *C, pos: u32) Error!void {
        const items = c.lines.items;
        if (items.len != 0 and items[items.len - 1].pos == pos) return;
        try c.lines.append(c.a, .{ .pc = c.pc(), .pos = pos });
    }
    /// Emits a forward jump, returning the operand's address for patch().
    pub fn jump(c: *C, o: Op) Error!u32 {
        try c.op(o);
        const at = c.pc();
        try c.u32le(0);
        return at;
    }
    pub fn patch(c: *C, at: u32) void {
        const rel: i32 = @intCast(@as(i64, c.pc()) - (@as(i64, at) + 4));
        std.mem.writeInt(i32, c.code.items[at..][0..4], rel, .little);
    }
    pub fn patchAll(c: *C, list: []const u32) void {
        for (list) |at| c.patch(at);
    }
    /// A backward jump to a known address.
    pub fn loopTo(c: *C, target: u32) Error!void {
        try c.op(.loop);
        const rel: i32 = @intCast(@as(i64, target) - (@as(i64, c.pc()) + 4));
        try c.code.appendSlice(c.a, &std.mem.toBytes(rel));
    }
    pub fn constIdx(c: *C, v: Value) Error!u32 {
        if (c.const_map.get(v.bits)) |i| return i;
        const i: u32 = @intCast(c.constants.items.len);
        try c.constants.append(c.a, v);
        try c.const_map.put(c.a, v.bits, i);
        return i;
    }
    pub fn atomIdx(c: *C, s: *JSString) Error!u32 {
        return c.constIdx(Value.fromString(s));
    }
    pub fn pushConst(c: *C, v: Value) Error!void {
        try c.opU32(.constant, try c.constIdx(v));
    }
    pub fn pushStr(c: *C, s: *JSString) Error!void {
        try c.pushConst(Value.fromString(s));
    }
    pub fn pushNumber(c: *C, d: f64) Error!void {
        const v = Value.fromNumber(d);
        if (v.isInt()) {
            const i = v.asInt();
            if (i >= -128 and i <= 127) {
                try c.op(.int8);
                try c.byte(@bitCast(@as(i8, @intCast(i))));
            } else {
                try c.opU32(.int32, @bitCast(i));
            }
        } else {
            try c.pushConst(v);
        }
    }
    pub fn icFor(c: *C, key: PropKey) Error!u32 {
        const i: u32 = @intCast(c.ics.items.len);
        try c.ics.append(c.a, .{ .key = key });
        return i;
    }
    pub fn icAtom(c: *C, name: *JSString) Error!u32 {
        return c.icFor(try str.toKey(c.vm, name));
    }
    /// A new hidden local, for temporaries that must survive statements.
    pub fn tempLocal(c: *C) u32 {
        const s = c.fi.nlocals;
        c.fi.nlocals += 1;
        return s;
    }

    fn envDepth(c: *C, target: *Scope) Error!u32 {
        var d: u32 = 0;
        var s: *Scope = c.scope;
        while (s != target) {
            if (s.env_size > 0) d += 1;
            s = s.parent orelse return c.vm.throwError(.SyntaxError, "Internal: variable scope not found");
        }
        if (d > 255) return c.vm.throwError(.SyntaxError, "Scopes nested too deeply");
        return d;
    }

    fn envOperands(c: *C, v: *Var) Error!void {
        try c.byte(@intCast(try c.envDepth(v.scope)));
        try c.u16le(v.index);
    }

    /// Pushes a variable's value, checking the dead zone where that could matter.
    pub fn getVar(c: *C, v: *Var) Error!void {
        if (v.kind == .import) {
            try c.opU32(.get_import, v.import_index);
            return;
        }
        if (v.captured) {
            if (v.needs_tdz) {
                try c.op(.get_env_check);
                try c.envOperands(v);
                try c.u32le(try c.atomIdx(v.name));
            } else {
                try c.op(.get_env);
                try c.envOperands(v);
            }
        } else if (v.needs_tdz) {
            try c.opU16(.get_loc_check, v.index);
            try c.u32le(try c.atomIdx(v.name));
        } else {
            try c.opU16(.get_loc, v.index);
        }
    }

    /// Pops into a variable with no checks: declarations and initial values.
    pub fn initVar(c: *C, v: *Var) Error!void {
        if (v.captured) {
            try c.op(.put_env);
            try c.envOperands(v);
        } else {
            try c.opU16(.put_loc, v.index);
        }
    }

    /// Pops into a variable as an assignment: const and dead-zone rules apply.
    pub fn assignVar(c: *C, v: *Var) Error!void {
        switch (v.kind) {
            .@"const", .import => {
                if (v.needs_tdz and v.kind != .import) {
                    try c.getVar(v);
                    try c.op(.pop);
                }
                try c.opU32(.throw_const, try c.atomIdx(v.name));
                try c.op(.pop);
                return;
            },
            .fn_name => {
                if (c.func.strict) try c.opU32(.throw_const, try c.atomIdx(v.name));
                try c.op(.pop);
                return;
            },
            else => {},
        }
        if (v.needs_tdz) {
            if (v.captured) {
                try c.op(.put_env_check);
                try c.envOperands(v);
                try c.u32le(try c.atomIdx(v.name));
            } else {
                try c.opU16(.put_loc_check, v.index);
                try c.u32le(try c.atomIdx(v.name));
            }
        } else {
            try c.initVar(v);
        }
    }

    /// Enters a scope: its Env if it has captured variables, dead-zone holes, hoisted functions.
    pub fn enterScope(c: *C, s: *Scope) Error!void {
        c.scope = s;
        if (s.env_size > 0 and !(c.module_mode and s.kind == .module)) {
            try c.opU16(.push_env, s.env_size);
            try c.control.append(c.a, .{ .kind = .env });
        }
        for (s.vars.items) |v| {
            if (!v.captured and v.needs_tdz and v.kind != .pseudo) try c.opU16(.set_hole, v.index);
        }
        try c.instantiateHoisted(s);
    }

    pub fn instantiateHoisted(c: *C, s: *Scope) Error!void {
        for (s.hoisted.items) |st| {
            const f = st.data.func_decl;
            try c.closure(f, null);
            if (f.decl_binding) |v| {
                try c.initVar(v);
            } else {
                try c.opU32(.def_global_fn, try c.atomIdx(f.name.?));
            }
        }
    }

    pub fn exitScope(c: *C, s: *Scope) Error!void {
        if (s.env_size > 0 and !(c.module_mode and s.kind == .module)) {
            try c.op(.pop_env);
            _ = c.control.pop();
        }
        c.scope = s.parent orelse s;
    }

    /// Compiles a nested function and pushes a closure over the current env.
    pub fn closure(c: *C, f: *ast.Func, hint: ?*JSString) Error!void {
        const proto = try compileFunction(c, f, hint);
        const i: u32 = @intCast(c.protos.items.len);
        try c.protos.append(c.a, proto);
        try c.opU32(.closure, i);
    }
};

fn dupeInto(gpa: Allocator, comptime T: type, items: []const T) Error![]T {
    return gpa.dupe(T, items);
}

/// Freezes a finished function's buffers into a heap FuncProto.
pub fn finish(c: *C, name: *JSString, start: u32, end: u32, length: u32) Error!*bc.FuncProto {
    const gpa = c.vm.gpa;
    const code = try dupeInto(gpa, u8, c.code.items);
    const constants = try dupeInto(gpa, Value, c.constants.items);
    const protos = try dupeInto(gpa, *bc.FuncProto, c.protos.items);
    const ics = try dupeInto(gpa, bc.IC, c.ics.items);
    const lines = try dupeInto(gpa, bc.LineEntry, c.lines.items);
    const f = c.func;
    const p = try c.vm.heap.create(bc.FuncProto, .proto);
    const cell = p.cell;
    p.* = .{
        .cell = cell,
        .code = code,
        .constants = constants,
        .protos = protos,
        .ics = ics,
        .lines = lines,
        .name = name,
        .source = c.source,
        .src_start = start,
        .src_end = end,
        .length = length,
        .nparams = @intCast(scope_mod.rawParamCount(f)),
        .nlocals = c.fi.nlocals,
        .max_stack = @intCast(c.max_depth + 8),
        .strict = f.strict,
        .is_arrow = f.is_arrow,
        .is_async = f.is_async,
        .is_generator = f.is_generator,
        .has_prototype = !f.is_arrow and !f.is_method and (!f.is_async or f.is_generator) or (f.is_method and f.is_generator),
        .is_class_ctor = f.is_class_ctor,
        .is_derived = f.is_derived,
        .coerce_this = !f.strict and c.fi.uses_this and !f.is_arrow,
        .needs_home = c.fi.uses_super or c.fi.home_var != null,
        .is_method = f.is_method,
    };
    return p;
}

fn paramLength(f: *const ast.Func) u32 {
    var n: u32 = 0;
    for (f.params) |param| {
        if (param.data == .assign or param.data == .spread) break;
        n += 1;
    }
    return n;
}

pub fn compileFunction(parent: *C, f: *ast.Func, hint: ?*JSString) Error!*bc.FuncProto {
    try parent.vm.checkNativeStack();
    const vm = parent.vm;
    const fi = f.info.?;
    var c = C{ .vm = vm, .a = parent.a, .parent = parent, .func = f, .fi = fi, .source = parent.source, .scope = fi.scope.?, .module_mode = parent.module_mode };
    const name = blk: {
        if (f.name) |n| break :blk if (n == vm.k.@"*default*".atom()) vm.k.default.atom() else n;
        break :blk hint orelse vm.empty;
    };
    try prologue(&c);
    if (f.is_class_init) {
        try cclass.classInitBody(&c);
    } else if (f.is_default_ctor) {
        if (f.is_derived) {
            try c.op(.super_forward);
            try c.op(.ret);
        } else {
            try c.op(.this);
            try c.op(.callee);
            try c.op(.run_fields);
        }
    } else {
        for (f.body) |st| try cstmt.statement(&c, st);
        if (f.expr_body) |e| {
            try cexpr.expr(&c, e);
            try cstmt.emitReturn(&c);
        }
    }
    try functionEnd(&c);
    const end = if (f.end > f.start) f.end else f.start;
    return finish(&c, name, f.start, end, paramLength(f));
}

fn functionEnd(c: *C) Error!void {
    const f = c.func;
    if (f.is_derived) {
        try c.getVar(c.fi.this_var.?);
        try c.op(.ret);
    } else {
        try c.op(.ret_undef);
    }
}

fn prologue(c: *C) Error!void {
    const f = c.func;
    const fi = c.fi;
    const s = fi.scope.?;
    if (f.is_async and !f.is_generator) try c.op(.async_start);
    if (s.env_size > 0) {
        try c.opU16(.push_env, s.env_size);
    }
    // Captured `var`s start undefined rather than as the hole.
    for (s.vars.items) |v| {
        if (v.captured and (v.kind == .@"var" or v.kind == .function)) {
            try c.op(.undef);
            try c.initVar(v);
        } else if (!v.captured and v.needs_tdz and v.kind != .pseudo) {
            try c.opU16(.set_hole, v.index);
        }
    }
    if (fi.this_var) |v| {
        if (f.is_derived) {
            if (!v.captured) try c.opU16(.set_hole, v.index);
        } else {
            try c.op(.this);
            try c.initVar(v);
        }
    }
    if (fi.arguments_var) |v| {
        try c.op(.arguments);
        try c.initVar(v);
    }
    if (fi.new_target_var) |v| {
        try c.op(.new_target);
        try c.initVar(v);
    }
    if (fi.home_var) |v| {
        try c.op(.home);
        try c.initVar(v);
    }
    if (fi.func_var) |v| {
        try c.op(.callee);
        try c.initVar(v);
    }
    if (fi.fn_name_var) |v| {
        try c.op(.callee);
        try c.initVar(v);
    }
    // Class-init functions have no parameters; everything else binds its arguments here.
    var raw: u32 = 0;
    for (f.params) |param| {
        switch (param.data) {
            .ident => |id| {
                const v = id.binding.?;
                if (v.captured) {
                    try c.opU16(.get_loc, raw);
                    try c.initVar(v);
                }
            },
            .spread => |target| {
                try c.opU16(.rest, raw);
                try cassign.bindPattern(c, target, .init);
                continue;
            },
            else => {
                try c.opU16(.get_loc, raw);
                try cassign.bindPattern(c, param, .init);
            },
        }
        raw += 1;
    }
    try c.instantiateHoisted(s);
    if (f.is_generator) try c.op(.initial_yield);
    if (f.is_class_ctor and !f.is_derived and !f.is_default_ctor) {
        try c.op(.this);
        try c.op(.callee);
        try c.op(.run_fields);
    }
}

pub const Mode = scope_mod.Mode;

pub const Compiled = struct {
    /// The script, eval or module body.
    main: *bc.FuncProto,
    /// Modules only: creates the hoisted functions before any module body runs.
    module_init: ?*bc.FuncProto = null,
    /// Modules only: the size of the module's Env, and where each named binding lives.
    env_size: u32 = 0,
    scope: ?*Scope = null,
};

/// Compiles a parsed, analyzed program.
pub fn compileProgram(vm: *Vm, a: Allocator, prog: *ast.Program, r: scope_mod.Result, source: *bc.Source) Error!Compiled {
    const f = prog.func;
    const fi = f.info.?;
    const s = fi.scope.?;
    var c = C{ .vm = vm, .a = a, .parent = null, .func = f, .fi = fi, .source = source, .scope = s };
    if (prog.is_module) {
        c.module_mode = true;
        var init = C{ .vm = vm, .a = a, .parent = null, .func = f, .fi = fi, .source = source, .scope = s, .module_mode = true };
        for (s.vars.items) |v| {
            if (v.kind == .@"var" or v.kind == .function) {
                try init.op(.undef);
                try init.initVar(v);
            }
        }
        try init.instantiateHoisted(s);
        try init.op(.ret_undef);
        const init_proto = try finish(&init, vm.empty, f.start, f.end, 0);
        init_proto.is_async = false;
        init_proto.has_prototype = false;
        try c.op(.async_start);
        for (s.vars.items) |v| {
            if (v.kind == .pseudo and fi.this_var == v) {
                try c.op(.undef);
                try c.initVar(v);
            }
        }
        for (f.body) |st| try cstmt.statement(&c, st);
        try c.op(.ret_undef);
        const main = try finish(&c, vm.empty, f.start, f.end, 0);
        return .{ .main = main, .module_init = init_proto, .env_size = s.env_size, .scope = s };
    }
    for (r.global_lex) |g| {
        try c.op(.decl_global_lex);
        try c.u32le(try c.atomIdx(g.name));
        try c.byte(@intFromBool(g.is_const));
    }
    for (r.global_vars) |name| {
        try c.opU32(.decl_global_var, try c.atomIdx(name));
    }
    c.completion = c.tempLocal();
    if (s.env_size > 0) try c.opU16(.push_env, s.env_size);
    if (fi.this_var) |v| {
        try c.op(.this);
        try c.initVar(v);
    }
    for (s.vars.items) |v| {
        if (!v.captured and v.needs_tdz and v.kind != .pseudo) try c.opU16(.set_hole, v.index);
    }
    try c.instantiateHoisted(s);
    for (f.body) |st| try cstmt.statement(&c, st);
    try c.opU16(.get_loc, c.completion.?);
    try c.op(.ret);
    return .{ .main = try finish(&c, vm.empty, f.start, f.end, 0) };
}
