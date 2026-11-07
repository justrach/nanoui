//! What a `<canvas>` shows, whichever context draws it: a WebGL or WebGPU context
//! registers here, and paint asks it for this frame's pixels when the canvas is in view,
//! so what's scrolled away is never read back from the GPU.
const std = @import("std");
const nanoui = @import("nanoui");
const dom = @import("../dom.zig");

pub const Source = struct {
    ctx: *anyopaque,
    /// Premultiplied BGRA, the top row first, alive until the frame is drawn. Null:
    /// nothing to show yet.
    pixels: *const fn (ctx: *anyopaque) ?nanoui.ui.Texture,
};

pub const Table = struct {
    map: std.AutoHashMapUnmanaged(*dom.Node, Source) = .empty,

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.map.deinit(gpa);
    }

    /// `node` shows `source` from now on, in place of what it showed.
    pub fn set(t: *Table, gpa: std.mem.Allocator, node: *dom.Node, source: Source) !void {
        try t.map.put(gpa, node, source);
    }

    pub fn remove(t: *Table, node: *dom.Node) void {
        _ = t.map.remove(node);
    }

    pub fn pixelsOf(t: *const Table, node: *dom.Node) ?nanoui.ui.Texture {
        const s = t.map.get(node) orelse return null;
        return s.pixels(s.ctx);
    }
};
