//! The document tree. Every node lives in its page's arena and dies with the
//! page: removed nodes stay allocated, since a script may still hold them.
//! Knows nothing of nanoui or JavaScript; what they attach to a node is kept
//! in opaque fields.
const std = @import("std");
const Allocator = std.mem.Allocator;
const style = @import("css/style.zig");
const perf = @import("perf_rules.zig");
const dom_flags = @import("dom_flags.zig");

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
    html_tag: perf.HtmlTag = .other,
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

    /// `hasClass`'s filter, cached `id`/`class` slices, and single-class fast state (Theorem 35 & 44).
    id_attr: ?[]const u8 = null,
    class_attr: ?[]const u8 = null,
    class_filter: u64 = 0,
    attr_filter: u64 = 0,
    subtree_class_bloom: u64 = 0,
    subtree_attr_bloom: u64 = 0,
    ancestor_bloom: u64 = 0,
    ancestor_hash: u64 = 0,
    class_src: [*]const u8 = "".ptr,
    class_src_len: usize = 0,
    class_single: bool = false,
    subtree_layout_dirty: bool = true,

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
    /// Upward-closed summary: this element or a descendant is a resource/sheet tag.
    has_resource: bool = false,
    has_id: bool = false,
    has_insertion_work: bool = false,
    has_on_attr: bool = false,
    /// Queued in `Document.dirty_nodes` for the next `flushStyle` pass.
    style_queued: bool = false,
    has_js_listeners: bool = false,
    children_gen: u32 = 0,
    style_shared_gen: u32 = 0,
    box_gen: u32 = 0,
    style_canon: ?*const style.Style = null,
    /// An inline split around blocks: its boxes, whose union its rect is.
    box_parts: []const *anyopaque = &.{},

    js_object: ?*anyopaque = null,
    js_style: ?*anyopaque = null,
    js_class_list: ?*anyopaque = null,
    box: ?*anyopaque = null,
    text_cache: ?*anyopaque = null,

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

    pub fn isElement(n: *const Node) bool { return n.kind == .element; }
    pub inline fn liveBox(n: *const Node) ?*anyopaque { return if (n.box_gen == n.doc.box_generation) n.box else null; }
    pub inline fn liveBoxParts(n: *const Node) []const *anyopaque { return if (n.box_gen == n.doc.box_generation) n.box_parts else &.{}; }
    pub inline fn setBox(n: *Node, b: ?*anyopaque) void { n.box = b; n.box_parts = &.{}; n.box_gen = n.doc.box_generation; }

    pub inline fn isTag(n: *const Node, tag: []const u8) bool {
        return n.kind == .element and n.tag.len == tag.len and (n.tag.len == 0 or (n.tag[0] == tag[0] and std.mem.eql(u8, n.tag, tag)));
    }

    pub inline fn attr(n: *const Node, name: []const u8) ?[]const u8 {
        if ((n.attr_filter & perf.attrBit(name)) == 0) return null;
        if (name.len == 2 and name[0] == 'i' and name[1] == 'd') return n.id_attr;
        if (name.len == 5 and name[0] == 'c' and std.mem.eql(u8, name, "class")) return n.class_attr;
        for (n.attrs.items) |a| if (a.name.len == name.len and (name.len == 0 or (a.name[0] == name[0] and std.mem.eql(u8, a.name, name)))) return a.value;
        return null;
    }

    pub fn hasAttr(n: *const Node, name: []const u8) bool { return n.attr(name) != null; }

    /// Sets an attribute; `name` and `value` are copied.
    pub fn setAttr(n: *Node, name: []const u8, value: []const u8) Allocator.Error!void {
        const gpa = n.doc.arena;
        for (n.attrs.items) |*a| if (std.mem.eql(u8, a.name, name)) {
            if (std.mem.eql(u8, a.value, value)) return;
            a.value = try gpa.dupe(u8, value);
            perf.syncNodeAttr(n, name, a.value);
            dom_flags.markSubtreeLayoutDirty(n);
            n.doc.touchAttr(n, name);
            if (changesBoxes(n, name)) n.doc.touchNodeLayout(n);
            return;
        };
        const v = try gpa.dupe(u8, value);
        try n.attrs.append(gpa, .{ .name = try gpa.dupe(u8, name), .value = v });
        if (name.len > 2 and name[0] == 'o' and name[1] == 'n') n.has_on_attr = true;
        perf.syncNodeAttr(n, name, v);
        dom_flags.markSubtreeLayoutDirty(n);
        n.doc.touchAttr(n, name);
        if (changesBoxes(n, name)) n.doc.touchNodeLayout(n);
    }

    pub fn removeAttr(n: *Node, name: []const u8) void {
        for (n.attrs.items, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) {
            _ = n.attrs.orderedRemove(i);
            perf.syncNodeAttr(n, name, null);
            dom_flags.markSubtreeLayoutDirty(n);
            n.doc.touchAttr(n, name);
            if (changesBoxes(n, name)) n.doc.touchNodeLayout(n);
            return;
        };
    }

    /// An attribute that decides what boxes there are, with no style changing.
    fn changesBoxes(n: *const Node, name: []const u8) bool { return n.isTag("details") and std.mem.eql(u8, name, "open"); }

    /// Whether the `class` attribute lists `name` (Theorem 35).
    pub fn hasClass(n: *const Node, name: []const u8) bool { return perf.hasNodeClass(n, name); }

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
            const first = child.first_child orelse return;
            const last = child.last_child.?;
            child.first_child = null;
            child.last_child = null;
            child.children_gen +%= 1;
            n.children_gen +%= 1;
            var has_res = n.isTag("style");
            var has_id = false;
            var has_work = false;
            var sub_cls: u64 = 0;
            var sub_att: u64 = 0;
            var k: ?*Node = first;
            while (k) |x| : (k = x.next) {
                x.parent = n;
                if (x.has_resource) has_res = true;
                if (x.has_id) has_id = true;
                if (x.has_insertion_work) has_work = true;
                sub_cls |= x.subtree_class_bloom;
                sub_att |= x.subtree_attr_bloom;
            }
            const prev = if (ref) |r| r.prev else n.last_child;
            first.prev = prev;
            last.next = ref;
            if (prev) |p| p.next = first else n.first_child = first;
            if (ref) |r| r.prev = last else n.last_child = last;
            dom_flags.propagateInsert(n, has_res, has_id, has_work, sub_cls, sub_att);
            dom_flags.touchTreeInsert(n.doc, n, first, last, has_id);
            return;
        }
        child.remove();
        child.parent = n;
        child.next = ref;
        child.prev = if (ref) |r| r.prev else n.last_child;
        if (child.prev) |p| p.next = child else n.first_child = child;
        if (ref) |r| r.prev = child else n.last_child = child;
        n.children_gen +%= 1;
        dom_flags.propagateInsert(n, child.has_resource or n.isTag("style"), child.has_id, child.has_insertion_work, child.subtree_class_bloom, child.subtree_attr_bloom);
        dom_flags.touchTreeInsert(n.doc, n, child, child, child.has_id);
    }

    pub fn appendChild(n: *Node, child: *Node) void { n.insertBefore(child, null); }

    /// Links a freshly created node into `n` during parsing or cloning without `touchTree`.
    pub fn parserInsert(n: *Node, child: *Node, ref: ?*Node) void {
        child.parent = n;
        child.next = ref;
        child.prev = if (ref) |r| r.prev else n.last_child;
        if (child.prev) |p| p.next = child else n.first_child = child;
        if (ref) |r| r.prev = child else n.last_child = child;
        n.children_gen +%= 1;
        dom_flags.propagateInsert(n, child.has_resource or n.isTag("style"), child.has_id, child.has_insertion_work, child.subtree_class_bloom, child.subtree_attr_bloom);
    }

    /// Takes the node out of its parent.
    pub fn remove(n: *Node) void {
        const p = n.parent orelse return;
        const prev_el = if (n.kind == .element) n.prevElement() else null;
        const next_el = if (n.kind == .element) n.nextElement() else null;
        if (n.prev) |a| a.next = n.next else p.first_child = n.next;
        if (n.next) |b| b.prev = n.prev else p.last_child = n.prev;
        n.parent = null;
        n.prev = null;
        n.next = null;
        n.subtree_layout_dirty = true;
        p.children_gen +%= 1;
        dom_flags.markSubtreeLayoutDirty(p);
        if (n.has_resource or p.isTag("style")) n.doc.scan_dirty = true;
        dom_flags.touchTreeRemove(n.doc, p, n.kind == .element, prev_el, next_el, n.has_id);
    }

    pub fn removeChildren(n: *Node) void {
        var c = n.first_child orelse return;
        n.first_child = null;
        n.last_child = null;
        n.children_gen +%= 1;
        dom_flags.markSubtreeLayoutDirty(n);
        var scan = n.isTag("style");
        var had_id = false;
        while (true) {
            const next = c.next;
            if (c.has_resource) scan = true;
            if (c.has_id) had_id = true;
            c.parent = null;
            c.prev = null;
            c.next = null;
            c.subtree_layout_dirty = true;
            c = next orelse break;
        }
        if (scan) n.doc.scan_dirty = true;
        dom_flags.touchTreeClear(n.doc, n, had_id);
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
        dom_flags.markSubtreeLayoutDirty(n);
        n.doc.touchTree(n, false);
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
        if (std.mem.eql(u8, n.data, s)) return;
        n.data = try n.doc.arena.dupe(u8, s);
        if (n.parent) |p| {
            if (p.isTag("style")) {
                n.doc.scan_dirty = true;
                n.doc.markStyle(p);
            }
            if (p.ns == .svg) {
                n.doc.svg_version +%= 1;
                n.doc.svg_dirty = true;
                return;
            }
        }
        n.doc.touchNodeLayout(n);
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
    scan_dirty: bool = true,
    /// What `:hover`, `:active` and `:focus` match; setting them restyles.
    hover: ?*Node = null,
    active: ?*Node = null,
    focus: ?*Node = null,
    /// No doctype: quirks mode.
    quirks: bool = false,
    /// Goes up as style is touched: what live collections know themselves by.
    generation: u32 = 0,
    /// Goes up when non-SVG-interior tree structure changes (outermost `<svg>` roots).
    svg_roots_generation: u32 = 0,
    box_generation: u32 = 1,
    layout_cache_gen: u32 = 1,
    /// Goes up when tree structure or an `id` attribute changes (Theorem 16).
    id_generation: u32 = 1,
    id_map_gen: u32 = 0,
    id_last_gen: u32 = 0,
    id_has_dups: bool = false,
    id_last_key: []const u8 = "",
    id_last_node: ?*Node = null,
    id_map: std.StringHashMapUnmanaged(*Node) = .empty,
    /// Per-document 128-slot parsed selector cache (Theorem 70).
    sel_cache_keys: [128][]const u8 = @splat(""),
    sel_cache_ptrs: [128]?*const anyopaque = @splat(null),
    sel_cache_lens: [128]u32 = @splat(0),
    svg_version: u32 = 0,
    svg_style_version: u32 = 0,
    font_epoch: u32 = 0,
    svg_dirty: bool = false,
    rule_flags: u8 = 0x7f,
    rule_attr_filter: u64 = std.math.maxInt(u64),
    rule_id_bloom: u64 = std.math.maxInt(u64),
    /// What a restyle has to look at: everything, or under just these.
    dirty_all: bool = true,
    dirty_nodes: std.ArrayList(*Node) = .empty,
    oof_dirty_node: ?*Node = null,
    /// What `showModal()` and `showPopover()` have raised, the oldest first.
    top_layer: std.ArrayList(*Node) = .empty,

    pub fn create(arena: Allocator) Allocator.Error!*Document {
        const d = try arena.create(Document);
        const n = try arena.create(Node);
        n.* = .{ .kind = .document, .doc = d };
        d.* = .{ .arena = arena, .node = n };
        return d;
    }

    pub inline fn invalidateLayoutCache(d: *Document) void {
        d.layout_cache_gen +%= 1;
        if (d.layout_cache_gen == 0) d.layout_cache_gen = 1;
    }

    /// Everything's style may have changed.
    pub fn touchStyle(d: *Document) void {
        d.generation +%= 1;
        d.svg_roots_generation +%= 1;
        d.style_dirty = true;
        d.layout_dirty = true;
        d.oof_dirty_node = null;
        d.dirty_all = true;
        d.invalidateLayoutCache();
    }

    pub fn inDocument(d: *const Document, n: *const Node) bool {
        var at: ?*const Node = n;
        while (at) |x| : (at = x.parent) if (x == d.node) return true;
        return false;
    }

    /// `n` and what's under it restyle.
    pub fn markStyle(d: *Document, n: *Node) void { d.touchUnder(n); }

    /// The style of what's under `n` may have changed: only that restyles.
    pub fn touchUnder(d: *Document, n: *Node) void { perf.touchUnder(d, n); }

    /// An attribute of `n` changed. Layout follows only if style did. What
    /// selects by it reaches its siblings at most, unless it is the inline style.
    fn touchAttr(d: *Document, n: *Node, name: []const u8) void { perf.touchAttr(d, n, name); }

    /// `n`'s children changed.
    fn touchTree(d: *Document, n: *Node, id_changed: bool) void {
        d.generation +%= 1;
        if (!d.inDocument(n)) return;
        if (id_changed) d.id_generation +%= 1;
        const disp_contents = n.computed != null and n.computed.?.display == .contents;
        if (!perf.isSvgInterior(n.ns == .svg, false, disp_contents)) {
            d.layout_dirty = true;
            d.oof_dirty_node = null;
            d.svg_roots_generation +%= 1;
        }
        d.touchUnder(n);
    }

    /// The top modal dialog: what's outside it takes no input.
    pub fn modalDialog(d: *const Document) ?*Node {
        var i = d.top_layer.items.len;
        while (i > 0) { i -= 1; if (d.top_layer.items[i].modal) return d.top_layer.items[i]; }
        return null;
    }

    /// Raises `n`, or lowers it when `up` is false.
    pub fn setTopLayer(d: *Document, n: *Node, up: bool) void {
        for (d.top_layer.items, 0..) |x, i| if (x == n) { _ = d.top_layer.orderedRemove(i); break; };
        n.in_top_layer = up;
        if (up) d.top_layer.append(d.arena, n) catch { n.in_top_layer = false; };
        d.touchStyle();
    }

    pub fn touchLayout(d: *Document) void {
        d.layout_dirty = true;
        d.oof_dirty_node = null;
        d.invalidateLayoutCache();
    }

    pub fn touchNodeLayout(d: *Document, n: *Node) void {
        d.layout_dirty = true;
        d.oof_dirty_node = null;
        dom_flags.markSubtreeLayoutDirty(n);
    }

    pub fn createElement(d: *Document, tag: []const u8) Allocator.Error!*Node { return d.createElementNs(tag, .html); }

    /// `tag` is copied, lowercased unless the namespace keeps case (SVG).
    pub fn createElementNs(d: *Document, tag: []const u8, ns: Ns) Allocator.Error!*Node {
        const n = try d.arena.create(Node);
        const name = try d.arena.dupe(u8, tag);
        if (ns == .html) _ = std.ascii.lowerString(name, name);
        n.* = .{ .kind = .element, .doc = d, .tag = name, .ns = ns, .html_tag = if (ns == .html) perf.classifyHtmlTag(name) else .other, .has_resource = perf.isResourceTag(name), .has_insertion_work = perf.isInsertionWorkTag(name) };
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

    pub fn documentElement(d: *const Document) ?*Node { return d.node.firstElementChild(); }

    fn childOfRoot(d: *const Document, tag: []const u8) ?*Node {
        const root = d.documentElement() orelse return null;
        var c = root.first_child;
        while (c) |k| : (c = k.next) if (k.isTag(tag)) return k;
        return null;
    }

    pub fn head(d: *const Document) ?*Node { return d.childOfRoot("head"); }
    pub fn body(d: *const Document) ?*Node { return d.childOfRoot("body") orelse d.childOfRoot("frameset"); }
    pub fn getElementById(d: *const Document, id: []const u8) ?*Node { return perf.getElementById(d, id); }

    /// The first `<title>`'s text, whitespace collapsed by the caller.
    pub fn title(d: *const Document, gpa: Allocator) Allocator.Error![]const u8 {
        var at = d.node.first_child;
        while (at) |n| : (at = n.nextInTree(d.node)) {
            if (n.isTag("title")) return n.textContent(gpa);
        }
        return "";
    }
};

test {
    _ = dom_flags;
}
