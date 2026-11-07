//! Buffer storage and vertex-fetch validation before submitting a draw.
const std = @import("std");
const bridge = @import("api_webgl.zig");
const api = @import("../gl/api.zig");
const state = @import("../gl/state.zig");
const Call = bridge.Call;
const Value = bridge.Value;
const eq = bridge.eq;

fn binding(a: Call, target: u32) ?*u32 {
    return switch (target) {
        api.ARRAY_BUFFER => &a.c.state.array_buffer,
        api.ELEMENT_ARRAY_BUFFER => &a.c.state.current().element,
        else => null,
    };
}

pub fn dispatch(a: Call, op: []const u8) bridge.Error!?Value {
    const g = &api.gl;
    const s = &a.c.state;
    if (eq(op, "createBuffer")) {
        var name: u32 = 0;
        g.glGenBuffers(1, &name);
        if (name == 0) return Value.null;
        s.buffers.put(a.c.gpa, name, .{}) catch {
            g.glDeleteBuffers(1, &name);
            return a.fail(state.OUT_OF_MEMORY);
        };
        return bridge.number(name);
    } else if (eq(op, "deleteBuffer")) {
        const name = try a.uint(0);
        if (s.buffers.contains(name)) {
            s.forgetBuffer(name);
            g.glDeleteBuffers(1, &name);
        }
    } else if (eq(op, "bindBuffer")) {
        const target = try a.uint(0);
        const name = try a.uint(1);
        const b = binding(a, target) orelse return a.fail(state.INVALID_ENUM);
        if (name != 0) {
            const info = s.buffers.getPtr(name) orelse return a.fail(state.INVALID_OPERATION);
            const kind: state.Buffer.Kind = if (target == api.ELEMENT_ARRAY_BUFFER) .element else .other;
            if (info.kind != .unset and info.kind != kind) return a.fail(state.INVALID_OPERATION);
            info.kind = kind;
        }
        b.* = name;
        g.glBindBuffer(target, name);
    } else if (eq(op, "bufferData") or eq(op, "bufferSubData")) {
        const target = try a.uint(0);
        const b = binding(a, target) orelse return a.fail(state.INVALID_ENUM);
        const info = s.buffers.getPtr(b.*) orelse return a.fail(state.INVALID_OPERATION);
        if (eq(op, "bufferData")) {
            const usage = try a.uint(2);
            if (usage != 0x88E0 and usage != 0x88E4 and usage != 0x88E8) return a.fail(state.INVALID_ENUM);
            const data = a.bytes(1);
            const size: i64 = if (data) |d| @intCast(d.len) else try a.int(1);
            if (size < 0 or size > 64 * 1024 * 1024) return a.fail(state.INVALID_VALUE);
            const copy = a.c.gpa.alloc(u8, @intCast(size)) catch return a.fail(state.OUT_OF_MEMORY);
            if (data) |d| @memcpy(copy, d) else @memset(copy, 0);
            // Preserve earlier errors without mistaking them for allocation failure.
            while (true) {
                const prior = g.glGetError();
                if (prior == 0) break;
                a.c.fail(prior);
            }
            g.glBufferData(target, @intCast(size), copy.ptr, usage);
            const e = g.glGetError();
            if (e != 0) {
                a.c.gpa.free(copy);
                return a.fail(e);
            }
            a.c.gpa.free(info.shadow);
            info.size = @intCast(size);
            // Keep all buffers shadowed so a future target cannot hide stale bytes.
            info.shadow = copy;
        } else {
            const offset = try a.int(1);
            const data = a.bytes(2) orelse return a.fail(state.INVALID_VALUE);
            if (offset < 0 or @as(u64, @intCast(offset)) + data.len > info.size) return a.fail(state.INVALID_VALUE);
            @memcpy(info.shadow[@as(usize, @intCast(offset))..][0..data.len], data);
            g.glBufferSubData(target, offset, @intCast(data.len), data.ptr);
        }
    } else if (eq(op, "vertexAttribPointer")) {
        const index = try a.uint(0);
        const size = try a.int(1);
        const kind = try a.uint(2);
        const stride = try a.int(4);
        const offset = try a.int(5);
        if (index >= state.max_attribs or size < 1 or size > 4 or stride < 0 or stride > 255 or offset < 0) return a.fail(state.INVALID_VALUE);
        const component: u32 = switch (kind) {
            0x1400, 0x1401 => 1,
            0x1402, 0x1403 => 2,
            0x1406 => 4,
            else => return a.fail(state.INVALID_ENUM),
        };
        if (@as(u32, @intCast(stride)) % component != 0 or @as(u32, @intCast(offset)) % component != 0) return a.fail(state.INVALID_OPERATION);
        if (!s.buffers.contains(s.array_buffer)) return a.fail(state.INVALID_OPERATION);
        const attr = &s.current().attribs[index];
        attr.buffer = s.array_buffer;
        attr.bytes = component * @as(u32, @intCast(size));
        attr.stride = if (stride == 0) attr.bytes else @intCast(stride);
        attr.offset = @intCast(offset);
        g.glVertexAttribPointer(index, size, kind, @intFromBool(a.arg(3).same(Value.true)), stride, @intCast(offset));
    } else if (eq(op, "enableVertexAttribArray") or eq(op, "disableVertexAttribArray")) {
        const index = try a.uint(0);
        if (index >= state.max_attribs) return a.fail(state.INVALID_VALUE);
        const enabled = eq(op, "enableVertexAttribArray");
        s.current().attribs[index].enabled = enabled;
        if (enabled) g.glEnableVertexAttribArray(index) else g.glDisableVertexAttribArray(index);
    } else if (eq(op, "drawArrays") or eq(op, "drawElements")) {
        const mode = try a.uint(0);
        if (mode > 6) return a.fail(state.INVALID_ENUM);
        var e: u32 = 0;
        if (eq(op, "drawArrays")) {
            const first = try a.int(1);
            const count = try a.int(2);
            if (first < 0 or count < 0) return a.fail(state.INVALID_VALUE);
            e = s.checkArrays(@intCast(first), @intCast(count), 1);
            if (e != 0) return a.fail(e);
            a.c.prepare();
            g.glDrawArrays(mode, first, count);
        } else {
            const count = try a.int(1);
            const kind = try a.uint(2);
            const offset = try a.int(3);
            if (count < 0 or offset < 0) return a.fail(state.INVALID_VALUE);
            if (kind == 0x1405 and !a.c.core()) return a.fail(state.INVALID_ENUM);
            e = s.checkElements(@intCast(count), kind, @intCast(offset), 1, a.c.core());
            if (e != 0) return a.fail(e);
            if (a.c.core()) g.glPrimitiveRestartIndex(switch (kind) {
                0x1401 => 255,
                0x1403 => 65535,
                else => 0xffffffff,
            });
            a.c.prepare();
            g.glDrawElements(mode, count, kind, @intCast(offset));
        }
        a.c.drew();
    } else return null;
    return Value.undefined;
}
