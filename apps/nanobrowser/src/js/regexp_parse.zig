//! Regular expression syntax: pattern text to a tree, with Annex B's leniency outside
//! unicode mode (literal braces and brackets, octal escapes, identity escapes).

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("regexp_unicode.zig");
pub const Range = unicode.Range;

pub const ParseError = error{ Invalid, OutOfMemory };

pub const ClassSet = struct {
    ranges: std.ArrayList(Range) = .empty,
    negate: bool = false,
};

pub const Node = union(enum) {
    empty,
    char: u32,
    any,
    class: *ClassSet,
    seq: []*Node,
    alt: []*Node,
    group: struct { index: u32, body: *Node },
    backref: u32,
    named_backref: []const u8,
    line_start,
    line_end,
    word_boundary: bool,
    look: struct { behind: bool, negate: bool, body: *Node },
    repeat: struct { body: *Node, min: u32, max: u32, greedy: bool, first_cap: u32, last_cap: u32 },
};

pub const GroupName = struct { name: []const u8, index: u32 };

pub const Flags = struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,
    has_indices: bool = false,

    pub fn parse(s: []const u8) ?Flags {
        var f = Flags{};
        for (s) |c| {
            const field: *bool = switch (c) {
                'g' => &f.global,
                'i' => &f.ignore_case,
                'm' => &f.multiline,
                's' => &f.dot_all,
                'u' => &f.unicode,
                'v' => &f.unicode_sets,
                'y' => &f.sticky,
                'd' => &f.has_indices,
                else => return null,
            };
            if (field.*) return null;
            field.* = true;
        }
        if (f.unicode and f.unicode_sets) return null;
        return f;
    }
};

pub const max_repeat = std.math.maxInt(u32);
const max_group_depth = 256;

pub const Parser = struct {
    a: Allocator,
    src: []const u32,
    i: usize = 0,
    flags: Flags,
    unicode_mode: bool,
    /// Group count and names, known up front so \1 vs octal can be decided.
    total_groups: u32 = 0,
    has_named: bool = false,
    next_group: u32 = 1,
    /// Group nesting; the parser and compiler recurse on it, so it has a limit.
    depth: u32 = 0,
    names: std.ArrayList(GroupName) = .empty,
    message: []const u8 = "Invalid regular expression",

    fn fail(p: *Parser, msg: []const u8) ParseError {
        p.message = msg;
        return error.Invalid;
    }
    inline fn eof(p: *Parser) bool {
        return p.i >= p.src.len;
    }
    inline fn peek(p: *Parser) u32 {
        return if (p.i < p.src.len) p.src[p.i] else 0;
    }
    inline fn peekAt(p: *Parser, n: usize) u32 {
        return if (p.i + n < p.src.len) p.src[p.i + n] else 0;
    }
    fn eat(p: *Parser, c: u32) bool {
        if (p.i < p.src.len and p.src[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }
    fn node(p: *Parser, n: Node) ParseError!*Node {
        const x = try p.a.create(Node);
        x.* = n;
        return x;
    }

    fn prescan(p: *Parser) void {
        var i: usize = 0;
        var in_class = false;
        while (i < p.src.len) : (i += 1) {
            const c = p.src[i];
            if (c == '\\') {
                i += 1;
            } else if (c == '[') {
                in_class = true;
            } else if (c == ']') {
                in_class = false;
            } else if (c == '(' and !in_class) {
                if (i + 1 < p.src.len and p.src[i + 1] == '?') {
                    if (i + 3 < p.src.len and p.src[i + 2] == '<' and p.src[i + 3] != '=' and p.src[i + 3] != '!') {
                        p.total_groups += 1;
                        p.has_named = true;
                    }
                } else p.total_groups += 1;
            }
        }
    }

    pub fn parse(p: *Parser) ParseError!*Node {
        p.prescan();
        const n = try p.disjunction();
        if (!p.eof()) return p.fail(if (p.peek() == ')') "Unmatched ')'" else "Unexpected character");
        return n;
    }

    fn disjunction(p: *Parser) ParseError!*Node {
        if (p.depth >= max_group_depth) return p.fail("Regular expression too large");
        p.depth += 1;
        defer p.depth -= 1;
        const first = try p.alternative();
        if (p.peek() != '|' or p.eof()) return first;
        var list: std.ArrayList(*Node) = .empty;
        try list.append(p.a, first);
        while (p.eat('|')) try list.append(p.a, try p.alternative());
        return p.node(.{ .alt = list.items });
    }

    fn alternative(p: *Parser) ParseError!*Node {
        var list: std.ArrayList(*Node) = .empty;
        while (!p.eof() and p.peek() != '|' and p.peek() != ')') {
            try list.append(p.a, try p.term());
        }
        if (list.items.len == 0) return p.node(.empty);
        if (list.items.len == 1) return list.items[0];
        return p.node(.{ .seq = list.items });
    }

    fn term(p: *Parser) ParseError!*Node {
        const caps_before = p.next_group;
        const c = p.peek();
        var atom: *Node = undefined;
        var quantifiable = true;
        switch (c) {
            '^' => {
                p.i += 1;
                return p.node(.line_start);
            },
            '$' => {
                p.i += 1;
                return p.node(.line_end);
            },
            '(' => {
                if (p.peekAt(1) == '?') {
                    const d = p.peekAt(2);
                    if (d == '=' or d == '!') {
                        p.i += 3;
                        atom = try p.lookBody(false, d == '!');
                        // Annex B lets lookaheads be quantified outside unicode mode.
                        quantifiable = !p.unicode_mode;
                    } else if (d == '<' and (p.peekAt(3) == '=' or p.peekAt(3) == '!')) {
                        const neg = p.peekAt(3) == '!';
                        p.i += 4;
                        atom = try p.lookBody(true, neg);
                        quantifiable = false;
                    } else if (d == ':') {
                        p.i += 3;
                        atom = try p.disjunction();
                        if (!p.eat(')')) return p.fail("Unterminated group");
                    } else if (d == '<') {
                        p.i += 3;
                        const name = try p.groupName();
                        for (p.names.items) |g| {
                            if (std.mem.eql(u8, g.name, name)) return p.fail("Duplicate capture group name");
                        }
                        const index = p.next_group;
                        p.next_group += 1;
                        try p.names.append(p.a, .{ .name = name, .index = index });
                        const body = try p.disjunction();
                        if (!p.eat(')')) return p.fail("Unterminated group");
                        atom = try p.node(.{ .group = .{ .index = index, .body = body } });
                    } else return p.fail("Invalid group");
                } else {
                    p.i += 1;
                    const index = p.next_group;
                    p.next_group += 1;
                    const body = try p.disjunction();
                    if (!p.eat(')')) return p.fail("Unterminated group");
                    atom = try p.node(.{ .group = .{ .index = index, .body = body } });
                }
            },
            '.' => {
                p.i += 1;
                atom = try p.node(.any);
            },
            '[' => {
                p.i += 1;
                atom = try p.classAtom();
            },
            '\\' => {
                p.i += 1;
                atom = try p.atomEscape();
                if (atom.* == .word_boundary) return atom;
            },
            '*', '+', '?' => return p.fail("Nothing to repeat"),
            '{' => {
                if (p.unicode_mode) return p.fail("Nothing to repeat");
                if (try p.tryBraces() != null) return p.fail("Nothing to repeat");
                p.i += 1;
                atom = try p.node(.{ .char = '{' });
            },
            ']', '}' => {
                if (p.unicode_mode) return p.fail("Lone quantifier brackets");
                p.i += 1;
                atom = try p.node(.{ .char = c });
            },
            else => {
                p.i += 1;
                atom = try p.node(.{ .char = c });
            },
        }
        return p.quantifier(atom, caps_before, quantifiable);
    }

    fn lookBody(p: *Parser, behind: bool, negate: bool) ParseError!*Node {
        const body = try p.disjunction();
        if (!p.eat(')')) return p.fail("Unterminated group");
        return p.node(.{ .look = .{ .behind = behind, .negate = negate, .body = body } });
    }

    fn groupName(p: *Parser) ParseError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (!p.eof() and p.peek() != '>') {
            var c = p.peek();
            p.i += 1;
            if (c == '\\') {
                if (!p.eat('u')) return p.fail("Invalid capture group name");
                c = (try p.unicodeEscapeBody()) orelse return p.fail("Invalid Unicode escape");
            }
            var t: [4]u8 = undefined;
            const n = @import("string.zig").encode(c, &t);
            try out.appendSlice(p.a, t[0..n]);
        }
        if (!p.eat('>') or out.items.len == 0) return p.fail("Invalid capture group name");
        return out.items;
    }

    const Braces = struct { min: u32, max: u32, end: usize };

    /// `{n}`, `{n,}` or `{n,m}` at the cursor; null if the text isn't a quantifier.
    fn tryBraces(p: *Parser) ParseError!?Braces {
        var j = p.i + 1;
        const start = j;
        var min: u64 = 0;
        while (j < p.src.len and p.src[j] >= '0' and p.src[j] <= '9') : (j += 1) {
            min = @min(min * 10 + (p.src[j] - '0'), max_repeat);
        }
        if (j == start or j >= p.src.len) return null;
        var max: u64 = min;
        if (p.src[j] == ',') {
            j += 1;
            if (j < p.src.len and p.src[j] == '}') {
                max = max_repeat;
            } else {
                const ms = j;
                max = 0;
                while (j < p.src.len and p.src[j] >= '0' and p.src[j] <= '9') : (j += 1) {
                    max = @min(max * 10 + (p.src[j] - '0'), max_repeat);
                }
                if (j == ms) return null;
            }
        }
        if (j >= p.src.len or p.src[j] != '}') return null;
        return .{ .min = @intCast(min), .max = @intCast(max), .end = j + 1 };
    }

    fn quantifier(p: *Parser, atom: *Node, caps_before: u32, quantifiable: bool) ParseError!*Node {
        var min: u32 = 0;
        var max: u32 = 0;
        switch (p.peek()) {
            '*' => {
                if (p.eof()) return atom;
                p.i += 1;
                max = max_repeat;
            },
            '+' => {
                p.i += 1;
                min = 1;
                max = max_repeat;
            },
            '?' => {
                p.i += 1;
                max = 1;
            },
            '{' => {
                const b = (try p.tryBraces()) orelse {
                    if (p.unicode_mode) return p.fail("Incomplete quantifier");
                    return atom;
                };
                if (b.min > b.max) return p.fail("numbers out of order in {} quantifier");
                p.i = b.end;
                min = b.min;
                max = b.max;
            },
            else => return atom,
        }
        if (!quantifiable) return p.fail("Invalid quantifier");
        const greedy = !p.eat('?');
        return p.node(.{ .repeat = .{ .body = atom, .min = min, .max = max, .greedy = greedy, .first_cap = caps_before, .last_cap = p.next_group } });
    }

    fn hexDigits(p: *Parser, n: usize) ?u32 {
        if (p.i + n > p.src.len) return null;
        var v: u32 = 0;
        for (p.src[p.i..][0..n]) |c| {
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = v * 16 + d;
        }
        p.i += n;
        return v;
    }

    /// After `\u`. Null means not a valid escape (the caller may treat it as a literal u).
    fn unicodeEscapeBody(p: *Parser) ParseError!?u32 {
        if (p.peek() == '{' and p.unicode_mode) {
            var j = p.i + 1;
            var v: u32 = 0;
            var n: u32 = 0;
            while (j < p.src.len and p.src[j] != '}') : (j += 1) {
                const c = p.src[j];
                const d: u32 = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => return p.fail("Invalid Unicode escape"),
                };
                v = v * 16 + d;
                if (v > 0x10FFFF) return p.fail("Invalid Unicode escape");
                n += 1;
            }
            if (j >= p.src.len or n == 0) return p.fail("Invalid Unicode escape");
            p.i = j + 1;
            return v;
        }
        const hi = p.hexDigits(4) orelse return null;
        // A surrogate pair of \u escapes is one code point in unicode mode.
        if (p.unicode_mode and hi >= 0xD800 and hi < 0xDC00 and p.peek() == '\\' and p.peekAt(1) == 'u') {
            const save = p.i;
            p.i += 2;
            if (p.hexDigits(4)) |lo| {
                if (lo >= 0xDC00 and lo < 0xE000) return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
            }
            p.i = save;
        }
        return hi;
    }

    /// The character an escape in a class or atom stands for; the `\` and letter are consumed.
    fn charEscape(p: *Parser, c: u32) ParseError!u32 {
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'f' => return 0x0C,
            'v' => return 0x0B,
            '0' => {
                if (!(p.peek() >= '0' and p.peek() <= '9')) return 0;
                if (p.unicode_mode) return p.fail("Invalid decimal escape");
                return p.legacyOctal(0);
            },
            '1'...'7' => {
                if (p.unicode_mode) return p.fail("Invalid class escape");
                return p.legacyOctal(c - '0');
            },
            'c' => {
                const l = p.peek();
                if ((l >= 'a' and l <= 'z') or (l >= 'A' and l <= 'Z')) {
                    p.i += 1;
                    return l & 31;
                }
                if (p.unicode_mode) return p.fail("Invalid unicode escape");
                p.i -= 1;
                return '\\';
            },
            'x' => {
                if (p.hexDigits(2)) |v| return v;
                if (p.unicode_mode) return p.fail("Invalid escape");
                return 'x';
            },
            'u' => {
                if (try p.unicodeEscapeBody()) |v| return v;
                if (p.unicode_mode) return p.fail("Invalid Unicode escape");
                return 'u';
            },
            else => {
                if (p.unicode_mode) {
                    switch (c) {
                        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/', '-' => return c,
                        else => return p.fail("Invalid escape"),
                    }
                }
                return c;
            },
        }
    }

    fn legacyOctal(p: *Parser, first: u32) u32 {
        var v = first;
        if (p.peek() >= '0' and p.peek() <= '7') {
            v = v * 8 + (p.peek() - '0');
            p.i += 1;
            if (v < 32 and p.peek() >= '0' and p.peek() <= '7') {
                v = v * 8 + (p.peek() - '0');
                p.i += 1;
            }
        }
        return v;
    }

    fn classEscapeSet(p: *Parser, c: u32) ParseError!?*ClassSet {
        const set = try p.a.create(ClassSet);
        set.* = .{};
        switch (c) {
            'd', 'D' => try unicode.addDigit(&set.ranges, p.a),
            'w', 'W' => try unicode.addWord(&set.ranges, p.a),
            's', 'S' => try unicode.addSpace(&set.ranges, p.a),
            'p', 'P' => {
                if (!p.unicode_mode) return null;
                if (!p.eat('{')) return p.fail("Invalid property name");
                var name: std.ArrayList(u8) = .empty;
                while (!p.eof() and p.peek() != '}') : (p.i += 1) {
                    try name.append(p.a, @intCast(p.peek() & 0x7F));
                }
                if (!p.eat('}')) return p.fail("Invalid property name");
                if (!try unicode.addProperty(&set.ranges, p.a, name.items)) return p.fail("Invalid property name");
            },
            else => return null,
        }
        if (c == 'D' or c == 'W' or c == 'S' or c == 'P') {
            const neg = try unicode.negated(p.a, set.ranges.items);
            set.ranges = neg;
        }
        return set;
    }

    fn atomEscape(p: *Parser) ParseError!*Node {
        if (p.eof()) return p.fail("\\ at end of pattern");
        const c = p.peek();
        p.i += 1;
        if (c == 'b') return p.node(.{ .word_boundary = false });
        if (c == 'B') return p.node(.{ .word_boundary = true });
        if (c >= '1' and c <= '9') {
            var j = p.i;
            var v: u64 = c - '0';
            while (j < p.src.len and p.src[j] >= '0' and p.src[j] <= '9') : (j += 1) {
                v = @min(v * 10 + (p.src[j] - '0'), 1 << 30);
            }
            if (v <= p.total_groups) {
                p.i = j;
                return p.node(.{ .backref = @intCast(v) });
            }
            if (p.unicode_mode) return p.fail("Invalid escape");
            if (c >= '8') return p.node(.{ .char = c });
        }
        if (c == 'k' and (p.unicode_mode or p.has_named)) {
            if (!p.eat('<')) return p.fail("Invalid named reference");
            return p.node(.{ .named_backref = try p.groupName() });
        }
        if (try p.classEscapeSet(c)) |set| return p.node(.{ .class = set });
        return p.node(.{ .char = try p.charEscape(c) });
    }

    fn classAtom(p: *Parser) ParseError!*Node {
        const set = try p.a.create(ClassSet);
        set.* = .{};
        set.negate = p.eat('^');
        while (true) {
            if (p.eof()) return p.fail("Unterminated character class");
            if (p.eat(']')) break;
            const lo = try p.classElement(set);
            if (p.peek() == '-' and p.peekAt(1) != ']' and p.i + 1 < p.src.len) {
                p.i += 1;
                const hi = try p.classElement(set);
                if (lo == null or hi == null) {
                    if (p.unicode_mode) return p.fail("Invalid character class");
                    if (lo) |x| try set.ranges.append(p.a, .{ .lo = x, .hi = x });
                    if (hi) |x| try set.ranges.append(p.a, .{ .lo = x, .hi = x });
                    try set.ranges.append(p.a, .{ .lo = '-', .hi = '-' });
                    continue;
                }
                if (lo.? > hi.?) return p.fail("Range out of order in character class");
                try set.ranges.append(p.a, .{ .lo = lo.?, .hi = hi.? });
            } else if (lo) |x| {
                try set.ranges.append(p.a, .{ .lo = x, .hi = x });
            }
        }
        return p.node(.{ .class = set });
    }

    /// One class member. A multi-character set (\d) merges in directly and returns null.
    fn classElement(p: *Parser, set: *ClassSet) ParseError!?u32 {
        const c = p.peek();
        p.i += 1;
        if (c != '\\') return c;
        if (p.eof()) return p.fail("\\ at end of pattern");
        const e = p.peek();
        p.i += 1;
        if (e == 'b') return 8;
        if (e == '-' and p.unicode_mode) return '-';
        if (try p.classEscapeSet(e)) |x| {
            try set.ranges.appendSlice(p.a, x.ranges.items);
            return null;
        }
        if (e == 'k' and !p.unicode_mode and !p.has_named) return 'k';
        if (e >= '8' and !p.unicode_mode and e <= '9') return e;
        return try p.charEscape(e);
    }
};
