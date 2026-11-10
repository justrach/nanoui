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
    uses_nth_index: bool = false,
    uses_chained_next: bool = false,
    uses_first_child: bool = false,
    uses_last_child: bool = false,
    uses_empty: bool = false,
    uses_attr_before_next: bool = false,
    /// 64-bit Bloom filter of attribute names in `[attr]` selectors.
    attr_filter: u64 = 0,
    /// Some rule sits under `@container`.
    uses_container: bool = false,
    quirks: bool = false,

    pub fn ruleFlags(ix: *const Index) u8 {
        return @as(u8, @intFromBool(ix.uses_has)) |
            (@as(u8, @intFromBool(ix.uses_next_sibling)) << 1) |
            (@as(u8, @intFromBool(ix.uses_later_sibling)) << 2);
    }

    fn scanSelector(ix: *Index, selector: *const sel.Selector, ua: bool) void {
        for (selector.compounds, 0..) |*c, idx| {
            const is_subject = idx + 1 == selector.compounds.len;
            const before_next = !is_subject and selector.compounds[idx + 1].combinator == .next;
            if (!ua and idx > 0) switch (c.combinator) {
                .next => {
                    ix.uses_next_sibling = true;
                    if (!is_subject or (idx > 1 and selector.compounds[idx - 1].combinator != .descendant and selector.compounds[idx - 1].combinator != .child)) {
                        ix.uses_chained_next = true;
                    }
                },
                .later => ix.uses_later_sibling = true,
                else => {},
            };
            for (c.simples) |x| switch (x) {
                .attr => |a| {
                    ix.attr_filter |= perf.attrBit(a.lower);
                    if (!ua and before_next) ix.uses_attr_before_next = true;
                },
                .pseudo => |p| if (!ua) {
                    if (p == .only_of_type) ix.uses_nth_index = true;
                    if (p == .only_child) { ix.uses_first_child = true; ix.uses_last_child = true; }
                    if (p == .empty) ix.uses_empty = true;
                    if (before_next and (p == .only_child or p == .empty)) ix.uses_chained_next = true;
                },
                .nth => |n| {
                    if (!ua) {
                        if (n.a != 0 or n.b != 1 or n.of_type or n.of.len > 0) {
                            ix.uses_nth_index = true;
                        } else if (n.from_end) {
                            ix.uses_last_child = true;
                        } else {
                            ix.uses_first_child = true;
                        }
                        if (before_next) ix.uses_chained_next = true;
                    }
                    if (n.of.len > 0) {
                        ix.uses_later_sibling = true;
                        for (n.of) |*sub| ix.scanSelector(sub, ua);
                    }
                },
                .not, .is, .host, .host_context => |l| for (l) |*sub| {
                    if (!ua) for (sub.compounds) |*sc| for (sc.simples) |sx| switch (sx) {
                        .nth, .has => ix.uses_nth_index = true,
                        .pseudo => |sp| if (sp == .only_child or sp == .only_of_type or sp == .empty) {
                            ix.uses_nth_index = true;
                        },
                        else => {},
                    };
                    ix.scanSelector(sub, ua);
                },
                .has => |l| {
                    if (!ua) ix.uses_has = true;
                    for (l) |*sub| ix.scanSelector(sub, ua);
                },
                else => {},
            };
        }
        for (selector.slotted) |*sub| ix.scanSelector(sub, ua);
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
                ix.scanSelector(selector, ua);
            }
        }
    }

    fn add(ix: *Index, e: Entry) Allocator.Error!void {
        const a = ix.arena.allocator();
        const c = e.sel.compounds;
        if (c.len == 0) return ix.universal.append(a, e);
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
    if (s.compounds.len <= 1) return 0;
    var bloom: u64 = 0;
    var i: usize = s.compounds.len - 1;
    while (i > 0) {
        const comb = s.compounds[i].combinator;
        if (comb != .child and comb != .descendant) break;
        i -= 1;
        for (s.compounds[i].simples) |x| switch (x) {
            .tag => |t| bloom |= perf.attrBit(t),
            .id => |id| bloom |= perf.attrBit(id),
            .class => |c| bloom |= perf.classBit(c),
            else => {},
        };
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
