//! The JS object: a shape, named-property slots (four inline), dense elements with
//! holes, and a one-word class payload. Also the per-class tracing and finalizing the
//! collector calls, and small allocation helpers shared by the built-ins.

const std = @import("std");
const heap = @import("heap.zig");
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const shape_mod = @import("shape.zig");
const Shape = shape_mod.Shape;
const JSString = @import("string.zig").JSString;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const bc = @import("bytecode.zig");
const coroutine = @import("coroutine.zig");
const module = @import("module.zig");
const promise = @import("promise.zig");
const collections = @import("b_collections.zig");
const typed = @import("b_typed.zig");
const regexp = @import("b_regexp.zig");

pub const NativeFn = *const fn (vm: *Vm, this: Value, args: []const Value) Error!Value;

pub const Class = enum(u8) {
    object,
    array,
    closure,
    native,
    bound,
    @"error",
    boolean,
    number,
    string,
    symbol,
    bigint,
    date,
    regexp,
    map,
    set,
    weakmap,
    weakset,
    weakref,
    finreg,
    promise,
    proxy,
    arraybuffer,
    typedarray,
    dataview,
    generator,
    async_generator,
    arguments,
    host_exotic,
    module_ns,
    array_iter,
    map_iter,
    set_iter,
    string_iter,
    regexp_string_iter,
    async_from_sync,
    intl,
    wrap_iter,
};

pub const Flags = packed struct(u16) {
    extensible: bool = true,
    callable: bool = false,
    constructor: bool = false,
    /// Own-property behaviour differs from ordinary: proxy, typed array, string wrapper, ...
    exotic: bool = false,
    /// name/length/prototype not materialized yet.
    lazy_fn: bool = false,
    /// Index keys also live in the shape (sparse or with unusual attributes).
    has_sparse: bool = false,
    elems_frozen: bool = false,
    elems_sealed: bool = false,
    length_readonly: bool = false,
    class_ctor: bool = false,
    derived_ctor: bool = false,
    /// A native constructor made by vm.newClass: `new` makes `this` first.
    host_class: bool = false,
    /// `document.all`: an object that answers `typeof` as undefined, is false in
    /// a condition and `== null`, as the language keeps it for old pages.
    html_dda: bool = false,
    _pad: u3 = 0,
};

pub const NativeData = struct {
    func: NativeFn,
    name: *JSString,
    arity: u32,
    captures: []Value = &.{},
};

pub const BoundData = struct { target: *Object, this: Value, args: []Value };
pub const ProxyData = struct { target: ?*Object, handler: ?*Object };
/// A built-in iterator's state: what it walks, where it is, what it yields.
pub const IterData = struct { target: Value, aux: Value = Value.undefined, index: usize = 0, kind: u8 = 0, done: bool = false };
/// Extra state of closures that need it: methods with `super`, class constructors.
pub const FnExtra = struct { home: ?*Object = null, fields: Value = Value.undefined };

/// What a host exotic object answers. A null hook falls back to ordinary behaviour.
/// get_named returning null means "not one of mine": the ordinary lookup continues.
pub const HostHooks = struct {
    get_named: ?*const fn (vm: *Vm, obj: *Object, name: []const u8) Error!?Value = null,
    set_named: ?*const fn (vm: *Vm, obj: *Object, name: []const u8, value: Value) Error!bool = null,
    delete_named: ?*const fn (vm: *Vm, obj: *Object, name: []const u8) Error!bool = null,
    get_index: ?*const fn (vm: *Vm, obj: *Object, index: u32) Error!?Value = null,
    set_index: ?*const fn (vm: *Vm, obj: *Object, index: u32, value: Value) Error!bool = null,
    length_index: ?*const fn (vm: *Vm, obj: *Object) Error!u32 = null,
    /// Appends the names own-key enumeration should show (strings the host owns).
    own_names: ?*const fn (vm: *Vm, obj: *Object, out: *std.ArrayList(Value)) Error!void = null,
    /// Marks whatever this object's host data keeps alive in JS.
    trace: ?*const fn (obj: *Object, m: *heap.Marker) void = null,
    /// Called once when the wrapper is collected.
    finalize: ?*const fn (obj: *Object) void = null,
};

pub const Payload = extern union {
    none: u64,
    value: Value,
    number: f64,
    fp: *bc.FuncProto,
    native: *NativeData,
    bound: *BoundData,
    proxy: *ProxyData,
    iter: *IterData,
    hooks: *const HostHooks,
    map: *collections.MapData,
    weak: *collections.WeakData,
    promise: *promise.PromiseData,
    regexp: *regexp.RegExpData,
    buffer: *typed.BufferData,
    typed: *typed.TypedData,
    co: *coroutine.Coroutine,
    agen: *coroutine.AsyncGen,
    module: *module.Module,
};

pub const inline_slots = 4;

pub const Object = struct {
    cell: heap.Cell,
    class: Class,
    flags: Flags,
    host_tag: u32,
    shape: *Shape,
    slots: [*]Value,
    elems: [*]Value,
    slot_cap: u32,
    elems_len: u32,
    elems_cap: u32,
    /// The array `length`; may pass elems_len when the tail is holes or sparse.
    arr_len: u32,
    payload: Payload,
    env: ?*heap.Env,
    host: ?*anyopaque,
    inline_store: [inline_slots]Value,

    pub inline fn proto(o: *const Object) ?*Object {
        return o.shape.proto;
    }
    pub inline fn value(o: *Object) Value {
        return Value.fromObject(o);
    }
    pub inline fn isArray(o: *const Object) bool {
        return o.class == .array;
    }
    /// The closure's extra record, which `host` holds for closures.
    pub inline fn extra(o: *const Object) ?*FnExtra {
        return @ptrCast(@alignCast(o.host));
    }

    // The embedding API's convenience accessors; see js.zig.
    pub fn get(o: *Object, vm: *Vm, name: []const u8) Error!Value {
        return vm.getNamed(o, name);
    }
    pub fn set(o: *Object, vm: *Vm, name: []const u8, v: Value) Error!void {
        return vm.setNamed(o, name, v);
    }
    pub fn getIdx(o: *Object, vm: *Vm, i: u32) Error!Value {
        return vm.getIndexed(o, i);
    }
    pub fn setIdx(o: *Object, vm: *Vm, i: u32, v: Value) Error!void {
        return vm.setIndexed(o, i, v);
    }
    pub fn defineMethod(o: *Object, vm: *Vm, name: []const u8, arity: u32, f: NativeFn) Error!void {
        return vm.defineMethodOn(o, name, arity, f);
    }
    pub fn defineAccessor(o: *Object, vm: *Vm, name: []const u8, getter: ?NativeFn, setter: ?NativeFn) Error!void {
        return vm.defineAccessorOn(o, name, getter, setter);
    }
    pub fn defineData(o: *Object, vm: *Vm, name: []const u8, v: Value, flags: shape_mod.PropFlags) Error!void {
        return vm.defineDataOn(o, name, v, flags);
    }
};

/// Allocates an object with the given shape; every other field starts empty.
pub fn alloc(vm: *Vm, shape: *Shape, class: Class) Error!*Object {
    const o = try vm.heap.create(Object, .object);
    o.class = class;
    o.flags = .{};
    o.host_tag = 0;
    o.shape = shape;
    o.slots = &o.inline_store;
    o.elems = undefined;
    o.slot_cap = inline_slots;
    o.elems_len = 0;
    o.elems_cap = 0;
    o.arr_len = 0;
    o.payload = .{ .none = 0 };
    o.env = null;
    o.host = null;
    return o;
}

/// An object whose own-property behaviour is special, in the shape tree only such objects use.
pub fn createExotic(vm: *Vm, proto: ?*Object, class: Class) Error!*Object {
    const o = try alloc(vm, try shape_mod.exoticRootFor(vm, proto), class);
    o.flags.exotic = true;
    return o;
}

/// A plain object with the given prototype.
pub fn create(vm: *Vm, proto: ?*Object, class: Class) Error!*Object {
    return alloc(vm, try shape_mod.rootFor(vm, proto), class);
}

pub fn newPlain(vm: *Vm) Error!*Object {
    return alloc(vm, vm.object_root, .object);
}

/// Grows named-property storage to at least n slots.
pub fn growSlots(vm: *Vm, o: *Object, n: u32) Error!void {
    if (n <= o.slot_cap) return;
    const cap = @max(n, o.slot_cap * 2);
    const mem = try vm.gpa.alloc(Value, cap);
    @memcpy(mem[0..o.slot_cap], o.slots[0..o.slot_cap]);
    if (o.slots != @as([*]Value, &o.inline_store)) vm.gpa.free(o.slots[0..o.slot_cap]);
    o.slots = mem.ptr;
    o.slot_cap = cap;
}

/// Grows dense storage to hold at least n elements. Does not change elems_len.
pub fn growElems(vm: *Vm, o: *Object, n: usize) Error!void {
    if (n <= o.elems_cap) return;
    if (n > 0x7FFF_FFFF) return vm.throwError(.RangeError, "Invalid array length");
    const cap: usize = @max(n, @as(usize, o.elems_cap) + @as(usize, o.elems_cap) / 2 + 4);
    if (o.elems_cap == 0) {
        const mem = try vm.gpa.alloc(Value, cap);
        o.elems = mem.ptr;
    } else {
        const mem = try vm.gpa.realloc(o.elems[0..o.elems_cap], cap);
        o.elems = mem.ptr;
    }
    o.elems_cap = @intCast(cap);
}

pub fn newArray(vm: *Vm, values: []const Value) Error!*Object {
    const a = try alloc(vm, vm.array_root, .array);
    if (values.len != 0) {
        try growElems(vm, a, values.len);
        @memcpy(a.elems[0..values.len], values);
        a.elems_len = @intCast(values.len);
        a.arr_len = a.elems_len;
    }
    return a;
}

/// Appends to a real array that has no sparse tail (one the engine just made).
pub fn arrayPush(vm: *Vm, a: *Object, v: Value) Error!void {
    if (a.elems_len == a.elems_cap) try growElems(vm, a, @as(usize, a.elems_len) + 1);
    a.elems[a.elems_len] = v;
    a.elems_len += 1;
    a.arr_len = a.elems_len;
}

pub fn trace(m: *heap.Marker, o: *Object) void {
    m.markCell(&o.shape.cell);
    m.markValues(o.slots[0..o.shape.count]);
    if (o.elems_len != 0) m.markValues(o.elems[0..o.elems_len]);
    if (o.env) |e| m.markCell(&e.cell);
    switch (o.class) {
        .closure => {
            m.markCell(&o.payload.fp.cell);
            if (o.extra()) |x| {
                m.markObj(x.home);
                m.mark(x.fields);
            }
        },
        .native => {
            m.markStr(o.payload.native.name);
            m.markValues(o.payload.native.captures);
        },
        .bound => {
            const b = o.payload.bound;
            m.markObj(b.target);
            m.mark(b.this);
            m.markValues(b.args);
        },
        .proxy => {
            m.markObj(o.payload.proxy.target);
            m.markObj(o.payload.proxy.handler);
        },
        .boolean, .number, .string, .symbol, .bigint => m.mark(o.payload.value),
        .array_iter, .map_iter, .set_iter, .string_iter, .regexp_string_iter, .async_from_sync, .wrap_iter => {
            m.mark(o.payload.iter.target);
            m.mark(o.payload.iter.aux);
        },
        .map, .set => o.payload.map.trace(m),
        .weakmap, .weakset, .weakref, .finreg => m.weak.append(m.vm.raw_gpa, o) catch @panic("gc: out of memory"),
        .promise => o.payload.promise.trace(m),
        .regexp => o.payload.regexp.trace(m),
        .typedarray, .dataview => m.markObj(o.payload.typed.buffer),
        .generator => m.markCell(&o.payload.co.cell),
        .async_generator => o.payload.agen.trace(m),
        .module_ns => m.markCell(&o.payload.module.cell),
        .host_exotic => if (o.payload.hooks.trace) |t| t(o, m),
        else => {},
    }
}

/// One ephemeron pass over a weak container; true if anything new was marked.
pub fn traceWeak(m: *heap.Marker, o: *Object) bool {
    return switch (o.class) {
        .weakmap, .weakset, .weakref, .finreg => o.payload.weak.traceWeak(m),
        else => false,
    };
}

pub fn sweepWeak(vm: *Vm, o: *Object) void {
    switch (o.class) {
        .weakmap, .weakset, .weakref, .finreg => o.payload.weak.sweep(vm),
        else => {},
    }
}

pub fn finalize(vm: *Vm, o: *Object) void {
    const gpa = vm.gpa;
    if (o.host != null and o.class != .closure) {
        if (vm.host_finalizer) |f| f(o);
    }
    if (o.slots != @as([*]Value, &o.inline_store)) gpa.free(o.slots[0..o.slot_cap]);
    if (o.elems_cap != 0) gpa.free(o.elems[0..o.elems_cap]);
    switch (o.class) {
        .closure => {
            if (o.extra()) |x| gpa.destroy(x);
            return;
        },
        .native => {
            gpa.free(o.payload.native.captures);
            gpa.destroy(o.payload.native);
        },
        .bound => {
            gpa.free(o.payload.bound.args);
            gpa.destroy(o.payload.bound);
        },
        .proxy => gpa.destroy(o.payload.proxy),
        .array_iter, .map_iter, .set_iter, .string_iter, .regexp_string_iter, .async_from_sync, .wrap_iter => gpa.destroy(o.payload.iter),
        .map, .set => o.payload.map.destroy(gpa),
        .weakmap, .weakset, .weakref, .finreg => o.payload.weak.destroy(gpa),
        .promise => o.payload.promise.destroy(gpa),
        .regexp => o.payload.regexp.destroy(gpa),
        .arraybuffer => o.payload.buffer.destroy(gpa),
        .typedarray, .dataview => gpa.destroy(o.payload.typed),
        .async_generator => o.payload.agen.destroy(gpa),
        .host_exotic => if (o.payload.hooks.finalize) |f| f(o),
        else => {},
    }
}
