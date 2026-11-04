//! Calls and construction: pushing frames for closures, invoking natives, bound
//! functions and proxies, and the entry points natives use to call back into JS.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const Value = @import("value.zig").Value;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const conv = @import("conv.zig");
const interp = @import("interp.zig");
const proxy = @import("b_proxy.zig");
const coroutine = @import("coroutine.zig");
const str = @import("string.zig");

/// Checks the budget and the deadline. Reached every interrupt_interval loops and calls.
pub fn interrupt(vm: *Vm) Error!void {
    vm.budget = Vm.interrupt_interval;
    const dl = vm.deadline orelse return;
    if (conv.monotonicNs() >= dl) {
        vm.deadline = null;
        return error.Terminated;
    }
}

fn classCallError(vm: *Vm, callee: *Object) Error {
    var buf: [120]u8 = undefined;
    const name = callee.payload.fp.name.flat(vm) catch "";
    const m = std.fmt.bufPrint(&buf, "Class constructor {s} cannot be invoked without 'new'", .{name[0..@min(name.len, 64)]}) catch "Class constructor cannot be invoked without 'new'";
    return vm.throwError(.TypeError, m);
}

/// Pushes a frame for a closure. On return, vm.sp is the new frame's operand stack.
pub fn pushClosure(vm: *Vm, callee: *Object, args: [*]Value, argc: u32, ret_sp: [*]Value, new_target: Value, this_in: Value, is_construct: bool) Error!*Frame {
    const fp = callee.payload.fp;
    if (fp.is_class_ctor and !is_construct) return classCallError(vm, callee);
    if (vm.frame_top >= vm_mod.max_frames) return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    const nparams: u32 = fp.nparams;
    var bp = args;
    if (argc > nparams) bp = args + argc;
    const locals_end = bp + fp.nlocals;
    const limit = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
    if (@intFromPtr(locals_end) + (@as(usize, fp.max_stack) + 64) * @sizeOf(Value) > limit) {
        return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    }
    var i: u32 = 0;
    if (argc > nparams) {
        while (i < nparams) : (i += 1) bp[i] = args[i];
    } else {
        i = argc;
    }
    while (i < fp.nlocals) : (i += 1) bp[i] = Value.undefined;
    var this = this_in;
    if (fp.coerce_this and !this.isObject()) {
        this = if (this.isNullish()) vm.global_obj.value() else (try conv.toObject(vm, this)).value();
    }
    vm.budget -= 1;
    if (vm.budget <= 0) try interrupt(vm);
    const f = &vm.frames[vm.frame_top];
    f.* = .{
        .fp = fp,
        .pc = fp.code.ptr,
        .bp = bp,
        .ret_sp = ret_sp,
        .env = callee.env,
        .func = callee,
        .this = this,
        .new_target = new_target,
        .args = args,
        .argc = argc,
        .is_entry = false,
        .is_construct = is_construct,
        .co = null,
    };
    vm.frame_top += 1;
    vm.sp = locals_end;
    return f;
}

fn callNative(vm: *Vm, o: *Object, this: Value, args: []const Value) Error!Value {
    const saved_nt = vm.new_target;
    const saved_callee = vm.callee;
    vm.new_target = Value.undefined;
    vm.callee = o;
    vm.depth += 1;
    defer {
        vm.new_target = saved_nt;
        vm.callee = saved_callee;
        vm.depth -= 1;
    }
    try vm.checkNativeStack();
    return o.payload.native.func(vm, this, args);
}

/// The text just before a call site, for "foo.bar is not a function".
fn calleeText(vm: *Vm, buf: []u8) []const u8 {
    if (vm.frame_top == 0) return "value";
    const f = &vm.frames[vm.frame_top - 1];
    const pos = f.fp.posOf(@intCast(@intFromPtr(f.pc) - @intFromPtr(f.fp.code.ptr)));
    const text = f.fp.source.text;
    var end: usize = @min(pos, text.len);
    while (end > 0 and text[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and end - start < 48) {
        const c = text[start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.' or c == '#') {
            start -= 1;
        } else break;
    }
    if (start == end) return "value";
    const n = @min(end - start, buf.len);
    @memcpy(buf[0..n], text[start..][0..n]);
    return buf[0..n];
}

fn notCallable(vm: *Vm, callee: Value) Error {
    var nb: [64]u8 = undefined;
    var b: [128]u8 = undefined;
    const t = if (callee.isObject() or vm.frame_top != 0) calleeText(vm, &nb) else "value";
    const m = std.fmt.bufPrint(&b, "{s} is not a function", .{t}) catch "value is not a function";
    return vm.throwError(.TypeError, m);
}

/// A call from bytecode to something that is not a closure.
pub fn callNonClosure(vm: *Vm, callee: Value, this: Value, args: []const Value) Error!Value {
    if (!callee.isObject()) return notCallable(vm, callee);
    const o = callee.asObject();
    switch (o.class) {
        .native => {
            if (o.flags.host_class) {
                var buf: [120]u8 = undefined;
                const name = o.payload.native.name.flat(vm) catch "";
                const m = std.fmt.bufPrint(&buf, "Class constructor {s} cannot be invoked without 'new'", .{name[0..@min(name.len, 64)]}) catch "Class constructor cannot be invoked without 'new'";
                return vm.throwError(.TypeError, m);
            }
            return callNative(vm, o, this, args);
        },
        .bound => {
            const b = o.payload.bound;
            if (b.args.len == 0) return call(vm, b.target.value(), b.this, args);
            const all = try vm.gpa.alloc(Value, b.args.len + args.len);
            defer vm.gpa.free(all);
            @memcpy(all[0..b.args.len], b.args);
            @memcpy(all[b.args.len..], args);
            return call(vm, b.target.value(), b.this, all);
        },
        .proxy => {
            if (!o.flags.callable) return notCallable(vm, callee);
            return proxy.callTrap(vm, o, this, args);
        },
        else => return notCallable(vm, callee),
    }
}

/// Copies arguments to the VM stack and pushes an entry frame.
fn pushEntry(vm: *Vm, callee: *Object, this: Value, args: []const Value, new_target: Value, is_construct: bool) Error!void {
    const base = vm.sp;
    const limit = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
    if (@intFromPtr(base) + (args.len + 8) * @sizeOf(Value) > limit) {
        return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    }
    base[0] = this;
    base[1] = callee.value();
    const a = base + 2;
    for (args, 0..) |v, i| a[i] = v;
    const f = try pushClosure(vm, callee, a, @intCast(args.len), base, new_target, this, is_construct);
    f.is_entry = true;
}

/// Calls any callable value from native code.
pub fn call(vm: *Vm, callee: Value, this: Value, args: []const Value) Error!Value {
    if (!callee.isObject()) return notCallable(vm, callee);
    const o = callee.asObject();
    if (o.class != .closure) return callNonClosure(vm, callee, this, args);
    vm.enterFromHost();
    const saved_sp = vm.sp;
    vm.depth += 1;
    defer vm.depth -= 1;
    try vm.checkNativeStack();
    try pushEntry(vm, o, this, args, Value.undefined, false);
    const r = interp.run(vm);
    vm.sp = saved_sp;
    return r;
}

/// The object `new` makes: ordinary, with new_target's prototype.
pub fn allocThis(vm: *Vm, _: *Object, new_target: Value) Error!*Object {
    const proto = try props.getV(vm, new_target, vm.k.prototype);
    return objmod.create(vm, if (proto.isObject()) proto.asObject() else vm.protos.object, .object);
}

/// The prototype a built-in constructor should use: new_target.prototype, or the default.
pub fn protoFromNewTarget(vm: *Vm, default: *Object) Error!*Object {
    const nt = vm.new_target;
    if (!nt.isObject() or nt.asObject() == vm.callee) return default;
    const p = try props.getV(vm, nt, vm.k.prototype);
    return if (p.isObject()) p.asObject() else default;
}

fn notConstructor(vm: *Vm) Error {
    var nb: [64]u8 = undefined;
    var b: [128]u8 = undefined;
    const t = calleeText(vm, &nb);
    const m = std.fmt.bufPrint(&b, "{s} is not a constructor", .{t}) catch "value is not a constructor";
    return vm.throwError(.TypeError, m);
}

pub fn construct(vm: *Vm, callee: Value, args: []const Value, new_target: Value) Error!Value {
    if (!callee.isConstructor()) return notConstructor(vm);
    const o = callee.asObject();
    switch (o.class) {
        .closure => {
            vm.enterFromHost();
            const saved_sp = vm.sp;
            vm.depth += 1;
            defer vm.depth -= 1;
            try vm.checkNativeStack();
            var this = Value.hole;
            if (!o.flags.derived_ctor) this = (try allocThis(vm, o, new_target)).value();
            try pushEntry(vm, o, this, args, new_target, true);
            const r = interp.run(vm);
            vm.sp = saved_sp;
            return r;
        },
        .native => {
            const saved_nt = vm.new_target;
            const saved_callee = vm.callee;
            vm.callee = o;
            vm.depth += 1;
            defer {
                vm.new_target = saved_nt;
                vm.callee = saved_callee;
                vm.depth -= 1;
            }
            try vm.checkNativeStack();
            vm.new_target = new_target;
            if (o.flags.host_class) {
                const proto = try props.getV(vm, new_target, vm.k.prototype);
                const this = try objmod.create(vm, if (proto.isObject()) proto.asObject() else vm.protos.object, .object);
                const r = try o.payload.native.func(vm, this.value(), args);
                return if (r.isObject()) r else this.value();
            }
            return o.payload.native.func(vm, Value.undefined, args);
        },
        .bound => {
            const b = o.payload.bound;
            const target = b.target.value();
            const nt = if (new_target.isObject() and new_target.asObject() == o) target else new_target;
            if (b.args.len == 0) return construct(vm, target, args, nt);
            const all = try vm.gpa.alloc(Value, b.args.len + args.len);
            defer vm.gpa.free(all);
            @memcpy(all[0..b.args.len], b.args);
            @memcpy(all[b.args.len..], args);
            return construct(vm, target, all, nt);
        },
        .proxy => return proxy.constructTrap(vm, o, args, new_target),
        else => return notConstructor(vm),
    }
}

/// Spread calls: [this fn arr] becomes [this fn a0 a1 ...]; returns the count.
pub fn expandArgs(vm: *Vm, spp: *[*]Value) Error!u32 {
    const sp = spp.*;
    const arr = (sp - 1)[0].asObject();
    const n: usize = arr.arr_len;
    const limit = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
    if (@intFromPtr(sp) + (n + 8) * @sizeOf(Value) > limit) {
        return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    }
    const dst = sp - 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = if (i < arr.elems_len) arr.elems[i] else Value.hole;
        dst[i] = if (v.isHole()) Value.undefined else v;
    }
    spp.* = dst + n;
    return @intCast(n);
}

/// Work a return does beyond popping: construct results and coroutine completion.
pub fn returnSpecial(vm: *Vm, f: *Frame, r_in: Value) Error!Value {
    var r = r_in;
    if (f.is_construct and !r.isObject()) r = f.this;
    if (f.co) |co| return coroutine.onReturn(vm, co, r);
    return r;
}
