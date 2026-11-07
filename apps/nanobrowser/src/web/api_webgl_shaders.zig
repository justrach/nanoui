//! Shader translation is deliberately small; compile/link status and logs are real.
const std = @import("std");
const b = @import("api_webgl.zig");
const api = @import("../gl/api.zig");
const state = @import("../gl/state.zig");
const translate = @import("../gl/translate.zig");
const eq = b.eq;
const Value = b.Value;

pub fn dispatch(a: b.Call, op: []const u8) b.Error!?Value {
    const g = &api.gl;
    const c = a.c;
    if (eq(op, "createShader")) {
        const kind = try a.uint(0);
        if (kind != 0x8B31 and kind != 0x8B30) {
            c.fail(state.INVALID_ENUM);
            return Value.null;
        }
        const name = g.glCreateShader(kind);
        if (name == 0) return Value.null;
        c.shaders.put(c.gpa, name, .{ .kind = kind }) catch {
            g.glDeleteShader(name);
            return a.fail(state.OUT_OF_MEMORY);
        };
        return b.number(name);
    } else if (eq(op, "shaderSource")) {
        const name = try a.uint(0);
        const shader = c.shaders.getPtr(name) orelse return a.fail(state.INVALID_VALUE);
        const source = try a.str(1);
        if (source.len > 1024 * 1024) return a.fail(state.INVALID_VALUE);
        const translated = try translate.translate(c.gpa, source, if (c.core()) .core_410 else .legacy_120, if (shader.kind == 0x8B31) .vertex else .fragment);
        shader.failure = null;
        switch (translated) {
            .failed => |why| {
                shader.failure = why;
                const invalid: [*]const u8 = "#error unsupported shader version\n";
                const len: i32 = 34;
                g.glShaderSource(name, 1, &invalid, &len);
                g.glCompileShader(name);
            },
            .source => |text| {
                defer c.gpa.free(text);
                const len: i32 = @intCast(text.len);
                g.glShaderSource(name, 1, &text.ptr, &len);
            },
        }
    } else if (eq(op, "compileShader")) {
        const name = try a.uint(0);
        const shader = c.shaders.get(name) orelse return a.fail(state.INVALID_VALUE);
        if (shader.failure == null) g.glCompileShader(name);
    } else if (eq(op, "getShaderParameter")) {
        const name = try a.uint(0);
        const param = try a.uint(1);
        const shader = c.shaders.get(name) orelse return a.fail(state.INVALID_VALUE);
        if (param != api.COMPILE_STATUS and param != 0x8B4F and param != 0x8B80) return a.fail(state.INVALID_ENUM);
        if (param == api.COMPILE_STATUS and shader.failure != null) return Value.false;
        var v: i32 = 0;
        g.glGetShaderiv(name, param, &v);
        return if (param == 0x8B4F) b.number(v) else Value.fromBool(v != 0);
    } else if (eq(op, "getShaderInfoLog") or eq(op, "getProgramInfoLog")) {
        const name = try a.uint(0);
        const shader = eq(op, "getShaderInfoLog");
        if (shader) {
            const s = c.shaders.get(name) orelse return a.fail(state.INVALID_VALUE);
            if (s.failure) |why| return try a.vm.newString(why);
        } else if (!c.state.programs.contains(name)) return a.fail(state.INVALID_VALUE);
        var len: i32 = 0;
        if (shader) g.glGetShaderiv(name, api.INFO_LOG_LENGTH, &len) else g.glGetProgramiv(name, api.INFO_LOG_LENGTH, &len);
        const log = try c.gpa.alloc(u8, @intCast(std.math.clamp(len, 1, 1024 * 1024)));
        defer c.gpa.free(log);
        var written: i32 = 0;
        if (shader) g.glGetShaderInfoLog(name, @intCast(log.len), &written, log.ptr) else g.glGetProgramInfoLog(name, @intCast(log.len), &written, log.ptr);
        return try a.vm.newString(log[0..@intCast(@max(written, 0))]);
    } else if (eq(op, "deleteShader")) {
        const name = try a.uint(0);
        if (c.shaders.remove(name)) g.glDeleteShader(name);
    } else if (eq(op, "createProgram")) {
        const name = g.glCreateProgram();
        if (name == 0) return Value.null;
        c.state.programs.put(c.gpa, name, .{}) catch {
            g.glDeleteProgram(name);
            return a.fail(state.OUT_OF_MEMORY);
        };
        return b.number(name);
    } else if (eq(op, "deleteProgram")) {
        const name = try a.uint(0);
        if (c.state.programs.fetchRemove(name)) |p| {
            c.gpa.free(p.value.blocks);
            g.glDeleteProgram(name);
        }
        if (c.state.program == name) {
            c.state.program = 0;
            g.glUseProgram(0);
        }
    } else if (eq(op, "attachShader") or eq(op, "detachShader")) {
        const p = try a.uint(0);
        const s = try a.uint(1);
        if (!c.state.programs.contains(p) or !c.shaders.contains(s)) return a.fail(state.INVALID_VALUE);
        if (eq(op, "attachShader")) g.glAttachShader(p, s) else g.glDetachShader(p, s);
    } else if (eq(op, "linkProgram")) {
        const name = try a.uint(0);
        const p = c.state.programs.getPtr(name) orelse return a.fail(state.INVALID_VALUE);
        g.glLinkProgram(name);
        var status: i32 = 0;
        g.glGetProgramiv(name, api.LINK_STATUS, &status);
        p.linked = status != 0;
        // Conservatively check every enabled attribute, including inactive ones.
        p.inputs = 0xffff;
        c.gpa.free(p.blocks);
        p.blocks = &.{};
        if (c.core() and p.linked) {
            var count: i32 = 0;
            g.glGetProgramiv(name, api.ACTIVE_UNIFORM_BLOCKS, &count);
            if (count > 0) {
                p.blocks = c.gpa.alloc(state.Block, @intCast(count)) catch {
                    p.linked = false;
                    return a.fail(state.OUT_OF_MEMORY);
                };
                for (p.blocks, 0..) |*block, i| {
                    var size: i32 = 0;
                    var binding: i32 = 0;
                    g.glGetActiveUniformBlockiv(name, @intCast(i), api.UNIFORM_BLOCK_DATA_SIZE, &size);
                    g.glGetActiveUniformBlockiv(name, @intCast(i), api.UNIFORM_BLOCK_BINDING, &binding);
                    block.* = .{ .size = @intCast(@max(size, 0)), .binding = @intCast(@max(binding, 0)) };
                }
            }
        }
    } else if (eq(op, "getProgramParameter")) {
        const name = try a.uint(0);
        const param = try a.uint(1);
        if (!c.state.programs.contains(name)) return a.fail(state.INVALID_VALUE);
        switch (param) {
            api.LINK_STATUS, 0x8B83, 0x8B80, 0x8B85, api.ACTIVE_ATTRIBUTES, api.ACTIVE_UNIFORMS => {},
            else => return a.fail(state.INVALID_ENUM),
        }
        var v: i32 = 0;
        g.glGetProgramiv(name, param, &v);
        return if (param == api.LINK_STATUS or param == 0x8B83 or param == 0x8B80) Value.fromBool(v != 0) else b.number(v);
    } else if (eq(op, "useProgram")) {
        const name = try a.uint(0);
        if (name != 0) {
            const p = c.state.programs.get(name) orelse return a.fail(state.INVALID_VALUE);
            if (!p.linked) return a.fail(state.INVALID_OPERATION);
        }
        c.state.program = name;
        g.glUseProgram(name);
    } else if (eq(op, "getAttribLocation") or eq(op, "getUniformLocation") or eq(op, "bindAttribLocation")) {
        const p = try a.uint(0);
        if (!c.state.programs.contains(p)) return a.fail(state.INVALID_VALUE);
        const bind_attr = eq(op, "bindAttribLocation");
        const text = try a.str(if (bind_attr) 2 else 1);
        const storage = try c.gpa.alloc(u8, text.len + 1);
        defer c.gpa.free(storage);
        @memcpy(storage[0..text.len], text);
        storage[text.len] = 0;
        const name = storage[0..text.len :0];
        if (bind_attr) {
            const i = try a.uint(1);
            if (i >= state.max_attribs) return a.fail(state.INVALID_VALUE);
            g.glBindAttribLocation(p, i, name);
        } else return b.number(if (eq(op, "getAttribLocation")) g.glGetAttribLocation(p, name) else g.glGetUniformLocation(p, name));
    } else if (std.mem.startsWith(u8, op, "uniform")) {
        return try uniform(a, op);
    } else return null;
    return Value.undefined;
}

fn uniform(a: b.Call, op: []const u8) b.Error!Value {
    const g = &api.gl;
    const loc = try a.int(0);
    if (loc == -1) return Value.undefined;
    if (a.c.state.program == 0) return a.fail(state.INVALID_OPERATION);
    if (eq(op, "uniform1f")) g.glUniform1f(loc, try a.float(1)) else if (eq(op, "uniform2f")) g.glUniform2f(loc, try a.float(1), try a.float(2)) else if (eq(op, "uniform3f")) g.glUniform3f(loc, try a.float(1), try a.float(2), try a.float(3)) else if (eq(op, "uniform4f")) g.glUniform4f(loc, try a.float(1), try a.float(2), try a.float(3), try a.float(4)) else if (eq(op, "uniform1i")) g.glUniform1i(loc, try a.int(1)) else if (eq(op, "uniform2i")) g.glUniform2i(loc, try a.int(1), try a.int(2)) else if (eq(op, "uniform3i")) g.glUniform3i(loc, try a.int(1), try a.int(2), try a.int(3)) else if (eq(op, "uniform4i")) g.glUniform4i(loc, try a.int(1), try a.int(2), try a.int(3), try a.int(4)) else if (eq(op, "uniformMatrix2fv") or eq(op, "uniformMatrix3fv") or eq(op, "uniformMatrix4fv")) {
        if (!a.arg(1).same(Value.false)) return a.fail(state.INVALID_VALUE);
        const bytes = a.bytes(2) orelse return a.fail(state.INVALID_VALUE);
        const dim: usize = if (eq(op, "uniformMatrix2fv")) 2 else if (eq(op, "uniformMatrix3fv")) 3 else 4;
        if (bytes.len % (dim * dim * 4) != 0) return a.fail(state.INVALID_VALUE);
        const count: i32 = @intCast(bytes.len / (dim * dim * 4));
        if (dim == 2) g.glUniformMatrix2fv(loc, count, 0, bytes.ptr) else if (dim == 3) g.glUniformMatrix3fv(loc, count, 0, bytes.ptr) else g.glUniformMatrix4fv(loc, count, 0, bytes.ptr);
    } else return a.fail(state.INVALID_OPERATION);
    return Value.undefined;
}
