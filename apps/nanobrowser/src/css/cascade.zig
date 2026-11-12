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
const animate = @import("animate.zig");
const scopes = @import("cascade_scopes.zig");
const dom_flags = @import("../dom_flags.zig");

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

/// Styles worked out under `display: none`, for as long as a caller wants them.
pub const DetachedMemo = std.AutoHashMapUnmanaged(*dom.Node, Detached);
pub const Detached = struct { style: *const Style, scope: ?*const vars.Scope };

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
    /// A style in this generation came from the viewport's size.
    viewport_read: bool = false,
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
    scratch_initial: Style = .{},
    scratch_base: Style = .{},
    scratch_ua: Style = .{},
    scratch_fresh: Style = .{},
    /// `<meta name=color-scheme>` asks for dark.
    meta_dark: bool = false,
    /// Family lists, the sheets' `@font-face` names, and real font measures.
    fonts: @import("font_family.zig").Names = .{},

    // Scratch, reused between elements.
    collected: std.ArrayList(rule_index.Entry) = .empty,
    matched: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_before: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_after: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_placeholder: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_marker: std.ArrayList(rule_index.Entry) = .empty,
    pseudo_backdrop: std.ArrayList(rule_index.Entry) = .empty,
    custom_builder: vars.Builder = .{},
    match_ctx: match.Ctx,
    /// What runs: `@keyframes` and transitions (`animate.zig`), and the time
    /// each frame gives them.
    anim: animate.Animator,
    now: f64 = 0,
    keyframes: std.StringHashMapUnmanaged(*const sheet_mod.Keyframes) = .empty,
    /// `@property`'s, and the scope above the root holding what each starts as.
    registered: vars.Registered = .empty,
    registered_scope: ?*const vars.Scope = null,
    style_share: @import("../perf_rules.zig").StyleShareCache = .{},
    share_gen: u32 = 0,
    pos_share_gen: u32 = 0,
    next_share_gen: u32 = 0,
    last_url_hash: u64 = 0,
    in_batch_flush: bool = false,
    any_scope_unpersist: bool = false,
    last_scope_root: ?*const dom.Node = null,
    last_scope_ix: ?*rule_index.Index = null,
    layout_change_node: ?*dom.Node = null,
    layout_change_many: bool = false,

    pub fn init(gpa: Allocator, doc: *dom.Document) Engine {
        return .{
            .gpa = gpa,
            .doc = doc,
            .generation_arena = std.heap.ArenaAllocator.init(gpa),
            .match_ctx = .{ .doc = doc },
            .anim = .init(gpa),
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
        e.pseudo_placeholder.deinit(e.gpa);
        e.anim.deinit();
        e.keyframes.deinit(e.gpa);
        e.registered.deinit(e.gpa);
        e.pseudo_marker.deinit(e.gpa);
        e.pseudo_backdrop.deinit(e.gpa);
        e.custom_builder.deinit(e.gpa);
        e.fonts.deinit(e.gpa);
        e.gpa.free(e.sheets);
    }

    pub fn genArena(e: *Engine) Allocator {
        return e.generation_arena.allocator();
    }

    /// The author sheets, in document order; the UA sheet is implicit. The
    /// sheets must outlive the engine's use of them. Out of memory keeps the
    /// sheets it had.
    pub fn setSheets(e: *Engine, sheets: []const *const Sheet) void {
        if (std.mem.eql(*const Sheet, e.sheets, sheets)) return;
        const copy = e.gpa.dupe(*const Sheet, sheets) catch return;
        e.gpa.free(e.sheets);
        e.sheets = copy;
        _ = e.fonts.declare(e.gpa, copy);
        e.index_dirty = true;
        e.doc.touchStyle();
    }

    pub const setScopedSheets = scopes.setScopedSheets;
    pub const dropScopeIndexes = scopes.dropScopeIndexes;
    pub const collectFor = scopes.collectFor;
    pub const containerHolds = scopes.containerHolds;

    pub fn setViewport(e: *Engine, v: Viewport) void {
        const same_units = v.width == e.viewport.width and v.height == e.viewport.height and v.dark == e.viewport.dark;
        const same_scheme = v.dark == e.viewport.dark;
        e.viewport = v;
        if (same_units) return;
        // A media query that flipped, or a value in viewport units. Failing those,
        // only layout reads the size, and a long page's restyle is spared on each
        // change of a window being dragged.
        const flipped = e.signature() != e.media_signature;
        if (flipped) e.index_dirty = true;
        if (flipped or e.viewport_read or !same_scheme) e.doc.touchStyle() else e.doc.touchLayout();
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

    pub fn ensureIndex(e: *Engine) Allocator.Error!void {
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
        e.keyframes.clearRetainingCapacity();
        e.registered.clearRetainingCapacity();
        var starts: std.ArrayList(vars.Entry) = .empty;
        for (e.sheets) |s| for (s.properties) |r| {
            if (e.registered.contains(r.name)) continue;
            try e.registered.put(e.gpa, r.name, r);
            try starts.append(a, .{ .hash = std.hash.Fnv1a_32.hash(r.name), .name = r.name, .value = r.initial });
        };
        e.registered_scope = null;
        if (starts.items.len > 0) {
            const root_scope = try a.create(vars.Scope);
            root_scope.* = .{ .entries = starts.items };
            e.registered_scope = root_scope;
        }
        for (e.sheets) |s| {
            if (!s.active(e.viewport)) continue;
            for (s.keyframes) |*k| {
                if (k.cond) |c| if (!c.matches(e.viewport)) continue;
                try e.keyframes.put(e.gpa, k.name, k);
            }
        }
        e.media_signature = e.signature();
        e.doc.rule_flags = ix.ruleFlags();
        e.doc.rule_attr_filter = ix.attr_filter;
        e.doc.rule_id_bloom = ix.referenced_ids_bloom;
        e.index_dirty = false;
    }

    pub const readMetaScheme = scopes.readMetaScheme;

    /// Fills `computed`, `before` and `after` for the whole document. A
    /// `display: none` element gets its style with display none, its
    /// descendants null. Frees the previous generation.
    pub fn restyleAll(e: *Engine) Allocator.Error!void {
        try e.ensureIndex();
        e.readMetaScheme();
        e.doc.invalidateLayoutCache();
        // The old generation dies once the new one is done. Only the current
        // generation's styles are compared with (see `current`).
        var old = e.generation_arena;
        e.generation_arena = std.heap.ArenaAllocator.init(e.gpa);
        defer old.deinit();
        // What it holds lives in the old generation.
        e.fonts.interned.clearRetainingCapacity();
        e.generation +%= 1;
        if (e.generation == 0) e.generation = 1;
        scopes.resetShareForAll(e);
        e.root_font = 16;
        e.match_ctx = .{ .doc = e.doc };
        e.viewport_read = false;
        e.layout_change_node = null;
        e.layout_change_many = true;

        const doc_node = e.doc.node;
        var at = doc_node.first_child;
        while (at) |n| {
            at = try e.styleOne(n, doc_node, null);
        }
        e.doc.style_dirty = false;
        e.anim.endGeneration(e.generation);
    }

    pub fn beginFlush(e: *Engine) void {
        scopes.maybeInvalidateShare(e);
        e.in_batch_flush = true;
    }

    /// Restyles `node` and what is in it, after a hover, class or attribute
    /// change. The change is what happened compared with the last computed
    /// style. Falls back on `restyleAll` when nothing has been computed yet or
    /// the root's font size moved, which `rem` makes global.
    pub fn restyleSubtree(e: *Engine, node: *dom.Node) Allocator.Error!Change {
        if (e.generation == 0 or e.index_dirty) { try e.restyleAll(); return .layout; }
        const root = if (e.doc.documentElement() == node) node else null;
        const root_size_before = if (root) |r| if (r.computed) |c| c.font_size else 16 else 16;
        if (!e.in_batch_flush) scopes.maybeInvalidateShare(e);
        e.match_ctx = .{ .doc = e.doc };
        var change: Change = .none;
        var at: ?*dom.Node = node;
        while (at) |n| at = try e.styleOne(n, node, &change);
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

    pub fn current(e: *const Engine, n: *const dom.Node) ?*const Style {
        return if (n.style_generation == e.generation) n.computed else null;
    }

    /// Styles one node; returns the next to visit, staying inside `root`.
    fn styleOne(e: *Engine, n: *dom.Node, root: *dom.Node, change: ?*Change) Allocator.Error!?*dom.Node {
        const parent = n.parent;
        const parent_is_element = parent != null and parent.?.kind == .element;
        const old = e.current(n);
        const old_before = if (n.style_generation == e.generation) n.before else null;
        const old_after = if (n.style_generation == e.generation) n.after else null;
        const prev_before = e.previous(n, .before);
        const prev_after = e.previous(n, .after);
        if (n.kind != .element) {
            const parent_style: ?*const Style = if (parent_is_element) e.current(parent.?) else null;
            const visible = parent_style != null and parent_style.?.display != .none;
            n.computed = if (n.kind == .text and visible) parent_style else null;
            n.style_generation = e.generation;
            return n.nextDeep(root);
        }
        var parent_style: *const Style = &e.root_parent;
        var parent_scope: ?*const vars.Scope = e.registered_scope;
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
            parent_scope = null;
            if (p.css_vars) |raw| parent_scope = @ptrCast(@alignCast(raw));
        }
        // Which tree it is in: what rules can match.
        if (n.is_shadow) {
            n.tree_scope = n;
        } else if (parent) |p| {
            n.tree_scope = p.tree_scope;
        }
        const perf = @import("../perf_rules.zig");
        perf.prof_style_elems += 1;
        perf.updateAncestorBloom(n, root);
        const in_svg = n.ns == .svg and !n.isTag("svg");
        const was_shared = n.style_shared_gen != 0;
        n.style_shared_gen = 0;
        n.style_canon = null;
        const canon_parent: *const Style = if (parent != null and parent.?.style_canon != null) parent.?.style_canon.? else parent_style;
        var share_cand: ?perf.ShareCand = null;
        if (try scopes.tryShareStyle(e, n, parent, parent_is_element, canon_parent, parent_scope, old, old_before, old_after, change, &share_cand)) {
            return scopes.finishSharedHit(e, n, root, change);
        }
        const fresh_ptr: *Style = if (old == null) try e.genArena().create(Style) else &e.scratch_fresh;
        const r = if (n.is_shadow) compute.shadowRoot(parent_style, parent_scope, fresh_ptr) else try compute.element(e, n, parent_style, parent_scope, fresh_ptr);
        if (fresh_ptr.container_type != .normal) try e.containers.put(e.gpa, n, {});
        try e.anim.styled(e, n, .none, parent_style, r.scope, e.previous(n, .none), fresh_ptr);
        var compared: Change = .layout;
        if (old) |o| {
            compared = diff.compare(o, fresh_ptr);
            if (compared != .none) {
                dom_flags.markSubtreeLayoutDirty(n);
                if (n.ns == .svg) e.doc.svg_style_version +%= 1;
            }
            const ch: Change = if (in_svg and compared == .layout) .paint else compared;
            if (change) |c| c.* = c.max(ch);
            if (ch == .layout) scopes.noteLayoutChange(e, n, o, fresh_ptr);
        } else {
            dom_flags.markSubtreeLayoutDirty(n);
            if (n.ns == .svg) e.doc.svg_style_version +%= 1;
            if (change) |c| {
                const ch: Change = if (in_svg) .paint else .layout;
                c.* = c.max(ch);
                if (ch == .layout) scopes.noteLayoutChange(e, n, null, fresh_ptr);
            }
        }
        const stored = try scopes.storeComputedStyle(e, n, old, in_svg, fresh_ptr, compared, change);
        n.computed = stored;
        n.style_generation = e.generation;
        n.css_vars = r.scope;
        if (parent == e.doc.node and n == e.doc.documentElement()) e.root_font = stored.font_size;
        if (stored.display == .none) {
            n.before = null;
            n.after = null;
            if (change) |c| if (old_before != null or old_after != null) { c.* = c.max(.layout); scopes.noteLayoutChange(e, n, old, stored); };
            var k = n.first_child;
            while (k) |x| : (k = x.next) e.clearSubtree(x, change, false);
            if (n.shadow_root) |x| e.clearSubtree(x, change, false);
            if (!n.is_shadow) if (share_cand) |sc| if (!e.anim.hasNode(n)) e.style_share.record(if (sc.disallow_cousin) e.pos_share_gen else e.share_gen, n, canon_parent, parent_scope, sc, stored, null, null, r.scope, false);
            return n.nextDeepSkipping(root);
        }
        var pseudo_attr = false;
        n.before = try e.pseudoStyle(n, .before, e.pseudo_before.items, r.before, stored, r.scope, old_before, prev_before, change, was_shared, &pseudo_attr);
        n.after = try e.pseudoStyle(n, .after, e.pseudo_after.items, r.after, stored, r.scope, old_after, prev_after, change, was_shared, &pseudo_attr);
        n.marker = try e.pseudoStyle(n, .marker, e.pseudo_marker.items, r.marker, stored, r.scope, null, null, null, false, null);
        n.backdrop = try e.pseudoStyle(n, .backdrop, e.pseudo_backdrop.items, r.backdrop, stored, r.scope, null, null, null, false, null);
        if (n.is_shadow) {
            if (!e.anim.hasNode(n)) e.style_share.recordShadow(e.share_gen, n, canon_parent, parent_scope, stored);
        } else if (share_cand) |sc| {
            const gen = if (sc.disallow_cousin) e.pos_share_gen else e.share_gen;
            if (!e.anim.hasNode(n)) e.style_share.record(gen, n, canon_parent, parent_scope, sc, stored, n.before, n.after, r.scope, r.marker or r.backdrop or pseudo_attr);
        }
        return n.nextDeep(root);
    }

    /// The style `n` (or its pseudo-element) had before this restyle, for what
    /// transitions from it. In a new generation the last one's is alive until
    /// the pass is over; anything older isn't.
    pub fn previous(e: *const Engine, n: *const dom.Node, which: animate.Pseudo) ?*const Style {
        if (n.style_generation != e.generation and n.style_generation +% 1 != e.generation) return null;
        return switch (which) { .none => n.computed, .before => n.before, .after => n.after, .marker => n.marker, .backdrop => n.backdrop };
    }

    fn pseudoStyle(e: *Engine, n: *dom.Node, which: animate.Pseudo, list: []rule_index.Entry, wanted: bool, parent: *const Style, scope: ?*const vars.Scope, old: ?*const Style, prev: ?*const Style, change: ?*Change, was_shared: bool, used_attr: ?*bool) Allocator.Error!?*const Style {
        var made: ?*const Style = null;
        if (wanted) {
            var fresh: Style = undefined;
            if (try compute.pseudo(e, n, list, parent, scope, &fresh, used_attr)) {
                try e.anim.styled(e, n, which, parent, scope, prev, &fresh);
                if (old) |o| {
                    const compared = diff.compare(o, &fresh);
                    if (compared == .none) return o;
                    dom_flags.markSubtreeLayoutDirty(n);
                    if (compared == .paint and !was_shared) {
                        if (change) |c| c.* = c.max(.paint);
                        @constCast(o).* = fresh;
                        return o;
                    }
                }
                const s = try e.genArena().create(Style);
                s.* = fresh;
                made = s;
            }
        }
        if ((old != null and made != null) or ((old == null) != (made == null))) {
            dom_flags.markSubtreeLayoutDirty(n);
            if (change) |c| {
                c.* = c.max(.layout);
                scopes.noteLayoutChange(e, n, parent, parent);
            }
        }
        return made;
    }

    /// No styles under `display: none`.
    pub fn clearSubtree(e: *Engine, top: *dom.Node, change: ?*Change, had_style: bool) void {
        if (had_style) dom_flags.markSubtreeLayoutDirty(top);
        if (change) |c| if (had_style) {
            const ch: Change = if (top.ns == .svg and !top.isTag("svg")) .paint else .layout;
            c.* = c.max(ch);
            if (ch == .layout) scopes.noteLayoutChange(e, top, top.computed, null);
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
    pub fn invalidatedByState(e: *Engine, node: *dom.Node, flip: state.Flip) ?*dom.Node {
        e.ensureIndex() catch return e.doc.documentElement();
        // Inside a shadow tree the tree's rules say; a whole tree restyles cheaply.
        if (node.tree_scope) |root| return root;
        var at: ?*dom.Node = node;
        while (at) |x| : (at = x.parent) if (x.is_shadow) return x;
        if (node.shadow_root != null) return node;
        return state.invalidatedBy(&e.index.?, e.doc, node, flip);
    }

    pub const styleAnyway = scopes.styleAnyway;

    /// A serialized value for `getComputedStyle`, in the engine's arena; null for
    /// a property with none (or not styled).
    pub fn computedValue(e: *Engine, node: *dom.Node, property_name: []const u8) ?[]const u8 {
        return computed_value.get(e, node, property_name);
    }
};
