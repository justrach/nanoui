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

/// The nearest ancestor that is a container, with this name if one is given.
fn nearestContainer(n: *const dom.Node, name: []const u8) ?*const dom.Node {
    var at = n.parent;
    while (at) |a| : (at = a.parent) {
        const st = a.computed orelse continue;
        if (a.kind != .element or st.container_type == .normal) continue;
        if (name.len == 0) return a;
        for (st.container_names) |x| if (std.mem.eql(u8, x, name)) return a;
    }
    return null;
}

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
    /// What each shadow tree's own `<style>`s and `<link>`s came to, by its root.
    scoped: std.AutoHashMapUnmanaged(*dom.Node, []const *const Sheet) = .empty,
    /// One index for each distinct list of sheets: a thousand shadow trees of one
    /// custom element share theirs.
    scope_index: std.AutoHashMapUnmanaged(u64, *rule_index.Index) = .empty,
    /// Elements with a `container-type`: their boxes are read after each layout.
    containers: std.AutoHashMapUnmanaged(*dom.Node, void) = .empty,
    viewport: Viewport = .{ .width = 1024, .height = 768 },
    /// Whether scripts run: `<noscript>` then stays hidden.
    scripting: bool = true,

    index: ?rule_index.Index = null,
    index_dirty: bool = true,
    /// The UA's rules alone, which every tree has.
    ua_index: ?rule_index.Index = null,
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
    pseudo_marker: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_backdrop: std.ArrayList(rule_index.Entry) = .empty,
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
        if (e.ua_index) |*ix| ix.deinit();
        e.dropScopeIndexes();
        e.scope_index.deinit(e.gpa);
        var lists = e.scoped.valueIterator();
        while (lists.next()) |l| e.gpa.free(l.*);
        e.scoped.deinit(e.gpa);
        e.containers.deinit(e.gpa);
        if (e.ua_arena) |*a| a.deinit();
        e.generation_arena.deinit();
        e.collected.deinit(e.gpa);
        e.matched.deinit(e.gpa);
        e.pseudo_before.deinit(e.gpa);
        e.pseudo_after.deinit(e.gpa);
        e.pseudo_marker.deinit(e.gpa);
        e.pseudo_backdrop.deinit(e.gpa);
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

    /// Every shadow tree's sheets, replacing what was set; `list`'s slices are
    /// copied. A root with none has no entry.
    pub fn setScopedSheets(e: *Engine, roots: []const *dom.Node, lists: []const []const *const Sheet) void {
        var old = e.scoped.valueIterator();
        while (old.next()) |l| e.gpa.free(l.*);
        e.scoped.clearRetainingCapacity();
        for (roots, lists) |r, l| {
            const copy = e.gpa.dupe(*const Sheet, l) catch continue;
            e.scoped.put(e.gpa, r, copy) catch e.gpa.free(copy);
        }
        e.dropScopeIndexes();
        e.doc.touchStyle();
    }

    fn dropScopeIndexes(e: *Engine) void {
        var it = e.scope_index.valueIterator();
        while (it.next()) |x| {
            x.*.deinit();
            e.gpa.destroy(x.*);
        }
        e.scope_index.clearRetainingCapacity();
    }

    /// The rules of a shadow tree, or none. Lists that are the same share an index.
    fn indexOfScope(e: *Engine, root: *dom.Node) Allocator.Error!?*rule_index.Index {
        const list = e.scoped.get(root) orelse return null;
        const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(list));
        if (e.scope_index.get(key)) |x| return x;
        const ix = try e.gpa.create(rule_index.Index);
        errdefer e.gpa.destroy(ix);
        ix.* = rule_index.Index.init(e.gpa);
        ix.quirks = e.doc.quirks;
        const a = ix.arena.allocator();
        const ranks = try rule_index.LayerRanks.build(a, list, e.viewport);
        var order: u32 = 0;
        for (list) |s| try ix.addSheet(s, e.viewport, false, &ranks, &order);
        try e.scope_index.put(e.gpa, key, ix);
        return ix;
    }

    /// The rules that can match `n`, from its tree, the tree inside it and the
    /// tree around it, into `collected`.
    pub fn collectFor(e: *Engine, n: *dom.Node) Allocator.Error!void {
        const gpa = e.gpa;
        const list = &e.collected;
        if (n.tree_scope) |root| {
            try e.ua_index.?.collect(gpa, n, &e.match_ctx, list);
            if (try e.indexOfScope(root)) |ix| try ix.collect(gpa, n, &e.match_ctx, list);
        } else try e.index.?.collect(gpa, n, &e.match_ctx, list);
        if (e.scoped.count() == 0 and n.tree_scope == null) return;
        if (n.shadow_root) |root| if (try e.indexOfScope(root)) |ix| {
            try rule_index.collectFrom(gpa, ix.host.items, n, &e.match_ctx, list);
        };
        if (n.parent) |p| if (p.shadow_root) |root| if (try e.indexOfScope(root)) |ix| {
            for (ix.slotted.items) |entry| if (match.matchesAny(entry.sel.slotted, n, &e.match_ctx)) try list.append(gpa, entry);
        };
        if (n.tree_scope) |root| if (n.attr("part")) |names| {
            const host = root.parent orelse return;
            const outer = if (host.tree_scope) |r2| try e.indexOfScope(r2) else &e.index.?;
            const ix = outer orelse return;
            for (ix.parts.items) |entry| {
                var it = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
                while (it.next()) |w| if (std.mem.eql(u8, w, entry.sel.part)) {
                    if (match.matches(entry.sel, host, &e.match_ctx)) try list.append(gpa, entry);
                    break;
                };
            }
        };
    }

    /// Whether the `@container` a rule sits under holds for `n`: each level asks
    /// the nearest container with its name, and an unlaid one answers no.
    pub fn containerHolds(e: *const Engine, cond: *const sheet_mod.ContainerCond, n: *const dom.Node) bool {
        _ = e;
        var at: ?*const sheet_mod.ContainerCond = cond;
        while (at) |c| : (at = c.parent) {
            const box = nearestContainer(n, c.name) orelse return false;
            if (c.query) |q| {
                if (box.container_w < 0) return false;
                const st = box.computed.?;
                const high = if (st.container_type == .size) box.container_h else -1;
                if (!q.matches(.{ .width = box.container_w, .height = high })) return false;
            }
        }
        return true;
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
        var lists = e.scoped.valueIterator();
        while (lists.next()) |l| for (l.*) |s| {
            mix(&h, s.active(e.viewport));
            for (s.conds) |c| mix(&h, c.matches(e.viewport));
        };
        return h;
    }

    fn ensureUa(e: *Engine) Allocator.Error!void {
        if (e.ua_sheet != null) return;
        e.ua_arena = std.heap.ArenaAllocator.init(e.gpa);
        const a = e.ua_arena.?.allocator();
        e.ua_sheet = try parser.parseSheet(a, ua.sheet, "");
        e.ua_quirks = try parser.parseSheet(a, ua.quirks, "");
    }

    fn ensureUaIndex(e: *Engine) Allocator.Error!void {
        if (e.ua_index != null and e.ua_index.?.quirks == e.doc.quirks) return;
        try e.ensureUa();
        if (e.ua_index) |*old| old.deinit();
        e.ua_index = rule_index.Index.init(e.gpa);
        const ix = &e.ua_index.?;
        ix.quirks = e.doc.quirks;
        const ranks: rule_index.LayerRanks = .{};
        var order: u32 = 0;
        try ix.addSheet(e.ua_sheet.?, e.viewport, true, &ranks, &order);
        if (e.doc.quirks) try ix.addSheet(e.ua_quirks.?, e.viewport, true, &ranks, &order);
    }

    fn ensureIndex(e: *Engine) Allocator.Error!void {
        if (!e.index_dirty and e.index != null) return;
        try e.ensureUaIndex();
        e.dropScopeIndexes();
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
            return n.nextDeep(root);
        }
        var parent_style: *const Style = &e.root_parent;
        var parent_scope: ?*const vars.Scope = null;
        if (parent_is_element) {
            const p = parent.?;
            parent_style = e.current(p) orelse {
                // Inside `display: none`, or not yet styled.
                e.clearSubtree(n, change, old != null);
                return n.nextDeepSkipping(root);
            };
            if (parent_style.display == .none) {
                e.clearSubtree(n, change, old != null);
                return n.nextDeepSkipping(root);
            }
            if (p.css_vars) |raw| parent_scope = @ptrCast(@alignCast(raw));
        }
        // Which tree it is in: what rules can match.
        if (n.is_shadow) {
            n.tree_scope = n;
        } else if (parent) |p| {
            n.tree_scope = p.tree_scope;
        }
        var fresh: Style = undefined;
        const r = if (n.is_shadow) compute.shadowRoot(parent_style, parent_scope, &fresh) else try compute.element(e, n, parent_style, parent_scope, &fresh);
        if (fresh.container_type != .normal) try e.containers.put(e.gpa, n, {});
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
            if (n.shadow_root) |x| e.clearSubtree(x, change, false);
            return n.nextDeepSkipping(root);
        }
        n.before = try e.pseudoStyle(n, e.pseudo_before.items, r.before, stored, r.scope, old_before, change);
        n.after = try e.pseudoStyle(n, e.pseudo_after.items, r.after, stored, r.scope, old_after, change);
        n.marker = try e.pseudoStyle(n, e.pseudo_marker.items, r.marker, stored, r.scope, null, null);
        n.backdrop = try e.pseudoStyle(n, e.pseudo_backdrop.items, r.backdrop, stored, r.scope, null, null);
        return n.nextDeep(root);
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
        while (at) |n| : (at = n.nextDeep(top)) {
            n.computed = null;
            n.before = null;
            n.after = null;
            n.marker = null;
            n.css_vars = null;
            n.style_generation = e.generation;
        }
    }

    /// Whether any author rule uses `:hover`, `:active` or `:focus` at all, so a
    /// hover on a page with none costs nothing.
    pub fn hoverSensitive(e: *Engine) bool {
        e.ensureIndex() catch return true;
        return e.index.?.state_deps.items.len > 0 or e.scoped.count() > 0;
    }

    /// The highest ancestor whose style may change when `node`'s hover, active
    /// or focus state flips, sibling combinators included; null if none. Only
    /// that subtree needs restyling.
    pub fn invalidatedByState(e: *Engine, node: *dom.Node) ?*dom.Node {
        e.ensureIndex() catch return e.doc.documentElement();
        // Inside a shadow tree the tree's rules say; a whole tree restyles cheaply.
        if (node.tree_scope) |root| return root;
        if (node.shadow_root != null) return node;
        return state.invalidatedBy(&e.index.?, e.doc, node);
    }

    /// A serialized value for `getComputedStyle`, in the engine's arena; null for
    /// a property with none (or not styled).
    pub fn computedValue(e: *Engine, node: *dom.Node, property_name: []const u8) ?[]const u8 {
        return computed_value.get(e, node, property_name);
    }
};
