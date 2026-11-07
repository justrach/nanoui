//! The CSS parser: a sheet's text to flat rules. Its error recovery follows CSS
//! Syntax: a bad declaration ends at its `;`, a bad rule at its block, and
//! parsing goes on. Nesting is flattened here (`sheet.zig` says how).
const std = @import("std");
const Allocator = std.mem.Allocator;
const tk = @import("tokenizer.zig");
const sheet = @import("sheet.zig");
const selectors = @import("selectors.zig");
const media = @import("media.zig");
const prop = @import("prop.zig");
const url = @import("url.zig");
const supports = @import("supports.zig");
const keyframes_rule = @import("parser_keyframes.zig");
const font_face = @import("parser_font_face.zig");

const Token = tk.Token;
const Declaration = sheet.Declaration;
const Declarations = sheet.Declarations;
const Selector = selectors.Selector;
const Cond = sheet.Cond;

/// Where a block sits: its enclosing selectors, conditions and layer.
const Scope = struct {
    selectors: ?[]const Selector = null,
    cond: ?*const Cond = null,
    layer: []const u8 = "",
    container: ?*const sheet.ContainerCond = null,
};

const max_depth = 64;

const P = struct {
    arena: Allocator,
    tz: tk.Tokenizer,
    base: []const u8,
    peeked: ?Token = null,
    /// A stack: a block's tokens sit above those of the blocks around it.
    temp: std.ArrayList(Token) = .empty,
    rules: std.ArrayList(sheet.Rule) = .empty,
    imports: std.ArrayList(sheet.Import) = .empty,
    font_faces: std.ArrayList(sheet.FontFace) = .empty,
    keyframes: std.ArrayList(sheet.Keyframes) = .empty,
    properties: std.ArrayList(sheet.PropertyRule) = .empty,
    layers: std.ArrayList([]const u8) = .empty,
    conds: std.ArrayList(*const Cond) = .empty,
    anon_layers: u32 = 0,
    depth: u32 = 0,
    /// `@import` is only valid before other rules.
    imports_open: bool = true,

    pub fn next(p: *P) Allocator.Error!Token {
        if (p.peeked) |t| {
            p.peeked = null;
            return t;
        }
        return p.tz.next();
    }

    fn peek(p: *P) Allocator.Error!Token {
        if (p.peeked) |t| return t;
        const t = try p.tz.next();
        p.peeked = t;
        return t;
    }

    /// A list of rules, to the end of input or (`in_block`) the closing brace.
    fn ruleList(p: *P, scope: Scope, in_block: bool) Allocator.Error!void {
        p.depth += 1;
        defer p.depth -= 1;
        while (true) {
            const t = try p.next();
            switch (t.kind) {
                .eof => return,
                .whitespace, .cdo, .cdc => {},
                .rbrace => {
                    if (in_block) return;
                    // At the top level a stray brace starts a (bad) rule.
                    p.peeked = t;
                    try p.styleRule(scope);
                },
                .at_keyword => try p.atRule(t, scope),
                else => {
                    p.peeked = t;
                    try p.styleRule(scope);
                },
            }
        }
    }

    /// Tokens onto `temp` until a `{` or `;` at this level, returning which;
    /// `.eof` if neither comes.
    pub fn prelude(p: *P, stop_semicolon: bool) Allocator.Error!tk.Kind {
        var nest: u32 = 0;
        while (true) {
            const t = try p.next();
            switch (t.kind) {
                .eof => return .eof,
                .lbrace => if (nest == 0) return .lbrace,
                .rbrace => if (nest == 0 and stop_semicolon) {
                    p.peeked = t;
                    return .rbrace;
                },
                .semicolon => if (stop_semicolon and nest == 0) return .semicolon,
                .function, .lparen, .lbracket => nest += 1,
                .rparen, .rbracket => nest -|= 1,
                else => {},
            }
            try p.temp.append(p.arena, t);
        }
    }

    pub fn skipBlock(p: *P) Allocator.Error!void {
        var nest: u32 = 1;
        while (nest > 0) {
            const t = try p.next();
            switch (t.kind) {
                .eof => return,
                .lbrace => nest += 1,
                .rbrace => nest -= 1,
                else => {},
            }
        }
    }

    fn styleRule(p: *P, scope: Scope) Allocator.Error!void {
        p.imports_open = false;
        const mark = p.temp.items.len;
        defer p.temp.items.len = mark;
        const end = try p.prelude(false);
        if (end != .lbrace) return;
        var sp: selectors.Parser = .{ .arena = p.arena, .parent = scope.selectors };
        const list = try sp.parseList(trim(p.temp.items[mark..]));
        if (list == null or p.depth > max_depth) return p.skipBlock();
        try p.blockContents(.{ .selectors = list, .cond = scope.cond, .layer = scope.layer, .container = scope.container });
    }

    /// A style rule's block: declarations, nested rules and nested at-rules.
    /// Each run of declarations becomes a rule, in source order.
    fn blockContents(p: *P, scope: Scope) Allocator.Error!void {
        p.depth += 1;
        defer p.depth -= 1;
        var pending: std.ArrayList(Declaration) = .empty;
        while (true) {
            const t = try p.next();
            switch (t.kind) {
                .eof => break,
                .rbrace => break,
                .whitespace, .semicolon => {},
                .at_keyword => {
                    try p.flush(&pending, scope);
                    try p.atRule(t, scope);
                },
                else => {
                    p.peeked = t;
                    const mark = p.temp.items.len;
                    defer p.temp.items.len = mark;
                    const end = try p.declOrRule(mark);
                    switch (end) {
                        .lbrace => {
                            try p.flush(&pending, scope);
                            var sp: selectors.Parser = .{ .arena = p.arena, .parent = scope.selectors };
                            const list = try sp.parseList(trim(p.temp.items[mark..]));
                            if (list == null or p.depth > max_depth) {
                                try p.skipBlock();
                            } else {
                                p.temp.items.len = mark;
                                try p.blockContents(.{ .selectors = list, .cond = scope.cond, .layer = scope.layer, .container = scope.container });
                            }
                        },
                        else => if (try parseDeclaration(p.arena, p.base, p.temp.items[mark..])) |d| {
                            try pending.append(p.arena, d);
                        },
                    }
                },
            }
        }
        try p.flush(&pending, scope);
    }

    /// Reads a declaration's or nested rule's tokens. A custom property's value
    /// may hold a `{}` block; anything else's `{` starts a nested rule.
    pub fn declOrRule(p: *P, mark: usize) Allocator.Error!tk.Kind {
        var nest: u32 = 0;
        var braces: u32 = 0;
        while (true) {
            const t = try p.next();
            switch (t.kind) {
                .eof => return .eof,
                .semicolon => if (nest == 0 and braces == 0) return .semicolon,
                .rbrace => {
                    if (braces == 0 and nest == 0) {
                        p.peeked = t;
                        return .rbrace;
                    }
                    braces -|= 1;
                },
                .lbrace => {
                    if (nest == 0 and braces == 0 and !isCustomStart(p.temp.items[mark..])) return .lbrace;
                    braces += 1;
                },
                .function, .lparen, .lbracket => nest += 1,
                .rparen, .rbracket => nest -|= 1,
                else => {},
            }
            try p.temp.append(p.arena, t);
        }
    }

    fn isCustomStart(toks: []const Token) bool {
        if (toks.len < 2) return false;
        if (toks[0].kind != .ident or !std.mem.startsWith(u8, toks[0].text, "--")) return false;
        var i: usize = 1;
        while (i < toks.len and toks[i].kind == .whitespace) : (i += 1) {}
        return i < toks.len and toks[i].kind == .colon;
    }

    fn flush(p: *P, pending: *std.ArrayList(Declaration), scope: Scope) Allocator.Error!void {
        if (pending.items.len == 0) return;
        const list = scope.selectors orelse {
            pending.clearRetainingCapacity();
            return;
        };
        const decls = try makeDeclarations(p.arena, pending.items);
        pending.* = .empty;
        try p.rules.append(p.arena, .{ .selectors = list, .decls = decls, .cond = scope.cond, .layer = scope.layer, .container = scope.container });
    }

    fn atRule(p: *P, at_tok: Token, scope: Scope) Allocator.Error!void {
        const mark = p.temp.items.len;
        defer p.temp.items.len = mark;
        const name = at_tok.text;
        const is = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.ascii.eqlIgnoreCase(a, b);
            }
        }.f;
        const end = try p.prelude(true);
        const pre = trim(p.temp.items[mark..]);
        if (end == .rbrace or end == .eof and pre.len == 0) return;
        if (is(name, "charset") or is(name, "namespace")) {
            if (end == .lbrace) try p.skipBlock();
            return;
        }
        if (is(name, "import")) {
            if (end == .lbrace) return p.skipBlock();
            if (p.imports_open) try p.importRule(pre);
            return;
        }
        if (is(name, "layer")) return p.layerRule(pre, end, scope);
        p.imports_open = false;
        if (end != .lbrace) return;
        if (is(name, "media")) {
            const list = try media.parseList(p.arena, pre);
            const cond = try p.arena.create(Cond);
            cond.* = .{ .media = list, .parent = scope.cond };
            try p.conds.append(p.arena, cond);
            return p.group(.{ .selectors = scope.selectors, .cond = cond, .layer = scope.layer, .container = scope.container });
        }
        if (is(name, "supports")) {
            if (!supports.evaluate(p.arena, pre)) return p.skipBlock();
            return p.group(scope);
        }
        if (is(name, "container")) {
            const q = try p.arena.create(sheet.ContainerCond);
            q.* = try media.parseContainer(p.arena, pre);
            q.parent = scope.container;
            var inner = scope;
            inner.container = q;
            return p.group(inner);
        }
        if (is(name, "scope")) return p.group(scope);
        if (is(name, "starting-style")) return p.skipBlock();
        if (is(name, "font-face")) {
            const decls = try p.declarationBlock();
            try p.font_faces.append(p.arena, .{ .decls = decls });
            return;
        }
        if (is(name, "keyframes") or is(name, "-webkit-keyframes") or is(name, "-moz-keyframes")) {
            if (pre.len == 0) return p.skipBlock();
            return keyframes_rule.parse(p, pre[0].text, scope.cond);
        }
        if (is(name, "property")) {
            if (pre.len == 0) return p.skipBlock();
            // Before the block: what it parses may move `temp`, where `pre` is.
            var rule: sheet.PropertyRule = .{ .name = pre[0].text };
            const decls = try p.declarationBlock();
            for (decls.items) |d| {
                if (is(d.name, "initial-value")) rule.initial = d.value;
                if (is(d.name, "inherits") and d.value.len > 0) rule.inherits = !d.value[0].isIdent("false");
            }
            try p.properties.append(p.arena, rule);
            return;
        }
        // @page, @counter-style, @font-feature-values, the unknown.
        return p.skipBlock();
    }

    /// A group's block: rules at the top level, a style block inside a rule.
    fn group(p: *P, scope: Scope) Allocator.Error!void {
        if (p.depth > max_depth) return p.skipBlock();
        if (scope.selectors != null) return p.blockContents(scope);
        return p.ruleList(scope, true);
    }

    fn importRule(p: *P, pre: []const Token) Allocator.Error!void {
        var i: usize = 0;
        if (pre.len == 0) return;
        var target: []const u8 = undefined;
        const first = pre[0];
        if (first.kind == .url or first.kind == .string) {
            target = first.text;
            i = 1;
        } else if (first.isFunction("url")) {
            i = 1;
            while (i < pre.len and pre[i].kind == .whitespace) : (i += 1) {}
            if (i >= pre.len or pre[i].kind != .string) return;
            target = pre[i].text;
            i += 1;
            while (i < pre.len and pre[i].kind != .rparen) : (i += 1) {}
            i += 1;
        } else return;
        var rec: sheet.Import = .{ .url = try url.join(p.arena, p.base, target) };
        var rest = trim(pre[@min(i, pre.len)..]);
        if (rest.len > 0 and rest[0].isIdent("layer")) {
            rec.layer = try p.anonLayer();
            rest = trim(rest[1..]);
        } else if (rest.len > 0 and rest[0].isFunction("layer")) {
            var j: usize = 1;
            var name: std.ArrayList(u8) = .empty;
            while (j < rest.len and rest[j].kind != .rparen) : (j += 1) {
                const piece = try tk.serialize(p.arena, rest[j .. j + 1]);
                try name.appendSlice(p.arena, piece);
            }
            rec.layer = name.items;
            rest = trim(rest[@min(j + 1, rest.len)..]);
        }
        if (rest.len > 0 and rest[0].isFunction("supports")) {
            var j: usize = 1;
            var nest: u32 = 1;
            while (j < rest.len) : (j += 1) {
                switch (rest[j].kind) {
                    .function, .lparen => nest += 1,
                    .rparen => {
                        nest -= 1;
                        if (nest == 0) break;
                    },
                    else => {},
                }
            }
            const inner = rest[1..@min(j, rest.len)];
            // `supports(display: grid)` has the bare declaration form.
            rec.skip = !supports.evaluate(p.arena, inner) and !supports.declaration(p.arena, inner);
            rest = trim(rest[@min(j + 1, rest.len)..]);
        }
        if (rest.len > 0) rec.media = try media.parseList(p.arena, rest);
        try p.imports.append(p.arena, rec);
    }

    fn anonLayer(p: *P) Allocator.Error![]const u8 {
        p.anon_layers += 1;
        return std.fmt.allocPrint(p.arena, "@anon-{d}-{d}", .{ @intFromPtr(p.tz.src.ptr), p.anon_layers });
    }

    fn layerName(p: *P, toks: []const Token, scope: Scope) Allocator.Error![]const u8 {
        var name: std.ArrayList(u8) = .empty;
        for (trim(toks)) |t| {
            if (t.kind == .ident) {
                try name.appendSlice(p.arena, t.text);
            } else if (t.isDelim('.')) {
                try name.append(p.arena, '.');
            }
        }
        if (scope.layer.len == 0) return name.items;
        return std.mem.concat(p.arena, u8, &.{ scope.layer, ".", name.items });
    }

    fn layerRule(p: *P, pre: []const Token, end: tk.Kind, scope: Scope) Allocator.Error!void {
        if (end == .lbrace) {
            var name: []const u8 = undefined;
            if (pre.len == 0) {
                const anon = try p.anonLayer();
                name = if (scope.layer.len == 0) anon else try std.mem.concat(p.arena, u8, &.{ scope.layer, ".", anon });
            } else {
                name = try p.layerName(pre, scope);
            }
            try p.layers.append(p.arena, name);
            return p.group(.{ .selectors = scope.selectors, .cond = scope.cond, .layer = name, .container = scope.container });
        }
        // A statement: the names, for their order.
        var i: usize = 0;
        while (i < pre.len) {
            var e = i;
            while (e < pre.len and pre[e].kind != .comma) : (e += 1) {}
            try p.layers.append(p.arena, try p.layerName(pre[i..e], scope));
            i = e + 1;
        }
    }

    /// A block of declarations only: `@font-face`.
    fn declarationBlock(p: *P) Allocator.Error!*const Declarations {
        var pending: std.ArrayList(Declaration) = .empty;
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
                    } else if (try font_face.declaration(p.arena, p.base, p.temp.items[mark..])) |d| {
                        try pending.append(p.arena, d);
                    }
                },
            }
        }
        return makeDeclarations(p.arena, pending.items);
    }
};

pub fn makeDeclarations(arena: Allocator, items: []const Declaration) Allocator.Error!*Declarations {
    const d = try arena.create(Declarations);
    d.* = .{ .items = try arena.dupe(Declaration, items) };
    for (items) |x| {
        if (x.important) d.has_important = true;
        if (x.prop == .custom) d.has_custom = true;
        if (x.prop == .content) d.has_content = true;
    }
    return d;
}

/// Whitespace off both ends.
pub fn trim(t: []const Token) []const Token {
    var s = t;
    while (s.len > 0 and s[0].kind == .whitespace) s = s[1..];
    while (s.len > 0 and s[s.len - 1].kind == .whitespace) s = s[0 .. s.len - 1];
    return s;
}

pub fn hashName(name: []const u8) u32 {
    return std.hash.Fnv1a_32.hash(name);
}

/// One declaration from its tokens; null when invalid. Copies what it keeps.
pub fn parseDeclaration(arena: Allocator, base: []const u8, raw: []const Token) Allocator.Error!?Declaration {
    const toks = trim(raw);
    if (toks.len == 0 or toks[0].kind != .ident) return null;
    var i: usize = 1;
    while (i < toks.len and toks[i].kind == .whitespace) : (i += 1) {}
    if (i >= toks.len or toks[i].kind != .colon) return null;
    var value = trim(toks[i + 1 ..]);
    var important = false;
    // `! important` at the end.
    if (value.len >= 2 and value[value.len - 1].isIdent("important")) {
        var e = value.len - 1;
        while (e > 0 and value[e - 1].kind == .whitespace) : (e -= 1) {}
        if (e > 0 and value[e - 1].isDelim('!')) {
            important = true;
            value = trim(value[0 .. e - 1]);
        }
    }
    const raw_name = toks[0].text;
    const custom = raw_name.len > 2 and raw_name[0] == '-' and raw_name[1] == '-';
    var name = raw_name;
    var p: prop.Prop = .custom;
    if (!custom) {
        if (value.len == 0) return null;
        var buf: [48]u8 = undefined;
        if (raw_name.len > buf.len) return null;
        const low = std.ascii.lowerString(&buf, raw_name);
        p = prop.lookup(low) orelse return null;
        name = if (std.mem.eql(u8, low, raw_name)) raw_name else try arena.dupe(u8, low);
    }
    for (value) |t| if (t.kind == .bad_string or t.kind == .bad_url) return null;
    var has_var = false;
    for (value) |t| if (t.kind == .function and (std.ascii.eqlIgnoreCase(t.text, "var") or std.ascii.eqlIgnoreCase(t.text, "env"))) {
        has_var = true;
        break;
    };
    var wide: sheet.Wide = .none;
    if (value.len == 1 and value[0].kind == .ident) {
        const w = value[0].text;
        if (std.ascii.eqlIgnoreCase(w, "inherit")) wide = .inherit;
        if (std.ascii.eqlIgnoreCase(w, "initial")) wide = .initial;
        if (std.ascii.eqlIgnoreCase(w, "unset")) wide = .unset;
        if (std.ascii.eqlIgnoreCase(w, "revert") or std.ascii.eqlIgnoreCase(w, "revert-layer")) wide = .revert;
    }
    return .{
        .prop = p,
        .name = name,
        .value = try resolveUrls(arena, base, value),
        .important = important,
        .has_var = has_var,
        .wide = wide,
        .hash = if (custom) hashName(name) else 0,
        .phase = prop.phase(p),
    };
}

/// Copies a value, with `url("x")` folded to one token and every URL joined
/// to the base.
pub fn resolveUrls(arena: Allocator, base: []const u8, value: []const Token) Allocator.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    try out.ensureTotalCapacity(arena, value.len);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        var t = value[i];
        if (t.kind == .url) {
            t.text = try url.join(arena, base, t.text);
        } else if (t.isFunction("url") or t.isFunction("src")) {
            var j = i + 1;
            while (j < value.len and value[j].kind == .whitespace) : (j += 1) {}
            if (j < value.len and value[j].kind == .string) {
                var k = j + 1;
                while (k < value.len and value[k].kind != .rparen) : (k += 1) {}
                out.appendAssumeCapacity(.{ .kind = .url, .text = try url.join(arena, base, value[j].text) });
                i = k;
                continue;
            }
        }
        out.appendAssumeCapacity(t);
    }
    return out.items;
}

/// Parses a stylesheet; its text is copied. `url()`s are resolved against
/// `base_url`.
pub fn parseSheet(arena: Allocator, css_text: []const u8, base_url: []const u8) Allocator.Error!*sheet.Sheet {
    const src = try arena.dupe(u8, css_text);
    var p: P = .{ .arena = arena, .tz = .{ .arena = arena, .src = src }, .base = try arena.dupe(u8, base_url) };
    try p.ruleList(.{}, false);
    const s = try arena.create(sheet.Sheet);
    s.* = .{
        .rules = p.rules.items,
        .imports = p.imports.items,
        .font_faces = p.font_faces.items,
        .keyframes = p.keyframes.items,
        .properties = p.properties.items,
        .layers = p.layers.items,
        .conds = p.conds.items,
        .base_url = p.base,
    };
    return s;
}

/// `parseSheet` for a sheet under a `media` attribute (`<style media>`,
/// `<link media>`); null is all media.
pub fn parseSheetMedia(arena: Allocator, css_text: []const u8, base_url: []const u8, media_text: ?[]const u8) Allocator.Error!*sheet.Sheet {
    const s = try parseSheet(arena, css_text, base_url);
    if (media_text) |m| s.media = try media.parseText(arena, m);
    return s;
}

/// Parses the declarations of a `style` attribute or `element.style`.
pub fn parseDeclarations(arena: Allocator, text: []const u8) Allocator.Error!*Declarations {
    return parseDeclarationsBase(arena, text, "");
}

pub fn parseDeclarationsBase(arena: Allocator, text: []const u8, base: []const u8) Allocator.Error!*Declarations {
    const src = try arena.dupe(u8, text);
    var p: P = .{ .arena = arena, .tz = .{ .arena = arena, .src = src }, .base = base };
    var pending: std.ArrayList(Declaration) = .empty;
    while (true) {
        const t = try p.next();
        switch (t.kind) {
            .eof => break,
            .whitespace, .semicolon, .rbrace => {},
            else => {
                p.peeked = t;
                const mark = p.temp.items.len;
                defer p.temp.items.len = mark;
                const end = try p.declOrRule(mark);
                if (end == .lbrace) {
                    try p.skipBlock();
                } else if (try parseDeclaration(arena, base, p.temp.items[mark..])) |d| {
                    try pending.append(arena, d);
                }
                if (end == .rbrace) _ = try p.next();
            },
        }
    }
    return makeDeclarations(arena, pending.items);
}
