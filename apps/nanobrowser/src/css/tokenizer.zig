//! The CSS Syntax tokenizer: a pull tokenizer over the sheet's text. Tokens
//! slice the source when no escape forces a copy, so the source must live as
//! long as they do (the parser copies it into the sheet's arena).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) {
    eof,
    ident,
    function,
    at_keyword,
    hash,
    string,
    url,
    bad_string,
    bad_url,
    number,
    percentage,
    dimension,
    whitespace,
    colon,
    semicolon,
    comma,
    lbracket,
    rbracket,
    lparen,
    rparen,
    lbrace,
    rbrace,
    delim,
    cdo,
    cdc,
};

pub const Token = struct {
    kind: Kind,
    /// An ident's, function's or at-keyword's name, a hash's value, a string's
    /// or URL's contents, a dimension's unit.
    text: []const u8 = "",
    num: f32 = 0,
    delim: u8 = 0,
    /// A number written with no fraction or exponent.
    is_int: bool = false,
    /// A hash that could be an id selector.
    is_id: bool = false,
    /// A number written with an explicit sign.
    signed: bool = false,
    /// A number's source characters (`U+0025`'s digits are not a number).
    raw: []const u8 = "",

    pub fn isIdent(t: Token, name: []const u8) bool {
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, name);
    }

    pub fn isFunction(t: Token, name: []const u8) bool {
        return t.kind == .function and std.ascii.eqlIgnoreCase(t.text, name);
    }

    pub fn isDelim(t: Token, c: u8) bool {
        return t.kind == .delim and t.delim == c;
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isName(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-';
}

fn isNl(c: u8) bool {
    return c == '\n' or c == '\r' or c == 0x0c;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or isNl(c);
}

pub const Tokenizer = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn at(t: *const Tokenizer, i: usize) u8 {
        return if (i < t.src.len) t.src[i] else 0;
    }

    fn validEscape(t: *const Tokenizer, i: usize) bool {
        return t.at(i) == '\\' and i + 1 < t.src.len and !isNl(t.at(i + 1));
    }

    fn startsIdent(t: *const Tokenizer, i: usize) bool {
        const c = t.at(i);
        if (i >= t.src.len) return false;
        if (c == '-') {
            const d = t.at(i + 1);
            return (i + 1 < t.src.len and (isNameStart(d) or d == '-')) or t.validEscape(i + 1);
        }
        return isNameStart(c) or t.validEscape(i);
    }

    fn startsNumber(t: *const Tokenizer, i: usize) bool {
        const c = t.at(i);
        if (std.ascii.isDigit(c)) return true;
        if (c == '.') return std.ascii.isDigit(t.at(i + 1));
        if (c == '+' or c == '-') {
            const d = t.at(i + 1);
            return std.ascii.isDigit(d) or (d == '.' and std.ascii.isDigit(t.at(i + 2)));
        }
        return false;
    }

    /// A code point from an escape at the `\`; advances past it.
    fn escape(t: *Tokenizer, out: *[4]u8) usize {
        t.pos += 1; // the backslash
        const c = t.at(t.pos);
        if (t.pos >= t.src.len) return put(0xFFFD, out);
        if (std.ascii.isHex(c)) {
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 6 and t.pos < t.src.len and std.ascii.isHex(t.src[t.pos])) : (n += 1) {
                v = v * 16 + (std.fmt.charToDigit(t.src[t.pos], 16) catch 0);
                t.pos += 1;
            }
            if (t.pos < t.src.len and isWs(t.src[t.pos])) {
                if (t.src[t.pos] == '\r' and t.at(t.pos + 1) == '\n') t.pos += 1;
                t.pos += 1;
            }
            if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) v = 0xFFFD;
            return put(@intCast(v), out);
        }
        // Any other character stands for itself, whole.
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(t.pos + len, t.src.len);
        const n = end - t.pos;
        @memcpy(out[0..n], t.src[t.pos..end]);
        t.pos = end;
        return n;
    }

    fn put(cp: u21, out: *[4]u8) usize {
        return std.unicode.utf8Encode(cp, out) catch 0;
    }

    /// A name, from the current position: a slice if there are no escapes.
    fn name(t: *Tokenizer) Allocator.Error![]const u8 {
        const start = t.pos;
        while (t.pos < t.src.len and isName(t.src[t.pos])) t.pos += 1;
        if (!t.validEscape(t.pos)) return t.src[start..t.pos];
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.arena, t.src[start..t.pos]);
        var buf: [4]u8 = undefined;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (isName(c)) {
                try out.append(t.arena, c);
                t.pos += 1;
            } else if (t.validEscape(t.pos)) {
                const n = t.escape(&buf);
                try out.appendSlice(t.arena, buf[0..n]);
            } else break;
        }
        return out.items;
    }

    fn skipComments(t: *Tokenizer) void {
        while (t.at(t.pos) == '/' and t.at(t.pos + 1) == '*') {
            const end = std.mem.indexOfPos(u8, t.src, t.pos + 2, "*/");
            t.pos = if (end) |e| e + 2 else t.src.len;
        }
    }

    pub fn next(t: *Tokenizer) Allocator.Error!Token {
        t.skipComments();
        if (t.pos >= t.src.len) return .{ .kind = .eof };
        const c = t.src[t.pos];
        if (isWs(c)) {
            while (t.pos < t.src.len and isWs(t.src[t.pos])) t.pos += 1;
            return .{ .kind = .whitespace };
        }
        if (c == '"' or c == '\'') return t.string(c);
        if (std.ascii.isDigit(c) or (c == '.' or c == '+' or c == '-') and t.startsNumber(t.pos)) return t.numeric();
        if (c == '-' and std.mem.startsWith(u8, t.src[t.pos..], "-->")) {
            t.pos += 3;
            return .{ .kind = .cdc };
        }
        if (t.startsIdent(t.pos)) return t.identLike();
        t.pos += 1;
        return switch (c) {
            '(' => .{ .kind = .lparen },
            ')' => .{ .kind = .rparen },
            '[' => .{ .kind = .lbracket },
            ']' => .{ .kind = .rbracket },
            '{' => .{ .kind = .lbrace },
            '}' => .{ .kind = .rbrace },
            ',' => .{ .kind = .comma },
            ':' => .{ .kind = .colon },
            ';' => .{ .kind = .semicolon },
            '#' => {
                if (t.pos < t.src.len and (isName(t.src[t.pos]) or t.validEscape(t.pos))) {
                    const is_id = t.startsIdent(t.pos);
                    return .{ .kind = .hash, .text = try t.name(), .is_id = is_id };
                }
                return delim(c);
            },
            '@' => {
                if (t.startsIdent(t.pos)) return .{ .kind = .at_keyword, .text = try t.name() };
                return delim(c);
            },
            '<' => {
                if (std.mem.startsWith(u8, t.src[t.pos..], "!--")) {
                    t.pos += 3;
                    return .{ .kind = .cdo };
                }
                return delim(c);
            },
            else => delim(c),
        };
    }

    fn delim(c: u8) Token {
        return .{ .kind = .delim, .delim = c };
    }

    fn string(t: *Tokenizer, q: u8) Allocator.Error!Token {
        t.pos += 1;
        const start = t.pos;
        var out: std.ArrayList(u8) = .empty;
        var copying = false;
        var buf: [4]u8 = undefined;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == q) {
                const s = if (copying) out.items else t.src[start..t.pos];
                t.pos += 1;
                return .{ .kind = .string, .text = s };
            }
            if (isNl(c)) return .{ .kind = .bad_string };
            if (c == '\\') {
                if (!copying) {
                    copying = true;
                    try out.appendSlice(t.arena, t.src[start..t.pos]);
                }
                if (t.pos + 1 >= t.src.len) {
                    t.pos += 1;
                    break;
                }
                if (isNl(t.src[t.pos + 1])) {
                    t.pos += 2;
                    if (t.src[t.pos - 1] == '\r' and t.at(t.pos) == '\n') t.pos += 1;
                    continue;
                }
                const n = t.escape(&buf);
                try out.appendSlice(t.arena, buf[0..n]);
                continue;
            }
            if (copying) try out.append(t.arena, c);
            t.pos += 1;
        }
        // The end of the input closes a string.
        return .{ .kind = .string, .text = if (copying) out.items else t.src[start..] };
    }

    fn numeric(t: *Tokenizer) Allocator.Error!Token {
        const start = t.pos;
        var is_int = true;
        const signed = t.src[t.pos] == '+' or t.src[t.pos] == '-';
        if (signed) t.pos += 1;
        while (std.ascii.isDigit(t.at(t.pos))) t.pos += 1;
        if (t.at(t.pos) == '.' and std.ascii.isDigit(t.at(t.pos + 1))) {
            is_int = false;
            t.pos += 2;
            while (std.ascii.isDigit(t.at(t.pos))) t.pos += 1;
        }
        const e = t.at(t.pos);
        if (e == 'e' or e == 'E') {
            const n = t.at(t.pos + 1);
            const m = t.at(t.pos + 2);
            if (std.ascii.isDigit(n) or ((n == '+' or n == '-') and std.ascii.isDigit(m))) {
                is_int = false;
                t.pos += 2;
                while (std.ascii.isDigit(t.at(t.pos))) t.pos += 1;
            }
        }
        // Overflow reads as the largest finite value, so math stays defined.
        const num = std.math.clamp(std.fmt.parseFloat(f32, t.src[start..t.pos]) catch 0, -1e30, 1e30);
        const raw = t.src[start..t.pos];
        if (t.startsIdent(t.pos)) {
            return .{ .kind = .dimension, .num = num, .text = try t.name(), .is_int = is_int, .signed = signed, .raw = raw };
        }
        if (t.at(t.pos) == '%') {
            t.pos += 1;
            return .{ .kind = .percentage, .num = num, .signed = signed, .raw = raw };
        }
        return .{ .kind = .number, .num = num, .is_int = is_int, .signed = signed, .raw = raw };
    }

    fn identLike(t: *Tokenizer) Allocator.Error!Token {
        const s = try t.name();
        if (t.at(t.pos) != '(') return .{ .kind = .ident, .text = s };
        t.pos += 1;
        if (!std.ascii.eqlIgnoreCase(s, "url")) return .{ .kind = .function, .text = s };
        var i = t.pos;
        while (isWs(t.at(i))) i += 1;
        const q = t.at(i);
        if (q == '"' or q == '\'') return .{ .kind = .function, .text = s };
        t.pos = i;
        return t.urlToken();
    }

    fn urlToken(t: *Tokenizer) Allocator.Error!Token {
        const start = t.pos;
        var out: std.ArrayList(u8) = .empty;
        var copying = false;
        var buf: [4]u8 = undefined;
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == ')') {
                const s = if (copying) out.items else t.src[start..t.pos];
                t.pos += 1;
                return .{ .kind = .url, .text = s };
            }
            if (isWs(c)) {
                const s = if (copying) out.items else t.src[start..t.pos];
                while (t.pos < t.src.len and isWs(t.src[t.pos])) t.pos += 1;
                if (t.at(t.pos) == ')' or t.pos >= t.src.len) {
                    t.pos += 1;
                    t.pos = @min(t.pos, t.src.len);
                    return .{ .kind = .url, .text = s };
                }
                return t.badUrl();
            }
            if (c == '"' or c == '\'' or c == '(') return t.badUrl();
            if (c == '\\') {
                if (!t.validEscape(t.pos)) return t.badUrl();
                if (!copying) {
                    copying = true;
                    try out.appendSlice(t.arena, t.src[start..t.pos]);
                }
                const n = t.escape(&buf);
                try out.appendSlice(t.arena, buf[0..n]);
                continue;
            }
            if (copying) try out.append(t.arena, c);
            t.pos += 1;
        }
        return .{ .kind = .url, .text = if (copying) out.items else t.src[start..] };
    }

    fn badUrl(t: *Tokenizer) Token {
        while (t.pos < t.src.len) {
            const c = t.src[t.pos];
            if (c == ')') {
                t.pos += 1;
                break;
            }
            t.pos += if (t.validEscape(t.pos)) 2 else 1;
        }
        t.pos = @min(t.pos, t.src.len);
        return .{ .kind = .bad_url };
    }
};

/// Writes tokens back as CSS text, for custom properties and values read by
/// script. Comments are gone; whitespace is one space.
pub fn serialize(gpa: Allocator, tokens: []const Token) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (tokens) |t| {
        switch (t.kind) {
            .ident => try out.appendSlice(gpa, t.text),
            .function => {
                try out.appendSlice(gpa, t.text);
                try out.append(gpa, '(');
            },
            .at_keyword => {
                try out.append(gpa, '@');
                try out.appendSlice(gpa, t.text);
            },
            .hash => {
                try out.append(gpa, '#');
                try out.appendSlice(gpa, t.text);
            },
            .string, .bad_string => {
                try out.append(gpa, '"');
                try out.appendSlice(gpa, t.text);
                try out.append(gpa, '"');
            },
            .url, .bad_url => {
                try out.appendSlice(gpa, "url(");
                try out.appendSlice(gpa, t.text);
                try out.append(gpa, ')');
            },
            .number, .percentage, .dimension => {
                var buf: [48]u8 = undefined;
                const sign = if (t.signed and t.num >= 0) "+" else "";
                const s = std.fmt.bufPrint(&buf, "{s}{d}", .{ sign, t.num }) catch "0";
                try out.appendSlice(gpa, s);
                if (t.kind == .percentage) try out.append(gpa, '%');
                if (t.kind == .dimension) try out.appendSlice(gpa, t.text);
            },
            .whitespace => try out.append(gpa, ' '),
            .colon => try out.append(gpa, ':'),
            .semicolon => try out.append(gpa, ';'),
            .comma => try out.append(gpa, ','),
            .lbracket => try out.append(gpa, '['),
            .rbracket => try out.append(gpa, ']'),
            .lparen => try out.append(gpa, '('),
            .rparen => try out.append(gpa, ')'),
            .lbrace => try out.append(gpa, '{'),
            .rbrace => try out.append(gpa, '}'),
            .delim => try out.append(gpa, t.delim),
            .cdo => try out.appendSlice(gpa, "<!--"),
            .cdc => try out.appendSlice(gpa, "-->"),
            .eof => {},
        }
    }
    return out.toOwnedSlice(gpa);
}
