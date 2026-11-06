//! What a context must remember so a page's draw can't send the driver past the end of a
//! buffer: each buffer's size, each attribute's layout, each program's inputs. GL itself
//! keeps all this and checks none of it, and JS's copy could be tampered with, so it lives
//! here; `check*` answer the GL error to raise, 0 for fine. No GL calls: tested on its own.
const std = @import("std");

pub const INVALID_ENUM: u32 = 0x0500;
pub const INVALID_VALUE: u32 = 0x0501;
pub const INVALID_OPERATION: u32 = 0x0502;
pub const OUT_OF_MEMORY: u32 = 0x0505;

pub const max_attribs = 16;
pub const max_ubo_bindings = 72;

pub const Buffer = struct {
    /// WebGL's rule: a buffer that has held indices can only hold indices.
    pub const Kind = enum { unset, element, other };
    size: u64 = 0,
    kind: Kind = .unset,
    /// Index buffers' bytes, for finding the highest index without a round trip.
    shadow: []u8 = &.{},
};

pub const Attrib = struct {
    enabled: bool = false,
    buffer: u32 = 0,
    /// Bytes of one vertex's value.
    bytes: u32 = 0,
    /// Bytes between vertices, never 0 here.
    stride: u32 = 0,
    offset: u64 = 0,
    divisor: u32 = 0,
};

pub const Vao = struct {
    attribs: [max_attribs]Attrib = @splat(.{}),
    element: u32 = 0,
};

pub const Block = struct { binding: u32, size: u32 };

pub const Program = struct {
    linked: bool = false,
    /// Attribute locations the program reads.
    inputs: u32 = 0,
    blocks: []Block = &.{},
};

pub const UboBinding = struct { buffer: u32 = 0, offset: u64 = 0, size: u64 = 0 };

pub const State = struct {
    gpa: std.mem.Allocator,
    buffers: std.AutoHashMapUnmanaged(u32, Buffer) = .empty,
    vaos: std.AutoHashMapUnmanaged(u32, *Vao) = .empty,
    programs: std.AutoHashMapUnmanaged(u32, Program) = .empty,
    default_vao: Vao = .{},
    vao: ?*Vao = null,
    array_buffer: u32 = 0,
    uniform_buffer: u32 = 0,
    copy_read: u32 = 0,
    copy_write: u32 = 0,
    program: u32 = 0,
    ubo: [max_ubo_bindings]UboBinding = @splat(.{}),

    pub fn deinit(s: *State) void {
        var b = s.buffers.valueIterator();
        while (b.next()) |x| s.gpa.free(x.shadow);
        s.buffers.deinit(s.gpa);
        var v = s.vaos.valueIterator();
        while (v.next()) |x| s.gpa.destroy(x.*);
        s.vaos.deinit(s.gpa);
        var p = s.programs.valueIterator();
        while (p.next()) |x| s.gpa.free(x.blocks);
        s.programs.deinit(s.gpa);
    }

    pub fn current(s: *State) *Vao {
        return s.vao orelse &s.default_vao;
    }

    /// A buffer's gone: nothing may draw from what the driver may reuse its name for.
    pub fn forgetBuffer(s: *State, name: u32) void {
        if (s.buffers.fetchRemove(name)) |kv| s.gpa.free(kv.value.shadow);
        forgetIn(&s.default_vao, name);
        var v = s.vaos.valueIterator();
        while (v.next()) |x| forgetIn(x.*, name);
        if (s.array_buffer == name) s.array_buffer = 0;
        if (s.uniform_buffer == name) s.uniform_buffer = 0;
        if (s.copy_read == name) s.copy_read = 0;
        if (s.copy_write == name) s.copy_write = 0;
        for (&s.ubo) |*u| if (u.buffer == name) {
            u.* = .{};
        };
    }

    fn forgetIn(v: *Vao, name: u32) void {
        if (v.element == name) v.element = 0;
        for (&v.attribs) |*a| if (a.buffer == name) {
            a.buffer = 0;
        };
    }

    /// The last index `count` things of an attribute reach, per instance or per vertex.
    fn reach(a: Attrib, last_vertex: u64, instances: u64) u64 {
        if (a.divisor == 0) return last_vertex;
        return (instances - 1) / a.divisor;
    }

    fn checkInputs(s: *State, last_vertex: u64, instances: u64) u32 {
        const program = s.programs.get(s.program) orelse return INVALID_OPERATION;
        if (!program.linked) return INVALID_OPERATION;
        const vao = s.current();
        var mask = program.inputs;
        while (mask != 0) : (mask &= mask - 1) {
            const i = @ctz(mask);
            if (i >= max_attribs) return INVALID_OPERATION;
            const a = vao.attribs[i];
            if (!a.enabled) continue;
            const b = s.buffers.get(a.buffer) orelse return INVALID_OPERATION;
            const end = std.math.mul(u64, reach(a, last_vertex, instances), a.stride) catch return INVALID_OPERATION;
            const tail = std.math.add(u64, a.offset, a.bytes) catch return INVALID_OPERATION;
            const need = std.math.add(u64, end, tail) catch return INVALID_OPERATION;
            if (need > b.size) return INVALID_OPERATION;
        }
        for (program.blocks) |block| {
            if (block.binding >= max_ubo_bindings) return INVALID_OPERATION;
            const u = s.ubo[block.binding];
            const b = s.buffers.get(u.buffer) orelse return INVALID_OPERATION;
            if (u.offset > b.size) return INVALID_OPERATION;
            const have = if (u.size != 0) @min(u.size, b.size - u.offset) else b.size - u.offset;
            if (have < block.size) return INVALID_OPERATION;
        }
        return 0;
    }

    /// `glDrawArrays`'s and `glDrawArraysInstanced`'s arguments, already non-negative.
    pub fn checkArrays(s: *State, first: u64, count: u64, instances: u64) u32 {
        if (count == 0 or instances == 0) return if (s.programReady()) 0 else INVALID_OPERATION;
        const last = std.math.add(u64, first, count - 1) catch return INVALID_OPERATION;
        return s.checkInputs(last, instances);
    }

    /// The same for `glDrawElements`; `restart` is whether WebGL 2's restart index is skipped.
    pub fn checkElements(s: *State, count: u64, kind: u32, offset: u64, instances: u64, restart: bool) u32 {
        const size: u64 = switch (kind) {
            0x1401 => 1,
            0x1403 => 2,
            0x1405 => 4,
            else => return INVALID_ENUM,
        };
        if (offset % size != 0) return INVALID_OPERATION;
        const b = s.buffers.get(s.current().element) orelse return INVALID_OPERATION;
        const bytes = std.math.mul(u64, count, size) catch return INVALID_OPERATION;
        const end = std.math.add(u64, offset, bytes) catch return INVALID_OPERATION;
        if (end > b.size or end > b.shadow.len) return INVALID_OPERATION;
        if (count == 0 or instances == 0) return if (s.programReady()) 0 else INVALID_OPERATION;
        const top = highestIndex(b.shadow[offset..end], size, restart) orelse return if (s.programReady()) 0 else INVALID_OPERATION;
        return s.checkInputs(top, instances);
    }

    fn programReady(s: *State) bool {
        const p = s.programs.get(s.program) orelse return false;
        return p.linked;
    }
};

/// The highest index in `bytes`, null if every one is the restart index.
pub fn highestIndex(bytes: []const u8, size: u64, restart: bool) ?u64 {
    var top: ?u64 = null;
    switch (size) {
        1 => for (bytes) |x| {
            if (restart and x == 0xff) continue;
            top = @max(top orelse 0, x);
        },
        2 => {
            var i: usize = 0;
            while (i + 2 <= bytes.len) : (i += 2) {
                const x = std.mem.readInt(u16, bytes[i..][0..2], .little);
                if (restart and x == 0xffff) continue;
                top = @max(top orelse 0, x);
            }
        },
        else => {
            var i: usize = 0;
            while (i + 4 <= bytes.len) : (i += 4) {
                const x = std.mem.readInt(u32, bytes[i..][0..4], .little);
                if (restart and x == 0xffffffff) continue;
                top = @max(top orelse 0, x);
            }
        },
    }
    return top;
}

const testing = std.testing;

fn ready(s: *State) !void {
    try s.programs.put(s.gpa, 7, .{ .linked = true, .inputs = 0b1 });
    s.program = 7;
    try s.buffers.put(s.gpa, 1, .{ .size = 24, .kind = .other });
    s.default_vao.attribs[0] = .{ .enabled = true, .buffer = 1, .bytes = 8, .stride = 8 };
}

test "webgl state: a draw inside the buffer passes, past its end doesn't" {
    var s: State = .{ .gpa = testing.allocator };
    defer s.deinit();
    try ready(&s);
    try testing.expectEqual(@as(u32, 0), s.checkArrays(0, 3, 1));
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 4, 1));
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(1, 3, 1));
    try testing.expectEqual(@as(u32, 0), s.checkArrays(2, 1, 1));
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0x7fffffff, 0x7fffffff, 1));
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(std.math.maxInt(u64), 2, 1));
    s.default_vao.attribs[0].offset = std.math.maxInt(u64);
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 1, 1));
}

test "webgl state: a draw with no linked program, or a bufferless enabled attribute, is refused" {
    var s: State = .{ .gpa = testing.allocator };
    defer s.deinit();
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 3, 1));
    try ready(&s);
    s.default_vao.attribs[0].buffer = 0;
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 3, 1));
    s.default_vao.attribs[0].enabled = false;
    try testing.expectEqual(@as(u32, 0), s.checkArrays(0, 3, 1));
}

test "webgl state: a deleted buffer can't be drawn from under a reused name" {
    var s: State = .{ .gpa = testing.allocator };
    defer s.deinit();
    try ready(&s);
    s.forgetBuffer(1);
    try s.buffers.put(s.gpa, 1, .{ .size = 1 << 20, .kind = .other });
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 3, 1));
}

test "webgl state: indices are read, offsets aligned, and instances counted by divisor" {
    var s: State = .{ .gpa = testing.allocator };
    defer s.deinit();
    try ready(&s);
    const shadow = try testing.allocator.dupe(u8, &.{ 0, 0, 2, 0, 3, 0 });
    try s.buffers.put(s.gpa, 2, .{ .size = 6, .kind = .element, .shadow = shadow });
    s.default_vao.element = 2;
    try testing.expectEqual(@as(u32, 0), s.checkElements(2, 0x1403, 0, 1, false));
    try testing.expectEqual(INVALID_OPERATION, s.checkElements(3, 0x1403, 0, 1, false));
    try testing.expectEqual(INVALID_OPERATION, s.checkElements(1, 0x1403, 1, 1, false));
    try testing.expectEqual(INVALID_OPERATION, s.checkElements(4, 0x1403, 0, 1, false));
    try testing.expectEqual(INVALID_ENUM, s.checkElements(1, 0x1406, 0, 1, false));
    s.default_vao.attribs[0].divisor = 2;
    try testing.expectEqual(@as(u32, 0), s.checkArrays(0, 100, 6));
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 100, 7));
}

test "webgl state: the highest index, restart skipped" {
    try testing.expectEqual(@as(?u64, 9), highestIndex(&.{ 1, 9, 3 }, 1, false));
    try testing.expectEqual(@as(?u64, 3), highestIndex(&.{ 1, 255, 3 }, 1, true));
    try testing.expectEqual(@as(?u64, null), highestIndex(&.{255}, 1, true));
}

test "webgl state: a uniform block's buffer must be big enough" {
    var s: State = .{ .gpa = testing.allocator };
    defer s.deinit();
    const blocks = try testing.allocator.dupe(Block, &.{.{ .binding = 3, .size = 32 }});
    try s.programs.put(s.gpa, 7, .{ .linked = true, .blocks = blocks });
    s.program = 7;
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 3, 1));
    try s.buffers.put(s.gpa, 1, .{ .size = 16, .kind = .other });
    s.ubo[3] = .{ .buffer = 1 };
    try testing.expectEqual(INVALID_OPERATION, s.checkArrays(0, 3, 1));
    try s.buffers.put(s.gpa, 1, .{ .size = 32, .kind = .other });
    try testing.expectEqual(@as(u32, 0), s.checkArrays(0, 3, 1));
}
