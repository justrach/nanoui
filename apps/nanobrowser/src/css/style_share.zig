//! 512-set 2-way set-associative style sharing cache for sibling, cousin, and
//! shadow-tree elements (`1,024` entries total).
//!
//! Theorems 72, 78 & 79 (`NanoUI.Speedometer3Apex`):
//! Two elements share an identical computed `Style` when they share canonical parent
//! style, custom-property scope, rule index, tag, `class` attribute, referenced `id`/
//! attributes, `:checked` / `display: contents` flex-parent / positional flags, and
//! neither element has active `Animator` state or contains `hover`/`active`/`focus`.

const std = @import("std");
const dom = @import("../dom.zig");
const style = @import("style.zig");
const vars = @import("vars.zig");
const rule_index = @import("rule_index.zig");
const perf = @import("../perf_rules.zig");

const unshareable_tags = std.StaticStringMap(void).initComptime(.{
    .{"body"}, .{"td"}, .{"th"}, .{"noscript"}, .{"select"},
    .{"textarea"}, .{"option"}, .{"optgroup"}, .{"fieldset"}, .{"progress"}, .{"summary"},
});

const html_style_attr_mask: u64 = blk: {
    var m: u64 = perf.attrBit("style") | perf.attrBit("slot") | perf.attrBit("part") | perf.attrBit("inert");
    for (perf.html_style_attrs.keys()) |k| m |= perf.attrBit(k);
    break :blk m;
};

const svg_style_attr_mask: u64 = blk: {
    var m: u64 = perf.attrBit("style") | perf.attrBit("lang");
    for (perf.svg_pres_attrs.keys()) |k| m |= perf.attrBit(k);
    break :blk m;
};

fn eqlOptSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

inline fn containsState(el: *const dom.Node, state_node: ?*const dom.Node) bool {
    const st = state_node orelse return false;
    if (el == st) return true;
    if (el.first_child == null) return false;
    return el.contains(st);
}

inline fn idBlocksShare(doc: *const dom.Document, ix: *const rule_index.Index, id_opt: ?[]const u8) bool {
    const id = id_opt orelse return false;
    if (ix.mentionsId(id) or ix.mentionsAttr("id")) return true;
    if (std.mem.indexOfScalar(u8, doc.url, '#')) |h| {
        if (std.mem.eql(u8, doc.url[h + 1 ..], id)) return true;
    }
    return false;
}

inline fn isInputChecked(n: *const dom.Node) bool {
    if (n.ns != .html or !n.isTag("input")) return false;
    const ty = n.attr("type") orelse return false;
    if (!std.ascii.eqlIgnoreCase(ty, "checkbox") and !std.ascii.eqlIgnoreCase(ty, "radio")) return false;
    return n.checked orelse n.hasAttr("checked");
}

fn isStyleRelevantAttr(ns: dom.Ns, name: []const u8, ix: *const rule_index.Index) bool {
    if (ns == .svg) {
        return perf.svg_pres_attrs.has(name) or std.mem.eql(u8, name, "style") or std.mem.eql(u8, name, "lang") or ix.mentionsAttr(name);
    }
    var buf: [64]u8 = undefined;
    var low = name;
    for (name) |c| if (std.ascii.isUpper(c)) {
        if (name.len > buf.len) return true;
        low = std.ascii.lowerString(&buf, name);
        break;
    };
    return perf.html_style_attrs.has(low) or
        std.mem.eql(u8, low, "style") or
        std.mem.eql(u8, low, "slot") or
        std.mem.eql(u8, low, "part") or
        std.mem.eql(u8, low, "inert") or
        ix.mentionsAttr(low);
}

pub const ShareCand = struct {
    set: usize,
    pos_flags: u8,
    uses_next: bool = false,
    disallow_cousin: bool = false,
    rule_ix: *const rule_index.Index,
    host_hash: u64 = 0,
    extra: [4]dom.Attr = undefined,
    extra_len: u8 = 0,
    prev_tag: []const u8 = "",
    prev_class: ?[]const u8 = null,
};

pub const StyleShareEntry = struct {
    generation: u32 = 0,
    shared_group: u32 = 0,
    parent_shared_gen: u32 = 0,
    ns: dom.Ns = .html,
    rule_ix: ?*const rule_index.Index = null,
    tree_scope: ?*const dom.Node = null,
    parent: ?*const dom.Node = null,
    parent_style: ?*const style.Style = null,
    parent_scope: ?*const vars.Scope = null,
    ancestor_bloom: u64 = 0,
    ancestor_hash: u64 = 0,
    host_hash: u64 = 0,
    tag: []const u8 = "",
    class_attr: ?[]const u8 = null,
    extra: [4]dom.Attr = undefined,
    extra_len: u8 = 0,
    pos_flags: u8 = 0,
    prev_tag: []const u8 = "",
    prev_class: ?[]const u8 = null,
    computed: *const style.Style = undefined,
    before: ?*const style.Style = null,
    after: ?*const style.Style = null,
    scope: ?*const vars.Scope = null,
};

pub const ShadowShareEntry = struct {
    generation: u32 = 0,
    shared_group: u32 = 0,
    parent_style: ?*const style.Style = null,
    parent_scope: ?*const vars.Scope = null,
    computed: *const style.Style = undefined,
};

pub const StyleShareCache = struct {
    pub const num_sets = 1024;
    entries: [num_sets * 4]StyleShareEntry = @splat(.{}),
    ways: [num_sets]u2 = @splat(0),
    shadow_entries: [16]ShadowShareEntry = @splat(.{}),
    next_group: u32 = 1,

    fn allocGroup(self: *StyleShareCache) u32 {
        const g = self.next_group;
        self.next_group = if (g == std.math.maxInt(u32)) 1 else g + 1;
        return g;
    }

    fn setOf(ix: *const rule_index.Index, parent_style: *const style.Style, parent_ptr: usize, tag: []const u8, class_attr: ?[]const u8, class_filter: u64, extra_hash: u64, host_hash: u64, pos_flags: u8) usize {
        var h: u64 = (@intFromPtr(parent_style) >> 4) *% 0x9E3779B97F4A7C15;
        h ^= (@intFromPtr(ix) >> 4) *% 0xD6E8FEB86659FD93;
        h ^= (parent_ptr >> 4) *% 0x9E3779B97F4A7C15;
        h ^= class_filter *% 0x517CC1B727220A95;
        if (class_attr) |ca| h ^= (@as(u64, ca.len) *% 0x94D049BB133111EB) ^ (@as(u64, if (ca.len > 0) ca[ca.len - 1] else 0) << 16);
        h ^= extra_hash *% 0xBF58476D1CE4E5B9;
        h ^= host_hash *% 0x27D4EB2F165667C5;
        h ^= (@as(u64, tag.len) << 8) | (if (tag.len > 0) @as(u64, tag[0]) | (@as(u64, tag[tag.len - 1]) << 16) else 0);
        h ^= @as(u64, pos_flags) *% 0x3C79AC492BA7B653;
        return @intCast((h ^ (h >> 32)) & (num_sets - 1));
    }

    pub fn lookupShadow(self: *const StyleShareCache, gen: u32, parent_style: *const style.Style, parent_scope: ?*const vars.Scope) ?*const ShadowShareEntry {
        const idx: usize = @intCast((((@intFromPtr(parent_style) >> 4) *% 0x9E3779B97F4A7C15) >> 32) & 15);
        const e = &self.shadow_entries[idx];
        if (e.generation == gen and e.parent_style == parent_style and e.parent_scope == parent_scope) return e;
        return null;
    }

    pub fn recordShadow(self: *StyleShareCache, gen: u32, n: *dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, stored: *const style.Style) void {
        const idx: usize = @intCast((((@intFromPtr(parent_style) >> 4) *% 0x9E3779B97F4A7C15) >> 32) & 15);
        const grp = self.allocGroup();
        n.style_shared_gen = grp;
        n.style_canon = stored;
        self.shadow_entries[idx] = .{
            .generation = gen,
            .shared_group = grp,
            .parent_style = parent_style,
            .parent_scope = parent_scope,
            .computed = stored,
        };
    }

    pub fn canShare(n: *const dom.Node, ix: *const rule_index.Index, parent_style: *const style.Style, parent_is_root: bool, parent_contents: bool, parent_is_host: bool, host_has_rules: bool, node_has_anim: bool) ?ShareCand {
        const doc = n.doc;
        if ((n.ns != .html and n.ns != .svg) or parent_is_root or parent_is_host or node_has_anim or doc.quirks) { perf.prof_ss_rej_root_host += 1; return null; }
        if (n.is_shadow or host_has_rules or idBlocksShare(doc, ix, n.id_attr)) { perf.prof_ss_rej_id += 1; return null; }
        if (n.tree_scope != null and (n.attr_filter & perf.attrBit("part")) != 0) return null;
        if (n.modal or n.popover_open or n.selected != null or n.value != null) { perf.prof_ss_rej_val += 1; return null; }
        if (ix.uses_has) { perf.prof_ss_has += 1; return null; }
        if (ix.unshareable_subj.mayMatch(n)) {
            perf.prof_ss_unshare += 1;
            if (ix.unshareable_subj.universal) perf.prof_ss_univ += 1;
            return null;
        }
        if (containsState(n, doc.hover) or containsState(n, doc.active) or containsState(n, doc.focus)) { perf.prof_ss_rej_state += 1; return null; }
        if (n.ns == .html) {
            if (unshareable_tags.has(n.tag)) { perf.prof_ss_rej_tag += 1; return null; }
            if ((n.isTag("button") or n.isTag("input")) and (n.ancestor_bloom & (perf.attrBit("fieldset") | perf.attrBit("optgroup"))) != 0) return null;
        }
        const base_mask = if (n.ns == .svg) svg_style_attr_mask else html_style_attr_mask;
        const rel_mask = ix.attr_filter | base_mask;
        var extra: [4]dom.Attr = undefined;
        var extra_len: u8 = 0;
        var extra_hash: u64 = 0;
        const ignored_count: usize = @as(usize, @intFromBool(n.class_attr != null)) + @as(usize, @intFromBool(n.id_attr != null));
        if (n.attrs.items.len > ignored_count and (n.attr_filter & rel_mask) != 0) {
            for (n.attrs.items) |a| {
                if ((a.name.len == 5 and a.name[0] == 'c' and std.mem.eql(u8, a.name, "class")) or
                    (a.name.len == 2 and a.name[0] == 'i' and std.mem.eql(u8, a.name, "id"))) continue;
                if ((perf.attrBit(a.name) & rel_mask) == 0) continue;
                if (!isStyleRelevantAttr(n.ns, a.name, ix)) continue;
                if (extra_len >= 4) return null;
                extra[extra_len] = a;
                extra_len += 1;
                extra_hash = (extra_hash *% 0x9E3779B97F4A7C15) ^ perf.attrBit(a.name) ^ std.hash.Wyhash.hash(0, a.value);
            }
        }
        const check_first = ix.first_subj.mayMatch(n);
        const check_last = ix.last_subj.mayMatch(n);
        const check_next = ix.next_subj.mayMatch(n);
        const check_empty = ix.empty_subj.mayMatch(n);
        const prev = if (check_first or check_next) n.prevElement() else null;
        var prev_tag: []const u8 = "";
        var prev_class: ?[]const u8 = null;
        var pos_flags: u8 = if (isInputChecked(n)) 8 else 0;
        if (parent_contents) {
            pos_flags |= 32;
            var at = n.parent;
            while (at) |p| : (at = p.parent) {
                const ps = p.computed orelse break;
                if (ps.display != .contents) {
                    if (ps.isFlex() or ps.isGrid()) pos_flags |= 64;
                    break;
                }
            }
        }
        if (check_next) {
            if (prev) |pr| {
                if (idBlocksShare(doc, ix, pr.id_attr) or pr.selected != null or pr.value != null or pr.modal or pr.popover_open) return null;
                if (containsState(pr, doc.hover) or containsState(pr, doc.active) or containsState(pr, doc.focus)) return null;
                if ((pr.attr_filter & (perf.attrBit("disabled") | perf.attrBit("open") | perf.attrBit("readonly") | perf.attrBit("required"))) != 0) return null;
                if (ix.uses_attr_before_next and (pr.attr_filter & ix.attr_filter) != 0) {
                    for (pr.attrs.items) |pa| {
                        if (std.mem.eql(u8, pa.name, "class") or std.mem.eql(u8, pa.name, "id")) continue;
                        if (isStyleRelevantAttr(pr.ns, pa.name, ix) and ix.mentionsAttr(pa.name)) return null;
                    }
                }
                if (isInputChecked(pr)) pos_flags |= 16;
                prev_tag = pr.tag;
                prev_class = pr.class_attr;
            }
        }
        if (check_first and prev == null) pos_flags |= 1;
        if (check_last and n.nextElement() == null) pos_flags |= 2;
        if (check_empty) {
            var is_empty = true;
            var ch = n.first_child;
            while (ch) |k| : (ch = k.next) {
                if (k.kind == .element or (k.kind == .text and k.data.len > 0)) {
                    is_empty = false;
                    break;
                }
            }
            if (is_empty) pos_flags |= 4;
        }
        const host_hash: u64 = if (ix.uses_host_in_subtree) blk: {
            if (n.tree_scope) |sr| if (sr.parent) |host| {
                break :blk (host.ancestor_hash *% 0x9E3779B97F4A7C15) ^ perf.nodeSelfHash(host);
            };
            break :blk 0;
        } else 0;
        const disallow_cousin = ix.uses_container or ix.anc_pos_subj.mayMatch(n) or (ix.uses_focus_within and doc.focus != null);
        const parent_ptr: usize = if (disallow_cousin and n.parent != null) @intFromPtr(n.parent.?) else 0;
        perf.prof_ss_cand += 1;
        return .{
            .set = setOf(ix, parent_style, parent_ptr, n.tag, n.class_attr, n.class_filter, extra_hash, host_hash, pos_flags),
            .pos_flags = pos_flags,
            .uses_next = check_next,
            .disallow_cousin = disallow_cousin,
            .rule_ix = ix,
            .host_hash = host_hash,
            .extra = extra,
            .extra_len = extra_len,
            .prev_tag = prev_tag,
            .prev_class = prev_class,
        };
    }

    fn matchesEntry(entry: *const StyleShareEntry, gen: u32, n: *const dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, cand: *const ShareCand) bool {
        if (entry.generation != gen) return false;
        if (entry.ns != n.ns or entry.rule_ix != cand.rule_ix or entry.parent_style != parent_style or entry.parent_scope != parent_scope) return false;
        if ((entry.tree_scope == null) != (n.tree_scope == null)) return false;
        if (entry.tree_scope != n.tree_scope and cand.rule_ix.uses_host_in_subtree and cand.disallow_cousin) return false;
        if (entry.pos_flags != cand.pos_flags or entry.ancestor_bloom != n.ancestor_bloom or entry.ancestor_hash != n.ancestor_hash or entry.host_hash != cand.host_hash or entry.extra_len != cand.extra_len) return false;
        if (n.parent != entry.parent and cand.disallow_cousin) return false;
        if (!std.mem.eql(u8, entry.tag, n.tag) or !eqlOptSlice(entry.class_attr, n.class_attr)) return false;
        for (0..cand.extra_len) |i| {
            if (!std.mem.eql(u8, entry.extra[i].name, cand.extra[i].name) or !std.mem.eql(u8, entry.extra[i].value, cand.extra[i].value)) return false;
        }
        if (cand.uses_next) {
            if (!std.mem.eql(u8, entry.prev_tag, cand.prev_tag) or !eqlOptSlice(entry.prev_class, cand.prev_class)) return false;
        }
        return true;
    }

    pub fn lookup(self: *const StyleShareCache, gen: u32, n: *const dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, cand: ShareCand) ?*const StyleShareEntry {
        const base = cand.set * 4;
        inline for (0..4) |w| {
            if (matchesEntry(&self.entries[base + w], gen, n, parent_style, parent_scope, &cand)) return &self.entries[base + w];
        }
        if (self.entries[base].generation != gen) perf.prof_ss_miss_gen += 1 else perf.prof_ss_miss_key += 1;
        return null;
    }

    fn pseudoShareable(ps_opt: ?*const style.Style) bool {
        const ps = ps_opt orelse return true;
        return ps.animations.len == 0 and ps.transitions.len == 0 and
            ps.counter_reset.len == 0 and ps.counter_increment.len == 0 and
            ps.counter_set.len == 0 and ps.content_parts.len == 0;
    }

    pub fn record(self: *StyleShareCache, gen: u32, n: *dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, cand: ShareCand, stored: *const style.Style, before: ?*const style.Style, after: ?*const style.Style, scope: ?*const vars.Scope, has_extra_pseudo: bool) void {
        if (has_extra_pseudo or stored.container_type != .normal) return;
        if (stored.animations.len != 0 or !pseudoShareable(before) or !pseudoShareable(after)) return;
        if (stored.counter_reset.len != 0 or stored.counter_increment.len != 0 or stored.counter_set.len != 0) return;
        perf.prof_ss_rec += 1;
        const grp = self.allocGroup();
        n.style_shared_gen = grp;
        n.style_canon = stored;
        const base = cand.set * 4;
        var idx: usize = base;
        var found = false;
        inline for (0..4) |w| {
            if (!found and self.entries[base + w].generation != gen) {
                idx = base + w;
                found = true;
            }
        }
        if (!found) {
            const w = self.ways[cand.set];
            self.ways[cand.set] +%= 1;
            idx = base + w;
        }
        self.entries[idx] = .{
            .generation = gen,
            .shared_group = grp,
            .parent_shared_gen = if (n.parent) |p| p.style_shared_gen else 0,
            .ns = n.ns,
            .rule_ix = cand.rule_ix,
            .tree_scope = n.tree_scope,
            .parent = n.parent,
            .parent_style = parent_style,
            .parent_scope = parent_scope,
            .ancestor_bloom = n.ancestor_bloom,
            .ancestor_hash = n.ancestor_hash,
            .host_hash = cand.host_hash,
            .tag = n.tag,
            .class_attr = n.class_attr,
            .extra = cand.extra,
            .extra_len = cand.extra_len,
            .pos_flags = cand.pos_flags,
            .prev_tag = cand.prev_tag,
            .prev_class = cand.prev_class,
            .computed = stored,
            .before = before,
            .after = after,
            .scope = scope,
        };
    }
};
