//! The embedding API's implementation: scripts, errors, value constructors and object
//! helpers. js.zig documents the surface; the Vm re-exports these as methods.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const ErrorKind = vm_mod.ErrorKind;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const NativeFn = objmod.NativeFn;
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const shape = @import("shape.zig");
const PropFlags = shape.PropFlags;
const bc = @import("bytecode.zig");
const parser = @import("parser.zig");
const scope = @import("scope.zig");
const compiler = @import("compiler.zig");
const calls = @import("interp_call.zig");
const interp_object = @import("interp_object.zig");
const promise = @import("promise.zig");
const module = @import("module.zig");
const b_error = @import("b_error.zig");

pub fn newSource(vm: *Vm, source: []const u8, name: []const u8) Error!*bc.Source {
    const text = try vm.gpa.dupe(u8, source);
    errdefer vm.gpa.free(text);
    const nm = try vm.gpa.dupe(u8, name);
    errdefer vm.gpa.free(nm);
    const s = try vm.heap.create(bc.Source, .source);
    s.text = text;
    s.name = nm;
    s.line_starts = &.{};
    return s;
}

/// Compiles a classic script or eval source to a closure, without running it.
pub fn compileScript(vm: *Vm, source: []const u8, filename: []const u8, mode: scope.Mode) Error!*Object {
    vm.enterFromHost();
    var arena = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prog = try parser.parseProgram(vm, a, source, .{ .is_eval = mode == .eval });
    const r = try scope.analyze(vm, a, &prog, source, mode);
    const src = try newSource(vm, source, filename);
    const c = try compiler.compileProgram(vm, a, &prog, r, src);
    return interp_object.makeClosure(vm, c.main, null);
}

/// Runs a classic script; the result is its completion value.
pub fn eval(vm: *Vm, source: []const u8, filename: []const u8) Error!Value {
    vm.enterFromHost();
    const f = compileScript(vm, source, filename, .script) catch |e| return finishEntry(vm, e);
    return calls.call(vm, f.value(), vm.global_obj.value(), &.{}) catch |e| return finishEntry(vm, e);
}

/// Natives may leave OutOfMemory; the host sees it as a thrown RangeError.
fn finishEntry(vm: *Vm, e: Error) Error {
    if (e == error.OutOfMemory) {
        throwOutOfMemory(vm);
        return error.Thrown;
    }
    return e;
}

/// Sets vm.exception to a RangeError, with slack past the heap limit to allocate it.
pub fn throwOutOfMemory(vm: *Vm) void {
    const saved = vm.counting.limit;
    vm.counting.limit = saved + 64 * 1024 * 1024;
    vm.exception = makeError(vm, .RangeError, "Out of memory: JS heap limit reached") catch Value.null;
    // Nothing can be freed until the task ends, so catch blocks get a little room to run.
    const grace = 1024 * 1024;
    vm.counting.limit = if (saved < vm.heap_limit + 64 * grace) saved + grace else saved;
}

pub fn makeError(vm: *Vm, kind: ErrorKind, msg: []const u8) Error!Value {
    return b_error.create(vm, kind, msg);
}

/// Sets vm.exception to a new error of this kind and returns error.Thrown.
pub fn throwError(vm: *Vm, kind: ErrorKind, msg: []const u8) Error {
    vm.exception = try makeError(vm, kind, msg);
    return error.Thrown;
}

pub fn throwValue(vm: *Vm, v: Value) Error {
    vm.exception = v;
    return error.Thrown;
}

/// Formats vm.exception (message and stack) for a console. The slice lives in the JS heap.
pub fn exceptionString(vm: *Vm) []const u8 {
    const ex = vm.exception;
    const saved = ex;
    defer vm.exception = saved;
    if (ex.isObject()) {
        const st = props.get(vm, ex.asObject(), vm.k.stack) catch Value.undefined;
        if (st.isString()) return st.asString().flat(vm) catch "Uncaught exception";
    }
    const s = conv.toStr(vm, ex) catch return "Uncaught exception";
    return s.flat(vm) catch "Uncaught exception";
}

pub fn setDynamicImportHook(vm: *Vm, ctx: ?*anyopaque, hook: ?module.ImportHook) void {
    vm.import_ctx = ctx;
    vm.import_fn = hook;
}

/// After ns nanoseconds, running JS throws an uncatchable termination. 0 clears it.
pub fn setDeadline(vm: *Vm, ns: u64) void {
    vm.deadline = if (ns == 0) null else conv.monotonicNs() + ns;
    vm.budget = @min(vm.budget, Vm.interrupt_interval);
}

pub fn setRootsHook(vm: *Vm, ctx: ?*anyopaque, f: ?*const fn (ctx: ?*anyopaque, m: *heap.Marker) void) void {
    vm.roots_ctx = ctx;
    vm.roots_fn = f;
}

/// Keeps a value alive across collections. Counted: unprotect once per protect.
pub fn protect(vm: *Vm, v: Value) Error!void {
    if (v.heapCell() == null) return;
    const gop = try vm.protected.getOrPut(vm.gpa, v.bits);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

pub fn unprotect(vm: *Vm, v: Value) void {
    const p = vm.protected.getPtr(v.bits) orelse return;
    p.* -= 1;
    if (p.* == 0) _ = vm.protected.remove(v.bits);
}

pub fn bytesAllocated(vm: *const Vm) usize {
    return vm.counting.bytes;
}

pub fn setHeapLimit(vm: *Vm, bytes: usize) void {
    vm.heap_limit = bytes;
    vm.counting.limit = bytes;
}

pub fn global(vm: *Vm) *Object {
    return vm.global_obj;
}

pub fn newString(vm: *Vm, utf8: []const u8) Error!Value {
    return Value.fromString(try str.fromUtf8(vm, utf8));
}

/// ToString as UTF-8. May call JS. The slice is valid until the next collection.
pub fn toStringSlice(vm: *Vm, v: Value) Error![]const u8 {
    return (try conv.toStr(vm, v)).flat(vm);
}

pub fn toNumber(vm: *Vm, v: Value) Error!f64 {
    return conv.toNumber(vm, v);
}

pub fn toBoolean(_: *Vm, v: Value) bool {
    return ops.truthy(v);
}

/// The typeof string.
pub fn typeOf(vm: *Vm, v: Value) []const u8 {
    const s = ops.typeOf(vm, v).asString();
    return s.ptr[0..s.byte_len];
}

pub fn newObject(vm: *Vm) Error!*Object {
    return objmod.newPlain(vm);
}

pub fn newObjectWithProto(vm: *Vm, proto: ?*Object) Error!*Object {
    return objmod.create(vm, proto, .object);
}

pub fn newArray(vm: *Vm, values: []const Value) Error!*Object {
    return objmod.newArray(vm, values);
}

/// A native function object. Its name and length appear lazily, like a closure's.
pub fn newNative(vm: *Vm, name: []const u8, arity: u32, f: NativeFn) Error!*Object {
    return newNativeObject(vm, name, arity, f, &.{});
}

fn newNativeObject(vm: *Vm, name: []const u8, arity: u32, f: NativeFn, captures: []const Value) Error!*Object {
    const atom = try str.intern(vm, name);
    const data = try vm.gpa.create(objmod.NativeData);
    errdefer vm.gpa.destroy(data);
    const caps = try vm.gpa.dupe(Value, captures);
    errdefer vm.gpa.free(caps);
    data.* = .{ .func = f, .name = atom, .arity = arity, .captures = caps };
    const o = try objmod.alloc(vm, vm.fn_root, .native);
    o.payload = .{ .native = data };
    o.flags.callable = true;
    o.flags.lazy_fn = true;
    return o;
}

/// A native function with captured values, readable inside it through vm.capture(i).
pub fn newNativeClosure(vm: *Vm, name: []const u8, arity: u32, f: NativeFn, captures: []const Value) Error!Value {
    return (try newNativeObject(vm, name, arity, f, captures)).value();
}

/// The running native's i-th captured value.
pub fn capture(vm: *Vm, i: usize) Value {
    return vm.callee.?.payload.native.captures[i];
}

pub const ClassPair = struct { ctor: *Object, proto: *Object };

/// A native constructor: `new` calls f with `this` already made with the right prototype
/// (so JS `class extends` works); a plain call throws TypeError.
pub fn newClass(vm: *Vm, name: []const u8, arity: u32, f: NativeFn, parent_proto: ?*Object) Error!ClassPair {
    const proto = try objmod.create(vm, parent_proto orelse vm.protos.object, .object);
    const ctor = try newNativeObject(vm, name, arity, f, &.{});
    ctor.flags.constructor = true;
    ctor.flags.host_class = true;
    try props.materialize(vm, ctor);
    try props.addProp(vm, ctor, vm.k.prototype, proto.value(), PropFlags.readonly);
    try props.addProp(vm, proto, vm.k.constructor, ctor.value(), PropFlags.hidden);
    return .{ .ctor = ctor, .proto = proto };
}

/// An object whose named and indexed gets are answered by the host's hooks.
pub fn newExoticObject(vm: *Vm, proto: ?*Object, tag: u32, host: ?*anyopaque, hooks: *const objmod.HostHooks) Error!*Object {
    const o = try objmod.createExotic(vm, proto, .host_exotic);
    o.host = host;
    o.host_tag = tag;
    o.payload = .{ .hooks = hooks };
    return o;
}

pub fn call(vm: *Vm, f: Value, this: Value, args: []const Value) Error!Value {
    vm.enterFromHost();
    return calls.call(vm, f, this, args) catch |e| return finishEntry(vm, e);
}

pub fn construct(vm: *Vm, f: Value, args: []const Value) Error!Value {
    vm.enterFromHost();
    return calls.construct(vm, f, args, f) catch |e| return finishEntry(vm, e);
}

pub const PromiseCapability = struct { promise: Value, resolve: Value, reject: Value };

pub fn newPromiseCapability(vm: *Vm) Error!PromiseCapability {
    const p = try promise.newPromise(vm, vm.protos.promise);
    const c = try promise.resolvingFunctions(vm, p);
    return .{ .promise = c.promise, .resolve = c.resolve, .reject = c.reject };
}

pub fn resolvePromise(vm: *Vm, p: Value, v: Value) Error!void {
    return promise.resolve(vm, p.asObject(), v);
}

pub fn rejectPromise(vm: *Vm, p: Value, v: Value) Error!void {
    return promise.reject(vm, p.asObject(), v);
}

pub fn getNamed(vm: *Vm, o: *Object, name: []const u8) Error!Value {
    return props.get(vm, o, try str.keyFromBytes(vm, name));
}

pub fn setNamed(vm: *Vm, o: *Object, name: []const u8, v: Value) Error!void {
    return props.put(vm, o, try str.keyFromBytes(vm, name), v);
}

pub fn getIndexed(vm: *Vm, o: *Object, i: u32) Error!Value {
    return props.get(vm, o, PropKey.fromIndex(i));
}

pub fn setIndexed(vm: *Vm, o: *Object, i: u32, v: Value) Error!void {
    return props.put(vm, o, PropKey.fromIndex(i), v);
}

pub fn defineMethodOn(vm: *Vm, o: *Object, name: []const u8, arity: u32, f: NativeFn) Error!void {
    const fnv = try newNative(vm, name, arity, f);
    try props.defineData(vm, o, try str.keyFromBytes(vm, name), fnv.value(), PropFlags.hidden);
}

pub fn defineAccessorOn(vm: *Vm, o: *Object, name: []const u8, getter: ?NativeFn, setter: ?NativeFn) Error!void {
    const g = if (getter) |f| (try newNative(vm, name, 0, f)).value() else Value.undefined;
    const s = if (setter) |f| (try newNative(vm, name, 1, f)).value() else Value.undefined;
    try props.defineAccessor(vm, o, try str.keyFromBytes(vm, name), g, s, false);
}

pub fn defineDataOn(vm: *Vm, o: *Object, name: []const u8, v: Value, flags: PropFlags) Error!void {
    try props.defineData(vm, o, try str.keyFromBytes(vm, name), v, flags);
}
