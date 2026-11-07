//! Exception unwinding. Handlers are markers on the operand stack, so generators
//! carry theirs when suspended and there are no side tables to keep in sync.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const fr = @import("frame.zig");
const coroutine = @import("coroutine.zig");
const iter = @import("iter.zig");
const api = @import("vm_api.zig");

pub const Result = union(enum) {
    /// A handler took it: continue the top frame.
    resume_top,
    /// An async function turned it into a rejection, and this entry frame returns that.
    value: Value,
    err: Error,
};

pub fn unwind(vm: *Vm, sp_in: [*]Value, err_in: Error) Result {
    var err = err_in;
    if (err == error.OutOfMemory) {
        api.throwOutOfMemory(vm);
        err = error.Thrown;
    }
    var sp = sp_in;
    while (true) {
        const f = &vm.frames[vm.frame_top - 1];
        if (err == error.Thrown) {
            const base = f.bp + f.fp.nlocals;
            var s = sp;
            while (@intFromPtr(s) > @intFromPtr(base)) {
                s -= 1;
                const v = s[0];
                if (!v.isInternal()) continue;
                if (fr.isCatchMarker(v)) {
                    const saved = (s - 1)[0];
                    f.env = if (saved.isUndefined()) null else @fieldParentPtr("cell", saved.asCell());
                    f.pc = f.fp.code.ptr + fr.catchOffset(v);
                    (s - 1)[0] = vm.exception;
                    vm.exception = Value.undefined;
                    vm.sp = s;
                    return .resume_top;
                }
                if (v.same(fr.iter_marker) or v.same(fr.async_iter_marker)) {
                    vm.sp = s + 1;
                    iter.closeQuiet(vm, (s - 2)[0]) catch |e| {
                        if (e == error.Terminated) err = e;
                    };
                    if (err != error.Thrown) break;
                }
            }
        }
        // No handler here: this frame is finished.
        if (f.co) |co| {
            if (err == error.Thrown and co.kind == .async_fn) {
                const r = coroutine.rejectAsync(vm, co) catch |e| {
                    err = e;
                    return leave(vm, f, &sp, err);
                };
                const entry = f.is_entry;
                sp = f.ret_sp;
                vm.frame_top -= 1;
                vm.sp = sp;
                if (entry) return .{ .value = r };
                sp[0] = r;
                vm.sp = sp + 1;
                return .resume_top;
            }
            co.state = .done;
        }
        const entry = f.is_entry;
        sp = f.ret_sp;
        vm.frame_top -= 1;
        if (entry) {
            vm.sp = sp;
            return .{ .err = err };
        }
    }
}

fn leave(vm: *Vm, f: *fr.Frame, sp: *[*]Value, err: Error) Result {
    // Rare: rejecting failed. Abandon every frame up to this run()'s entry.
    var top = f;
    while (true) {
        const entry = top.is_entry;
        sp.* = top.ret_sp;
        vm.frame_top -= 1;
        if (entry) break;
        top = &vm.frames[vm.frame_top - 1];
    }
    vm.sp = sp.*;
    return .{ .err = err };
}
