//! The JavaScript engine's embedding API; the only file a host imports.
//!
//! Lifecycle
//!   const vm = try js.Vm.create(gpa);           defer vm.deinit();
//!   const r = try vm.eval(source, "app.js");    // classic script; completion value
//!   vm.runJobs();                               // drain microtasks between tasks
//!   if (vm.bytesAllocated() > budget) vm.collect();  // only with no JS or native on the stack
//!
//! Errors: every fallible call returns js.Error. error.Thrown means vm.exception holds the
//! value (vm.exceptionString() formats message and stack). error.Terminated means the
//! deadline passed; JS can't catch it. error.OutOfMemory only escapes before JS runs; once
//! running, hitting the heap limit (vm.setHeapLimit, default 2 GiB) becomes a RangeError.
//!
//! Memory: JS things are collected only by vm.collect(), which is illegal while JS or a native
//! is running. Between tasks, anything the host keeps must be reachable from the global
//! object, marked by the hook given to vm.setRootsHook(ctx, fn(ctx, *Marker)), or held with
//! vm.protect(v) / vm.unprotect(v). Natives need no handle scopes.
//!
//! Natives: fn (vm: *Vm, this: Value, args: []const Value) Error!Value. Make them with
//! vm.newNative(name, arity, f), or vm.newNativeClosure(name, arity, f, captures) and read
//! vm.capture(i) inside. A native's name and length are created on first use.
//!
//! Classes: vm.newClass(name, arity, ctor, parent_proto) gives { ctor, proto }. `new` calls
//! ctor with `this` already made with the right prototype, so JS `class extends` works; a plain
//! call throws TypeError. Install ctor where scripts can see it (obj.defineData on the global).
//!
//! Host data: every object has `host: ?*anyopaque` and `host_tag: u32`, free for wrapping DOM
//! nodes (closures use `host` internally; don't set it on functions). vm.host_finalizer, if
//! set, is called with each object that has host data when it is collected.
//! vm.newExoticObject(proto, tag, host, &hooks) makes an object whose named and indexed
//! gets are answered by HostHooks, for live collections (NodeList, dataset, style). A null
//! result from a get hook falls through to ordinary lookup, so prototype methods still work.
//!
//! Modules: m = vm.compileModule(src, url); load each m.requestName(vm, i) (recursively),
//! vm.linkModule(m, ctx, resolve) where resolve(ctx, vm, specifier, referrer) returns the
//! compiled *Module; vm.evaluateModule(m) returns a promise; then vm.runJobs().
//! import(): vm.setDynamicImportHook(ctx, hook); hook(ctx, vm, specifier, referrer_url, cap)
//! loads later and ends with js.finishDynamicImport(vm, m, cap, ctx, resolve), or
//! js.failDynamicImport(vm, cap, message). The vm keeps the cap's promise alive only through
//! the promise's own reachability, so protect cap.promise across an asynchronous load.
//!
//! Interrupts: vm.setDeadline(ns_from_now) makes running JS (and regexps) stop with
//! error.Terminated once passed; 0 clears it. A fired deadline clears itself.
//!
//! Time: Date uses vm.tz_offset_fn = fn(utc_ms) minutes-east-of-UTC for local time; UTC if null.
//!
//! Not provided by the engine: console, timers, queueMicrotask (use js.enqueueJob), fetch.
//! Direct eval runs in the global scope, exactly like indirect eval.

const vm_mod = @import("vm.zig");
const value = @import("value.zig");
const objmod = @import("object.zig");
const heap = @import("heap.zig");
const module = @import("module.zig");
const promise = @import("promise.zig");
const shape = @import("shape.zig");
const api = @import("vm_api.zig");
const str = @import("string.zig");

pub const Vm = vm_mod.Vm;
pub const Error = vm_mod.Error;
pub const ErrorKind = vm_mod.ErrorKind;
pub const Value = value.Value;
pub const PropKey = value.PropKey;
pub const Object = objmod.Object;
pub const NativeFn = objmod.NativeFn;
pub const Getter = NativeFn;
pub const Setter = NativeFn;
pub const HostHooks = objmod.HostHooks;
pub const Marker = heap.Marker;
pub const Module = module.Module;
pub const ModuleResolver = module.ResolveFn;
pub const DynamicImportHook = module.ImportHook;
pub const RejectionHook = promise.RejectionHook;
pub const PropFlags = shape.PropFlags;
pub const PromiseCapability = api.PromiseCapability;
pub const Capability = promise.Capability;
pub const ClassPair = api.ClassPair;
pub const JSString = str.JSString;

pub const finishDynamicImport = module.finishDynamicImport;
pub const failDynamicImport = module.failDynamicImport;
pub const namespaceOf = module.namespaceOf;

/// Queues a callable to run as a microtask; hosts build queueMicrotask on this.
pub const enqueueJob = promise.enqueueCallback;
