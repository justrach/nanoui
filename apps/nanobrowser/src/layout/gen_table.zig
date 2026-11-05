//! Anonymous table parts, per CSS 2 §17.2.1: a cell without a row, a row
//! without a table, and anything else directly in a table's parts gets the
//! boxes it lacks, so `table.zig` always sees table, group, row, cell.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const gen = @import("gen.zig");
const Box = box.Box;
const Entry = box.Entry;
const Error = ctx.Error;
const Gen = gen.Gen;

fn isPart(e: Entry) bool {
    if (e.tag != .box) return false;
    return switch (e.box.?.kind) {
        .table_row_group, .table_row, .table_cell, .table_caption => true,
        else => false,
    };
}

fn isAbs(e: Entry) bool {
    return e.tag == .box and e.box.?.style.isOutOfFlow();
}

fn anonBox(g: *Gen, parent: *const css.Style, kind: box.Kind, display: css.Display) Error!*Box {
    return gen.newBox(g.c, kind, null, try g.c.anonStyle(parent, display));
}

/// True if the run holds anything but collapsible space.
fn hasContent(run: []const Entry) bool {
    for (run) |e| if (!gen.isWhitespace(e)) return true;
    return false;
}

/// Wraps runs of table parts that have no table around them in an anonymous table.
pub fn wrapOrphans(g: *Gen, parent: *Box, entries: []const Entry) Error![]const Entry {
    var any = false;
    for (entries) |e| any = any or isPart(e);
    if (!any) return entries;
    var out: std.ArrayList(Entry) = .empty;
    const a = g.c.arena;
    var i: usize = 0;
    while (i < entries.len) {
        if (!isPart(entries[i])) {
            try out.append(a, entries[i]);
            i += 1;
            continue;
        }
        var j = i + 1;
        var end = j;
        while (j < entries.len and (isPart(entries[j]) or gen.isWhitespace(entries[j]))) : (j += 1) {
            if (isPart(entries[j])) end = j + 1;
        }
        const t = try anonBox(g, parent.style, .table, .table);
        try fixTable(g, t, entries[i..end]);
        try out.append(a, .{ .tag = .box, .box = t, .style = t.style });
        i = end;
    }
    return out.items;
}

pub fn fixTable(g: *Gen, b: *Box, entries: []const Entry) Error!void {
    var from: usize = 0;
    for (entries, 0..) |e, i| {
        if (isAbs(e)) {
            b.append(e.box.?);
            continue;
        }
        const direct = e.tag == .box and (e.box.?.kind == .table_row_group or e.box.?.kind == .table_caption);
        if (!direct) continue;
        try groupRun(g, b, entries[from..i]);
        b.append(e.box.?);
        from = i + 1;
    }
    try groupRun(g, b, entries[from..]);
    // Collapsed borders are the boxes' own from here on.
    if (b.style.border_collapse) _ = try @import("table.zig").analyse(g.c, b);
}

fn groupRun(g: *Gen, b: *Box, run: []const Entry) Error!void {
    var keep = false;
    for (run) |e| keep = keep or !(gen.isWhitespace(e) or isAbs(e));
    if (!keep) return;
    const anon = try anonBox(g, b.style, .table_row_group, .table_row_group);
    b.append(anon);
    var rest: std.ArrayList(Entry) = .empty;
    for (run) |e| if (!isAbs(e)) try rest.append(g.c.arena, e);
    try fixGroup(g, anon, rest.items);
}

pub fn fixGroup(g: *Gen, b: *Box, entries: []const Entry) Error!void {
    var from: usize = 0;
    for (entries, 0..) |e, i| {
        if (isAbs(e)) {
            b.append(e.box.?);
            continue;
        }
        if (e.tag != .box or e.box.?.kind != .table_row) continue;
        try rowRun(g, b, entries[from..i]);
        b.append(e.box.?);
        from = i + 1;
    }
    try rowRun(g, b, entries[from..]);
}

fn rowRun(g: *Gen, b: *Box, run: []const Entry) Error!void {
    if (!hasContent(run)) return;
    const anon = try anonBox(g, b.style, .table_row, .table_row);
    b.append(anon);
    try fixRow(g, anon, run);
}

pub fn fixRow(g: *Gen, b: *Box, entries: []const Entry) Error!void {
    var from: usize = 0;
    for (entries, 0..) |e, i| {
        if (isAbs(e)) {
            b.append(e.box.?);
            continue;
        }
        if (e.tag != .box or e.box.?.kind != .table_cell) continue;
        try cellRun(g, b, entries[from..i]);
        b.append(e.box.?);
        from = i + 1;
    }
    try cellRun(g, b, entries[from..]);
}

fn cellRun(g: *Gen, b: *Box, run: []const Entry) Error!void {
    if (!hasContent(run)) return;
    const anon = try anonBox(g, b.style, .table_cell, .table_cell);
    b.append(anon);
    try gen.container(g, anon, run);
}
