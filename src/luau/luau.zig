//! Opt-in native UI descriptions. No app, filesystem, network or process API.
//! A runtime is single-owner, non-reentrant, and must not be used concurrently.
const std = @import("std");
const ui = @import("nanoui").ui;
const api = @import("api.zig");
pub const tree = @import("tree.zig");
pub const Node = tree.Node;
pub const draw = @import("view.zig").draw;
pub const max_source = 64 * 1024;
pub const max_memory = 16 * 1024 * 1024;
pub const call_seconds = 0.020;
pub const Input = struct {
    pointer_x: f64 = 0.5,
    pointer_y: f64 = 0.5,
    width: f64,
    height: f64,
    dark: bool = false,
    reduced_motion: bool = false,
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    lua: *api.State,
    used: usize = 0,
    limited: bool = false,
    deadline: f64 = 0,
    failed: bool = false,

    /// Compile text only, install the bounded DSL, then sandbox its globals.
    /// Compilation is native and has a post-call deadline, not hard preemption.
    /// Call this off the UI thread for externally supplied source. UI rendering
    /// is synchronous and bounded cooperatively; prefer trusted bundled scripts.
    pub fn create(gpa: std.mem.Allocator, source: []const u8) !*Runtime {
        if (source.len > max_source) return error.SourceLimit;
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .lua = undefined };
        self.lua = api.lua_newstate(allocate, self) orelse return error.OutOfMemory;
        errdefer api.lua_close(self.lua);
        api.luaL_openlibs(self.lua);
        // No module loading, I/O, ambient clock, environment mutation, coroutines,
        // dynamic compilation, output or GC control. ui is local to the chunk.
        for ([_][*:0]const u8{
            "os",       "io",     "debug", "coroutine", "require",        "load",    "loadstring",
            "loadfile", "dofile", "print", "warn",      "collectgarbage", "getfenv", "setfenv",
            "newproxy", "gcinfo",
        }) |name| {
            api.lua_pushnil(self.lua);
            api.lua_setfield(self.lua, api.globals, name);
        }
        const code = try std.mem.concat(gpa, u8, &.{ @embedFile("prelude.luau"), source, @embedFile("suffix.luau") });
        defer gpa.free(code);
        var size: usize = 0;
        const start = ui.clock.now();
        const bytecode = api.luau_compile(code.ptr, code.len, null, &size) orelse return error.OutOfMemory;
        defer api.free(bytecode);
        if (ui.clock.now() - start > call_seconds) return error.ExecutionLimit;
        api.luaL_sandbox(self.lua);
        const cb = api.lua_callbacks(self.lua);
        cb.userdata = self;
        cb.interrupt = interrupt;
        self.limited = true;
        self.deadline = ui.clock.now() + call_seconds;
        if (api.luau_load(self.lua, "native-ui", bytecode, size, 0) != 0) return error.InvalidSource;
        if (api.lua_pcall(self.lua, 0, 1, 0) != 0) return error.ScriptFailed;
        if (ui.clock.now() > self.deadline) return error.ExecutionLimit;
        if (api.lua_type(self.lua, -1) != api.function) return error.ExpectedRenderer;
        return self;
    }

    pub fn destroy(self: *Runtime) void {
        const gpa = self.gpa;
        api.lua_close(self.lua);
        gpa.destroy(self);
    }

    /// Return an owned tree in the caller's frame/arena allocator. The tree
    /// never borrows VM strings. Any failed call permanently retires the VM.
    /// Re-create explicitly to retry; don't auto-retry broken source per frame.
    pub fn render(self: *Runtime, arena: std.mem.Allocator, input: Input) !Node {
        if (self.failed) return error.RuntimeFailed;
        if (!valid(input)) return error.InvalidInput;
        errdefer self.failed = true;
        self.deadline = ui.clock.now() + call_seconds;
        api.lua_pushvalue(self.lua, 1);
        api.lua_pushnumber(self.lua, std.math.clamp(input.pointer_x, 0, 1));
        api.lua_pushnumber(self.lua, std.math.clamp(input.pointer_y, 0, 1));
        api.lua_pushnumber(self.lua, input.width);
        api.lua_pushnumber(self.lua, input.height);
        api.lua_pushboolean(self.lua, @intFromBool(input.dark));
        api.lua_pushboolean(self.lua, @intFromBool(input.reduced_motion));
        if (api.lua_pcall(self.lua, 6, 1, 0) != 0) return error.ScriptFailed;
        defer api.lua_settop(self.lua, 1);
        if (ui.clock.now() > self.deadline) return error.ExecutionLimit;
        var parser = tree.Parser{ .lua = self.lua, .arena = arena, .deadline = self.deadline };
        const node = try parser.parse(1);
        if (ui.clock.now() > self.deadline) return error.ExecutionLimit;
        return node;
    }
};

fn valid(input: Input) bool {
    return std.math.isFinite(input.pointer_x) and std.math.isFinite(input.pointer_y) and
        std.math.isFinite(input.width) and std.math.isFinite(input.height) and
        input.width >= 0 and input.width <= 100000 and input.height >= 0 and input.height <= 100000;
}

fn allocate(ud: ?*anyopaque, ptr: ?*anyopaque, old: usize, size: usize) callconv(.c) ?*anyopaque {
    const self: *Runtime = @ptrCast(@alignCast(ud.?));
    const previous = if (ptr == null) 0 else old;
    if (size == 0) {
        api.free(ptr);
        self.used -= previous;
        return null;
    }
    const next = self.used - previous + size;
    if (self.limited and next > max_memory) return null;
    const result = api.realloc(ptr, size) orelse return null;
    self.used = next;
    return result;
}

fn interrupt(l: *api.State, gc: c_int) callconv(.c) void {
    // Raising inside a collector callback is not allowed; the next VM
    // safepoint checks the same expired deadline, including through pcall.
    if (gc >= 0) return;
    const self: *Runtime = @ptrCast(@alignCast(api.lua_callbacks(l).userdata.?));
    if (ui.clock.now() > self.deadline) {
        api.lua_pushstring(l, "native UI execution limit exceeded");
        api.lua_error(l);
    }
}

test {
    _ = @import("tests.zig");
}
