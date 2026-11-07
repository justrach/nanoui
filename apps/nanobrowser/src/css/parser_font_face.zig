//! An `@font-face` rule's declarations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("tokenizer.zig").Token;
const Declaration = @import("sheet.zig").Declaration;
const parser = @import("parser.zig");

/// `font-family: Optimistic Display`: a family name may be bare words, which
/// are one string with single spaces. Null when these are anything else.
fn wordsAsString(arena: Allocator, t: []const Token) Allocator.Error!?[]const Token {
    if (t.len < 2) return null;
    var out: std.ArrayList(u8) = .empty;
    for (t) |x| switch (x.kind) {
        .ident => {
            if (out.items.len > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, x.text);
        },
        .whitespace => {},
        else => return null,
    };
    const one = try arena.alloc(Token, 1);
    one[0] = .{ .kind = .string, .text = out.items };
    return one;
}

/// `@font-face` descriptors aren't properties; they're kept under `custom`
/// with their names.
pub fn declaration(arena: Allocator, base: []const u8, raw: []const Token) Allocator.Error!?Declaration {
    const toks = parser.trim(raw);
    if (toks.len < 2 or toks[0].kind != .ident) return null;
    var i: usize = 1;
    while (i < toks.len and toks[i].kind == .whitespace) : (i += 1) {}
    if (i >= toks.len or toks[i].kind != .colon) return null;
    if (std.ascii.eqlIgnoreCase(toks[0].text, "font-family")) if (try wordsAsString(arena, parser.trim(toks[i + 1 ..]))) |one| {
        return .{ .prop = .custom, .name = toks[0].text, .value = one, .hash = parser.hashName(toks[0].text) };
    };
    return .{ .prop = .custom, .name = toks[0].text, .value = try parser.resolveUrls(arena, base, parser.trim(toks[i + 1 ..])), .hash = parser.hashName(toks[0].text) };
}
