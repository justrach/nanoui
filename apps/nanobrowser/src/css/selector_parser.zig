//! The selector parser. A rule's whole selector list is invalid if any selector
//! in it is; `:is()` and `:where()` forgive theirs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tk = @import("tokenizer.zig");
const types = @import("selectors.zig");
const names = @import("selector_names.zig");

const Token = tk.Token;
const Combinator = types.Combinator;
const AttrOp = types.AttrOp;
const PseudoElement = types.PseudoElement;
const PseudoClass = types.PseudoClass;
const Attr = types.Attr;
const Nth = types.Nth;
const Simple = types.Simple;
const Compound = types.Compound;
const Selector = types.Selector;

const max_depth = 24;
const legacyElement = names.legacyElement;
const isOtherElement = names.isOtherElement;
const isElementFunction = names.isElementFunction;
const pseudo_classes = names.pseudo_classes;
pub const parseAnB = names.parseAnB;

pub const Parser = struct {
    arena: Allocator,
    /// The enclosing style rule's selectors, for `&` and implicit nesting.
    parent: ?[]const Selector = null,

    /// `&` cannot stand for a pseudo-element: those of the parent list are dropped.
    fn nestable(p: *Parser, parent: []const Selector) Allocator.Error![]const Selector {
        var any = false;
        for (parent) |s| {
            if (s.pseudo != .none) any = true;
        }
        if (!any) return parent;
        var out: std.ArrayList(Selector) = .empty;
        for (parent) |s| if (s.pseudo == .none) try out.append(p.arena, s);
        return out.items;
    }

    /// A comma list; null when any selector in it is invalid, as a rule's
    /// whole prelude then is.
    pub fn parseList(p: *Parser, toks: []const Token) Allocator.Error!?[]const Selector {
        return p.list(toks, 0, false, false);
    }

    fn list(p: *Parser, toks: []const Token, depth: u32, forgiving: bool, relative: bool) Allocator.Error!?[]const Selector {
        if (depth > max_depth) return null;
        var out: std.ArrayList(Selector) = .empty;
        var i: usize = 0;
        while (true) {
            var end = i;
            var nest: u32 = 0;
            while (end < toks.len) : (end += 1) {
                switch (toks[end].kind) {
                    .function, .lparen, .lbracket => nest += 1,
                    .rparen, .rbracket => nest -|= 1,
                    .comma => if (nest == 0) break,
                    else => {},
                }
            }
            const one = try p.complex(toks[i..end], depth, relative);
            if (one) |s| {
                try out.append(p.arena, s);
            } else if (!forgiving) return null;
            if (end >= toks.len) break;
            i = end + 1;
        }
        if (out.items.len == 0 and !forgiving) return null;
        return out.items;
    }

    fn complex(p: *Parser, toks: []const Token, depth: u32, relative: bool) Allocator.Error!?Selector {
        var c: Cur = .{ .t = toks };
        c.skipWs();
        if (c.atEnd()) return null;
        var compounds: std.ArrayList(Compound) = .empty;
        var sel: Selector = .{ .compounds = &.{} };
        var saw_nesting = false;
        var leading: ?Combinator = null;
        if (combinatorAt(&c)) |lead| {
            if (!relative and (depth > 0 or p.parent == null)) return null;
            leading = lead;
            c.skipWs();
        }
        var combinator: Combinator = .descendant;
        while (true) {
            var st: CompoundState = .{};
            const simples = try p.compound(&c, depth, &st) orelse return null;
            if (st.pseudo != .none) {
                if (sel.pseudo != .none) return null;
                sel.pseudo = st.pseudo;
                sel.slotted = st.slotted;
                sel.part = st.part;
            }
            sel.specificity += st.specificity;
            sel.uses_state = sel.uses_state or st.uses_state;
            saw_nesting = saw_nesting or st.saw_nesting;
            // Matching recurses per compound; no real selector comes near this.
            if (compounds.items.len >= 256) return null;
            try compounds.append(p.arena, .{ .simples = simples, .combinator = combinator });
            const ws = c.hadWs();
            if (c.atEnd()) break;
            if (combinatorAt(&c)) |comb| {
                combinator = comb;
                c.skipWs();
                if (c.atEnd()) return null;
            } else if (ws) {
                combinator = .descendant;
            } else return null;
            // Nothing follows a pseudo-element but its own pseudo-classes.
            if (sel.pseudo != .none and sel.pseudo != .other and sel.pseudo != .placeholder) return null;
        }
        if (relative) sel.leading = leading orelse .descendant;
        // Inside a style rule, a selector with no `&` is relative to the parent.
        if (depth == 0 and !relative) if (p.parent) |raw_parent| {
            if (leading != null or !saw_nesting) {
                const parent = try p.nestable(raw_parent);
                const simples = try p.arena.alloc(Simple, 1);
                simples[0] = .{ .is = parent };
                sel.specificity += maxSpecificity(parent);
                sel.uses_state = sel.uses_state or anyState(parent);
                const first = try p.arena.dupe(Compound, compounds.items);
                first[0].combinator = leading orelse .descendant;
                try compounds.resize(p.arena, 0);
                try compounds.append(p.arena, .{ .simples = simples });
                try compounds.appendSlice(p.arena, first);
            }
        };
        sel.compounds = compounds.items;
        return sel;
    }

    const CompoundState = struct {
        specificity: u32 = 0,
        pseudo: PseudoElement = .none,
        uses_state: bool = false,
        saw_nesting: bool = false,
        slotted: []const Selector = &.{},
        part: []const u8 = "",
    };

    fn compound(p: *Parser, c: *Cur, depth: u32, st: *CompoundState) Allocator.Error!?[]const Simple {
        var out: std.ArrayList(Simple) = .empty;
        var first = true;
        var has_type = false;
        while (true) {
            const t = c.peek() orelse break;
            switch (t.kind) {
                .ident => {
                    if (has_type or !(first or prevIsNesting(out.items))) return null;
                    c.i += 1;
                    if (c.peekIsNamespaceBar()) {
                        c.i += 1;
                        continue;
                    }
                    const low = try lower(p.arena, t.text);
                    try out.append(p.arena, .{ .tag = low });
                    has_type = true;
                    st.specificity += 1;
                },
                .delim => switch (t.delim) {
                    '*' => {
                        if (has_type or !first) return null;
                        c.i += 1;
                        if (c.peekIsNamespaceBar()) {
                            c.i += 1;
                            continue;
                        }
                        try out.append(p.arena, .universal);
                        has_type = true;
                    },
                    '.' => {
                        c.i += 1;
                        const n = c.peek() orelse return null;
                        if (n.kind != .ident) return null;
                        c.i += 1;
                        try out.append(p.arena, .{ .class = n.text });
                        st.specificity += 1 << 8;
                    },
                    '&' => {
                        c.i += 1;
                        st.saw_nesting = true;
                        if (p.parent) |raw_parent| {
                            const parent = try p.nestable(raw_parent);
                            try out.append(p.arena, .{ .is = parent });
                            st.specificity += maxSpecificity(parent);
                            st.uses_state = st.uses_state or anyState(parent);
                        } else {
                            try out.append(p.arena, .{ .pseudo = .scope });
                        }
                    },
                    else => break,
                },
                .hash => {
                    if (!t.is_id) return null;
                    c.i += 1;
                    try out.append(p.arena, .{ .id = t.text });
                    st.specificity += 1 << 16;
                },
                .lbracket => {
                    const a = try p.attribute(c) orelse return null;
                    try out.append(p.arena, .{ .attr = a });
                    st.specificity += 1 << 8;
                },
                .colon => {
                    c.i += 1;
                    const s = try p.pseudo(c, depth, st) orelse return null;
                    if (s) |simple| try out.append(p.arena, simple);
                },
                else => break,
            }
            first = false;
        }
        if (out.items.len == 0) {
            // A lone pseudo-element is a compound too (`::before`).
            if (st.pseudo == .none) return null;
        }
        return out.items;
    }

    fn prevIsNesting(items: []const Simple) bool {
        if (items.len == 0) return false;
        return switch (items[items.len - 1]) {
            .is, .pseudo => true,
            else => false,
        };
    }

    fn attribute(p: *Parser, c: *Cur) Allocator.Error!?Attr {
        c.i += 1;
        c.skipWs();
        var name = c.peek() orelse return null;
        if (name.isDelim('*') or name.isDelim('|')) {
            // A namespace prefix is not honoured.
            c.i += 1;
            if (name.isDelim('*')) c.i += 1;
            name = c.peek() orelse return null;
        }
        if (name.kind != .ident) return null;
        c.i += 1;
        if (c.peekIsNamespaceBar()) {
            c.i += 1;
            name = c.peek() orelse return null;
            if (name.kind != .ident) return null;
            c.i += 1;
        }
        var a: Attr = .{ .name = name.text, .lower = try lower(p.arena, name.text) };
        c.skipWs();
        const op_tok = c.peek() orelse return null;
        if (op_tok.kind == .rbracket) {
            c.i += 1;
            return a;
        }
        if (op_tok.kind != .delim) return null;
        c.i += 1;
        if (op_tok.delim == '=') {
            a.op = .equals;
        } else {
            const eq = c.peek() orelse return null;
            if (!eq.isDelim('=')) return null;
            c.i += 1;
            a.op = switch (op_tok.delim) {
                '~' => .includes,
                '|' => .dash,
                '^' => .prefix,
                '$' => .suffix,
                '*' => .substring,
                else => return null,
            };
        }
        c.skipWs();
        const v = c.peek() orelse return null;
        if (v.kind != .ident and v.kind != .string) return null;
        a.value = v.text;
        c.i += 1;
        c.skipWs();
        var end = c.peek() orelse return null;
        if (end.kind == .ident) {
            if (std.ascii.eqlIgnoreCase(end.text, "i")) {
                a.ci = true;
            } else if (std.ascii.eqlIgnoreCase(end.text, "s")) {
                a.ci = false;
            } else return null;
            c.i += 1;
            c.skipWs();
            end = c.peek() orelse return null;
        }
        if (end.kind != .rbracket) return null;
        c.i += 1;
        return a;
    }

    /// After the first colon. Outer null: invalid. Inner null: valid but
    /// adds no test (a pseudo-element).
    fn pseudo(p: *Parser, c: *Cur, depth: u32, st: *CompoundState) Allocator.Error!??Simple {
        const t = c.peek() orelse return null;
        if (t.kind == .colon) {
            c.i += 1;
            const n = c.peek() orelse return null;
            if (n.kind == .function) {
                if (!std.ascii.startsWithIgnoreCase(n.text, "-webkit-") and !isElementFunction(n.text)) return null;
                c.i += 1;
                const inner = c.functionBody();
                st.pseudo = .other;
                if (std.ascii.eqlIgnoreCase(n.text, "slotted")) {
                    st.slotted = try p.list(inner, depth + 1, false, false) orelse return null;
                    st.specificity += maxSpecificity(st.slotted) + 1;
                    st.pseudo = .slotted;
                } else if (std.ascii.eqlIgnoreCase(n.text, "part")) {
                    var a: Cur = .{ .t = inner };
                    a.skipWs();
                    const name = a.peek() orelse return null;
                    if (name.kind != .ident) return null;
                    st.part = name.text;
                    st.pseudo = .part;
                    st.specificity += 1;
                }
                return @as(?Simple, null);
            }
            if (n.kind != .ident) return null;
            c.i += 1;
            return pseudoElement(n.text, st);
        }
        if (t.kind == .ident) {
            c.i += 1;
            // The old single-colon forms of pseudo-elements.
            if (legacyElement(t.text)) return pseudoElement(t.text, st);
            if (std.ascii.eqlIgnoreCase(t.text, "host")) {
                st.specificity += 1 << 8;
                return @as(?Simple, .{ .host = &.{} });
            }
            const pc = pseudo_classes.get(try lower(p.arena, t.text)) orelse return null;
            st.specificity += 1 << 8;
            switch (pc) {
                .hover, .active, .focus, .focus_visible, .focus_within => st.uses_state = true,
                else => {},
            }
            const simple: Simple = switch (pc) {
                .first_of_type => .{ .nth = .{ .a = 0, .b = 1, .of_type = true } },
                .last_of_type => .{ .nth = .{ .a = 0, .b = 1, .of_type = true, .from_end = true } },
                .first_child => .{ .nth = .{ .a = 0, .b = 1 } },
                .last_child => .{ .nth = .{ .a = 0, .b = 1, .from_end = true } },
                else => .{ .pseudo = pc },
            };
            return simple;
        }
        if (t.kind == .function) {
            c.i += 1;
            const inner = c.functionBody();
            return p.pseudoFunction(t.text, inner, depth, st);
        }
        return null;
    }

    fn pseudoFunction(p: *Parser, raw_name: []const u8, inner: []const Token, depth: u32, st: *CompoundState) Allocator.Error!??Simple {
        const name = try lower(p.arena, raw_name);
        const eql = std.mem.eql;
        const state_of = struct {
            fn apply(s: *CompoundState, list_: []const Selector) void {
                s.uses_state = s.uses_state or anyState(list_);
            }
        };
        if (eql(u8, name, "not")) {
            const l = try p.list(inner, depth + 1, false, false) orelse return null;
            st.specificity += maxSpecificity(l);
            state_of.apply(st, l);
            return @as(?Simple, .{ .not = l });
        }
        if (eql(u8, name, "is") or eql(u8, name, "matches") or eql(u8, name, "-webkit-any")) {
            const l = try p.list(inner, depth + 1, true, false) orelse return null;
            st.specificity += maxSpecificity(l);
            state_of.apply(st, l);
            return @as(?Simple, .{ .is = l });
        }
        if (eql(u8, name, "where")) {
            const l = try p.list(inner, depth + 1, true, false) orelse return null;
            state_of.apply(st, l);
            return @as(?Simple, .{ .is = l });
        }
        if (eql(u8, name, "has")) {
            const l = try p.list(inner, depth + 1, false, true) orelse return null;
            st.specificity += maxSpecificity(l);
            state_of.apply(st, l);
            return @as(?Simple, .{ .has = l });
        }
        if (eql(u8, name, "lang")) {
            var c: Cur = .{ .t = inner };
            const v = c.peek() orelse return null;
            if (v.kind != .ident and v.kind != .string) return null;
            st.specificity += 1 << 8;
            return @as(?Simple, .{ .lang = v.text });
        }
        if (eql(u8, name, "host") or eql(u8, name, "host-context")) {
            const l = try p.list(inner, depth + 1, false, false) orelse return null;
            st.specificity += maxSpecificity(l) + (1 << 8);
            state_of.apply(st, l);
            return @as(?Simple, if (name.len == 4) .{ .host = l } else .{ .host_context = l });
        }
        if (eql(u8, name, "dir")) {
            st.specificity += 1 << 8;
            return @as(?Simple, .{ .pseudo = .defined });
        }
        const nth_kind: ?Nth = if (eql(u8, name, "nth-child"))
            Nth{ .a = 0, .b = 0 }
        else if (eql(u8, name, "nth-last-child"))
            Nth{ .a = 0, .b = 0, .from_end = true }
        else if (eql(u8, name, "nth-of-type"))
            Nth{ .a = 0, .b = 0, .of_type = true }
        else if (eql(u8, name, "nth-last-of-type"))
            Nth{ .a = 0, .b = 0, .of_type = true, .from_end = true }
        else
            null;
        if (nth_kind) |base| {
            var nth = base;
            st.specificity += 1 << 8;
            // `An+B of S`.
            var an_end = inner.len;
            for (inner, 0..) |t, i| if (t.isIdent("of")) {
                an_end = i;
                break;
            };
            if (an_end < inner.len) {
                if (nth.of_type) return null;
                const l = try p.list(inner[an_end + 1 ..], depth + 1, false, false) orelse return null;
                st.specificity += maxSpecificity(l);
                state_of.apply(st, l);
                nth.of = l;
            }
            const ab = try parseAnB(p.arena, inner[0..an_end]) orelse return null;
            nth.a = ab[0];
            nth.b = ab[1];
            return @as(?Simple, .{ .nth = nth });
        }
        return null;
    }
};

fn pseudoElement(name: []const u8, st: *CompoundState_) ??Simple {
    if (std.ascii.eqlIgnoreCase(name, "before")) {
        st.pseudo = .before;
    } else if (std.ascii.eqlIgnoreCase(name, "after")) {
        st.pseudo = .after;
    } else if (std.ascii.eqlIgnoreCase(name, "placeholder") or std.ascii.eqlIgnoreCase(name, "-webkit-input-placeholder")) {
        st.pseudo = .placeholder;
    } else if (std.ascii.eqlIgnoreCase(name, "marker")) {
        st.pseudo = .marker;
    } else if (std.ascii.eqlIgnoreCase(name, "backdrop")) {
        st.pseudo = .backdrop;
    } else if (isOtherElement(name) or std.ascii.startsWithIgnoreCase(name, "-webkit-")) {
        st.pseudo = .other;
    } else return null;
    st.specificity += 1;
    return @as(?Simple, null);
}

const CompoundState_ = Parser.CompoundState;

pub fn maxSpecificity(l: []const Selector) u32 {
    var m: u32 = 0;
    for (l) |s| m = @max(m, s.specificity);
    return m;
}

fn anyState(l: []const Selector) bool {
    for (l) |s| if (s.uses_state) return true;
    return false;
}

fn lower(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    for (s) |c| if (c >= 'A' and c <= 'Z') {
        const copy = try arena.dupe(u8, s);
        _ = std.ascii.lowerString(copy, copy);
        return copy;
    };
    return s;
}

fn combinatorAt(c: *Cur) ?Combinator {
    const t = c.peek() orelse return null;
    if (t.kind != .delim) return null;
    const out: Combinator = switch (t.delim) {
        '>' => .child,
        '+' => .next,
        '~' => .later,
        else => return null,
    };
    c.i += 1;
    return out;
}

/// A cursor over tokens.
const Cur = struct {
    t: []const Token,
    i: usize = 0,

    fn atEnd(c: *const Cur) bool {
        return c.i >= c.t.len;
    }

    fn peek(c: *const Cur) ?Token {
        return if (c.i < c.t.len) c.t[c.i] else null;
    }

    fn skipWs(c: *Cur) void {
        while (c.i < c.t.len and c.t[c.i].kind == .whitespace) c.i += 1;
    }

    /// Skips whitespace; true if there was any.
    fn hadWs(c: *Cur) bool {
        const at = c.i;
        c.skipWs();
        return c.i != at;
    }

    fn peekIsNamespaceBar(c: *const Cur) bool {
        const t = c.peek() orelse return false;
        if (!t.isDelim('|')) return false;
        // `a|=` belongs to an attribute test, not a namespace.
        if (c.i + 1 < c.t.len and c.t[c.i + 1].isDelim('=')) return false;
        return true;
    }

    /// The tokens inside the function just entered; moves past its close.
    fn functionBody(c: *Cur) []const Token {
        const start = c.i;
        var depth: u32 = 1;
        while (c.i < c.t.len) : (c.i += 1) {
            switch (c.t[c.i].kind) {
                .function, .lparen => depth += 1,
                .rparen => {
                    depth -= 1;
                    if (depth == 0) {
                        const body = c.t[start..c.i];
                        c.i += 1;
                        return body;
                    }
                },
                else => {},
            }
        }
        return c.t[start..c.i];
    }

    fn skipFunction(c: *Cur) void {
        c.i += 1;
        _ = c.functionBody();
    }
};

/// Parses a selector list from text; null when it is invalid. The selector
/// API's entry point.
pub fn parseText(arena: Allocator, text: []const u8) Allocator.Error!?[]const Selector {
    var tz: tk.Tokenizer = .{ .arena = arena, .src = text };
    var toks: std.ArrayList(Token) = .empty;
    while (true) {
        const t = try tz.next();
        if (t.kind == .eof) break;
        try toks.append(arena, t);
    }
    var p: Parser = .{ .arena = arena };
    return p.parseList(toks.items);
}
