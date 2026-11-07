//! The list of active formatting elements: reconstructing it when text or an
//! inline element arrives, and the adoption agency algorithm that untangles
//! misnested formatting (`<b><p>x</b>y</p>`).
const std = @import("std");
const dom = @import("../dom.zig");
const tree = @import("tree.zig");
const tags = @import("tags.zig");

const Builder = tree.Builder;
const Error = tree.Error;
const T = tags.T;

/// Pushes an element, keeping at most three identical ones since the last
/// marker (the "Noah's Ark clause").
pub fn pushFormatting(b: *Builder, n: *dom.Node, id: T) Error!void {
    var same: usize = 0;
    var oldest: ?usize = null;
    var i = b.formatting.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.formatting.items[i];
        const o = e.node orelse break;
        if (e.id == id and sameElement(o, n)) {
            same += 1;
            oldest = i;
        }
    }
    if (same >= 3) _ = b.formatting.orderedRemove(oldest.?);
    try b.formatting.append(b.arena, .{ .node = n, .id = id });
}

fn sameElement(a: *const dom.Node, c: *const dom.Node) bool {
    if (!std.mem.eql(u8, a.tag, c.tag) or a.ns != c.ns) return false;
    if (a.attrs.items.len != c.attrs.items.len) return false;
    for (a.attrs.items) |x| {
        const v = c.attr(x.name) orelse return false;
        if (!std.mem.eql(u8, v, x.value)) return false;
    }
    return true;
}

fn formattingIndex(b: *const Builder, n: *const dom.Node) ?usize {
    var i = b.formatting.items.len;
    while (i > 0) {
        i -= 1;
        if (b.formatting.items[i].node == n) return i;
    }
    return null;
}

pub fn removeFormatting(b: *Builder, n: *const dom.Node) void {
    if (formattingIndex(b, n)) |i| _ = b.formatting.orderedRemove(i);
}

/// "Reconstruct the active formatting elements".
pub fn reconstruct(b: *Builder) Error!void {
    const items = b.formatting.items;
    if (items.len == 0) return;
    const last = items[items.len - 1];
    if (last.node == null or b.stackIndex(last.node.?) != null) return;
    // Back to the entry after the last one that is a marker or still open.
    var i = items.len - 1;
    while (i > 0) {
        const e = b.formatting.items[i - 1];
        const n = e.node orelse break;
        if (b.stackIndex(n) != null) break;
        i -= 1;
    }
    while (i < b.formatting.items.len) : (i += 1) {
        const e = b.formatting.items[i];
        const old = e.node.?;
        const fresh = try b.cloneElement(old);
        const at = b.placeFor(null);
        if (b.open.items.len >= 512) b.pop();
        at.parent.insertBefore(fresh, at.before);
        try b.open.append(b.arena, .{ .node = fresh, .id = e.id });
        b.formatting.items[i].node = fresh;
    }
}

/// The adoption agency for an end tag `name`. True means the caller should
/// treat the token as "any other end tag".
pub fn run(b: *Builder, name: []const u8, id: T) Error!bool {
    const c = b.current() orelse return false;
    if (c.id == id and c.node.ns == .html and std.mem.eql(u8, c.node.tag, name) and formattingIndex(b, c.node) == null) {
        b.pop();
        return false;
    }
    var outer: u32 = 0;
    while (outer < 8) : (outer += 1) {
        const formatting = findFormatting(b, id) orelse return true;
        const fm_stack = b.stackIndex(formatting.node) orelse {
            _ = b.formatting.orderedRemove(formatting.index);
            return false;
        };
        if (!b.nodeInScope(formatting.node)) return false;
        const furthest_at = findFurthest(b, fm_stack) orelse {
            b.popUntilNode(formatting.node);
            removeFormatting(b, formatting.node);
            return false;
        };
        try step(b, formatting.node, formatting.id, fm_stack, furthest_at, formatting.index);
    }
    return false;
}

const Found = struct { node: *dom.Node, id: T, index: usize };

fn findFormatting(b: *const Builder, id: T) ?Found {
    var i = b.formatting.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.formatting.items[i];
        const n = e.node orelse return null;
        if (e.id == id) return .{ .node = n, .id = e.id, .index = i };
    }
    return null;
}

/// The topmost special element below the formatting element.
fn findFurthest(b: *const Builder, fm_stack: usize) ?usize {
    var i = fm_stack + 1;
    while (i < b.open.items.len) : (i += 1) {
        if (tags.isSpecial(b.open.items[i].id)) return i;
    }
    return null;
}

/// One round of the outer loop: steps 8 to 20.
fn step(b: *Builder, fm: *dom.Node, fm_id: T, fm_stack: usize, furthest_at: usize, fm_list: usize) Error!void {
    const furthest = b.open.items[furthest_at].node;
    const common = b.open.items[fm_stack - 1 * @intFromBool(fm_stack > 0)].node;
    var bookmark = fm_list;
    var last = furthest;
    var idx = furthest_at;
    var inner: u32 = 0;
    while (true) {
        inner += 1;
        idx -= 1;
        const e = b.open.items[idx];
        if (e.node == fm) break;
        var at_list = formattingIndex(b, e.node);
        if (inner > 3) if (at_list) |al| {
            _ = b.formatting.orderedRemove(al);
            if (al < bookmark) bookmark -= 1;
            at_list = null;
        };
        const list_index = at_list orelse {
            _ = b.open.orderedRemove(idx);
            continue;
        };
        const fresh = try b.cloneElement(e.node);
        b.formatting.items[list_index].node = fresh;
        b.open.items[idx].node = fresh;
        if (last == furthest) bookmark = list_index + 1;
        fresh.appendChild(last);
        last = fresh;
    }
    // Step 14: `last` goes in the appropriate place, with `common` as target.
    const at = b.placeFor(common);
    at.parent.insertBefore(last, at.before);
    // Steps 15 to 17: a copy of the formatting element takes over furthest's children.
    const fresh = try b.cloneElement(fm);
    while (furthest.first_child) |k| fresh.appendChild(k);
    furthest.appendChild(fresh);
    // Step 18.
    if (formattingIndex(b, fm)) |i| {
        _ = b.formatting.orderedRemove(i);
        if (i < bookmark) bookmark -= 1;
    }
    bookmark = @min(bookmark, b.formatting.items.len);
    try b.formatting.insert(b.arena, bookmark, .{ .node = fresh, .id = fm_id });
    // Step 19.
    b.removeFromStack(fm);
    const fi = b.stackIndex(furthest).?;
    try b.open.insert(b.arena, fi + 1, .{ .node = fresh, .id = fm_id });
}
