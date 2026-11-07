//! What selectors call things: pseudo-classes and pseudo-elements by name, and the
//! `An+B` of `:nth-child()`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tk = @import("tokenizer.zig");
const types = @import("selectors.zig");

const Token = tk.Token;
const PseudoClass = types.PseudoClass;

pub fn legacyElement(name: []const u8) bool {
    const l = [_][]const u8{ "before", "after", "first-line", "first-letter" };
    for (l) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

pub fn isOtherElement(name: []const u8) bool {
    const l = [_][]const u8{ "selection", "placeholder", "first-line", "first-letter", "file-selector-button", "details-content", "target-text", "cue", "scroll-marker" };
    for (l) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

pub fn isElementFunction(name: []const u8) bool {
    const l = [_][]const u8{ "part", "slotted", "cue", "highlight", "view-transition-group", "view-transition-image-pair", "view-transition-old", "view-transition-new" };
    for (l) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

pub const pseudo_classes = std.StaticStringMap(PseudoClass).initComptime(.{
    .{ "root", .root },                   .{ "empty", .empty },                         .{ "first-child", .first_child },
    .{ "last-child", .last_child },       .{ "only-child", .only_child },               .{ "first-of-type", .first_of_type },
    .{ "last-of-type", .last_of_type },   .{ "only-of-type", .only_of_type },           .{ "link", .link },
    .{ "any-link", .any_link },           .{ "-webkit-any-link", .any_link },           .{ "visited", .visited },
    .{ "hover", .hover },                 .{ "active", .active },                       .{ "focus", .focus },
    .{ "focus-visible", .focus_visible }, .{ "focus-within", .focus_within },           .{ "checked", .checked },
    .{ "disabled", .disabled },           .{ "enabled", .enabled },                     .{ "required", .required },
    .{ "optional", .optional },           .{ "placeholder-shown", .placeholder_shown }, .{ "read-only", .read_only },
    .{ "read-write", .read_write },       .{ "scope", .scope },                         .{ "target", .target },
    .{ "defined", .defined },             .{ "default", .default },                     .{ "valid", .valid },
    .{ "indeterminate", .indeterminate }, .{ "invalid", .never },                       .{ "user-valid", .never },
    .{ "user-invalid", .never },          .{ "in-range", .valid },                      .{ "out-of-range", .never },
    .{ "fullscreen", .never },            .{ "modal", .modal },                         .{ "popover-open", .popover_open },
    .{ "autofill", .never },              .{ "-webkit-autofill", .never },
    .{ "open", .open },                   .{ "closed", .never },                        .{ "paused", .never },
    .{ "playing", .never },               .{ "past", .never },                          .{ "future", .never },
    .{ "current", .never },               .{ "picture-in-picture", .never },            .{ "blank", .never },
});

/// `An+B`: `odd`, `even`, `3`, `2n`, `-n+3`, `2n - 1`. The tokenizer splits
/// these oddly, so they are read from the tokens written back as text.
pub fn parseAnB(arena: Allocator, toks: []const Token) Allocator.Error!?[2]i32 {
    const text = try tk.serialize(arena, toks);
    var buf: std.ArrayList(u8) = .empty;
    for (text) |c| if (c != ' ' and c != '\t' and c != '\n') try buf.append(arena, std.ascii.toLower(c));
    return anb(buf.items);
}

fn anb(s: []const u8) ?[2]i32 {
    if (std.mem.eql(u8, s, "odd")) return .{ 2, 1 };
    if (std.mem.eql(u8, s, "even")) return .{ 2, 0 };
    if (s.len == 0) return null;
    const n = std.mem.indexOfScalar(u8, s, 'n') orelse {
        const b = std.fmt.parseInt(i32, s, 10) catch return null;
        return .{ 0, b };
    };
    const a_text = s[0..n];
    const a: i32 = if (a_text.len == 0 or std.mem.eql(u8, a_text, "+"))
        1
    else if (std.mem.eql(u8, a_text, "-"))
        -1
    else
        std.fmt.parseInt(i32, a_text, 10) catch return null;
    const rest = s[n + 1 ..];
    if (rest.len == 0) return .{ a, 0 };
    if (rest[0] != '+' and rest[0] != '-') return null;
    const b = std.fmt.parseInt(i32, rest, 10) catch return null;
    return .{ a, b };
}
