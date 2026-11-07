//! Explicit byte-array textures and readback; no DOM image uploads or pointer overloads.
const std = @import("std");
const b = @import("api_webgl.zig");
const api = @import("../gl/api.zig");
const state = @import("../gl/state.zig");
const formats = @import("../gl/formats.zig");
const eq = b.eq;
const Value = b.Value;

pub fn dispatch(a: b.Call, op: []const u8) b.Error!?Value {
    const g = &api.gl;
    const c = a.c;
    if (eq(op, "readPixels")) {
        const x = try a.int(0);
        const y = try a.int(1);
        const w = try a.int(2);
        const h = try a.int(3);
        if (try a.uint(4) != 0x1908 or try a.uint(5) != 0x1401) return a.fail(state.INVALID_ENUM);
        if (x < 0 or y < 0 or w < 0 or h < 0 or @as(i64, x) + w > c.width or @as(i64, y) + h > c.height) return a.fail(state.INVALID_VALUE);
        const out = a.bytes(6) orelse return a.fail(state.INVALID_VALUE);
        const need = formats.blockBytes(@intCast(w), @intCast(h), 4, c.pack_alignment);
        if (need > out.len) return a.fail(state.INVALID_OPERATION);
        if (need > 0) {
            c.prepare();
            g.glReadPixels(x, y, w, h, 0x1908, 0x1401, out.ptr);
        }
    } else if (eq(op, "pixelStorei")) {
        const param = try a.uint(0);
        const v = try a.int(1);
        switch (param) {
            api.PACK_ALIGNMENT, api.UNPACK_ALIGNMENT => {
                if (v != 1 and v != 2 and v != 4 and v != 8) return a.fail(state.INVALID_VALUE);
                if (param == api.PACK_ALIGNMENT) c.pack_alignment = @intCast(v) else c.unpack_alignment = @intCast(v);
                g.glPixelStorei(param, v);
            },
            0x9240 => c.unpack_flip = v != 0,
            0x9241 => c.unpack_premultiply = v != 0,
            0x9243 => {
                if (v != 0 and v != 0x9244) return a.fail(state.INVALID_VALUE);
                c.unpack_colorspace = v;
            },
            else => return a.fail(state.INVALID_ENUM),
        }
    } else if (eq(op, "createTexture")) {
        var name: u32 = 0;
        g.glGenTextures(1, &name);
        if (name == 0) return Value.null;
        c.textures.put(c.gpa, name, {}) catch {
            g.glDeleteTextures(1, &name);
            return a.fail(state.OUT_OF_MEMORY);
        };
        return b.number(name);
    } else if (eq(op, "deleteTexture")) {
        const name = try a.uint(0);
        if (c.textures.remove(name)) g.glDeleteTextures(1, &name);
    } else if (eq(op, "activeTexture")) {
        const unit = try a.uint(0);
        var max: i32 = 0;
        g.glGetIntegerv(0x8B4D, @ptrCast(&max));
        if (unit < 0x84C0 or unit - 0x84C0 >= @as(u32, @intCast(@max(max, 0)))) return a.fail(state.INVALID_ENUM);
        g.glActiveTexture(unit);
    } else if (eq(op, "bindTexture")) {
        const target = try a.uint(0);
        const name = try a.uint(1);
        if (target != 0x0DE1) return a.fail(state.INVALID_ENUM);
        if (name != 0 and !c.textures.contains(name)) return a.fail(state.INVALID_OPERATION);
        g.glBindTexture(target, name);
    } else if (eq(op, "texParameteri") or eq(op, "texParameterf")) {
        const target = try a.uint(0);
        const param = try a.uint(1);
        if (target != 0x0DE1) return a.fail(state.INVALID_ENUM);
        switch (param) {
            0x2800, 0x2801, 0x2802, 0x2803 => {},
            else => return a.fail(state.INVALID_ENUM),
        }
        g.glTexParameteri(target, param, try a.int(2));
    } else if (eq(op, "texImage2D") or eq(op, "texSubImage2D")) {
        const sub = eq(op, "texSubImage2D");
        if (a.args.len != 9) return a.fail(state.INVALID_VALUE);
        const target = try a.uint(0);
        const level = try a.int(1);
        const w = try a.int(if (sub) 4 else 3);
        const h = try a.int(if (sub) 5 else 4);
        if (target != 0x0DE1 or try a.uint(6) != 0x1908 or try a.uint(7) != 0x1401) return a.fail(state.INVALID_ENUM);
        if (level < 0 or level > 13 or w < 0 or h < 0 or w > 8192 or h > 8192) return a.fail(state.INVALID_VALUE);
        if (!sub and (try a.int(5) != 0 or (try a.uint(2) != 0x1908 and !(c.core() and try a.uint(2) == 0x8058)))) return a.fail(state.INVALID_VALUE);
        const x = if (sub) try a.int(2) else 0;
        const y = if (sub) try a.int(3) else 0;
        if (x < 0 or y < 0) return a.fail(state.INVALID_VALUE);
        const need: usize = @intCast(formats.blockBytes(@intCast(w), @intCast(h), 4, c.unpack_alignment));
        if (need > 64 * 1024 * 1024) return a.fail(state.OUT_OF_MEMORY);
        const data = a.bytes(8);
        if (data) |d| {
            if (d.len < need) return a.fail(state.INVALID_OPERATION);
        } else if (!a.arg(8).same(Value.null) or sub) return a.fail(state.INVALID_VALUE);
        const copy = c.gpa.alloc(u8, need) catch return a.fail(state.OUT_OF_MEMORY);
        defer c.gpa.free(copy);
        if (data) |d| @memcpy(copy, d[0..need]) else @memset(copy, 0);
        const stride: usize = @intCast(formats.rowStride(@intCast(w), 4, c.unpack_alignment));
        if (c.unpack_premultiply) {
            var row: usize = 0;
            while (row < @as(usize, @intCast(h))) : (row += 1) formats.premultiply(copy[row * stride ..][0 .. @as(usize, @intCast(w)) * 4]);
        }
        if (c.unpack_flip and h > 1) {
            const scratch = try c.gpa.alloc(u8, @as(usize, @intCast(w)) * 4);
            defer c.gpa.free(scratch);
            formats.flipRows(copy, stride, @intCast(h), scratch.len, scratch);
        }
        if (sub) g.glTexSubImage2D(target, level, x, y, w, h, 0x1908, 0x1401, copy.ptr) else g.glTexImage2D(target, level, try a.int(2), w, h, 0, 0x1908, 0x1401, copy.ptr);
    } else if (eq(op, "generateMipmap")) {
        if (try a.uint(0) != 0x0DE1) return a.fail(state.INVALID_ENUM);
        g.glGenerateMipmap(0x0DE1);
    } else return null;
    return Value.undefined;
}
