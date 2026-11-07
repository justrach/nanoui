//! Suspended activations: generators, async functions and async generators are one
//! mechanism, a frame copied to the heap and copied back. Resumption pushes [value, mode]
//! where mode is 0 next, 1 throw, 2 return. The async generator request queue is here too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const shape = @import("shape.zig");
const interp = @import("interp.zig");
const calls = @import("interp_call.zig");
const promise = @import("promise.zig");
const iter = @import("iter.zig");

pub const Kind = enum(u8) { generator, async_fn, async_gen };
pub const State = enum(u8) { suspended_start, suspended_yield, awaiting, running, done };

pub const Coroutine = struct {
    cell: heap.Cell,
    kind: Kind,
    state: State,
    yield_raw: bool = false,
    fp: *bc.FuncProto,
    func: *Object,
    this: Value,
    new_target: Value,
    env: ?*heap.Env = null,
    pc_offset: u32 = 0,
    saved: []Value = &.{},
    saved_len: u32 = 0,
    /// async_fn: its result promise. async_gen: the generator object.
    owner: ?*Object = null,

    pub fn trace(c: *Coroutine, m: *heap.Marker) void {
        m.markCell(&c.fp.cell);
        m.markObj(c.func);
        m.mark(c.this);
        m.mark(c.new_target);
        if (c.env) |e| m.markCell(&e.cell);
        m.markValues(c.saved[0..c.saved_len]);
        m.markObj(c.owner);
    }
    pub fn finalize(c: *Coroutine, gpa: Allocator) void {
        gpa.free(c.saved);
    }
};

fn newCoroutine(vm: *Vm, f: *Frame, kind: Kind) Error!*Coroutine {
    const c = try vm.heap.create(Coroutine, .coroutine);
    const cell = c.cell;
    c.* = .{ .cell = cell, .kind = kind, .state = .running, .fp = f.fp, .func = f.func, .this = f.this, .new_target = f.new_target };
    return c;
}

/// Copies locals and operands into the coroutine.
fn saveFrame(vm: *Vm, co: *Coroutine, f: *Frame, sp: [*]Value, next_pc: [*]const u8) Error!void {
    const n = (@intFromPtr(sp) - @intFromPtr(f.bp)) / @sizeOf(Value);
    if (co.saved.len < n) {
        vm.gpa.free(co.saved);
        co.saved = &.{};
        co.saved = try vm.gpa.alloc(Value, n);
    }
    @memcpy(co.saved[0..n], f.bp[0..n]);
    co.saved_len = @intCast(n);
    co.env = f.env;
    co.pc_offset = @intCast(@intFromPtr(next_pc) - @intFromPtr(f.fp.code.ptr));
}

/// The value this frame's run returns to whoever is waiting for it.
pub fn suspendFrame(vm: *Vm, f: *Frame, op: Op, sp: [*]Value) Error!Value {
    const pc = f.pc;
    switch (op) {
        .initial_yield => {
            const fp = f.fp;
            const kind: Kind = if (fp.is_async) .async_gen else .generator;
            const co = try newCoroutine(vm, f, kind);
            f.co = co;
            co.state = .suspended_start;
            try saveFrame(vm, co, f, sp, pc + 1);
            const proto_v = try props.get(vm, f.func, vm.k.prototype);
            const default_proto = if (fp.is_async) vm.protos.async_generator else vm.protos.generator;
            const proto = if (proto_v.isObject()) proto_v.asObject() else default_proto;
            if (fp.is_async) {
                const data = try vm.gpa.create(AsyncGen);
                data.* = .{ .co = co };
                const g = objmod.create(vm, proto, .async_generator) catch |e| {
                    vm.gpa.destroy(data);
                    return e;
                };
                g.payload = .{ .agen = data };
                co.owner = g;
                return g.value();
            }
            const g = try objmod.create(vm, proto, .generator);
            g.payload = .{ .co = co };
            return g.value();
        },
        .yield_, .yield_raw => {
            const co = f.co.?;
            const v = (sp - 1)[0];
            co.yield_raw = op == .yield_raw;
            co.state = .suspended_yield;
            try saveFrame(vm, co, f, sp - 1, pc + 1);
            return v;
        },
        .await_ => {
            const co = f.co orelse return vm.throwError(.SyntaxError, "await is only valid in async functions");
            const v = (sp - 1)[0];
            co.state = .awaiting;
            try saveFrame(vm, co, f, sp - 1, pc + 1);
            try promise.awaitValue(vm, v, co);
            return if (co.kind == .async_fn) co.owner.?.value() else Value.undefined;
        },
        else => unreachable,
    }
}

/// async_start: the function's result promise exists before its first instruction.
pub fn asyncStart(vm: *Vm, f: *Frame) Error!void {
    const co = try newCoroutine(vm, f, .async_fn);
    co.owner = try promise.newPromise(vm, vm.protos.promise);
    f.co = co;
}

/// A coroutine's function finished normally with r.
pub fn onReturn(vm: *Vm, co: *Coroutine, r: Value) Error!Value {
    co.state = .done;
    co.saved_len = 0;
    if (co.kind == .async_fn) {
        try promise.resolve(vm, co.owner.?, r);
        return co.owner.?.value();
    }
    return r;
}

/// An async function threw: its promise rejects, and that promise is what it returned.
pub fn rejectAsync(vm: *Vm, co: *Coroutine) Error!Value {
    co.state = .done;
    const e = vm.exception;
    vm.exception = Value.undefined;
    try promise.reject(vm, co.owner.?, e);
    return co.owner.?.value();
}

/// Restores a suspended frame and runs it until it suspends again or finishes.
fn resumeRun(vm: *Vm, co: *Coroutine, v: Value, mode: i32) Error!Value {
    vm.enterFromHost();
    const was_start = co.state == .suspended_start;
    if (vm.frame_top >= vm_mod.max_frames) return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    const base = vm.sp;
    const n = co.saved_len;
    const limit = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
    if (@intFromPtr(base) + (n + co.fp.max_stack + 64) * @sizeOf(Value) > limit) {
        return vm.throwError(.RangeError, "Maximum call stack size exceeded");
    }
    vm.depth += 1;
    defer vm.depth -= 1;
    try vm.checkNativeStack();
    @memcpy(base[0..n], co.saved[0..n]);
    var sp = base + n;
    if (!was_start) {
        sp[0] = v;
        sp[1] = Value.fromInt(mode);
        sp += 2;
    }
    co.state = .running;
    vm.frames[vm.frame_top] = .{
        .fp = co.fp,
        .pc = co.fp.code.ptr + co.pc_offset,
        .bp = base,
        .ret_sp = base,
        .env = co.env,
        .func = co.func,
        .this = co.this,
        .new_target = co.new_target,
        .args = base,
        .argc = 0,
        .is_entry = true,
        .is_construct = false,
        .co = co,
    };
    vm.frame_top += 1;
    vm.sp = sp;
    const r = interp.run(vm);
    vm.sp = base;
    return r;
}

/// A promise this coroutine awaited has settled.
pub fn resumeAwait(vm: *Vm, co: *Coroutine, v: Value, is_reject: bool) Error!void {
    const mode: i32 = if (is_reject) 1 else 0;
    if (co.kind == .async_fn) {
        _ = try resumeRun(vm, co, v, mode);
        return;
    }
    const gen = co.owner.?;
    const data = gen.payload.agen;
    data.executing = true;
    agenAfterRun(vm, data, resumeRun(vm, co, v, mode)) catch |e| {
        data.executing = false;
        return e;
    };
    data.executing = false;
    try agenDrain(vm, gen);
}

/// A { value, done } object from the shared shape.
pub fn iterResult(vm: *Vm, v: Value, done: bool) Error!Value {
    const o = try objmod.alloc(vm, vm.iter_result_shape, .object);
    o.slots[0] = v;
    o.slots[1] = Value.fromBool(done);
    return o.value();
}

/// gen.next / gen.throw / gen.return.
pub fn generatorResume(vm: *Vm, co: *Coroutine, v: Value, mode: i32) Error!Value {
    switch (co.state) {
        .running, .awaiting => return vm.throwError(.TypeError, "Generator is already running"),
        .done => {
            if (mode == 1) {
                vm.exception = v;
                return error.Thrown;
            }
            return iterResult(vm, if (mode == 2) v else Value.undefined, true);
        },
        .suspended_start => {
            if (mode == 1) {
                co.state = .done;
                vm.exception = v;
                return error.Thrown;
            }
            if (mode == 2) {
                co.state = .done;
                return iterResult(vm, v, true);
            }
        },
        .suspended_yield => {},
    }
    const r = try resumeRun(vm, co, v, mode);
    if (co.state == .done) return iterResult(vm, r, true);
    if (co.yield_raw) return r;
    return iterResult(vm, r, false);
}

pub const Request = struct { mode: i32, value: Value, cap: promise.Capability };

/// The async generator's state beyond its coroutine: the request queue.
pub const AsyncGen = struct {
    co: *Coroutine,
    queue: std.ArrayList(Request) = .empty,
    head: usize = 0,
    executing: bool = false,
    /// Waiting on the value of a return request to settle.
    awaiting_return: bool = false,

    pub fn trace(a: *AsyncGen, m: *heap.Marker) void {
        m.markCell(&a.co.cell);
        for (a.queue.items[a.head..]) |r| {
            m.mark(r.value);
            r.cap.trace(m);
        }
    }
    pub fn destroy(a: *AsyncGen, gpa: Allocator) void {
        a.queue.deinit(gpa);
        gpa.destroy(a);
    }
};

/// Settles the oldest request according to how the last run ended.
fn agenAfterRun(vm: *Vm, data: *AsyncGen, result: Error!Value) Error!void {
    const co = data.co;
    const r = result catch |e| {
        if (e != error.Thrown) return e;
        co.state = .done;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        const req = data.queue.items[data.head];
        data.head += 1;
        return promise.callReject(vm, req.cap, ex);
    };
    switch (co.state) {
        .awaiting => {},
        .suspended_yield => {
            const req = data.queue.items[data.head];
            data.head += 1;
            try promise.callResolve(vm, req.cap, try iterResult(vm, r, false));
        },
        else => {
            co.state = .done;
            const req = data.queue.items[data.head];
            data.head += 1;
            try promise.callResolve(vm, req.cap, try iterResult(vm, r, true));
        },
    }
}

/// Works through queued requests until the generator suspends on something.
pub fn agenDrain(vm: *Vm, gen: *Object) Error!void {
    const data = gen.payload.agen;
    const co = data.co;
    while (data.head < data.queue.items.len) {
        if (data.executing or data.awaiting_return) return;
        if (co.state == .running or co.state == .awaiting) return;
        const req = data.queue.items[data.head];
        if (co.state == .suspended_start and req.mode != 0) co.state = .done;
        if (co.state == .done) {
            switch (req.mode) {
                0 => {
                    data.head += 1;
                    try promise.callResolve(vm, req.cap, try iterResult(vm, Value.undefined, true));
                },
                1 => {
                    data.head += 1;
                    try promise.callReject(vm, req.cap, req.value);
                },
                else => {
                    data.awaiting_return = true;
                    try promise.awaitReturn(vm, gen, req.value);
                    return;
                },
            }
            continue;
        }
        data.executing = true;
        const r = resumeRun(vm, co, req.value, req.mode);
        data.executing = false;
        try agenAfterRun(vm, data, r);
    }
    data.queue.clearRetainingCapacity();
    data.head = 0;
}

/// The value of a return request on a finished generator has settled.
pub fn agenReturnSettled(vm: *Vm, gen: *Object, v: Value, is_reject: bool) Error!void {
    const data = gen.payload.agen;
    data.awaiting_return = false;
    const req = data.queue.items[data.head];
    data.head += 1;
    if (is_reject) {
        try promise.callReject(vm, req.cap, v);
    } else {
        try promise.callResolve(vm, req.cap, try iterResult(vm, v, true));
    }
    try agenDrain(vm, gen);
}

/// Wraps a sync iterator for for-await and yield* in an async generator.
pub fn asyncFromSync(vm: *Vm, sync: iter.Iter) Error!iter.Iter {
    const data = try vm.gpa.create(objmod.IterData);
    data.* = .{ .target = sync.iter, .aux = sync.next };
    const o = objmod.create(vm, vm.protos.async_from_sync, .async_from_sync) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .iter = data };
    return .{ .iter = o.value(), .next = try props.get(vm, o, vm.k.next) };
}
