//! Validate inert trees with raw reads: script metatables never execute here.
const std = @import("std");
const ui = @import("nanoui").ui;
const a = @import("api.zig");
pub const Kind = enum { column, row, layer, rect, text };
pub const Motion = struct {
    spring: bool = true,
    x: f32 = 0,
    y: f32 = 0,
    stiffness: f32 = 140,
    damping: f32 = 20,
    duration: f32 = 0.18,
};
pub const Node = struct {
    kind: Kind,
    id: []const u8,
    text: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    gap: f32 = 0,
    radius: f32 = 0,
    opacity: f32 = 1,
    color: u24 = 0,
    size: f32 = 14,
    motion: ?Motion = null,
    children: []Node = &.{},
};

pub const Parser = struct {
    lua: *a.State,
    arena: std.mem.Allocator,
    deadline: f64,
    nodes: usize = 0,
    bytes: usize = 0,
    ids: std.StringHashMapUnmanaged(void) = .empty,

    pub fn parse(p: *Parser, depth: usize) anyerror!Node {
        if (depth > 16 or p.nodes >= 128) return error.TreeLimit;
        if (ui.clock.now() > p.deadline) return error.ExecutionLimit;
        p.nodes += 1;
        const l = p.lua;
        if (a.lua_type(l, -1) != a.table) return error.ExpectedNode;
        const at = a.lua_gettop(l);
        try fields(l, at, &.{ "kind", "id", "text", "x", "y", "width", "height", "gap", "radius", "opacity", "color", "size", "motion", "children" });
        const kind = std.meta.stringToEnum(Kind, try p.string(at, "kind", true, 16)) orelse return error.UnknownNode;
        const id = try p.string(at, "id", true, 64);
        if (id.len == 0) return error.InvalidId;
        const entry = try p.ids.getOrPut(p.arena, id);
        if (entry.found_existing) return error.DuplicateId;
        var n = Node{ .kind = kind, .id = id };
        n.text = try p.string(at, "text", kind == .text, 4096);
        n.x = try number(l, at, "x", 0, -100000, 100000);
        n.y = try number(l, at, "y", 0, -100000, 100000);
        n.width = try number(l, at, "width", 0, 0, 100000);
        n.height = try number(l, at, "height", 0, 0, 100000);
        n.gap = try number(l, at, "gap", 0, 0, 1000);
        n.radius = try number(l, at, "radius", 0, 0, 10000);
        n.opacity = try number(l, at, "opacity", 1, 0, 1);
        n.size = try number(l, at, "size", 14, 1, 256);
        const rgb = try number(l, at, "color", 0, 0, 0xffffff);
        if (@trunc(rgb) != rgb) return error.InvalidNumber;
        n.color = @intFromFloat(rgb);
        if (a.lua_rawgetfield(l, at, "motion") != 0) {
            defer a.pop(l);
            if (a.lua_type(l, -1) != a.table) return error.InvalidMotion;
            const mi = a.lua_gettop(l);
            try fields(l, mi, &.{ "mode", "x", "y", "stiffness", "damping", "duration" });
            const mode = try p.string(mi, "mode", true, 8);
            if (!std.mem.eql(u8, mode, "spring") and !std.mem.eql(u8, mode, "tween")) return error.InvalidMotion;
            n.motion = .{
                .spring = std.mem.eql(u8, mode, "spring"),
                .x = try number(l, mi, "x", 0, -128, 128),
                .y = try number(l, mi, "y", 0, -128, 128),
                .stiffness = try number(l, mi, "stiffness", 140, 1, 1000),
                .damping = try number(l, mi, "damping", 20, 1, 100),
                .duration = try number(l, mi, "duration", 0.18, 0, 2),
            };
        } else a.pop(l);
        if (a.lua_rawgetfield(l, at, "children") != 0) {
            defer a.pop(l);
            if (a.lua_type(l, -1) != a.table or kind == .text or kind == .rect) return error.InvalidChildren;
            const ci = a.lua_gettop(l);
            const len = a.lua_objlen(l, ci);
            if (len < 0 or len > 128) return error.TreeLimit;
            // objlen alone doesn't reject sparse arrays or map-shaped children.
            var count: usize = 0;
            a.lua_pushnil(l);
            while (a.lua_next(l, ci) != 0) {
                defer a.pop(l);
                if (a.lua_type(l, -2) != a.number) return error.InvalidChildren;
                const key = a.lua_tonumberx(l, -2, null);
                if (!std.math.isFinite(key) or @trunc(key) != key or key < 1 or key > @as(f64, @floatFromInt(len))) return error.InvalidChildren;
                count += 1;
            }
            if (count != @as(usize, @intCast(len))) return error.InvalidChildren;
            n.children = try p.arena.alloc(Node, count);
            for (n.children, 0..) |*child, i| {
                _ = a.lua_rawgeti(l, ci, @intCast(i + 1));
                defer a.pop(l);
                child.* = try p.parse(depth + 1);
            }
        } else a.pop(l);
        return n;
    }

    fn string(p: *Parser, at: c_int, key: [*:0]const u8, required: bool, max: usize) ![]const u8 {
        _ = a.lua_rawgetfield(p.lua, at, key);
        defer a.pop(p.lua);
        if (!required and a.lua_type(p.lua, -1) == 0) return "";
        const value = a.text(p.lua, -1) orelse return error.ExpectedString;
        p.bytes += value.len;
        if (value.len > max or p.bytes > 8192 or !std.unicode.utf8ValidateSlice(value)) return error.TextLimit;
        return p.arena.dupe(u8, value);
    }
};

fn fields(l: *a.State, at: c_int, allowed: []const []const u8) !void {
    a.lua_pushnil(l);
    while (a.lua_next(l, at) != 0) {
        defer a.pop(l);
        const key = a.text(l, -2) orelse return error.UnknownProperty;
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.UnknownProperty;
    }
}

fn number(l: *a.State, at: c_int, key: [*:0]const u8, fallback: f32, min: f32, max: f32) !f32 {
    _ = a.lua_rawgetfield(l, at, key);
    defer a.pop(l);
    if (a.lua_type(l, -1) == 0) return fallback;
    if (a.lua_type(l, -1) != a.number) return error.InvalidNumber;
    const value = a.lua_tonumberx(l, -1, null);
    if (!std.math.isFinite(value) or value < min or value > max) return error.InvalidNumber;
    return @floatCast(value);
}
