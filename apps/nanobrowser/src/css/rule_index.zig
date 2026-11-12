//! The active rules of a page, bucketed by what their subject compound
//! requires: an id, a class, a tag, or nothing. An element tests only the
//! rules in its own buckets, so a big sheet on a big page is not rules × elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const sheet = @import("sheet.zig");
const sel = @import("selectors.zig");
const match = @import("selector_match.zig");
const media = @import("media.zig");
const perf = @import("../perf_rules.zig");

const Declarations = sheet.Declarations;

pub const Entry = struct {
    sel: *const sel.Selector,
    decls: *const Declarations,
    /// Sorting by this gives cascade order, lowest first: origin, layer,
    /// specificity, source order.
    key: u64,
    ancestor_bloom: u64 = 0,
    attr_bloom: u64 = 0,
    layer: u16,
    ua: bool,
    /// The `@container` it sits under: checked when an element has matched it.
    container: ?*const sheet.ContainerCond = null,

    /// As a rule from inside a shadow tree about something outside it: any rule of
    /// the outer tree wins over it.
    fn outerWeak(e: Entry) Entry {
        var out = e;
        out.key &= ~(@as(u64, 0xFFF) << 51);
        out.layer = 0;
        return out;
    }
};

/// An author selector with a state pseudo-class, for `invalidatedByState`. The UA
/// sheet's (the focus ring, a link's `:active`) are left out, or every page
/// would be hover sensitive; a host restyles the focused element itself.
pub const StateDep = struct { sel: *const sel.Selector };

const List = std.ArrayList(Entry);
const Map = std.StringHashMapUnmanaged(List);

/// The rank of everything not in a layer, above all layers.
const unlayered: u16 = 0xFFF;

fn makeKey(ua: bool, layer: u16, specificity: u32, order: u32) u64 {
    const a: u64 = (specificity >> 16) & 255;
    const b: u64 = (specificity >> 8) & 255;
    const c: u64 = specificity & 255;
    const spec = (a << 16) | (b << 8) | c;
    return (@as(u64, @intFromBool(!ua)) << 63) | (@as(u64, layer) << 51) | (spec << 27) | @min(order, (1 << 27) - 1);
}

pub const RuleReq = @import("subject_mask.zig").RuleReq;
pub const SubjectMask = @import("subject_mask.zig").SubjectMask;

fn compoundHasPositional(c: *const sel.Compound) bool {
    for (c.simples) |x| switch (x) {
        .nth, .has => return true,
        .pseudo => |p| switch (p) {
            .first_child, .last_child, .only_child, .first_of_type, .last_of_type, .only_of_type, .empty => return true,
            else => {},
        },
        .not, .is, .host, .host_context => |l| for (l) |*sub| if (selectorHasPositionalOrSibling(sub)) return true,
        else => {},
    };
    return false;
}

fn selectorHasPositionalOrSibling(s: *const sel.Selector) bool {
    for (s.compounds, 0..) |*c, idx| {
        if (idx > 0 and (c.combinator == .next or c.combinator == .later)) return true;
        if (compoundHasPositional(c)) return true;
    }
    return false;
}

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    ids: Map = .empty,
    classes: Map = .empty,
    tags: Map = .empty,
    universal: List = .empty,
    state_deps: std.ArrayList(StateDep) = .empty,
    /// Rules for a shadow tree's host (`:host`), and what's slotted into it
    /// (`::slotted`); `::part` rules for what's in the shadow trees of this tree.
    host: List = .empty,
    slotted: List = .empty,
    parts: List = .empty,
    /// Some author rule uses `:has`: a change can reach its ancestors.
    uses_has: bool = false,
    /// Some rule uses `+` (`.next`) or `~` / `:nth-child(of S)` (`.later`).
    uses_next_sibling: bool = false,
    uses_later_sibling: bool = false,
    uses_ancestor_positional: bool = false,
    uses_attr_before_next: bool = false,
    uses_focus_within: bool = false,
    uses_nth_or_type: bool = false,
    any_first: bool = false,
    any_last: bool = false,
    any_empty: bool = false,
    unshareable_subj: SubjectMask = .{},
    first_subj: SubjectMask = .{},
    last_subj: SubjectMask = .{},
    empty_subj: SubjectMask = .{},
    next_subj: SubjectMask = .{},
    anc_pos_subj: SubjectMask = .{},
    /// 64-bit Bloom filter of attribute names in `[attr]` selectors.
    attr_filter: u64 = 0,
    referenced_ids_bloom: u64 = 0,
    referenced_ids: std.StringHashMapUnmanaged(void) = .empty,
    referenced_attrs: std.StringHashMapUnmanaged(void) = .empty,
    /// Some rule sits under `@container`.
    uses_container: bool = false,
    uses_host_in_subtree: bool = false,
    quirks: bool = false,

    pub inline fn mentionsId(ix: *const Index, id: []const u8) bool {
        if ((perf.attrBit(id) & ix.referenced_ids_bloom) == 0) return false;
        return ix.referenced_ids.contains(id);
    }

    pub inline fn mentionsAttr(ix: *const Index, lower_name: []const u8) bool {
        if ((perf.attrBit(lower_name) & ix.attr_filter) == 0) return false;
        return ix.referenced_attrs.contains(lower_name);
    }

    pub fn ruleFlags(ix: *const Index) u8 {
        return @as(u8, @intFromBool(ix.uses_has)) |
            (@as(u8, @intFromBool(ix.uses_next_sibling)) << 1) |
            (@as(u8, @intFromBool(ix.uses_later_sibling)) << 2) |
            (@as(u8, @intFromBool(ix.uses_nth_or_type)) << 3) |
            (@as(u8, @intFromBool(ix.any_first)) << 4) |
            (@as(u8, @intFromBool(ix.any_last)) << 5) |
            (@as(u8, @intFromBool(ix.any_empty)) << 6);
    }

    fn scanAttrAndHas(ix: *Index, selector: *const sel.Selector, ua: bool, before_next_outer: bool) void {
        for (selector.compounds, 0..) |*c, idx| {
            const is_subject = idx + 1 == selector.compounds.len;
            const before_next = before_next_outer or (!is_subject and selector.compounds[idx + 1].combinator == .next);
            if (!ua and idx > 0) switch (c.combinator) {
                .next => {
                    ix.uses_next_sibling = true;
                    if (before_next) ix.uses_nth_or_type = true;
                },
                .later => ix.uses_later_sibling = true,
                else => {},
            };
            for (c.simples) |x| switch (x) {
                .id => |id| {
                    ix.referenced_ids_bloom |= perf.attrBit(id);
                    ix.referenced_ids.put(ix.arena.allocator(), id, {}) catch {};
                },
                .attr => |a| {
                    ix.attr_filter |= perf.attrBit(a.lower);
                    ix.referenced_attrs.put(ix.arena.allocator(), a.lower, {}) catch {};
                    if (!ua and before_next) ix.uses_attr_before_next = true;
                },
                .pseudo => |p| if (!ua) switch (p) {
                    .focus_within => ix.uses_focus_within = true,
                    .first_child => ix.any_first = true,
                    .last_child => ix.any_last = true,
                    .only_child => { ix.any_first = true; ix.any_last = true; },
                    .empty => ix.any_empty = true,
                    .first_of_type, .last_of_type, .only_of_type => ix.uses_nth_or_type = true,
                    else => {},
                },
                .nth => |n| {
                    if (!ua) {
                        if (n.a != 0 or n.b != 1 or n.of_type or n.of.len > 0) ix.uses_nth_or_type = true else if (n.from_end) ix.any_last = true else ix.any_first = true;
                    }
                    if (n.of.len > 0) {
                        ix.uses_later_sibling = true;
                        for (n.of) |*sub| ix.scanAttrAndHas(sub, ua, before_next);
                    }
                },
                .not, .is, .host, .host_context => |l| for (l) |*sub| ix.scanAttrAndHas(sub, ua, before_next),
                .has => |l| {
                    if (!ua) ix.uses_has = true;
                    for (l) |*sub| ix.scanAttrAndHas(sub, ua, before_next);
                },
                else => {},
            };
        }
        for (selector.slotted) |*sub| ix.scanAttrAndHas(sub, ua, false);
    }

    fn scanSelector(ix: *Index, selector: *const sel.Selector, ua: bool, anc_bloom: u64) void {
        ix.scanAttrAndHas(selector, ua, false);
        if (ua or selector.compounds.len == 0) return;
        const subj_idx = selector.compounds.len - 1;
        const subj_simples = selector.compounds[subj_idx].simples;
        var subj_chain_start: usize = subj_idx;
        while (subj_chain_start > 0) {
            const comb = selector.compounds[subj_chain_start].combinator;
            if (comb != .next and comb != .later) break;
            subj_chain_start -= 1;
        }
        for (selector.compounds[0..subj_chain_start], 0..) |*c, idx| {
            if ((idx > 0 and (c.combinator == .next or c.combinator == .later)) or compoundHasPositional(c)) {
                ix.uses_ancestor_positional = true;
                ix.anc_pos_subj.record(subj_simples, anc_bloom);
                break;
            }
        }
        for (selector.compounds[subj_chain_start..], subj_chain_start..) |*c, idx| {
            const is_subject = idx == subj_idx;
            const before_next = !is_subject and selector.compounds[idx + 1].combinator == .next;
            if (idx > subj_chain_start) switch (c.combinator) {
                .next => {
                    ix.next_subj.record(subj_simples, anc_bloom);
                    if (!is_subject or idx > subj_chain_start + 1) ix.unshareable_subj.record(subj_simples, anc_bloom);
                },
                .later => ix.unshareable_subj.record(subj_simples, anc_bloom),
                else => {},
            };
            for (c.simples) |x| switch (x) {
                .pseudo => |p| switch (p) {
                    .first_of_type, .last_of_type, .only_of_type => ix.unshareable_subj.record(subj_simples, anc_bloom),
                    .first_child => {
                        ix.first_subj.record(subj_simples, anc_bloom);
                        if (before_next) ix.unshareable_subj.record(subj_simples, anc_bloom);
                    },
                    .last_child => {
                        ix.last_subj.record(subj_simples, anc_bloom);
                        if (before_next) ix.unshareable_subj.record(subj_simples, anc_bloom);
                    },
                    .only_child => {
                        ix.first_subj.record(subj_simples, anc_bloom);
                        ix.last_subj.record(subj_simples, anc_bloom);
                        if (before_next) ix.unshareable_subj.record(subj_simples, anc_bloom);
                    },
                    .empty => {
                        ix.empty_subj.record(subj_simples, anc_bloom);
                        if (before_next) ix.unshareable_subj.record(subj_simples, anc_bloom);
                    },
                    else => {},
                },
                .nth => |n| {
                    if (n.a != 0 or n.b != 1 or n.of_type or n.of.len > 0 or before_next) {
                        ix.unshareable_subj.record(subj_simples, anc_bloom);
                    } else if (n.from_end) {
                        ix.last_subj.record(subj_simples, anc_bloom);
                    } else {
                        ix.first_subj.record(subj_simples, anc_bloom);
                    }
                },
                .not, .is => |l| for (l) |*sub| {
                    recordSubPositional(ix, sub, subj_simples, anc_bloom, !before_next);
                },
                .host, .host_context => |l| for (l) |*sub| {
                    if (selectorHasPositionalOrSibling(sub)) ix.unshareable_subj.record(subj_simples, anc_bloom);
                },
                else => {},
            };
        }
    }

    fn recordSubPositional(ix: *Index, sub: *const sel.Selector, subj_simples: []const sel.Simple, anc_bloom: u64, allow_shareable: bool) void {
        if (!selectorHasPositionalOrSibling(sub)) return;
        if (!allow_shareable or sub.compounds.len != 1) {
            ix.unshareable_subj.record(subj_simples, anc_bloom);
            return;
        }
        for (sub.compounds[0].simples) |sx| switch (sx) {
            .pseudo => |p| switch (p) {
                .first_child => ix.first_subj.record(subj_simples, anc_bloom),
                .last_child => ix.last_subj.record(subj_simples, anc_bloom),
                .only_child => {
                    ix.first_subj.record(subj_simples, anc_bloom);
                    ix.last_subj.record(subj_simples, anc_bloom);
                },
                .empty => ix.empty_subj.record(subj_simples, anc_bloom),
                .first_of_type, .last_of_type, .only_of_type => ix.unshareable_subj.record(subj_simples, anc_bloom),
                else => {},
            },
            .nth => |n| {
                if (n.a != 0 or n.b != 1 or n.of_type or n.of.len > 0) {
                    ix.unshareable_subj.record(subj_simples, anc_bloom);
                } else if (n.from_end) {
                    ix.last_subj.record(subj_simples, anc_bloom);
                } else {
                    ix.first_subj.record(subj_simples, anc_bloom);
                }
            },
            .has => ix.unshareable_subj.record(subj_simples, anc_bloom),
            .not, .is => |l2| for (l2) |*s2| recordSubPositional(ix, s2, subj_simples, anc_bloom, allow_shareable),
            .host, .host_context => ix.unshareable_subj.record(subj_simples, anc_bloom),
            else => {},
        };
    }

    pub fn init(gpa: Allocator) Index {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        ix.arena.deinit();
    }

    /// Adds a sheet's active rules. `order` continues across sheets.
    pub fn addSheet(ix: *Index, s: *const sheet.Sheet, v: media.Viewport, ua: bool, layers: *const LayerRanks, order: *u32) Allocator.Error!void {
        if (!s.active(v)) return;
        for (s.rules) |*r| {
            if (r.cond) |c| if (!c.matches(v)) continue;
            order.* += 1;
            const layer = if (ua) 0 else layers.rank(r.layer);
            for (r.selectors) |*selector| {
                if (selector.pseudo == .other) continue;
                const entry: Entry = .{
                    .sel = selector,
                    .decls = r.decls,
                    .key = makeKey(ua, layer, selector.specificity, order.*),
                    .ancestor_bloom = if (ix.quirks) 0 else selectorAncestorBloom(selector),
                    .attr_bloom = selectorSubjectAttrBloom(selector),
                    .layer = layer,
                    .ua = ua,
                    .container = r.container,
                };
                if (r.container != null) ix.uses_container = true;
                const a = ix.arena.allocator();
                if (selector.pseudo == .slotted) {
                    try ix.slotted.append(a, entry.outerWeak());
                } else if (selector.pseudo == .part) {
                    try ix.parts.append(a, entry);
                } else if (isHostRule(selector)) {
                    try ix.host.append(a, entry.outerWeak());
                } else try ix.add(entry);
                if (selector.uses_state and !ua) try ix.state_deps.append(ix.arena.allocator(), .{ .sel = selector });
                ix.scanSelector(selector, ua, entry.ancestor_bloom);
            }
        }
    }

    fn add(ix: *Index, e: Entry) Allocator.Error!void {
        const a = ix.arena.allocator();
        const c = e.sel.compounds;
        if (c.len == 0) return ix.universal.append(a, e);
        if (!ix.uses_host_in_subtree) {
            for (c) |comp| for (comp.simples) |x| switch (x) {
                .host, .host_context => ix.uses_host_in_subtree = true,
                else => {},
            };
        }
        const subject = c[c.len - 1].simples;
        var class: ?[]const u8 = null;
        var tag: ?[]const u8 = null;
        for (subject) |s| switch (s) {
            .id => |id| return ix.put(&ix.ids, id, e),
            .class => |n| {
                if (class == null) class = n;
            },
            .tag => |n| tag = n,
            else => {},
        };
        if (class) |n| return ix.put(&ix.classes, n, e);
        if (tag) |n| return ix.put(&ix.tags, n, e);
        return ix.universal.append(a, e);
    }

    fn put(ix: *Index, map: *Map, key_in: []const u8, e: Entry) Allocator.Error!void {
        const a = ix.arena.allocator();
        var key = key_in;
        // Quirks mode compares ids and classes case-insensitively, so the
        // buckets are lowercase too; tags are lowercase already.
        if (ix.quirks) key = try std.ascii.allocLowerString(a, key_in);
        const got = try map.getOrPut(a, key);
        if (!got.found_existing) got.value_ptr.* = .empty;
        try got.value_ptr.append(a, e);
    }

    /// Appends every rule matching `el` to `out`, unsorted, its pseudo-element
    /// rules included.
    pub fn collect(ix: *const Index, gpa: Allocator, el: *dom.Node, ctx: *match.Ctx, out: *List) Allocator.Error!void {
        try tryList(gpa, ix.universal.items, el, ctx, out);
        if (el.attrs.items.len > 0) {
            if (el.id_attr) |id| if (ix.ids.count() > 0) {
                if (ix.lookup(&ix.ids, id)) |l| try tryList(gpa, l.items, el, ctx, out);
            };
            if (el.class_attr) |classes| if (ix.classes.count() > 0) {
                if (el.class_single) {
                    if (ix.lookup(&ix.classes, el.class_src[0..el.class_src_len])) |l| try tryList(gpa, l.items, el, ctx, out);
                } else {
                    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n\x0c");
                    while (it.next()) |c| {
                        if (ix.lookup(&ix.classes, c)) |l| try tryList(gpa, l.items, el, ctx, out);
                    }
                }
            };
        }
        if (el.ns == .html) {
            if (ix.tags.get(el.tag)) |l| try tryList(gpa, l.items, el, ctx, out);
        } else {
            var buf: [64]u8 = undefined;
            if (el.tag.len <= buf.len) {
                const low = std.ascii.lowerString(&buf, el.tag);
                if (ix.tags.get(low)) |l| try tryList(gpa, l.items, el, ctx, out);
            }
        }
    }

    fn lookup(ix: *const Index, map: *const Map, key: []const u8) ?List {
        if (!ix.quirks) return map.get(key);
        var buf: [128]u8 = undefined;
        if (key.len > buf.len) return null;
        return map.get(std.ascii.lowerString(&buf, key));
    }
};

/// Whether a selector's subject is `:host`.
fn isHostRule(s: *const sel.Selector) bool {
    if (s.compounds.len == 0) return false;
    for (s.compounds[s.compounds.len - 1].simples) |x| switch (x) {
        .host, .host_context => return true,
        else => {},
    };
    return false;
}

fn selectorAncestorBloom(s: *const sel.Selector) u64 {
    if (s.compounds.len <= 1 or s.pseudo == .slotted or s.pseudo == .part) return 0;
    for (s.compounds) |c| for (c.simples) |x| switch (x) {
        .host, .host_context => return 0,
        else => {},
    };
    var bloom: u64 = 0;
    var i: usize = s.compounds.len - 1;
    while (i > 0) {
        const comb = s.compounds[i].combinator;
        switch (comb) {
            .child, .descendant => {
                i -= 1;
                for (s.compounds[i].simples) |x| switch (x) {
                    .tag => |t| bloom |= perf.attrBit(t),
                    .id => |id| bloom |= perf.attrBit(id),
                    .class => |c| bloom |= perf.classBit(c),
                    else => {},
                };
            },
            .next, .later => i -= 1,
        }
    }
    return bloom;
}

fn selectorSubjectAttrBloom(s: *const sel.Selector) u64 {
    if (s.compounds.len == 0) return 0;
    var bloom: u64 = 0;
    for (s.compounds[s.compounds.len - 1].simples) |x| switch (x) {
        .attr => |a| bloom |= perf.attrBit(a.lower),
        else => {},
    };
    return bloom;
}

/// The rules of `items` that match `el`, as `collect` gives them.
pub fn collectFrom(gpa: Allocator, items: []const Entry, el: *dom.Node, ctx: *match.Ctx, out: *List) Allocator.Error!void {
    try tryList(gpa, items, el, ctx, out);
}

fn tryList(gpa: Allocator, items: []const Entry, el: *dom.Node, ctx: *match.Ctx, out: *List) Allocator.Error!void {
    const anc = ctx.ancestor_bloom;
    const attrs = el.attr_filter;
    for (items) |e| {
        if ((e.ancestor_bloom & anc) != e.ancestor_bloom or (e.attr_bloom & attrs) != e.attr_bloom) continue;
        if (match.matches(e.sel, el, ctx)) try out.append(gpa, e);
    }
}

/// Cascade layers in order: earlier layers rank lower, and a layer's own rules
/// rank above its sublayers'.
pub const LayerRanks = struct {
    map: std.StringHashMapUnmanaged(u16) = .empty,

    pub fn rank(l: *const LayerRanks, name: []const u8) u16 {
        if (name.len == 0) return unlayered;
        return l.map.get(name) orelse unlayered;
    }

    const LNode = struct {
        name: []const u8,
        kids: std.ArrayList(*LNode) = .empty,
    };

    /// Ranks every layer named by `sheets`, in `arena`.
    pub fn build(arena: Allocator, sheets: []const *const sheet.Sheet, v: media.Viewport) Allocator.Error!LayerRanks {
        var root: LNode = .{ .name = "" };
        var nodes: std.StringHashMapUnmanaged(*LNode) = .empty;
        for (sheets) |s| {
            if (!s.active(v)) continue;
            for (s.layers) |full| {
                var parent = &root;
                var end: usize = 0;
                while (end <= full.len) {
                    const dot = std.mem.indexOfScalarPos(u8, full, end, '.') orelse full.len;
                    const path = full[0..dot];
                    const got = try nodes.getOrPut(arena, path);
                    if (!got.found_existing) {
                        const n = try arena.create(LNode);
                        n.* = .{ .name = path };
                        got.value_ptr.* = n;
                        try parent.kids.append(arena, n);
                    }
                    parent = got.value_ptr.*;
                    end = dot + 1;
                }
            }
        }
        var out: LayerRanks = .{};
        var next: u16 = 1;
        try out.assign(arena, &root, &next);
        return out;
    }

    fn assign(l: *LayerRanks, arena: Allocator, n: *const LNode, next: *u16) Allocator.Error!void {
        for (n.kids.items) |k| try l.assign(arena, k, next);
        if (n.name.len == 0) return;
        try l.map.put(arena, n.name, next.*);
        if (next.* < unlayered - 1) next.* += 1;
    }
};

test "rule keys order by origin, layer, specificity, order" {
    const a = makeKey(true, 0, 0x010000, 5);
    const b = makeKey(false, 1, 0, 1);
    try std.testing.expect(a < b);
    const c = makeKey(false, 1, 0x000100, 1);
    try std.testing.expect(b < c);
    const d = makeKey(false, unlayered, 0, 1);
    try std.testing.expect(c < d);
    const e = makeKey(false, unlayered, 0, 2);
    try std.testing.expect(d < e);
}
