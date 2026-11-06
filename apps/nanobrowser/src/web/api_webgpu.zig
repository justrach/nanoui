//! Small private bridge. JavaScript owns WebGPU state machines and validation;
//! this boundary independently validates IDs, ranges and native resource kinds.
const std = @import("std");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const gpu = @import("../gpu/context.zig");
const typed = @import("../js/b_typed.zig");
const V = js.Value;
const Vm = js.Vm;
const E = js.Error;
fn context(vm: *Vm) *gpu.Context {
    const w = bind.world(vm);
    w.page.gpu.gpa = w.gpa;
    return &w.page.gpu;
}
fn failure(vm: *Vm, e: gpu.Error) E {
    const c = context(vm);
    if (e == error.OutOfMemory) return vm.throwError(.Error, "GPUOutOfMemoryError: GPU allocation failed");
    if (e == error.DeviceLost) return vm.throwError(.Error, "GPUInternalError: Metal command failed");
    return vm.throwError(.Error, if (c.diagnostic().len > 0) c.diagnostic() else @errorName(e));
}
fn num(vm: *Vm, args: []const V, i: usize) E!u32 {
    const n = try vm.toNumber(bind.arg(args, i));
    if (!std.math.isFinite(n) or n < 0 or n > 0xffffffff or @floor(n) != n) return vm.throwError(.TypeError, "GPU argument must be an unsigned integer");
    return @intFromFloat(n);
}
fn available(vm: *Vm, _: V, _: []const V) E!V {
    return V.fromBool(context(vm).available());
}
fn buffer(vm: *Vm, _: V, args: []const V) E!V {
    const id = context(vm).buffer(try num(vm, args, 0), try num(vm, args, 1)) catch |e| return failure(vm, e);
    return V.fromUsize(id);
}
fn shader(vm: *Vm, _: V, args: []const V) E!V {
    const id = context(vm).shader(try bind.str(vm, args, 0)) catch |e| return failure(vm, e);
    return V.fromUsize(id);
}
fn compute(vm: *Vm, _: V, args: []const V) E!V {
    const id = context(vm).compute(try num(vm, args, 0), try bind.str(vm, args, 1)) catch |e| return failure(vm, e);
    return V.fromUsize(id);
}
fn render(vm: *Vm, _: V, args: []const V) E!V {
    const id = context(vm).render(try num(vm, args, 0), try bind.str(vm, args, 1), try num(vm, args, 2), try bind.str(vm, args, 3)) catch |e| return failure(vm, e);
    return V.fromUsize(id);
}
fn texture(vm: *Vm, _: V, args: []const V) E!V {
    const id = context(vm).texture(try num(vm, args, 0), try num(vm, args, 1)) catch |e| return failure(vm, e);
    return V.fromUsize(id);
}
fn destroy(vm: *Vm, _: V, args: []const V) E!V {
    context(vm).destroy(try num(vm, args, 0));
    return V.undefined;
}
fn read(vm: *Vm, _: V, args: []const V) E!V {
    const bytes = context(vm).bytes(try num(vm, args, 0), try num(vm, args, 1), try num(vm, args, 2)) catch |e| return failure(vm, e);
    const obj = try typed.newBuffer(vm, bytes.len, vm.protos.arraybuffer);
    @memcpy(obj.payload.buffer.bytes, bytes);
    return obj.value();
}
fn write(vm: *Vm, _: V, args: []const V) E!V {
    const obj = bind.arg(args, 2).objectOrNull() orelse return bind.illegal(vm);
    const bytes = if (obj.class == .arraybuffer and !obj.payload.buffer.detached) obj.payload.buffer.bytes else return bind.illegal(vm);
    const dst = context(vm).bytes(try num(vm, args, 0), try num(vm, args, 1), bytes.len) catch |e| return failure(vm, e);
    @memcpy(dst, bytes);
    return V.undefined;
}
fn detach(vm: *Vm, _: V, args: []const V) E!V {
    const obj = bind.arg(args, 0).objectOrNull() orelse return bind.illegal(vm);
    if (obj.class != .arraybuffer) return bind.illegal(vm);
    obj.payload.buffer.detached = true;
    return V.undefined;
}
fn copy(vm: *Vm, _: V, args: []const V) E!V {
    context(vm).copy(try num(vm, args, 0), try num(vm, args, 1), try num(vm, args, 2), try num(vm, args, 3), try num(vm, args, 4)) catch |e| return failure(vm, e);
    return V.undefined;
}
fn dispatch(vm: *Vm, _: V, args: []const V) E!V {
    return dispatchChecked(vm, args, true);
}
fn validateDispatch(vm: *Vm, _: V, args: []const V) E!V {
    return dispatchChecked(vm, args, false);
}
fn dispatchChecked(vm: *Vm, args: []const V, execute: bool) E!V {
    var buffers: [8]u32 = @splat(0);
    const arr = bind.arg(args, 1).objectOrNull() orelse return bind.illegal(vm);
    for (&buffers, 0..) |*b, i| {
        const value = try arr.getIdx(vm, @intCast(i));
        b.* = try num(vm, &.{value}, 0);
    }
    const id = try num(vm, args, 0);
    const groups: [3]usize = .{ try num(vm, args, 2), try num(vm, args, 3), try num(vm, args, 4) };
    if (execute) context(vm).dispatch(id, buffers, groups) catch |e| return failure(vm, e) else context(vm).validateDispatch(id, buffers, groups) catch |e| return failure(vm, e);
    return V.undefined;
}
fn draw(vm: *Vm, _: V, args: []const V) E!V {
    var clear: ?[4]f64 = null;
    if (bind.arg(args, 4).objectOrNull()) |arr| {
        var color: [4]f64 = undefined;
        for (&color, 0..) |*v, i| {
            v.* = try vm.toNumber(try arr.getIdx(vm, @intCast(i)));
            if (!std.math.isFinite(v.*)) return bind.illegal(vm);
        }
        clear = color;
    }
    context(vm).draw(try num(vm, args, 0), try num(vm, args, 1), try num(vm, args, 2), try num(vm, args, 3), clear) catch |e| return failure(vm, e);
    bind.world(vm).changed();
    return V.undefined;
}
fn attach(vm: *Vm, _: V, args: []const V) E!V {
    const w = bind.world(vm);
    const n = try bind.nodeArg(vm, args, 0, "WebGPU canvas");
    context(vm).attach(&w.page.canvases, n, try num(vm, args, 1), vm.toBoolean(bind.arg(args, 2))) catch |e| return failure(vm, e);
    w.changed();
    return V.undefined;
}
fn unconfigure(vm: *Vm, _: V, args: []const V) E!V {
    const w = bind.world(vm);
    w.page.canvases.remove(try bind.nodeArg(vm, args, 0, "WebGPU canvas"));
    w.changed();
    return V.undefined;
}
pub const internals = [_]bind.Method{
    .{ .name = "gpuAvailable", .arity = 0, .f = available },
    .{ .name = "gpuBuffer", .arity = 2, .f = buffer },
    .{ .name = "gpuShader", .arity = 1, .f = shader },
    .{ .name = "gpuCompute", .arity = 2, .f = compute },
    .{ .name = "gpuRender", .arity = 4, .f = render },
    .{ .name = "gpuTexture", .arity = 2, .f = texture },
    .{ .name = "gpuDestroy", .arity = 1, .f = destroy },
    .{ .name = "gpuRead", .arity = 3, .f = read },
    .{ .name = "gpuWrite", .arity = 3, .f = write },
    .{ .name = "gpuDetach", .arity = 1, .f = detach },
    .{ .name = "gpuCopy", .arity = 5, .f = copy },
    .{ .name = "gpuDispatch", .arity = 5, .f = dispatch },
    .{ .name = "gpuValidateDispatch", .arity = 5, .f = validateDispatch },
    .{ .name = "gpuDraw", .arity = 5, .f = draw },
    .{ .name = "gpuAttach", .arity = 3, .f = attach },
    .{ .name = "gpuUnconfigure", .arity = 1, .f = unconfigure },
};
