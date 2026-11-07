//! `@keyframes`: its block of percentages, each with its declarations.
const std = @import("std");
const sheet = @import("sheet.zig");
const parser = @import("parser.zig");
const Allocator = std.mem.Allocator;

/// `p`: the parser, its `{` just read.
pub fn parse(p: anytype, name: []const u8, cond: ?*const sheet.Cond) Allocator.Error!void {
    var frames: std.ArrayList(sheet.Keyframe) = .empty;
    while (true) {
        const t = try p.next();
        switch (t.kind) {
            .eof, .rbrace => break,
            .whitespace, .semicolon => {},
            else => {
                p.peeked = t;
                const mark = p.temp.items.len;
                defer p.temp.items.len = mark;
                if (try p.prelude(false) != .lbrace) break;
                const decls = try block(p);
                var at: f32 = 0;
                for (p.temp.items[mark..]) |k| {
                    if (k.isIdent("from")) {
                        at = 0;
                    } else if (k.isIdent("to")) {
                        at = 1;
                    } else if (k.kind == .percentage) {
                        at = k.num / 100;
                    } else continue;
                    if (at >= 0 and at <= 1) try frames.append(p.arena, .{ .at = at, .decls = decls });
                }
            },
        }
    }
    std.mem.sort(sheet.Keyframe, frames.items, {}, struct {
        fn less(_: void, a: sheet.Keyframe, b: sheet.Keyframe) bool {
            return a.at < b.at;
        }
    }.less);
    try p.keyframes.append(p.arena, .{ .name = name, .frames = frames.items, .cond = cond });
}

/// A block of real properties' declarations, nothing nested.
fn block(p: anytype) Allocator.Error!*const sheet.Declarations {
    var pending: std.ArrayList(sheet.Declaration) = .empty;
    while (true) {
        const t = try p.next();
        switch (t.kind) {
            .eof, .rbrace => break,
            .whitespace, .semicolon => {},
            else => {
                p.peeked = t;
                const mark = p.temp.items.len;
                defer p.temp.items.len = mark;
                const end = try p.declOrRule(mark);
                if (end == .lbrace) {
                    try p.skipBlock();
                } else if (try parser.parseDeclaration(p.arena, p.base, p.temp.items[mark..])) |d| {
                    try pending.append(p.arena, d);
                }
            },
        }
    }
    return parser.makeDeclarations(p.arena, pending.items);
}
