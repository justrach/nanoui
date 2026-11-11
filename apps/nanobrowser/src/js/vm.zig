//! The VM: every root the engine owns (global object, intrinsic prototypes, interned
//! names, job queue, value stack, frames), creation and teardown, and the embedding
//! API's methods, most of which live in vm_api.zig and are re-exported here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const heap = @import("heap.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const Symbol = str.Symbol;
const shape = @import("shape.zig");
const Shape = shape.Shape;
const objmod = @import("object.zig");
const Object = objmod.Object;
const frames = @import("frame.zig");
const api = @import("vm_api.zig");
const builtins = @import("builtins.zig");
const promise = @import("promise.zig");
const module = @import("module.zig");
const regexp_compile = @import("regexp_compile.zig");
const b_regexp = @import("b_regexp.zig");
const jit = @import("jit.zig");

pub const Error = error{ Thrown, Terminated, OutOfMemory };

pub const ErrorKind = enum(u8) { Error, TypeError, RangeError, SyntaxError, ReferenceError, EvalError, URIError, AggregateError };

/// Pre-interned property keys; each field's name is its text.
pub const Names = struct {
    length: PropKey = PropKey.none,
    name: PropKey = PropKey.none,
    prototype: PropKey = PropKey.none,
    constructor: PropKey = PropKey.none,
    __proto__: PropKey = PropKey.none,
    value: PropKey = PropKey.none,
    done: PropKey = PropKey.none,
    next: PropKey = PropKey.none,
    @"return": PropKey = PropKey.none,
    throw: PropKey = PropKey.none,
    then: PropKey = PropKey.none,
    get: PropKey = PropKey.none,
    set: PropKey = PropKey.none,
    has: PropKey = PropKey.none,
    enumerable: PropKey = PropKey.none,
    configurable: PropKey = PropKey.none,
    writable: PropKey = PropKey.none,
    message: PropKey = PropKey.none,
    cause: PropKey = PropKey.none,
    stack: PropKey = PropKey.none,
    errors: PropKey = PropKey.none,
    toString: PropKey = PropKey.none,
    valueOf: PropKey = PropKey.none,
    toJSON: PropKey = PropKey.none,
    join: PropKey = PropKey.none,
    index: PropKey = PropKey.none,
    input: PropKey = PropKey.none,
    groups: PropKey = PropKey.none,
    indices: PropKey = PropKey.none,
    lastIndex: PropKey = PropKey.none,
    source: PropKey = PropKey.none,
    flags: PropKey = PropKey.none,
    exec: PropKey = PropKey.none,
    raw: PropKey = PropKey.none,
    callee: PropKey = PropKey.none,
    proxy: PropKey = PropKey.none,
    revoke: PropKey = PropKey.none,
    status: PropKey = PropKey.none,
    reason: PropKey = PropKey.none,
    resolve: PropKey = PropKey.none,
    undefined: PropKey = PropKey.none,
    default: PropKey = PropKey.none,
    this: PropKey = PropKey.none,
    arguments: PropKey = PropKey.none,
    eval: PropKey = PropKey.none,
    await: PropKey = PropKey.none,
    yield: PropKey = PropKey.none,
    let: PropKey = PropKey.none,
    static: PropKey = PropKey.none,
    implements: PropKey = PropKey.none,
    interface: PropKey = PropKey.none,
    package: PropKey = PropKey.none,
    private: PropKey = PropKey.none,
    protected: PropKey = PropKey.none,
    public: PropKey = PropKey.none,
    async: PropKey = PropKey.none,
    of: PropKey = PropKey.none,
    target: PropKey = PropKey.none,
    meta: PropKey = PropKey.none,
    as: PropKey = PropKey.none,
    from: PropKey = PropKey.none,
    url: PropKey = PropKey.none,
    @"new.target": PropKey = PropKey.none,
    @"%home": PropKey = PropKey.none,
    @"%func": PropKey = PropKey.none,
    @"#constructor": PropKey = PropKey.none,
    @"*default*": PropKey = PropKey.none,
    number: PropKey = PropKey.none,
    string: PropKey = PropKey.none,
    object: PropKey = PropKey.none,
    function: PropKey = PropKey.none,
    boolean: PropKey = PropKey.none,
    symbol: PropKey = PropKey.none,
    bigint: PropKey = PropKey.none,
    null: PropKey = PropKey.none,
    true: PropKey = PropKey.none,
    false: PropKey = PropKey.none,
    NaN: PropKey = PropKey.none,
    Infinity: PropKey = PropKey.none,
    @"-Infinity": PropKey = PropKey.none,
    fulfilled: PropKey = PropKey.none,
    rejected: PropKey = PropKey.none,
    pending: PropKey = PropKey.none,
    anonymous: PropKey = PropKey.none,
    @"[object Object]": PropKey = PropKey.none,
};

pub const WellKnown = struct {
    iterator: *Symbol = undefined,
    asyncIterator: *Symbol = undefined,
    hasInstance: *Symbol = undefined,
    toPrimitive: *Symbol = undefined,
    toStringTag: *Symbol = undefined,
    species: *Symbol = undefined,
    isConcatSpreadable: *Symbol = undefined,
    match: *Symbol = undefined,
    matchAll: *Symbol = undefined,
    replace: *Symbol = undefined,
    search: *Symbol = undefined,
    split: *Symbol = undefined,
    unscopables: *Symbol = undefined,
};

pub const typed_kinds = 11;

/// Intrinsic objects, kept here so their identity survives user code changing globals.
pub const Protos = struct {
    object: *Object = undefined,
    function: *Object = undefined,
    array: *Object = undefined,
    string: *Object = undefined,
    number: *Object = undefined,
    boolean: *Object = undefined,
    symbol: *Object = undefined,
    bigint: *Object = undefined,
    errors: [8]*Object = undefined,
    iterator: *Object = undefined,
    async_iterator: *Object = undefined,
    array_iter: *Object = undefined,
    map_iter: *Object = undefined,
    set_iter: *Object = undefined,
    string_iter: *Object = undefined,
    regexp_string_iter: *Object = undefined,
    async_from_sync: *Object = undefined,
    generator: *Object = undefined,
    async_generator: *Object = undefined,
    generator_function: *Object = undefined,
    async_function: *Object = undefined,
    async_generator_function: *Object = undefined,
    promise: *Object = undefined,
    regexp: *Object = undefined,
    date: *Object = undefined,
    map: *Object = undefined,
    set: *Object = undefined,
    weakmap: *Object = undefined,
    weakset: *Object = undefined,
    weakref: *Object = undefined,
    finreg: *Object = undefined,
    arraybuffer: *Object = undefined,
    typed_array: *Object = undefined,
    typed: [typed_kinds]*Object = undefined,
    dataview: *Object = undefined,
    // Constructors that algorithms need by identity.
    promise_ctor: *Object = undefined,
    array_ctor: *Object = undefined,
    regexp_ctor: *Object = undefined,
    arraybuffer_ctor: *Object = undefined,
    typed_ctor: [typed_kinds]*Object = undefined,
    array_values: *Object = undefined,
    array_iter_next: *Object = undefined,
    regexp_exec: *Object = undefined,
};

pub const max_frames = 12000;
pub const stack_slots = 1024 * 1024;
pub const mega_ic_size = 8192;

pub const MegaICEntry = extern struct {
    pub const acc_flag: u32 = 0x8000_0000;
    shape: ?*Shape = null,
    key_bits: u64 = 0,
    holder: ?*Object = null,
    holder_shape: ?*Shape = null,
    slot: u32 = 0,
    epoch: u32 = 0,
};

threadlocal var cached_stacks: [2]?[]Value = .{ null, null };
threadlocal var cached_frames: [2]?[]frames.Frame = .{ null, null };

/// Whole pages straight from the OS, left untouched so they commit only when reached.
fn pages(comptime T: type, n: usize) Error![]T {
    const a = std.heap.page_allocator;
    const raw = a.rawAlloc(n * @sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
    const p: [*]T = @ptrCast(@alignCast(raw));
    return p[0..n];
}

fn allocStack() Error![]Value {
    for (&cached_stacks) |*slot| {
        if (slot.*) |s| {
            slot.* = null;
            return s;
        }
    }
    return pages(Value, stack_slots);
}

fn freeStack(s: []Value) void {
    for (&cached_stacks) |*slot| {
        if (slot.* == null) {
            slot.* = s;
            return;
        }
    }
    std.heap.page_allocator.free(s);
}

fn allocFrames() Error![]frames.Frame {
    for (&cached_frames) |*slot| {
        if (slot.*) |f| {
            slot.* = null;
            return f;
        }
    }
    return pages(frames.Frame, max_frames);
}

fn freeFrames(f: []frames.Frame) void {
    for (&cached_frames) |*slot| {
        if (slot.* == null) {
            slot.* = f;
            return;
        }
    }
    std.heap.page_allocator.free(f);
}

pub const Vm = struct {
    gpa: Allocator,
    raw_gpa: Allocator,
    counting: heap.Counting,
    heap: heap.Heap,
    atoms: std.StringHashMapUnmanaged(*JSString) = .empty,
    root_shapes: std.AutoHashMapUnmanaged(?*Object, *Shape) = .empty,
    exotic_root_shapes: std.AutoHashMapUnmanaged(?*Object, *Shape) = .empty,
    k: Names = .{},
    sym: WellKnown = .{},
    protos: Protos = .{},
    symbol_registry: std.StringHashMapUnmanaged(*Symbol) = .empty,
    object_root: *Shape = undefined,
    array_root: *Shape = undefined,
    fn_root: *Shape = undefined,
    iter_result_shape: *Shape = undefined,
    args_strict_shape: *Shape = undefined,
    args_sloppy_shape: *Shape = undefined,
    regexp_shape: *Shape = undefined,
    regexp_match_shape: *Shape = undefined,
    function_has_instance: *Object = undefined,
    intl_protos: [6]*Object = undefined,
    regex_cache: std.StringHashMapUnmanaged(*regexp_compile.Program) = .empty,
    global_obj: *Object = undefined,
    global_lex: *Object = undefined,
    empty: *JSString = undefined,
    char_strs: [128]*JSString = undefined,
    kw_atoms: [37]?*JSString = @splat(null),

    // Execution state.
    stack: []Value = &.{},
    stack_end: usize = 0,
    sp: [*]Value = undefined,
    frames: []frames.Frame = &.{},
    frame_top: u32 = 0,
    fast_call_stub: ?*const anyopaque = null,
    fast_getter_stub: ?*const anyopaque = null,
    fast_args_apply_stub: ?*const anyopaque = null,
    /// Native re-entry depth; the native stack limit is set when it is zero.
    depth: u32 = 0,
    stack_limit: usize = 0,
    /// How much native stack JS may use. The host may lower this on a small thread.
    max_native_stack: usize = 4 * 1024 * 1024,
    exception: Value = Value.undefined,
    /// In a native called by `new`: the new.target; otherwise undefined.
    new_target: Value = Value.undefined,
    /// The native function being called, for captures.
    callee: ?*Object = null,

    // Interrupt.
    budget: i32 = interrupt_interval,
    deadline: ?u64 = null,

    // Promises.
    jobs: std.ArrayList(promise.Job) = .empty,
    jobs_head: usize = 0,
    rejection_hook: ?promise.RejectionHook = null,
    rejection_ctx: ?*anyopaque = null,
    pending_rejections: std.ArrayList(*Object) = .empty,

    // Host hooks.
    roots_ctx: ?*anyopaque = null,
    roots_fn: ?*const fn (ctx: ?*anyopaque, m: *heap.Marker) void = null,
    protected: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    import_ctx: ?*anyopaque = null,
    import_fn: ?module.ImportHook = null,
    /// Minutes east of UTC for a UTC time in ms; null means UTC.
    tz_offset_fn: ?*const fn (utc_ms: f64) f64 = null,
    /// Called when an object with host data is collected, before it is freed.
    host_finalizer: ?*const fn (obj: *Object) void = null,
    modules: std.ArrayList(*module.Module) = .empty,

    /// The host's heap limit. The live limit may sit a little above it after an
    /// out-of-memory error, so catch blocks can run; a collection brings it back.
    heap_limit: usize = 2 * 1024 * 1024 * 1024,

    /// Math.random state.
    rng: u64 = 0x9E3779B97F4A7C15,
    /// Scratch for JSON and join cycle detection.
    visiting: std.ArrayList(*Object) = .empty,
    /// Bumped whenever an object with `flags.is_proto` changes shape or prototype,
    /// invalidating multi-hop prototype inline cache entries in O(1).
    proto_epoch: u32 = 1,
    jit_pool: jit.JitPool = .{},
    mega_ic: *[mega_ic_size]MegaICEntry = undefined,

    pub const interrupt_interval = 16384;

    pub inline fn bumpProtoEpoch(vm: *Vm) void {
        vm.proto_epoch +%= 1;
        if (vm.proto_epoch == 0) vm.proto_epoch = 1;
    }

    pub inline fn clearMegaIC(vm: *Vm) void {
        @memset(vm.mega_ic, .{});
    }

    pub inline fn megaSlot(vm: *Vm, sh: *const Shape, key_bits: u64) *MegaICEntry {
        const h = ((@intFromPtr(sh) >> 4) ^ (key_bits >> 3) ^ (key_bits >> 19)) & (mega_ic_size - 1);
        return &vm.mega_ic[h];
    }

    pub fn create(gpa_in: Allocator) Error!*Vm {
        const vm = try gpa_in.create(Vm);
        errdefer gpa_in.destroy(vm);
        const mega = try gpa_in.create([mega_ic_size]MegaICEntry);
        errdefer gpa_in.destroy(mega);
        @memset(mega, .{});
        vm.* = .{
            .gpa = undefined,
            .raw_gpa = gpa_in,
            .counting = .{ .gpa = gpa_in },
            .heap = undefined,
            .mega_ic = mega,
        };
        vm.gpa = vm.counting.allocator();
        vm.heap = .{ .gpa = vm.gpa };
        vm.stack = try allocStack();
        vm.stack_end = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
        vm.sp = vm.stack.ptr;
        vm.frames = try allocFrames();
        vm.fast_call_stub = jit.getFastCallStub();
        vm.fast_getter_stub = jit.getFastGetterStub();
        vm.fast_args_apply_stub = jit.getFastArgsApplyStub();
        try vm.initStrings();
        try builtins.init(vm);
        vm.protos.object.flags.proto_dirty = false;
        vm.protos.array.flags.proto_dirty = false;
        vm.protos.array_ctor.flags.is_proto = true;
        vm.protos.array_ctor.flags.proto_dirty = false;
        vm.protos.array_iter.flags.proto_dirty = false;
        vm.protos.regexp.flags.proto_dirty = false;
        vm.protos.string.flags.is_proto = true;
        vm.protos.number.flags.is_proto = true;
        vm.protos.boolean.flags.is_proto = true;
        return vm;
    }

    fn initStrings(vm: *Vm) Error!void {
        const e = try vm.heap.create(JSString, .string);
        e.* = .{ .cell = e.cell, .is_ascii = true, .is_atom = true, .byte_len = 0, .len16 = 0, .ptr = &e.inline_buf };
        e.key = PropKey.fromAtom(e);
        try vm.atoms.put(vm.gpa, e.inline_buf[0..0], e);
        vm.empty = e;
        var i: usize = 0;
        while (i < 128) : (i += 1) {
            const c = try vm.heap.create(JSString, .string);
            c.* = .{ .cell = c.cell, .is_ascii = true, .is_atom = true, .owns = false, .byte_len = 1, .len16 = 1, .ptr = &c.inline_buf };
            c.inline_buf[0] = @intCast(i);
            c.key = if (i >= '0' and i <= '9') PropKey.fromIndex(@intCast(i - '0')) else PropKey.fromAtom(c);
            try vm.atoms.put(vm.gpa, c.inline_buf[0..1], c);
            vm.char_strs[i] = c;
        }
        inline for (@typeInfo(Names).@"struct".field_names) |n| {
            @field(vm.k, n) = PropKey.fromAtom(try str.intern(vm, n));
        }
        inline for (@typeInfo(WellKnown).@"struct".field_names) |n| {
            const d = try str.intern(vm, "Symbol." ++ n);
            @field(vm.sym, n) = try str.newSymbol(vm, d);
        }
    }

    pub fn deinit(vm: *Vm) void {
        const raw = vm.raw_gpa;
        b_regexp.clearCache(vm);
        vm.regex_cache.deinit(vm.gpa);
        heap.freeAll(vm);
        vm.pending_rejections.deinit(vm.gpa);
        vm.atoms.deinit(vm.gpa);
        vm.root_shapes.deinit(vm.gpa);
        vm.exotic_root_shapes.deinit(vm.gpa);
        var it = vm.symbol_registry.keyIterator();
        while (it.next()) |k| vm.gpa.free(k.*);
        vm.symbol_registry.deinit(vm.gpa);
        vm.jobs.deinit(vm.gpa);
        vm.protected.deinit(vm.gpa);
        vm.modules.deinit(vm.gpa);
        vm.visiting.deinit(vm.gpa);
        vm.jit_pool.deinit(raw);
        freeStack(vm.stack);
        freeFrames(vm.frames);
        raw.destroy(vm.mega_ic);
        raw.destroy(vm);
    }

    /// Marks everything the VM itself keeps alive.
    pub fn markRoots(vm: *Vm, m: *heap.Marker) void {
        m.markObj(vm.global_obj);
        m.markObj(vm.global_lex);
        m.mark(vm.exception);
        m.markStr(vm.empty);
        for (vm.char_strs) |s| m.markStr(s);
        for (vm.kw_atoms) |s| if (s) |a| m.markStr(a);
        inline for (@typeInfo(Names).@"struct".field_names) |n| m.markKey(@field(vm.k, n));
        inline for (@typeInfo(WellKnown).@"struct".field_names) |n| m.markCell(&@field(vm.sym, n).cell);
        inline for (@typeInfo(Protos).@"struct".field_names) |n| {
            const f = @field(vm.protos, n);
            if (@TypeOf(f) == *Object) {
                m.markObj(f);
            } else {
                for (f) |o| m.markObj(o);
            }
        }
        m.markCell(&vm.object_root.cell);
        m.markCell(&vm.array_root.cell);
        m.markCell(&vm.fn_root.cell);
        m.markObj(vm.function_has_instance);
        for (vm.intl_protos) |o| m.markObj(o);
        for (vm.pending_rejections.items) |o| m.markObj(o);
        m.markCell(&vm.iter_result_shape.cell);
        m.markCell(&vm.args_strict_shape.cell);
        m.markCell(&vm.args_sloppy_shape.cell);
        m.markCell(&vm.regexp_shape.cell);
        m.markCell(&vm.regexp_match_shape.cell);
        var it = vm.symbol_registry.valueIterator();
        while (it.next()) |s| m.markCell(&s.*.cell);
        var pi = vm.protected.keyIterator();
        while (pi.next()) |k| m.mark(.{ .bits = k.* });
        for (vm.jobs.items[vm.jobs_head..]) |*j| j.trace(m);
        for (vm.modules.items) |mo| m.markCell(&mo.cell);
        if (vm.roots_fn) |f| f(vm.roots_ctx, m);
    }

    /// Throws RangeError unless there is native stack to spare.
    pub inline fn checkNativeStack(vm: *Vm) Error!void {
        if (@frameAddress() < vm.stack_limit) return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    }

    /// Records where the native stack starts when JS is entered from outside.
    pub inline fn enterFromHost(vm: *Vm) void {
        if (vm.depth == 0) vm.stack_limit = @frameAddress() -| vm.max_native_stack;
    }

    // Errors.
    pub const throwError = api.throwError;
    pub const throwValue = api.throwValue;
    pub const exceptionString = api.exceptionString;
    // Scripts and modules.
    pub const eval = api.eval;
    pub const compileModule = module.compile;
    pub const linkModule = module.link;
    pub const evaluateModule = module.evaluate;
    pub const setDynamicImportHook = api.setDynamicImportHook;
    // Tasks.
    pub const runJobs = promise.runJobs;
    pub const setRejectionHook = promise.setRejectionHook;
    pub const setDeadline = api.setDeadline;
    pub const collect = heap.collect;
    pub const setRootsHook = api.setRootsHook;
    pub const protect = api.protect;
    pub const unprotect = api.unprotect;
    pub const bytesAllocated = api.bytesAllocated;
    pub const setHeapLimit = api.setHeapLimit;
    pub const global = api.global;
    // Values.
    pub const newString = api.newString;
    pub const internString = api.internString;
    pub const toStringSlice = api.toStringSlice;
    pub const toNumber = api.toNumber;
    pub const toBoolean = api.toBoolean;
    pub const typeOf = api.typeOf;
    pub const newObject = api.newObject;
    pub const newObjectWithProto = api.newObjectWithProto;
    pub const newArray = api.newArray;
    pub const newNative = api.newNative;
    pub const newNativeClosure = api.newNativeClosure;
    pub const capture = api.capture;
    pub const newClass = api.newClass;
    pub const newExoticObject = api.newExoticObject;
    pub const call = api.call;
    pub const construct = api.construct;
    pub const newPromiseCapability = api.newPromiseCapability;
    pub const resolvePromise = api.resolvePromise;
    pub const rejectPromise = api.rejectPromise;
    // Object helpers behind Object.get and friends.
    pub const getNamed = api.getNamed;
    pub const setNamed = api.setNamed;
    pub const getIndexed = api.getIndexed;
    pub const setIndexed = api.setIndexed;
    pub const defineMethodOn = api.defineMethodOn;
    pub const defineAccessorOn = api.defineAccessorOn;
    pub const defineAccessorValueOn = api.defineAccessorValueOn;
    pub const defineDataOn = api.defineDataOn;
};
