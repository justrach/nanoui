//! Conjunctive subject filter (`SubjectMask` / `RuleReq`) for positional and
//! sibling-dependent CSS selector tracking (`NanoUI.Speedometer3Model` Theorem 79).
const std = @import("std");
const dom = @import("../dom.zig");
const sel = @import("selectors.zig");
const perf = @import("../perf_rules.zig");

pub const RuleReq = struct {
    id_bit: u64 = 0,
    class_mask: u64 = 0,
    tag_bit: u64 = 0,
    attr_mask: u64 = 0,
    anc_mask: u64 = 0,
};

pub const SubjectMask = struct {
    pub const max_reqs = 24;
    reqs: [max_reqs]RuleReq = @splat(.{}),
    len: u8 = 0,
    any_id: u64 = 0,
    any_class: u64 = 0,
    any_tag: u64 = 0,
    any_attr: u64 = 0,
    any_anc: u64 = 0,
    ov_id: u64 = 0,
    ov_class: u64 = 0,
    ov_tag: u64 = 0,
    ov_attr: u64 = 0,
    ov_anc: u64 = 0,
    universal: bool = false,

    pub fn record(self: *SubjectMask, subject: []const sel.Simple, ancestor_bloom: u64) void {
        var r: RuleReq = .{ .anc_mask = ancestor_bloom };
        for (subject) |s| switch (s) {
            .id => |id| r.id_bit |= perf.attrBit(id),
            .class => |c| r.class_mask |= perf.classBit(c),
            .tag => |t| r.tag_bit |= perf.attrBit(t),
            .attr => |a| r.attr_mask |= perf.attrBit(a.lower),
            else => {},
        };
        if (r.id_bit == 0 and r.class_mask == 0 and r.tag_bit == 0 and r.attr_mask == 0 and r.anc_mask == 0) {
            self.universal = true;
            return;
        }
        for (self.reqs[0..self.len]) |ex| {
            if (std.meta.eql(ex, r)) return;
        }
        if (self.len < max_reqs) {
            self.reqs[self.len] = r;
            self.len += 1;
            self.any_id |= r.id_bit;
            self.any_class |= r.class_mask;
            self.any_tag |= r.tag_bit;
            self.any_attr |= r.attr_mask;
            self.any_anc |= r.anc_mask;
            return;
        }
        if (r.id_bit != 0) self.ov_id |= r.id_bit else if (r.class_mask != 0) self.ov_class |= r.class_mask else if (r.tag_bit != 0) self.ov_tag |= r.tag_bit else if (r.attr_mask != 0) self.ov_attr |= r.attr_mask else self.ov_anc |= r.anc_mask;
    }

    pub inline fn mayMatch(self: *const SubjectMask, n: *const dom.Node) bool {
        if (self.universal) return true;
        var low_buf: [64]u8 = undefined;
        const need_tag = (self.any_tag | self.ov_tag) != 0;
        const tag_b: u64 = if (!need_tag) 0 else if (n.ns == .html or n.tag.len > low_buf.len) perf.attrBit(n.tag) else perf.attrBit(std.ascii.lowerString(&low_buf, n.tag));
        if ((self.ov_id | self.ov_class | self.ov_tag | self.ov_attr | self.ov_anc) != 0) {
            if (self.ov_id != 0) if (n.id_attr) |id| if ((self.ov_id & perf.attrBit(id)) != 0) return true;
            if ((self.ov_class & n.class_filter) != 0 or (self.ov_tag & tag_b) != 0 or (self.ov_attr & n.attr_filter) != 0 or (self.ov_anc & n.ancestor_bloom) != 0) return true;
        }
        if (self.len == 0) return false;
        const id_b: u64 = if (self.any_id != 0 and n.id_attr != null) perf.attrBit(n.id_attr.?) else 0;
        if (((id_b & self.any_id) | (n.class_filter & self.any_class) | (tag_b & self.any_tag) | (n.attr_filter & self.any_attr) | (n.ancestor_bloom & self.any_anc)) == 0) return false;
        for (self.reqs[0..self.len]) |r| {
            if ((n.ancestor_bloom & r.anc_mask) != r.anc_mask) continue;
            if ((tag_b & r.tag_bit) != r.tag_bit) continue;
            if ((n.class_filter & r.class_mask) != r.class_mask) continue;
            if ((n.attr_filter & r.attr_mask) != r.attr_mask) continue;
            if ((id_b & r.id_bit) != r.id_bit) continue;
            return true;
        }
        return false;
    }
};
