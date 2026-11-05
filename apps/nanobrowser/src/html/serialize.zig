//! HTML serialization: what `innerHTML` and `outerHTML` read back. Walks the
//! tree with a loop, so depth built by scripts cannot overflow the stack.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const tags = @import("tags.zig");

const Out = std.ArrayList(u8);

fn escapeText(gpa: Allocator, out: *Out, s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '&') {
            try out.appendSlice(gpa, "&amp;");
        } else if (c == '<') {
            try out.appendSlice(gpa, "&lt;");
        } else if (c == '>') {
            try out.appendSlice(gpa, "&gt;");
        } else if (c == 0xC2 and i + 1 < s.len and s[i + 1] == 0xA0) {
            try out.appendSlice(gpa, "&nbsp;");
            i += 1;
        } else {
            try out.append(gpa, c);
        }
        i += 1;
    }
}

fn escapeAttr(gpa: Allocator, out: *Out, s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '"' => try out.appendSlice(gpa, "&quot;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            0xC2 => {
                if (i + 1 < s.len and s[i + 1] == 0xA0) {
                    try out.appendSlice(gpa, "&nbsp;");
                    i += 1;
                } else {
                    try out.append(gpa, c);
                }
            },
            else => try out.append(gpa, c),
        }
        i += 1;
    }
}

fn isRawTextParent(n: ?*const dom.Node) bool {
    const p = n orelse return false;
    if (p.kind != .element or p.ns != .html) return false;
    const raw = [_][]const u8{ "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript" };
    for (raw) |r| if (std.mem.eql(u8, p.tag, r)) return true;
    return false;
}

/// A node's opening: the whole of it for anything but an element with contents.
fn open(gpa: Allocator, out: *Out, n: *const dom.Node) Allocator.Error!void {
    switch (n.kind) {
        .element => {
            try out.append(gpa, '<');
            try out.appendSlice(gpa, n.tag);
            for (n.attrs.items) |a| {
                try out.append(gpa, ' ');
                try out.appendSlice(gpa, a.name);
                try out.appendSlice(gpa, "=\"");
                try escapeAttr(gpa, out, a.value);
                try out.append(gpa, '"');
            }
            try out.append(gpa, '>');
        },
        .text => {
            if (isRawTextParent(n.parent)) {
                try out.appendSlice(gpa, n.data);
            } else {
                try escapeText(gpa, out, n.data);
            }
        },
        .comment => {
            try out.appendSlice(gpa, "<!--");
            try out.appendSlice(gpa, n.data);
            try out.appendSlice(gpa, "-->");
        },
        .doctype => {
            try out.appendSlice(gpa, "<!DOCTYPE ");
            try out.appendSlice(gpa, n.data);
            try out.append(gpa, '>');
        },
        .document, .fragment => {},
    }
}

fn close(gpa: Allocator, out: *Out, n: *const dom.Node) Allocator.Error!void {
    if (n.kind != .element) return;
    if (n.ns == .html and tags.isVoid(n.tag)) return;
    try out.appendSlice(gpa, "</");
    try out.appendSlice(gpa, n.tag);
    try out.append(gpa, '>');
}

fn isLeaf(n: *const dom.Node) bool {
    return n.kind == .element and n.ns == .html and tags.isVoid(n.tag);
}

/// `node` as markup, owned by the caller: with its own tags when
/// `include_self` (`outerHTML`), else its contents (`innerHTML`).
pub fn serialize(gpa: Allocator, node: *dom.Node, include_self: bool) Allocator.Error![]u8 {
    var out: Out = .empty;
    errdefer out.deinit(gpa);
    if (include_self) try open(gpa, &out, node);
    if (!isLeaf(node)) {
        var at: ?*dom.Node = (node.template_content orelse node).first_child;
        while (at) |n| {
            try open(gpa, &out, n);
            // A template's markup is its content's, which has a tree of its own.
            if (n.template_content) |f| {
                const inner = try serialize(gpa, f, false);
                defer gpa.free(inner);
                try out.appendSlice(gpa, inner);
            }
            if (n.first_child != null and !isLeaf(n)) {
                at = n.first_child;
                continue;
            }
            try close(gpa, &out, n);
            // Up and along, closing what ends.
            var up: *dom.Node = n;
            at = null;
            while (true) {
                if (up.next) |s| {
                    at = s;
                    break;
                }
                const p = up.parent orelse break;
                if (p == node) break;
                try close(gpa, &out, p);
                up = p;
            }
        }
    }
    if (include_self) try close(gpa, &out, node);
    return out.toOwnedSlice(gpa);
}
