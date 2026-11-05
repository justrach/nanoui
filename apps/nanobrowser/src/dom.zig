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

    /// `hasClass`'s filter, and the attribute text it is of.
    class_filter: u64 = 0,
    class_src: [*]const u8 = "".ptr,
    class_src_len: usize = 0,

    /// A shadow root's stand-in: an element whose parent is its host, though it
    /// is none of the host's children, so walks of the host's tree stay out of it.
    /// What is in it is what the host renders.
    is_shadow: bool = false,
    /// On a shadow root: scripts don't get to it through its host. Made by the parser.
    shadow_closed: bool = false,
    shadow_declarative: bool = false,
    /// On a host: its shadow root.
    shadow_root: ?*Node = null,
    /// The shadow root of the tree the element is in, null in the document's: which
    /// rules can match it. Kept by the cascade.
    tree_scope: ?*Node = null,
    /// A `<template>`'s content: a fragment that is outside the document.
    template_content: ?*Node = null,
    /// A container's content box from the last layout, for `@container` and cq
    /// units; negative until it has had one.
    container_w: f32 = -1,
    container_h: f32 = -1,
    /// `::marker`'s and `::backdrop`'s styles.
    marker: ?*const style.Style = null,
    backdrop: ?*const style.Style = null,
    /// `showModal()` or `showPopover()` has it above everything (`Document.top_layer`).
    in_top_layer: bool = false,
    /// Showing as a popover: `:popover-open`.
    popover_open: bool = false,
    /// Showing by `showModal()`: `:modal`.
    modal: bool = false,
    /// An inline split around blocks: its boxes, whose union its rect is.
    box_parts: []const *anyopaque = &.{},

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
    /// Its `srcset` candidate's density: file pixels to a CSS pixel.
    image_density: f32 = 1,

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
        n.doc.touchAttr(n, name);
        if (changesBoxes(n, name)) n.doc.touchLayout();
        for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, name)) {
            a.value = v;
            return;
        };
        try n.attrs.append(gpa, .{ .name = try gpa.dupe(u8, name), .value = v });
    }

    pub fn removeAttr(n: *Node, name: []const u8) void {
        for (n.attrs.items, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) {
            _ = n.attrs.orderedRemove(i);
            n.doc.touchAttr(n, name);
            if (changesBoxes(n, name)) n.doc.touchLayout();
            return;
        };
    }

    /// An attribute that decides what boxes there are, with no style changing.
    fn changesBoxes(n: *const Node, name: []const u8) bool {
        return n.isTag("details") and std.mem.eql(u8, name, "open");
    }

    fn classBit(name: []const u8) u64 {
        const mix = @as(u32, name[0]) *% 31 +% @as(u32, name[name.len - 1]) *% 17 +% @as(u32, @truncate(name.len));
        return @as(u64, 1) << @intCast(mix & 63);
    }

    /// Whether the `class` attribute lists `name`. Style matching asks this all
    /// the time, and mostly the answer is no: each node keeps a little filter
    /// of its classes, good until the attribute's text is replaced.
    pub fn hasClass(n: *const Node, name: []const u8) bool {
        const list = n.attr("class") orelse return false;
        if (name.len == 0) return false;
        if (n.class_src != list.ptr or n.class_src_len != list.len) {
            var bits: u64 = 0;
            var words = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
            while (words.next()) |w| bits |= classBit(w);
            const self = @constCast(n);
            self.class_src = list.ptr;
            self.class_src_len = list.len;
            self.class_filter = bits;
        }
        if (n.class_filter & classBit(name) == 0) return false;
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
        n.doc.touchTree(n);
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
        n.doc.touchTree(p);
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

    /// The next node in the tree with shadow trees in it: a host's shadow tree
    /// comes before its children. Stays inside `root`.
    pub fn nextDeep(n: *Node, root: *const Node) ?*Node {
        if (n.shadow_root) |r| return r;
        if (n.first_child) |c| return c;
        return n.nextDeepSkipping(root);
    }

    /// As `nextDeep`, past what is in this node.
    pub fn nextDeepSkipping(n: *Node, root: *const Node) ?*Node {
        var at: *Node = n;
        while (at != root) {
            if (at.is_shadow) {
                // A shadow tree is over: its host's own children are next.
                const host = at.parent orelse return null;
                if (host.first_child) |c| return c;
                at = host;
                continue;
            }
            if (at.next) |s| return s;
            at = at.parent orelse return null;
        }
        return null;
    }

    /// Gives the element a shadow root.
    pub fn attachShadow(n: *Node, closed: bool, declarative: bool) Allocator.Error!*Node {
        const root = try n.doc.createElement("slot");
        root.is_shadow = true;
        root.shadow_closed = closed;
        root.shadow_declarative = declarative;
        root.parent = n;
        n.shadow_root = root;
        n.doc.touchTree(n);
        return root;
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
    /// Goes up as style is touched: what live collections know themselves by.
    generation: u32 = 0,
    /// Goes up when anything in an inline `<svg>` changes: what's drawn from
    /// their markup is made again (`paint/svg_markup.zig`).
    svg_version: u32 = 0,
    svg_dirty: bool = false,
    /// What a restyle has to look at: everything, or under just these.
    dirty_all: bool = true,
    dirty_nodes: std.ArrayList(*Node) = .empty,
    /// What `showModal()` and `showPopover()` have raised, the oldest first.
    top_layer: std.ArrayList(*Node) = .empty,

    pub fn create(arena: Allocator) Allocator.Error!*Document {
        const d = try arena.create(Document);
        const n = try arena.create(Node);
        n.* = .{ .kind = .document, .doc = d };
        d.* = .{ .arena = arena, .node = n };
        return d;
    }

    /// Everything's style may have changed.
    pub fn touchStyle(d: *Document) void {
        d.generation +%= 1;
        d.style_dirty = true;
        d.layout_dirty = true;
        d.dirty_all = true;
    }

    fn inDocument(d: *const Document, n: *const Node) bool {
        var at: ?*const Node = n;
        while (at) |x| : (at = x.parent) if (x == d.node) return true;
        return false;
    }

    /// `n` and what's under it restyle.
    pub fn markStyle(d: *Document, n: *Node) void {
        d.touchUnder(n);
    }

    /// The style of what's under `n` may have changed: only that restyles.
    fn touchUnder(d: *Document, n: *Node) void {
        d.style_dirty = true;
        if (d.dirty_all) return;
        if (d.dirty_nodes.items.len >= 256) {
            d.dirty_all = true;
            return;
        }
        d.dirty_nodes.append(d.arena, n) catch {
            d.dirty_all = true;
        };
    }

    /// An attribute of `n` changed. Layout follows only if style did. What
    /// selects by it reaches its siblings at most, unless it is the inline style.
    fn touchAttr(d: *Document, n: *Node, name: []const u8) void {
        d.generation +%= 1;
        if (!d.inDocument(n)) return;
        d.touchUnder(if (std.mem.eql(u8, name, "style")) n else n.parent orelse n);
    }

    /// `n`'s children changed.
    fn touchTree(d: *Document, n: *Node) void {
        d.generation +%= 1;
        if (!d.inDocument(n)) return;
        d.layout_dirty = true;
        d.touchUnder(n);
    }

    /// The top modal dialog: what's outside it takes no input.
    pub fn modalDialog(d: *const Document) ?*Node {
        var i = d.top_layer.items.len;
        while (i > 0) {
            i -= 1;
            if (d.top_layer.items[i].modal) return d.top_layer.items[i];
        }
        return null;
    }

    /// Raises `n`, or lowers it when `up` is false.
    pub fn setTopLayer(d: *Document, n: *Node, up: bool) void {
        for (d.top_layer.items, 0..) |x, i| if (x == n) {
            _ = d.top_layer.orderedRemove(i);
            break;
        };
        n.in_top_layer = up;
        if (up) d.top_layer.append(d.arena, n) catch {
            n.in_top_layer = false;
        };
        d.touchStyle();
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
