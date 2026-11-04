//! The style engine of a page: holds its sheets, walks the tree and gives each
//! element its computed `Style`. Computed styles live in the engine's arena,
//! freed a generation at a time: `restyleAll` starts a new one, and
//! `restyleSubtree` adds to the current one until the next `restyleAll`.
//! Layout may keep the pointers it reads until then.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const style = @import("style.zig");
const sheet_mod = @import("sheet.zig");
const media = @import("media.zig");
const parser = @import("parser.zig");
const query = @import("query.zig");
const match = @import("selector_match.zig");
const rule_index = @import("rule_index.zig");
const vars = @import("vars.zig");
const compute = @import("compute.zig");
const diff = @import("style_diff.zig");
const ua = @import("ua.zig");
const state = @import("cascade_state.zig");
const computed_value = @import("computed_value.zig");

const Style = style.Style;

pub const Sheet = sheet_mod.Sheet;
pub const Declarations = sheet_mod.Declarations;
pub const Viewport = media.Viewport;
pub const parseSheet = parser.parseSheet;
pub const parseSheetMedia = parser.parseSheetMedia;
pub const parseDeclarations = parser.parseDeclarations;
pub const querySelector = query.querySelector;
pub const querySelectorAll = query.querySelectorAll;
pub const matchesSelector = query.matchesSelector;
pub const closest = query.closest;

/// What a restyle changed, compared with the last computed style.
pub const Change = enum {
    none,
    paint,
    layout,

    pub fn max(a: Change, b: Change) Change {
        return if (@backingInt(b) > @backingInt(a)) b else a;
    }
};

pub const Engine = struct {
    gpa: Allocator,
    doc: *dom.Document,
    sheets: []const *const Sheet = &.{},
    viewport: Viewport = .{ .width = 1024, .height = 768 },
    /// Whether scripts run: `<noscript>` then stays hidden.
    scripting: bool = true,

    index: ?rule_index.Index = null,
    index_dirty: bool = true,
    /// Which media conditions held when the index was built.
    media_signature: u64 = 0,
    ua_arena: ?std.heap.ArenaAllocator = null,
    ua_sheet: ?*const Sheet = null,
    ua_quirks: ?*const Sheet = null,

    generation_arena: std.heap.ArenaAllocator,
    generation: u32 = 0,
    root_font: f32 = 16,
    /// The root element's parent: the initial style.
    root_parent: Style = .{},
    /// `<meta name=color-scheme>` asks for dark.
    meta_dark: bool = false,

    // Scratch, reused between elements.
    collected: std.ArrayList(rule_index.Entry) = .empty,
    matched: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_before: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_after: std.ArrayList(rule_index.Entry) = .empty,
    custom_builder: vars.Builder = .{},
    match_ctx: match.Ctx,

    pub fn init(gpa: Allocator, doc: *dom.Document) Engine {
        return .{
            .gpa = gpa,
            .doc = doc,
            .generation_arena = std.heap.ArenaAllocator.init(gpa),
            .match_ctx = .{ .doc = doc },
        };
    }

    pub fn deinit(e: *Engine) void {
        if (e.index) |*ix| ix.deinit();
        if (e.ua_arena) |*a| a.deinit();
        e.generation_arena.deinit();
        e.collected.deinit(e.gpa);
        e.matched.deinit(e.gpa);
        e.pseudo_before.deinit(e.gpa);
        e.pseudo_after.deinit(e.gpa);
        e.custom_builder.deinit(e.gpa);
        e.gpa.free(e.sheets);
    }

    pub fn genArena(e: *Engine) Allocator {
        return e.generation_arena.allocator();
    }

    /// The author sheets, in document order; the UA sheet is implicit. The
    /// sheets must outlive the engine's use of them. Out of memory keeps the
    /// sheets it had.
    pub fn setSheets(e: *Engine, sheets: []const *const Sheet) void {
        const copy = e.gpa.dupe(*const Sheet, sheets) catch return;
        e.gpa.free(e.sheets);
        e.sheets = copy;
        e.index_dirty = true;
        e.doc.touchStyle();
    }

    pub fn setViewport(e: *Engine, v: Viewport) void {
        const same_units = v.width == e.viewport.width and v.height == e.viewport.height and v.dark == e.viewport.dark;
        e.viewport = v;
        if (same_units) return;
        // Viewport units in every value, and maybe the media queries.
        e.doc.touchStyle();
        if (e.signature() != e.media_signature) e.index_dirty = true;
    }

    fn signature(e: *const Engine) u64 {
        var h: u64 = 1469598103934665603;
        const mix = struct {
            fn f(x: *u64, b: bool) void {
                x.* = (x.* *% 1099511628211) +% @intFromBool(b);
            }
        }.f;
        for (e.sheets) |s| {
            mix(&h, s.active(e.viewport));
            for (s.conds) |c| mix(&h, c.matches(e.viewport));
        }
        return h;
    }

    fn ensureUa(e: *Engine) Allocator.Error!void {
        if (e.ua_sheet != null) return;
        e.ua_arena = std.heap.ArenaAllocator.init(e.gpa);
        const a = e.ua_arena.?.allocator();
        e.ua_sheet = try parser.parseSheet(a, ua.sheet, "");
        e.ua_quirks = try parser.parseSheet(a, ua.quirks, "");
    }

    fn ensureIndex(e: *Engine) Allocator.Error!void {
        if (!e.index_dirty and e.index != null) return;
        try e.ensureUa();
        if (e.index) |*old| old.deinit();
        e.index = null;
        e.index = rule_index.Index.init(e.gpa);
        const ix = &e.index.?;
        ix.quirks = e.doc.quirks;
        const a = ix.arena.allocator();
        const ranks = try rule_index.LayerRanks.build(a, e.sheets, e.viewport);
        var order: u32 = 0;
        try ix.addSheet(e.ua_sheet.?, e.viewport, true, &ranks, &order);
        if (e.doc.quirks) try ix.addSheet(e.ua_quirks.?, e.viewport, true, &ranks, &order);
        for (e.sheets) |s| try ix.addSheet(s, e.viewport, false, &ranks, &order);
        e.media_signature = e.signature();
        e.index_dirty = false;
    }

    fn readMetaScheme(e: *Engine) void {
        e.meta_dark = false;
        const head = e.doc.head() orelse return;
        var c = head.first_child;
        while (c) |k| : (c = k.next) {
            if (!k.isTag("meta")) continue;
            const name = k.attr("name") orelse continue;
            if (!std.ascii.eqlIgnoreCase(name, "color-scheme")) continue;
            const content = k.attr("content") orelse continue;
            var light = false;
            var dark = false;
            var it = std.mem.tokenizeAny(u8, content, " \t\r\n\x0c,");
            while (it.next()) |w| {
                if (std.ascii.eqlIgnoreCase(w, "light")) light = true;
                if (std.ascii.eqlIgnoreCase(w, "dark")) dark = true;
            }
            e.meta_dark = dark and (!light or e.viewport.dark);
        }
    }

    /// Fills `computed`, `before` and `after` for the whole document. A
    /// `display: none` element gets its style with display none, its
    /// descendants null. Frees the previous generation.
    pub fn restyleAll(e: *Engine) Allocator.Error!void {
        try e.ensureIndex();
        e.readMetaScheme();
        // The old generation dies once the new one is done. Only the current
        // generation's styles are compared with (see `current`).
        var old = e.generation_arena;
        e.generation_arena = std.heap.ArenaAllocator.init(e.gpa);
        defer old.deinit();
        e.generation +%= 1;
        if (e.generation == 0) e.generation = 1;
        e.root_font = 16;
        e.match_ctx = .{ .doc = e.doc };

        const doc_node = e.doc.node;
        var at = doc_node.first_child;
        while (at) |n| {
            at = try e.styleOne(n, doc_node, null);
        }
        e.doc.style_dirty = false;
    }

    /// Restyles `node` and what is in it, after a hover, class or attribute
    /// change. The change is what happened compared with the last computed
    /// style. Falls back on `restyleAll` when nothing has been computed yet or
    /// the root's font size moved, which `rem` makes global.
    pub fn restyleSubtree(e: *Engine, node: *dom.Node) Allocator.Error!Change {
        if (e.generation == 0 or e.index_dirty) {
            try e.restyleAll();
            return .layout;
        }
        const root = if (e.doc.documentElement() == node) node else null;
        const root_size_before = if (root) |r| if (r.computed) |c| c.font_size else 16 else 16;
        e.match_ctx = .{ .doc = e.doc };
        var change: Change = .none;
        var at: ?*dom.Node = node;
        while (at) |n| {
            at = try e.styleOne(n, node, &change);
        }
        if (root) |r| if (r.computed) |c| if (c.font_size != root_size_before) {
            try e.restyleAll();
            return .layout;
        };
        return change;
    }

    /// As `restyleSubtree` for what a script changed at `node`: its ancestors
    /// go first, one by one, when a rule's `:has` could reach them.
    pub fn restyleChanged(e: *Engine, node: *dom.Node) Allocator.Error!Change {
        if (e.generation == 0 or e.index_dirty) {
            try e.restyleAll();
            return .layout;
        }
        if (e.index.?.uses_has) {
            var chain: std.ArrayList(*dom.Node) = .empty;
            defer chain.deinit(e.gpa);
            var at = node.parent;
            while (at) |a| : (at = a.parent) if (a.kind == .element) try chain.append(e.gpa, a);
            e.match_ctx = .{ .doc = e.doc };
            var i = chain.items.len;
            while (i > 0) {
                i -= 1;
                const a = chain.items[i];
                var change: Change = .none;
                _ = try e.styleOne(a, a, &change);
                // It changed: all under it follows, `node` among it.
                if (change != .none) {
                    const below = try e.restyleSubtree(a);
                    return change.max(below);
                }
            }
        }
        return e.restyleSubtree(node);
    }

    fn current(e: *const Engine, n: *const dom.Node) ?*const Style {
        return if (n.style_generation == e.generation) n.computed else null;
    }

    /// Styles one node; returns the next to visit, staying inside `root`.
    fn styleOne(e: *Engine, n: *dom.Node, root: *dom.Node, change: ?*Change) Allocator.Error!?*dom.Node {
        const parent = n.parent;
        const parent_is_element = parent != null and parent.?.kind == .element;
        const old = e.current(n);
        const old_before = if (n.style_generation == e.generation) n.before else null;
        const old_after = if (n.style_generation == e.generation) n.after else null;
        if (n.kind != .element) {
            const parent_style: ?*const Style = if (parent_is_element) e.current(parent.?) else null;
            const visible = parent_style != null and parent_style.?.display != .none;
            n.computed = if (n.kind == .text and visible) parent_style else null;
            n.style_generation = e.generation;
            return n.nextInTree(root);
        }
        var parent_style: *const Style = &e.root_parent;
        var parent_scope: ?*const vars.Scope = null;
        if (parent_is_element) {
            const p = parent.?;
            parent_style = e.current(p) orelse {
                // Inside `display: none`, or not yet styled.
                e.clearSubtree(n, change, old != null);
                return n.nextSkippingChildren(root);
            };
            if (parent_style.display == .none) {
                e.clearSubtree(n, change, old != null);
                return n.nextSkippingChildren(root);
            }
            if (p.css_vars) |raw| parent_scope = @ptrCast(@alignCast(raw));
        }
        var fresh: Style = undefined;
        const r = try compute.element(e, n, parent_style, parent_scope, &fresh);
        if (old) |o| {
            if (change) |c| c.* = c.max(diff.compare(o, &fresh));
        } else if (change) |c| c.* = .layout;
        const stored: *const Style = blk: {
            if (old) |o| if (diff.compare(o, &fresh) == .none) break :blk o;
            const s = try e.genArena().create(Style);
            s.* = fresh;
            break :blk s;
        };
        n.computed = stored;
        n.style_generation = e.generation;
        n.css_vars = r.scope;
        if (parent == e.doc.node and n == e.doc.documentElement()) e.root_font = stored.font_size;
        if (stored.display == .none) {
            n.before = null;
            n.after = null;
            if (change) |c| if (old_before != null or old_after != null) {
                c.* = c.max(.layout);
            };
            var k = n.first_child;
            while (k) |x| : (k = x.next) e.clearSubtree(x, change, false);
            return n.nextSkippingChildren(root);
        }
        n.before = try e.pseudoStyle(n, e.pseudo_before.items, r.before, stored, r.scope, old_before, change);
        n.after = try e.pseudoStyle(n, e.pseudo_after.items, r.after, stored, r.scope, old_after, change);
        return n.nextInTree(root);
    }

    fn pseudoStyle(e: *Engine, n: *dom.Node, list: []rule_index.Entry, wanted: bool, parent: *const Style, scope: ?*const vars.Scope, old: ?*const Style, change: ?*Change) Allocator.Error!?*const Style {
        var made: ?*const Style = null;
        if (wanted) {
            var fresh: Style = undefined;
            if (try compute.pseudo(e, n, list, parent, scope, &fresh)) {
                const s = try e.genArena().create(Style);
                s.* = fresh;
                made = s;
            }
        }
        if (change) |c| {
            if (old != null and made != null) {
                c.* = c.max(diff.compare(old.?, made.?));
            } else if ((old == null) != (made == null)) {
                c.* = c.max(.layout);
            }
        }
        return made;
    }

    /// No styles under `display: none`.
    fn clearSubtree(e: *Engine, top: *dom.Node, change: ?*Change, had_style: bool) void {
        if (change) |c| if (had_style) {
            c.* = c.max(.layout);
        };
        var at: ?*dom.Node = top;
        while (at) |n| : (at = n.nextInTree(top)) {
            n.computed = null;
            n.before = null;
            n.after = null;
            n.css_vars = null;
            n.style_generation = e.generation;
        }
    }

    /// Whether any author rule uses `:hover`, `:active` or `:focus` at all, so a
    /// hover on a page with none costs nothing.
    pub fn hoverSensitive(e: *Engine) bool {
        e.ensureIndex() catch return true;
        return e.index.?.state_deps.items.len > 0;
    }

    /// The highest ancestor whose style may change when `node`'s hover, active
    /// or focus state flips, sibling combinators included; null if none. Only
    /// that subtree needs restyling.
    pub fn invalidatedByState(e: *Engine, node: *dom.Node) ?*dom.Node {
        e.ensureIndex() catch return e.doc.documentElement();
        return state.invalidatedBy(&e.index.?, e.doc, node);
    }

    /// A serialized value for `getComputedStyle`, in the engine's arena; null for
    /// a property with none (or not styled).
    pub fn computedValue(e: *Engine, node: *dom.Node, property_name: []const u8) ?[]const u8 {
        return computed_value.get(e, node, property_name);
    }
};
