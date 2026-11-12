//! What the layout tests share: a document built by hand with styles set
//! directly on its nodes, and a measurer with round numbers: every byte half
//! an em wide, ascent 0.8em, descent 0.2em. At 16px a character is 8 wide and
//! a line 16 tall, with its baseline 12.8 below the top. `data-w`, `data-h` on
//! an element are its picture's size.
const std = @import("std");
const box = @import("box.zig");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const layout = @import("layout.zig");

pub const Style = css.Style;
pub const Len = css.Len;
pub const Box = box.Box;
pub const Node = dom.Node;

fn fakeWidth(_: *anyopaque, text: []const u8, font: box.Font) f32 {
    return @as(f32, @floatFromInt(text.len)) * font.size * 0.5;
}

fn fakeMetrics(_: *anyopaque, font: box.Font) box.Metrics {
    return .{ .ascent = font.size * 0.8, .descent = font.size * 0.2, .gap = 0 };
}

fn fakeImage(_: *anyopaque, node: *dom.Node) ?box.Size {
    const w = node.attr("data-w") orelse return null;
    const h = node.attr("data-h") orelse return null;
    return .{
        .w = std.fmt.parseFloat(f32, w) catch return null,
        .h = std.fmt.parseFloat(f32, h) catch return null,
    };
}

var dummy: u8 = 0;
pub const measurer: box.Measurer = .{ .ctx = &dummy, .width = fakeWidth, .metrics = fakeMetrics, .image = fakeImage };

pub const T = struct {
    arena_state: *std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    doc: *dom.Document,
    html: *Node,
    body: *Node,
    tree: box.Tree = undefined,

    pub fn init() !T {
        const state = try std.testing.allocator.create(std.heap.ArenaAllocator);
        state.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = state.allocator();
        const doc = try dom.Document.create(a);
        var t: T = .{ .arena_state = state, .a = a, .doc = doc, .html = undefined, .body = undefined };
        t.html = try t.el(doc.node, "html", .{ .display = .block });
        t.body = try t.el(t.html, "body", .{ .display = .block });
        return t;
    }

    pub fn deinit(t: *T) void {
        t.arena_state.deinit();
        std.testing.allocator.destroy(t.arena_state);
    }

    /// A new element under `parent`, with this style.
    pub fn el(t: *T, parent: *Node, tag: []const u8, s: Style) !*Node {
        const n = try t.doc.createElement(tag);
        const st = try t.a.create(Style);
        st.* = s;
        n.computed = st;
        parent.appendChild(n);
        return n;
    }

    pub fn div(t: *T, parent: *Node, s: Style) !*Node {
        var st = s;
        if (st.display == .inline_) st.display = .block;
        return t.el(parent, "div", st);
    }

    pub fn span(t: *T, parent: *Node, s: Style) !*Node {
        return t.el(parent, "span", s);
    }

    pub fn text(t: *T, parent: *Node, s: []const u8) !*Node {
        const n = try t.doc.createText(s);
        parent.appendChild(n);
        return n;
    }

    pub fn run(t: *T, vw: f32, vh: f32) !void {
        t.tree = try layout.run(t.a, t.doc, .{ .width = vw, .height = vh }, measurer);
    }

    pub fn boxOf(t: *T, n: *Node) *Box {
        _ = t;
        return @ptrCast(@alignCast(n.liveBox().?));
    }

    /// Expects `n`'s border box.
    pub fn rect(t: *T, n: *Node, x: f32, y: f32, w: f32, h: f32) !void {
        const b = t.boxOf(n);
        try close(x, b.x, "x");
        try close(y, b.y, "y");
        try close(w, b.w, "w");
        try close(h, b.h, "h");
    }

    /// A box's lines of text, gathered down its inline children in order of
    /// where they are.
    pub fn firstRun(t: *T, n: *Node) box.TextRun {
        return t.boxOf(n).runs[0];
    }
};

pub fn close(want: f32, got: f32, what: []const u8) !void {
    if (@abs(want - got) > 0.01) {
        std.debug.print("{s}: want {d}, got {d}\n", .{ what, want, got });
        return error.TestExpectedEqual;
    }
}

pub fn px(v: f32) Len {
    return Len.of(v);
}

pub fn pct(v: f32) Len {
    return .{ .pct = v };
}

pub fn eqText(a: []const u8, b: []const u8) !void {
    try std.testing.expectEqualStrings(a, b);
}
