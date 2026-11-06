//! Page-owned Metal resources. IDs never recycle; explicit destruction leaves a
//! tombstone. Submission is synchronous, so no callback can outlive the page.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const wgsl = @import("wgsl.zig");
const dom = @import("../dom.zig");
const source = @import("../paint/canvas_source.zig");
const metal = @import("metal.zig");
pub const supported = builtin.os.tag == .macos;
pub const Obj = if (supported) nanoui.objc.Object else *opaque {};
pub const Error = error{ Unsupported, Validation, OutOfMemory, DeviceLost };
pub const Kind = enum { buffer, shader, compute, render, texture };
pub const Resource = struct {
    kind: Kind,
    obj: ?Obj = null,
    alive: bool = true,
    size: usize = 0,
    usage: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    shader: u32 = 0,
    fragment_shader: u32 = 0,
    binding_mask: u8 = 0,
    fragment_binding_mask: u8 = 0,
    wg: [3]usize = .{ 1, 1, 1 },
    arena: ?std.heap.ArenaAllocator = null,
    translation: ?wgsl.Translation = null,
};
pub const Canvas = struct {
    ctx: *Context,
    node: *dom.Node,
    texture: u32,
    pixels: []u8 = &.{},
    opaque_alpha: bool = false,
    fn read(raw: *anyopaque) ?nanoui.ui.Texture {
        const c: *Canvas = @ptrCast(@alignCast(raw));
        const r = c.ctx.get(c.texture, .texture) catch return null;
        const len = @as(usize, r.width) * r.height * 4;
        if (c.pixels.len != len) {
            c.ctx.gpa.free(c.pixels);
            c.pixels = c.ctx.gpa.alloc(u8, len) catch {
                c.pixels = &.{};
                return null;
            };
        }
        if (comptime supported) metal.readTexture(r.obj.?, r.width, r.height, c.pixels);
        // Canvas contract is premultiplied BGRA. WebGPU premultiplied mode already
        // stores premultiplied channels; opaque mode ignores the alpha channel.
        if (c.opaque_alpha) {
            var i: usize = 3;
            while (i < len) : (i += 4) c.pixels[i] = 255;
        }
        return .{ .bgra = c.pixels, .width = r.width, .height = r.height, .stride = @as(usize, r.width) * 4 };
    }
};
pub const Context = struct {
    gpa: std.mem.Allocator = std.heap.page_allocator,
    device: ?Obj = null,
    queue: ?Obj = null,
    resources: std.ArrayList(Resource) = .empty,
    allocated_bytes: usize = 0,
    canvases: std.ArrayList(*Canvas) = .empty,
    message: [4096]u8 = @splat(0),
    message_len: usize = 0,

    pub fn fail(c: *Context, text: []const u8) Error {
        c.note(text);
        return error.Validation;
    }
    pub fn note(c: *Context, text: []const u8) void {
        c.message_len = @min(text.len, c.message.len);
        @memcpy(c.message[0..c.message_len], text[0..c.message_len]);
    }
    pub fn diagnostic(c: *const Context) []const u8 {
        return c.message[0..c.message_len];
    }
    pub fn available(c: *Context) bool {
        if (comptime !supported) return false;
        c.ensure() catch return false;
        return true;
    }
    pub fn ensure(c: *Context) Error!void {
        if (comptime !supported) return error.Unsupported;
        if (c.device != null) return;
        c.device = metal.createDevice() orelse return error.Unsupported;
        c.queue = metal.createQueue(c.device.?) orelse {
            metal.release(c.device.?);
            c.device = null;
            return error.Unsupported;
        };
    }
    pub fn deinit(c: *Context) void {
        for (c.resources.items) |*r| {
            if (comptime supported) {
                if (r.obj) |o| metal.release(o);
            }
            if (r.arena) |*a| a.deinit();
        }
        for (c.canvases.items) |canvas| {
            c.gpa.free(canvas.pixels);
            c.gpa.destroy(canvas);
        }
        c.canvases.deinit(c.gpa);
        c.resources.deinit(c.gpa);
        if (comptime supported) {
            if (c.queue) |o| metal.release(o);
            if (c.device) |o| metal.release(o);
        }
        c.* = .{};
    }
    fn add(c: *Context, r: Resource) Error!u32 {
        if (c.resources.items.len >= 4096) return c.fail("page GPU resource limit exceeded");
        try c.resources.append(c.gpa, r);
        c.allocated_bytes += r.size;
        return @intCast(c.resources.items.len);
    }
    pub fn get(c: *Context, id: u32, kind: Kind) Error!*Resource {
        if (id == 0 or id > c.resources.items.len) return c.fail("invalid GPU resource");
        const r = &c.resources.items[id - 1];
        if (!r.alive or r.kind != kind or r.obj == null) return c.fail("destroyed, invalid or wrong-kind GPU resource");
        return r;
    }
    pub fn destroy(c: *Context, id: u32) void {
        if (id == 0 or id > c.resources.items.len) return;
        const r = &c.resources.items[id - 1];
        if (r.alive) c.allocated_bytes -= r.size;
        if (comptime supported) {
            if (r.obj) |o| metal.release(o);
        }
        r.obj = null;
        r.alive = false;
    }
    pub fn buffer(c: *Context, size: usize, usage: u32) Error!u32 {
        if (comptime !supported) return error.Unsupported;
        try c.ensure();
        if (size == 0 or size > 64 * 1024 * 1024 or usage == 0 or usage & ~@as(u32, 0x3ff) != 0) return c.fail("invalid buffer size or usage (limit 64 MiB)");
        if (size > (256 << 20) - c.allocated_bytes) return error.OutOfMemory;
        const obj = metal.buffer(c.device.?, size) orelse return error.OutOfMemory;
        errdefer metal.release(obj);
        @memset(metal.bytes(obj, size), 0);
        return c.add(.{ .kind = .buffer, .obj = obj, .size = size, .usage = usage });
    }
    pub fn bytes(c: *Context, id: u32, offset: usize, len: usize) Error![]u8 {
        if (comptime !supported) return error.Unsupported;
        const r = try c.get(id, .buffer);
        if (offset > r.size or len > r.size - offset) return c.fail("buffer access out of bounds");
        return metal.bytes(r.obj.?, r.size)[offset..][0..len];
    }
    pub fn shader(c: *Context, text: []const u8) Error!u32 {
        if (comptime !supported) return error.Unsupported;
        try c.ensure();
        var arena = std.heap.ArenaAllocator.init(c.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var sink: wgsl.Sink = .{ .arena = a };
        const owned_text = try a.dupe(u8, text);
        const tr = wgsl.translate(a, &sink, owned_text) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            const d = sink.diag.?;
            return c.fail(try std.fmt.allocPrint(a, "WGSL {d}:{d}: {s}", .{ d.pos.line, d.pos.col, d.message }));
        };
        const lib = metal.library(c, tr.source) orelse return error.Validation;
        errdefer metal.release(lib);
        return c.add(.{ .kind = .shader, .obj = lib, .arena = arena, .translation = tr });
    }
    pub fn bindings(c: *Context, shader_id: u32) Error![]const wgsl.Binding {
        return (try c.get(shader_id, .shader)).translation.?.bindings;
    }
    fn entry(c: *Context, r: *Resource, name: []const u8, stage: @import("wgsl_ast.zig").Stage) Error!wgsl.Entry {
        for (r.translation.?.entries) |e| if (std.mem.eql(u8, e.name, name) and e.stage == stage) return e;
        return c.fail("entry point missing or has wrong stage");
    }
    pub fn compute(c: *Context, shader_id: u32, name: []const u8) Error!u32 {
        if (comptime !supported) return error.Unsupported;
        const r = try c.get(shader_id, .shader);
        const e = try c.entry(r, name, .compute);
        const obj = metal.compute(c, r.obj.?, name) orelse return error.Validation;
        errdefer metal.release(obj);
        return c.add(.{ .kind = .compute, .obj = obj, .shader = shader_id, .binding_mask = e.bindings, .wg = e.workgroup });
    }
    pub fn render(c: *Context, vs: u32, vertex: []const u8, fs: u32, fragment: []const u8) Error!u32 {
        if (comptime !supported) return error.Unsupported;
        const v = try c.get(vs, .shader);
        const f = try c.get(fs, .shader);
        const ve = try c.entry(v, vertex, .vertex);
        const fe = try c.entry(f, fragment, .fragment);
        for (v.translation.?.bindings) |vb| for (f.translation.?.bindings) |fb| {
            if (vb.slot == fb.slot and uses(ve.bindings, vb.slot) and uses(fe.bindings, fb.slot) and
                (vb.kind != fb.kind or vb.writable != fb.writable)) return c.fail("incompatible vertex and fragment buffer binding types");
        };
        const obj = metal.render(c, v.obj.?, vertex, f.obj.?, fragment) orelse return error.Validation;
        errdefer metal.release(obj);
        return c.add(.{ .kind = .render, .obj = obj, .shader = vs, .fragment_shader = fs, .binding_mask = ve.bindings, .fragment_binding_mask = fe.bindings });
    }
    pub fn texture(c: *Context, width: u32, height: u32) Error!u32 {
        if (comptime !supported) return error.Unsupported;
        try c.ensure();
        if (width == 0 or height == 0 or width > 4096 or height > 4096) return c.fail("texture dimensions must be 1 through 4096");
        const size = @as(usize, width) * height * 4;
        if (size > (256 << 20) - c.allocated_bytes) return error.OutOfMemory;
        const obj = metal.texture(c.device.?, width, height) orelse return error.OutOfMemory;
        errdefer metal.release(obj);
        return c.add(.{ .kind = .texture, .obj = obj, .width = width, .height = height, .size = size });
    }
    pub fn attach(c: *Context, table: *source.Table, node: *dom.Node, texture_id: u32, opaque_alpha: bool) Error!void {
        _ = try c.get(texture_id, .texture);
        for (c.canvases.items) |can| if (can.node == node) {
            can.texture = texture_id;
            can.opaque_alpha = opaque_alpha;
            try table.set(c.gpa, node, .{ .ctx = can, .pixels = Canvas.read });
            return;
        };
        const can = try c.gpa.create(Canvas);
        errdefer c.gpa.destroy(can);
        can.* = .{ .ctx = c, .node = node, .texture = texture_id, .opaque_alpha = opaque_alpha };
        try c.canvases.append(c.gpa, can);
        errdefer c.canvases.items.len -= 1;
        try table.set(c.gpa, node, .{ .ctx = can, .pixels = Canvas.read });
    }
    pub fn dispatch(c: *Context, id: u32, buffers: [8]u32, groups: [3]usize) Error!void {
        return c.dispatchChecked(id, buffers, groups, true);
    }
    pub fn validateDispatch(c: *Context, id: u32, buffers: [8]u32, groups: [3]usize) Error!void {
        return c.dispatchChecked(id, buffers, groups, false);
    }
    fn dispatchChecked(c: *Context, id: u32, buffers: [8]u32, groups: [3]usize, execute: bool) Error!void {
        if (comptime !supported) return error.Unsupported;
        const p = try c.get(id, .compute);
        const shader_r = try c.get(p.shader, .shader);
        if (!metal.validWorkgroup(c, p.obj.?, p.wg)) return c.fail("workgroup exceeds device limit");
        var bound: [8]?Obj = @splat(null);
        var lengths: [8]u32 = @splat(0);
        for (groups) |g| if (g > 65535) return c.fail("dispatch dimensions exceed limit");
        const total = groups[0] * groups[1] * groups[2] * p.wg[0] * p.wg[1] * p.wg[2];
        if (total > 1048576) return c.fail("dispatch exceeds supported one-million-thread limit");
        // Explicit layouts may contain bindings unused by this entry point.
        for (buffers) |buf| if (buf != 0) {
            _ = try c.get(buf, .buffer);
        };
        for (shader_r.translation.?.bindings, 0..) |b, i| {
            if (!uses(p.binding_mask, b.slot)) continue;
            for (shader_r.translation.?.bindings[0..i]) |previous| {
                if (uses(p.binding_mask, previous.slot) and buffers[b.slot] != 0 and buffers[b.slot] == buffers[previous.slot] and (b.writable or previous.writable)) return c.fail("writable storage bindings must not alias");
            }
            const r = try c.get(buffers[b.slot], .buffer);
            try c.validateBuffer(r, b);
            bound[b.slot] = r.obj;
            if (b.kind == .storage) lengths[b.slot] = @intCast(r.size / b.stride);
        }
        if (execute and total != 0) try metal.dispatch(c, p.obj.?, bound, lengths, groups, p.wg);
    }
    pub fn copy(c: *Context, src: u32, src_offset: usize, dst: u32, dst_offset: usize, len: usize) Error!void {
        if (comptime !supported) return error.Unsupported;
        const s = try c.get(src, .buffer);
        const d = try c.get(dst, .buffer);
        if (src == dst or s.usage & 4 == 0 or d.usage & 8 == 0 or (src_offset | dst_offset | len) % 4 != 0) return c.fail("invalid buffer copy usage, alias or alignment");
        _ = try c.bytes(src, src_offset, len);
        _ = try c.bytes(dst, dst_offset, len);
        if (len > 0) try metal.copy(c, s.obj.?, src_offset, d.obj.?, dst_offset, len);
    }
    fn uses(mask: u8, slot: usize) bool {
        return mask & (@as(u8, 1) << @intCast(slot)) != 0;
    }
    fn validateBuffer(c: *Context, r: *Resource, b: wgsl.Binding) Error!void {
        if (b.kind == .uniform) {
            if (r.usage & 64 == 0 or r.size < b.min_size or r.size > 65536) return c.fail("uniform binding requires UNIFORM usage, the shader minimum size and at most 64 KiB");
        } else if (r.usage & 128 == 0 or r.size < b.min_size or r.size % b.stride != 0)
            return c.fail("storage binding requires STORAGE usage and whole scalar elements");
    }
    pub fn validateRenderBindings(c: *Context, id: u32, buffers: [8]u32) Error!void {
        if (comptime !supported) return error.Unsupported;
        const p = try c.get(id, .render);
        for (buffers) |buf| if (buf != 0) {
            _ = try c.get(buf, .buffer);
        };
        for ([_]u32{ p.shader, p.fragment_shader }, [_]u8{ p.binding_mask, p.fragment_binding_mask }) |shader_id, mask| {
            for (try c.bindings(shader_id)) |b| {
                if (uses(mask, b.slot)) try c.validateBuffer(try c.get(buffers[b.slot], .buffer), b);
            }
        }
    }
    pub fn draw(c: *Context, texture_id: u32, pipeline: u32, count: usize, first: usize, clear: ?[4]f64) Error!void {
        return c.drawBound(texture_id, pipeline, count, first, clear, @splat(0));
    }
    pub fn drawBound(c: *Context, texture_id: u32, pipeline: u32, count: usize, first: usize, clear: ?[4]f64, buffers: [8]u32) Error!void {
        if (comptime !supported) return error.Unsupported;
        const tex = try c.get(texture_id, .texture);
        const p = if (pipeline != 0) try c.get(pipeline, .render) else null;
        if (count > 65535 or first > 65535 or (count > 0 and p == null)) return c.fail("invalid draw");
        var vertex_buffers: [8]?Obj = @splat(null);
        var fragment_buffers: [8]?Obj = @splat(null);
        if (p) |r| {
            try c.validateRenderBindings(pipeline, buffers);
            for (buffers, 0..) |buf, slot| {
                if (uses(r.binding_mask, slot)) vertex_buffers[slot] = (try c.get(buf, .buffer)).obj;
                if (uses(r.fragment_binding_mask, slot)) fragment_buffers[slot] = (try c.get(buf, .buffer)).obj;
            }
        }
        try metal.draw(c, tex.obj.?, if (p) |r| r.obj else null, count, first, clear, vertex_buffers, fragment_buffers);
    }
};
