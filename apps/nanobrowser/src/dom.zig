//! The document tree. Every node lives in its page's arena and dies with the
//! page: removed nodes stay allocated, since a script may still hold them.
//! Knows nothing of nanoui or JavaScript; what they attach to a node is kept
//! in opaque fields.
const std = @import("std");
const Allocator = std.mem.Allocator;
const style = @import("css/style.zig");

pub const Kind = enum { document, fragment, element, text, comment, doctype };
pub const Ns = enum { html, svg, mathml };
pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Node = struct {
    kind: Kind,
    doc: *Document,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    prev: ?*Node = null,
    next: ?*Node = null,

    /// An element's name, lowercase ("div"); "" otherwise.
    tag: []const u8 = "",
    ns: Ns = .html,
    attrs: std.ArrayList(Attr) = .empty,
    /// A text's or comment's characters, a doctype's name.
    data: []const u8 = "",

    /// What the cascade last gave it (`css/cascade.zig`); null if display
    /// is none above it, or not yet styled. `before`, `after`: its pseudo
    /// elements, when they have `content`.
    computed: ?*const style.Style = null,
    before: ?*const style.Style = null,
    after: ?*const style.Style = null,
    /// The parsed `style` attribute (a `css.Declarations`), kept by the cascade.
    inline_decls: ?*anyopaque = null,
    /// `inline_decls` was parsed from this text (compared by pointer).
    inline_src: []const u8 = "",
    /// The custom properties in force (a `css/vars.zig` scope) and the
    /// cascade generation that `computed`, `before`, `after` and this belong
    /// to: a removed node may keep stale pointers until it is restyled.
    css_vars: ?*const anyopaque = null,
    style_generation: u32 = 0,

    /// The node's JS object (`web/`), its listeners, its layout box.
    js_object: ?*anyopaque = null,
    listeners: ?*anyopaque = null,
    box: ?*anyopaque = null,

    /// A form control's live state: the value when edited (else the
    /// attribute's), its editor (`paint/controls.zig`), checked and selected.
    value: ?[]const u8 = null,
    editor: ?*anyopaque = null,
    checked: ?bool = null,
    selected: ?bool = null,
    /// A decoded picture's bytes, from `<img>`: empty until it arrives.
    image: []const u8 = "",
    image_key: []const u8 = "",

    pub fn isElement(n: *const Node) bool {
        return n.kind == .element;
    }

    pub fn isTag(n: *const Node, tag: []const u8) bool {
        return n.kind == .element and std.mem.eql(u8, n.tag, tag);
    }

    pub fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs.items) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }

    pub fn hasAttr(n: *const Node, name: []const u8) bool {
        return n.attr(name) != null;
    }

    /// Sets an attribute; `name` and `value` are copied.
    pub fn setAttr(n: *Node, name: []const u8, value: []const u8) Allocator.Error!void {
        const gpa = n.doc.arena;
        const v = try gpa.dupe(u8, value);
        n.doc.touchStyle();
        for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, name)) {
            a.value = v;
            return;
        };
        try n.attrs.append(gpa, .{ .name = try gpa.dupe(u8, name), .value = v });
    }

    pub fn removeAttr(n: *Node, name: []const u8) void {
        for (n.attrs.items, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) {
            _ = n.attrs.orderedRemove(i);
            n.doc.touchStyle();
            return;
        };
    }

    /// Whether the `class` attribute lists `name`.
    pub fn hasClass(n: *const Node, name: []const u8) bool {
        const list = n.attr("class") orelse return false;
        var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
        while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
        return false;
    }

    pub fn firstElementChild(n: *const Node) ?*Node {
        var c = n.first_child;
        while (c) |k| : (c = k.next) if (k.kind == .element) return k;
        return null;
    }

    pub fn lastElementChild(n: *const Node) ?*Node {
        var c = n.last_child;
        while (c) |k| : (c = k.prev) if (k.kind == .element) return k;
        return null;
    }

    pub fn nextElement(n: *const Node) ?*Node {
        var c = n.next;
        while (c) |k| : (c = k.next) if (k.kind == .element) return k;
        return null;
    }

    pub fn prevElement(n: *const Node) ?*Node {
        var c = n.prev;
        while (c) |k| : (c = k.prev) if (k.kind == .element) return k;
        return null;
    }

    pub fn parentElement(n: *const Node) ?*Node {
        const p = n.parent orelse return null;
        return if (p.kind == .element) p else null;
    }

    /// Whether `other` is `n` or inside it.
    pub fn contains(n: *const Node, other: *const Node) bool {
        var at: ?*const Node = other;
        while (at) |a| : (at = a.parent) if (a == n) return true;
        return false;
    }

    /// Takes `child` from where it is and puts it before `ref` (at the end
    /// when null). A fragment gives its children. `child` must not contain `n`.
    pub fn insertBefore(n: *Node, child: *Node, ref: ?*Node) void {
        if (child.kind == .fragment) {
            while (child.first_child) |k| n.insertBefore(k, ref);
            return;
        }
        child.remove();
        child.parent = n;
        child.next = ref;
        child.prev = if (ref) |r| r.prev else n.last_child;
        if (child.prev) |p| p.next = child else n.first_child = child;
        if (ref) |r| r.prev = child else n.last_child = child;
        n.doc.touchStyle();
    }

    pub fn appendChild(n: *Node, child: *Node) void {
        n.insertBefore(child, null);
    }

    /// Takes the node out of its parent.
    pub fn remove(n: *Node) void {
        const p = n.parent orelse return;
        if (n.prev) |a| a.next = n.next else p.first_child = n.next;
        if (n.next) |b| b.prev = n.prev else p.last_child = n.prev;
        n.parent = null;
        n.prev = null;
        n.next = null;
        n.doc.touchStyle();
    }

    pub fn removeChildren(n: *Node) void {
        while (n.first_child) |c| c.remove();
    }

    /// The next node in document order; stays inside `root`.
    pub fn nextInTree(n: *Node, root: *const Node) ?*Node {
        if (n.first_child) |c| return c;
        return n.nextSkippingChildren(root);
    }

    /// As `nextInTree`, past this node's children.
    pub fn nextSkippingChildren(n: *Node, root: *const Node) ?*Node {
        var at: *Node = n;
        while (at != root) {
            if (at.next) |s| return s;
            at = at.parent orelse return null;
        }
        return null;
    }

    /// Appends the text of the node and everything in it to `out`.
    pub fn collectText(n: *Node, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (n.kind == .text) return out.appendSlice(gpa, n.data);
        if (n.kind == .comment or n.kind == .doctype) return;
        var at = n.first_child;
        while (at) |k| {
            if (k.kind == .text) try out.appendSlice(gpa, k.data);
            at = k.nextInTree(n);
        }
    }

    /// The text within the node, in `gpa`.
    pub fn textContent(n: *Node, gpa: Allocator) Allocator.Error![]const u8 {
        if (n.kind == .text or n.kind == .comment) return n.data;
        var out: std.ArrayList(u8) = .empty;
        try n.collectText(gpa, &out);
        return out.items;
    }

    /// Replaces the node's contents with one text node (none for "").
    pub fn setTextContent(n: *Node, s: []const u8) Allocator.Error!void {
        if (n.kind == .text or n.kind == .comment) return n.setData(s);
        n.removeChildren();
        if (s.len > 0) n.appendChild(try n.doc.createText(s));
    }

    /// Sets a text's characters; `s` is copied.
    pub fn setData(n: *Node, s: []const u8) Allocator.Error!void {
        n.data = try n.doc.arena.dupe(u8, s);
        n.doc.touchLayout();
    }
};

pub const Document = struct {
    /// The page's arena (see the top of this file).
    arena: Allocator,
    node: *Node,
    /// The URL it was loaded from.
    url: []const u8 = "about:blank",
    /// Style must be computed again; layout too, which that implies.
    style_dirty: bool = true,
    layout_dirty: bool = true,
    /// What `:hover`, `:active` and `:focus` match; setting them restyles.
    hover: ?*Node = null,
    active: ?*Node = null,
    focus: ?*Node = null,
    /// No doctype: quirks mode.
    quirks: bool = false,

    pub fn create(arena: Allocator) Allocator.Error!*Document {
        const d = try arena.create(Document);
        const n = try arena.create(Node);
        n.* = .{ .kind = .document, .doc = d };
        d.* = .{ .arena = arena, .node = n };
        return d;
    }

    pub fn touchStyle(d: *Document) void {
        d.style_dirty = true;
        d.layout_dirty = true;
    }

    pub fn touchLayout(d: *Document) void {
        d.layout_dirty = true;
    }

    pub fn createElement(d: *Document, tag: []const u8) Allocator.Error!*Node {
        return d.createElementNs(tag, .html);
    }

    /// `tag` is copied, lowercased unless the namespace keeps case (SVG).
    pub fn createElementNs(d: *Document, tag: []const u8, ns: Ns) Allocator.Error!*Node {
        const n = try d.arena.create(Node);
        const name = try d.arena.dupe(u8, tag);
        if (ns == .html) _ = std.ascii.lowerString(name, name);
        n.* = .{ .kind = .element, .doc = d, .tag = name, .ns = ns };
        return n;
    }

    pub fn createText(d: *Document, s: []const u8) Allocator.Error!*Node {
        const n = try d.arena.create(Node);
        n.* = .{ .kind = .text, .doc = d, .data = try d.arena.dupe(u8, s) };
        return n;
    }

    pub fn createComment(d: *Document, s: []const u8) Allocator.Error!*Node {
        const n = try d.arena.create(Node);
        n.* = .{ .kind = .comment, .doc = d, .data = try d.arena.dupe(u8, s) };
        return n;
    }

    pub fn createFragment(d: *Document) Allocator.Error!*Node {
        const n = try d.arena.create(Node);
        n.* = .{ .kind = .fragment, .doc = d };
        return n;
    }

    pub fn documentElement(d: *const Document) ?*Node {
        return d.node.firstElementChild();
    }

    fn childOfRoot(d: *const Document, tag: []const u8) ?*Node {
        const root = d.documentElement() orelse return null;
        var c = root.first_child;
        while (c) |k| : (c = k.next) if (k.isTag(tag)) return k;
        return null;
    }

    pub fn head(d: *const Document) ?*Node {
        return d.childOfRoot("head");
    }

    pub fn body(d: *const Document) ?*Node {
        return d.childOfRoot("body") orelse d.childOfRoot("frameset");
    }

    pub fn getElementById(d: *const Document, id: []const u8) ?*Node {
        var at = d.node.first_child;
        while (at) |n| : (at = n.nextInTree(d.node)) {
            if (n.kind == .element) if (n.attr("id")) |v| if (std.mem.eql(u8, v, id)) return n;
        }
        return null;
    }

    /// The first `<title>`'s text, whitespace collapsed by the caller.
    pub fn title(d: *const Document, gpa: Allocator) Allocator.Error![]const u8 {
        var at = d.node.first_child;
        while (at) |n| : (at = n.nextInTree(d.node)) {
            if (n.isTag("title")) return n.textContent(gpa);
        }
        return "";
    }
};

test "tree edits keep their links" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const d = try Document.create(a.allocator());
    const p = try d.createElement("DIV");
    try std.testing.expectEqualStrings("div", p.tag);
    d.node.appendChild(p);
    const x = try d.createText("x");
    const y = try d.createText("y");
    p.appendChild(y);
    p.insertBefore(x, y);
    try std.testing.expectEqualStrings("xy", try p.textContent(a.allocator()));
    x.remove();
    try std.testing.expect(p.first_child == y and y.prev == null);
    const f = try d.createFragment();
    f.appendChild(x);
    p.appendChild(f);
    try std.testing.expect(p.last_child == x and f.first_child == null);
    try p.setAttr("id", "me");
    try std.testing.expect(d.getElementById("me") == p);
}
