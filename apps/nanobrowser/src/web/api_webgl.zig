//! Bounded real WebGL bridge. Driver calls never receive unchecked host-memory ranges.
const std = @import("std");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const ctx = @import("../gl/context.zig");
const gl = @import("../gl/api.zig");
const state = @import("../gl/state.zig");
const typed = @import("../js/b_typed.zig");
pub const Value = js.Value;
pub const Error = js.Error;
pub const Call = struct {
    vm: *js.Vm,
    c: *ctx.Context,
    args: []const Value,
    pub fn arg(a: Call, n: usize) Value {
        return bind.arg(a.args, n);
    }
    pub fn int(a: Call, n: usize) Error!i32 {
        // Do not run page callbacks while native resource-map pointers are live.
        if (a.arg(n).isObject()) return a.vm.throwError(.TypeError, "WebGL numeric argument must be primitive");
        const v = try a.vm.toNumber(a.arg(n));
        if (!std.math.isFinite(v)) return 0;
        return @intFromFloat(std.math.clamp(v, -2147483648, 2147483647));
    }
    pub fn uint(a: Call, n: usize) Error!u32 {
        return @bitCast(try a.int(n));
    }
    pub fn float(a: Call, n: usize) Error!f32 {
        if (a.arg(n).isObject()) return a.vm.throwError(.TypeError, "WebGL numeric argument must be primitive");
        return @floatCast(try a.vm.toNumber(a.arg(n)));
    }
    pub fn str(a: Call, n: usize) Error![]const u8 {
        if (a.arg(n).isObject()) return a.vm.throwError(.TypeError, "WebGL string argument must be primitive");
        return a.vm.toStringSlice(a.arg(n));
    }
    pub fn bytes(a: Call, n: usize) ?[]u8 {
        const o = a.arg(n).objectOrNull() orelse return null;
        if (o.class == .arraybuffer) return if (o.payload.buffer.detached) null else o.payload.buffer.bytes;
        if (o.class != .typedarray and o.class != .dataview) return null;
        if (o.payload.typed.buffer.payload.buffer.detached) return null;
        const len = if (o.class == .dataview) o.payload.typed.len else typed.length(o) * typed.elemSize(o.payload.typed.kind);
        return typed.bytesOf(o)[0..len];
    }
    pub fn fail(a: Call, code: u32) Value {
        a.c.fail(code);
        return Value.undefined;
    }
};
pub fn number(n: anytype) Value {
    return Value.fromNumber(@floatFromInt(n));
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn create(vm: *js.Vm, _: Value, args: []const Value) Error!Value {
    const node = bind.asNode(bind.arg(args, 0)) orelse return Value.false;
    const page = bind.world(vm).page;
    if (node.kind != .element or !eq(node.tag, "canvas")) return Value.false;
    const kind = try bind.str(vm, args, 1);
    if (!eq(kind, "webgl") and !eq(kind, "experimental-webgl") and !eq(kind, "webgl2")) return Value.false;
    const two = eq(kind, "webgl2");
    for (page.webgl.items.items) |c| if (c.node == node) return Value.fromBool(c.core() == two);
    if (page.webgl.full() or page.canvases.map.contains(node)) return Value.false;
    const c = ctx.create(page.gpa, page, node, .{
        .webgl2 = two,
        .alpha = !bind.arg(args, 2).same(Value.false),
        .depth = !bind.arg(args, 3).same(Value.false),
        .stencil = bind.arg(args, 4).same(Value.true),
        .premultiplied = !bind.arg(args, 5).same(Value.false),
        .preserve = bind.arg(args, 6).same(Value.true),
    }) orelse return Value.false;
    if (!page.webgl.add(page.gpa, c)) {
        c.destroy();
        return Value.false;
    }
    return Value.true;
}

fn call(vm: *js.Vm, _: Value, args: []const Value) Error!Value {
    const node = bind.asNode(bind.arg(args, 0)) orelse return Value.null;
    const page = bind.world(vm).page;
    var context: ?*ctx.Context = null;
    for (page.webgl.items.items) |c| if (c.node == node) {
        context = c;
        break;
    };
    const c = context orelse return Value.null;
    const op = try bind.str(vm, args, 1);
    const a: Call = .{ .vm = vm, .c = c, .args = if (args.len >= 2) args[2..] else &.{} };
    c.use();
    c.sync();
    const g = &gl.gl;
    if (eq(op, "reset")) {
        c.reset();
        return Value.undefined;
    }
    if (eq(op, "width")) return number(c.width);
    if (eq(op, "height")) return number(c.height);
    if (eq(op, "getError")) {
        if (c.pending_error != 0) {
            const e = c.pending_error;
            c.pending_error = 0;
            return number(e);
        }
        return number(g.glGetError());
    }
    if (eq(op, "clearColor")) g.glClearColor(try a.float(0), try a.float(1), try a.float(2), try a.float(3)) else if (eq(op, "clear")) {
        const mask = try a.uint(0);
        if (mask & ~@as(u32, 0x4500) != 0) return a.fail(state.INVALID_VALUE);
        c.prepare();
        g.glClear(mask);
        c.drew();
    } else if (eq(op, "viewport") or eq(op, "scissor")) {
        const w = try a.int(2);
        const h = try a.int(3);
        if (w < 0 or h < 0) return a.fail(state.INVALID_VALUE);
        if (eq(op, "viewport")) g.glViewport(try a.int(0), try a.int(1), w, h) else g.glScissor(try a.int(0), try a.int(1), w, h);
    } else if (eq(op, "enable") or eq(op, "disable")) {
        const cap = try a.uint(0);
        switch (cap) {
            0x0BE2, 0x0B44, 0x0B71, 0x0BD0, 0x8037, 0x809E, 0x80A0, 0x0C11, 0x0B90 => {},
            else => return a.fail(state.INVALID_ENUM),
        }
        if (eq(op, "enable")) g.glEnable(cap) else g.glDisable(cap);
    } else if (eq(op, "blendFunc")) g.glBlendFunc(try a.uint(0), try a.uint(1)) else if (eq(op, "blendEquation")) g.glBlendEquation(try a.uint(0)) else if (eq(op, "depthFunc")) g.glDepthFunc(try a.uint(0)) else if (eq(op, "depthMask")) g.glDepthMask(@intFromBool(a.arg(0).same(Value.true))) else if (eq(op, "clearDepth")) g.glClearDepth(try a.float(0)) else if (eq(op, "colorMask")) g.glColorMask(@intFromBool(a.arg(0).same(Value.true)), @intFromBool(a.arg(1).same(Value.true)), @intFromBool(a.arg(2).same(Value.true)), @intFromBool(a.arg(3).same(Value.true))) else if (eq(op, "flush")) g.glFlush() else if (eq(op, "finish")) g.glFinish() else if (try @import("api_webgl_buffers.zig").dispatch(a, op)) |v| return v else if (try @import("api_webgl_shaders.zig").dispatch(a, op)) |v| return v else if (try @import("api_webgl_pixels.zig").dispatch(a, op)) |v| return v else if (eq(op, "getParameter")) {
        const p = try a.uint(0);
        if (p == 0x1F02) return vm.newString(if (c.core()) "WebGL 2.0 (nanobrowser bounded subset)" else "WebGL 1.0 (nanobrowser bounded subset)");
        if (p == 0x1F00 or p == 0x1F01) return vm.newString("nanobrowser offscreen OpenGL");
        if (p == 0x8B8C) return vm.newString(if (c.core()) "WebGL GLSL ES 3.00 (translated)" else "WebGL GLSL ES 1.00 (translated)");
        switch (p) {
            0x0D33, 0x851C, 0x8869, 0x8872, 0x8B4C, 0x8B4D, 0x8D57 => {
                var v: i32 = 0;
                g.glGetIntegerv(p, @ptrCast(&v));
                return number(v);
            },
            else => {
                c.fail(state.INVALID_ENUM);
                return Value.null;
            },
        }
    } else return a.fail(state.INVALID_OPERATION);
    return Value.undefined;
}

pub const internals = [_]bind.Method{
    .{ .name = "webglCreate", .arity = 7, .f = create },
    .{ .name = "webglCall", .arity = 2, .f = call },
};
