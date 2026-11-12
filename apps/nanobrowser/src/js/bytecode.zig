//! The bytecode: a stack machine with u8 opcodes and little-endian inline operands,
//! the compiled function record (FuncProto), and the shared source text.
//! Operand layouts are noted beside each opcode; `k` is a u32 index into constants,
//! `ic` a u32 index into the inline caches, `rel` an i32 offset from the operand's end.

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = @import("heap.zig");
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const Shape = @import("shape.zig").Shape;
const Object = @import("object.zig").Object;
const JSString = @import("string.zig").JSString;
const module = @import("module.zig");

pub const Op = enum(u8) {
    // pushes
    undef,
    null_,
    true_,
    false_,
    hole,
    int8, // i8
    int32, // i32
    constant, // k
    this,
    callee,
    new_target,
    home,
    arguments,
    args_get, // u16 slot
    args_len, // u16 slot
    args_elem, // u16 slot (idx -> val)
    args_apply, // u16 slot (recv fn thisArg -> ret)
    rest, // u16 first index
    // stack shuffles
    pop,
    dup,
    dup2,
    swap,
    nip, // a b -> b
    insert2, // a b -> b a b
    insert3, // a b c -> c a b c
    rot3l, // a b c -> b c a
    rot3r, // a b c -> c a b
    // locals
    get_loc, // u16
    put_loc, // u16
    set_loc, // u16 (keeps value)
    get_loc_check, // u16 k
    put_loc_check, // u16 k
    set_hole, // u16
    // environments
    push_env, // u16 size
    pop_env,
    clone_env,
    get_env, // u8 depth, u16 slot
    put_env,
    get_env_check, // u8, u16, k
    put_env_check, // u8, u16, k
    // globals
    get_global, // ic
    get_global_typeof, // ic
    put_global, // ic
    decl_global_var, // k
    def_global_fn, // k (fn ->)
    decl_global_lex, // k, u8 is_const
    init_global_lex, // ic (v ->)
    delete_global, // k
    // modules
    get_import, // u32 import index
    import_meta,
    dynamic_import,
    // properties
    get_field, // ic
    get_field2, // ic (obj -> obj val)
    put_field, // ic (obj val -> val)
    get_length, // ic
    get_elem,
    get_elem2,
    put_elem, // obj key val -> val
    delete_elem,
    super_get, // this home key -> val
    super_put, // this home key val -> val
    define_field, // ic (obj val -> obj)
    define_elem, // obj key val -> obj
    define_method, // u8 flags (obj key fn -> obj)
    set_proto, // obj val -> obj
    set_fn_name, // key fn -> key fn
    get_private, // obj sym -> val
    put_private, // obj sym val -> val
    define_private, // obj sym val -> obj
    define_private_method, // u8 kind (obj sym fn -> obj)
    home_set, // home fn -> home fn
    has_private, // sym obj -> bool
    new_private, // k
    // creators
    new_object,
    array_from, // u32 n
    array_append, // arr val -> arr
    array_spread, // arr iterable -> arr
    object_spread, // obj src -> obj
    object_rest, // u16 n (src key*n -> rest)
    closure, // u32 proto
    new_regexp, // k k
    make_class, // u32 proto, u8 has_parent (parent? -> ctor proto)
    set_fields, // ctor proto fn -> ctor proto
    run_static, // ctor proto fn -> ctor proto
    run_fields, // this func ->
    // operators
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    sar,
    shr,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    seq,
    sne,
    neg,
    plus,
    not,
    bit_not,
    inc,
    dec,
    typeof_,
    to_numeric,
    to_propkey,
    to_str,
    instanceof_,
    in_,
    // control
    jump, // rel
    loop, // rel (backward; checks the interrupt budget)
    jump_false, // rel
    jump_true, // rel
    jump_false_keep, // rel
    jump_true_keep, // rel
    jump_notnull_keep, // rel
    jump_not_undef, // rel (v -> v if not undefined, else ->)
    opt_chain, // rel, u8 extra pops
    call, // u16 argc
    new_, // u16 argc
    do_call, // internal to the dispatch loop
    do_new, // internal to the dispatch loop
    apply, // this fn arr -> ret
    apply_new, // _ ctor arr -> ret
    get_super_ctor, // func -> parent
    super_call, // u16 argc (new_target parent args -> obj)
    super_apply, // new_target parent arr -> obj
    super_forward, // default derived constructor: all arguments
    check_super_once, // this ->
    ret,
    ret_undef,
    ctor_ret_check, // rel (v -> v, jump if object; undefined -> nothing, fallthrough)
    throw_,
    throw_const, // k
    check_coercible,
    // exceptions and finally
    push_try, // rel
    pop_try,
    gosub, // rel
    ret_sub,
    // iteration
    iter_init,
    async_iter_init,
    iter_next, // rel
    iter_step,
    iter_rest,
    iter_close,
    iter_drop,
    async_iter_call,
    async_iter_close, // i n m -> res
    iter_result, // rel (res -> value, or jump when done)
    for_in_start, // obj -> keys
    for_in_next, // u16 keys, u16 index, rel
    // generators and async
    async_start,
    initial_yield,
    yield_,
    yield_raw,
    await_,
    resume_next, // rel
    resume_throw,
    delegate_get_iter, // u8 is_async (x -> iter next)
    delegate_call, // u16 mode slot, rel (iter next recv -> iter next res)
    delegate_done, // rel (res -> res, or value and jump)
    to_object,
    with_get, // k, rel ([W] -> [value] and jump if W has the name, else [])
    with_get_call, // k, rel ([W] -> [W fn] and jump if W has the name, else [])
    with_put, // k, rel ([val W] -> [val], having stored and jumped if W has the name)
    with_delete, // k, rel ([W] -> [bool] and jump if W has the name, else [])
    nop,
};

pub const IC = struct {
    pub const missing_slot: u32 = std.math.maxInt(u32);
    pub const proto_poly_cap = 16;
    pub const own_poly_cap = 4;

    pub inline fn protoHashBase(sh: *const Shape) usize {
        const p = @intFromPtr(sh);
        const x = p ^ (p >> 3);
        return ((x >> 4) & 7) << 1;
    }

    key: PropKey,
    shape: ?*Shape = null,
    holder: ?*Object = null,
    holder_shape: ?*Shape = null,
    slot: u32 = 0,
    epoch: u32 = 0,
    is_accessor: bool = false,
    is_transition: bool = false,
    is_str_len: bool = false,
    fast_own_data: bool = false,
    fast_proto_data: bool = false,
    proto_idx: u8 = 0,
    own_idx: u8 = 0,
    own_slots: [own_poly_cap]u32 = @splat(0),
    own_shapes: [own_poly_cap]?*Shape = @splat(null),
    proto_shapes: [proto_poly_cap]?*Shape = @splat(null),
};

pub const LineEntry = struct { pc: u32, pos: u32 };
pub const CatchEntry = struct { bc_pc: u32, word_off: u32 };
pub const JitCacheSlot = struct {
    jit_fn: ?*const anyopaque = null,
    catch_map: []CatchEntry = &.{},
};

pub const Source = struct {
    cell: heap.Cell,
    text: []u8,
    name: []u8,
    /// Offsets of line starts, built the first time a position is reported.
    line_starts: []u32 = &.{},
    borrowed_text: bool = false,

    pub fn finalize(s: *Source, gpa: Allocator) void {
        if (!s.borrowed_text) gpa.free(s.text);
        gpa.free(s.name);
        gpa.free(s.line_starts);
    }

    pub const LineCol = struct { line: u32, col: u32 };

    pub fn lineCol(s: *Source, gpa: Allocator, pos: u32) Allocator.Error!LineCol {
        if (s.line_starts.len == 0) {
            var n: usize = 1;
            for (s.text) |c| {
                if (c == '\n') n += 1;
            }
            const t = try gpa.alloc(u32, n);
            t[0] = 0;
            var w: usize = 1;
            for (s.text, 0..) |c, i| {
                if (c == '\n') {
                    t[w] = @intCast(i + 1);
                    w += 1;
                }
            }
            s.line_starts = t;
        }
        var lo: usize = 0;
        var hi: usize = s.line_starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s.line_starts[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        return .{ .line = @intCast(lo), .col = pos - s.line_starts[lo - 1] + 1 };
    }
};

pub const FuncProto = struct {
    cell: heap.Cell,
    code: []u8,
    constants: []Value,
    protos: []*FuncProto,
    ics: []IC,
    lines: []LineEntry,
    name: *JSString,
    source: *Source,
    src_start: u32,
    src_end: u32,
    /// `length`: parameters before the first default or rest.
    length: u32,
    nparams: u16,
    nlocals: u32,
    max_stack: u32,
    stack_need_bytes: u32 = 0,
    strict: bool,
    is_arrow: bool,
    is_async: bool,
    is_generator: bool,
    has_prototype: bool,
    is_class_ctor: bool,
    is_derived: bool,
    /// Needs `this` coerced on entry (sloppy function that reads it).
    coerce_this: bool,
    needs_home: bool,
    is_method: bool,
    needs_args: bool = false,
    has_loop: bool = false,
    borrowed_code: bool = false,
    module: ?*module.Module = null,
    jit_fn: ?*const anyopaque = null,
    jit_fast_fn: ?*const anyopaque = null,
    catch_map: []CatchEntry = &.{},
    jit_cache_slot: ?*JitCacheSlot = null,
    hot_count: u16 = 0,
    jit_disabled: bool = false,

    pub const fast_entry_words = 24;

    pub inline fn findCatchWord(p: *const FuncProto, bc_pc: u32) ?u32 {
        for (p.catch_map) |ce| {
            if (ce.bc_pc == bc_pc) return ce.word_off;
        }
        return null;
    }

    pub inline fn setJitFn(p: *FuncProto, jfn: ?*const anyopaque) void {
        p.jit_fn = jfn;
        p.jit_fast_fn = if (jfn != null and !p.is_class_ctor and p.nlocals <= 256)
            @ptrFromInt(@intFromPtr(jfn.?) + fast_entry_words * @sizeOf(u32))
        else
            null;
    }

    pub fn trace(p: *FuncProto, m: *heap.Marker) void {
        m.markValues(p.constants);
        for (p.protos) |c| m.markCell(&c.cell);
        for (p.ics) |*ic| m.markKey(ic.key);
        if (p.ics.len != 0) m.protos.append(m.vm.raw_gpa, p) catch @panic("gc: out of memory");
        m.markStr(p.name);
        m.markCell(&p.source.cell);
        if (p.module) |mo| m.markCell(&mo.cell);
    }

    /// Theorem 51 (`NanoUI.Speedometer3Climb.single_pass_gc_sweep_and_warm_ic_sound`):
    /// Preserves warm inline caches across GC when their referenced cells remain live.
    pub fn sweepICs(p: *FuncProto) void {
        for (p.ics) |*ic| {
            const dead = (if (ic.shape) |s| !s.cell.marked else false) or
                (if (ic.holder) |h| !h.cell.marked else false) or
                (if (ic.holder_shape) |hs| !hs.cell.marked else false);
            if (dead) {
                ic.shape = null;
                ic.holder = null;
                ic.holder_shape = null;
                ic.epoch = 0;
                ic.is_accessor = false;
                ic.is_transition = false;
                ic.fast_own_data = false;
                ic.fast_proto_data = false;
                ic.proto_idx = 0;
                ic.proto_shapes = @splat(null);
            } else {
                for (&ic.proto_shapes) |*ps| {
                    if (ps.*) |s| if (!s.cell.marked) {
                        ps.* = null;
                    };
                }
            }
            for (&ic.own_shapes) |*os| {
                if (os.*) |s| if (!s.cell.marked) {
                    os.* = null;
                };
            }
        }
    }

    pub fn finalize(p: *FuncProto, gpa: Allocator) void {
        if (!p.borrowed_code) {
            gpa.free(p.code);
            gpa.free(p.lines);
            if (p.catch_map.len > 0) gpa.free(p.catch_map);
        }
        gpa.free(p.constants);
        gpa.free(p.protos);
        gpa.free(p.ics);
    }

    /// The source position of the instruction at or before pc.
    pub fn posOf(p: *const FuncProto, pc: u32) u32 {
        var lo: usize = 0;
        var hi: usize = p.lines.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (p.lines[mid].pc <= pc) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) p.src_start else p.lines[lo - 1].pos;
    }
};

/// The net stack effect of opcodes with a fixed one.
pub fn effect(op: Op) i32 {
    return switch (op) {
        .undef, .null_, .true_, .false_, .hole, .int8, .int32, .constant, .this, .callee, .new_target, .home, .arguments, .args_get, .args_len, .rest => 1,
        .args_elem => 0,
        .pop => -1,
        .dup => 1,
        .dup2 => 2,
        .swap, .rot3l, .rot3r => 0,
        .nip => -1,
        .insert2, .insert3 => 1,
        .get_loc, .get_loc_check, .get_env, .get_env_check, .get_global, .get_global_typeof, .get_import, .import_meta => 1,
        .put_loc, .put_loc_check, .put_env, .put_env_check, .init_global_lex, .def_global_fn => -1,
        .set_loc, .set_hole, .push_env, .pop_env, .clone_env, .put_global, .decl_global_var, .decl_global_lex => 0,
        .delete_global, .new_private, .new_object, .closure, .new_regexp => 1,
        .dynamic_import => 0,
        .get_field, .get_length => 0,
        .get_field2 => 1,
        .put_field, .get_elem, .delete_elem => -1,
        .get_elem2 => 0,
        .put_elem => -2,
        .super_get => -2,
        .super_put => -3,
        .define_field => -1,
        .define_elem, .define_method => -2,
        .set_proto => -1,
        .set_fn_name => 0,
        .get_private => -1,
        .put_private => -2,
        .define_private, .define_private_method => -2,
        .has_private => -1,
        .array_append, .array_spread, .object_spread => -1,
        .set_fields, .run_static => -1,
        .run_fields => -2,
        .add, .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr, .lt, .le, .gt, .ge, .eq, .ne, .seq, .sne, .instanceof_, .in_ => -1,
        .neg, .plus, .not, .bit_not, .inc, .dec, .typeof_, .to_numeric, .to_propkey, .to_str => 0,
        .jump, .loop, .opt_chain => 0,
        .jump_false, .jump_true, .jump_false_keep, .jump_true_keep, .jump_notnull_keep, .jump_not_undef => -1,
        .apply, .apply_new, .super_apply, .args_apply => -2,
        .get_super_ctor, .check_coercible, .nop => 0,
        .super_forward => 1,
        .check_super_once => -1,
        .ret => -1,
        .ret_undef, .throw_const => 0,
        .ctor_ret_check => 0,
        .throw_ => -1,
        .push_try => 2,
        .pop_try => -2,
        .gosub => 0,
        .ret_sub => -1,
        .iter_init, .async_iter_init => 2,
        .iter_next, .iter_step, .iter_rest, .async_iter_call => 1,
        .iter_close, .iter_drop => -3,
        .async_iter_close => -2,
        .iter_result => 0,
        .for_in_start => 1,
        .for_in_next => 1,
        .async_start, .initial_yield => 0,
        .yield_, .yield_raw, .await_ => 1,
        .resume_next, .resume_throw => -1,
        .delegate_get_iter => 1,
        .delegate_call => 0,
        .delegate_done => 0,
        .with_get, .with_put, .with_delete => -1,
        .with_get_call => -1,
        else => 0,
    };
}
