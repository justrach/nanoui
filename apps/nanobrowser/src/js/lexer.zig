//! The tokenizer. Tokens are made on demand; the parser tells it when a `/` starts
//! a regular expression and when a `}` continues a template, which is the only way
//! to get those decisions right. Comments and newlines are skipped here and recorded
//! as `nl_before` for automatic semicolon insertion.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const str = @import("string.zig");
const JSString = str.JSString;
const lit = @import("lexer_lit.zig");

pub const T = enum(u8) {
    eof,
    ident,
    private_name,
    num,
    bigint,
    string,
    template,
    regex,
    // punctuators
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dot,
    ellipsis,
    semi,
    comma,
    question,
    qdot,
    colon,
    arrow,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    seq,
    sne,
    plus,
    minus,
    star,
    slash,
    percent,
    pow,
    inc,
    dec,
    shl,
    sar,
    shr,
    amp,
    pipe,
    caret,
    bang,
    tilde,
    land,
    lor,
    nullish,
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    pow_assign,
    shl_assign,
    sar_assign,
    shr_assign,
    and_assign,
    or_assign,
    xor_assign,
    land_assign,
    lor_assign,
    nullish_assign,
    // reserved words
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_export,
    kw_extends,
    kw_false,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_null,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_true,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    kw_enum,

    pub fn isKeyword(t: T) bool {
        return @backingInt(t) >= @backingInt(T.kw_break);
    }
};

const keywords = std.StaticStringMap(T).initComptime(.{
    .{ "break", .kw_break },       .{ "case", .kw_case },         .{ "catch", .kw_catch },
    .{ "class", .kw_class },       .{ "const", .kw_const },       .{ "continue", .kw_continue },
    .{ "debugger", .kw_debugger }, .{ "default", .kw_default },   .{ "delete", .kw_delete },
    .{ "do", .kw_do },             .{ "else", .kw_else },         .{ "export", .kw_export },
    .{ "extends", .kw_extends },   .{ "false", .kw_false },       .{ "finally", .kw_finally },
    .{ "for", .kw_for },           .{ "function", .kw_function }, .{ "if", .kw_if },
    .{ "import", .kw_import },     .{ "in", .kw_in },             .{ "instanceof", .kw_instanceof },
    .{ "new", .kw_new },           .{ "null", .kw_null },         .{ "return", .kw_return },
    .{ "super", .kw_super },       .{ "switch", .kw_switch },     .{ "this", .kw_this },
    .{ "throw", .kw_throw },       .{ "true", .kw_true },         .{ "try", .kw_try },
    .{ "typeof", .kw_typeof },     .{ "var", .kw_var },           .{ "void", .kw_void },
    .{ "while", .kw_while },       .{ "with", .kw_with },         .{ "enum", .kw_enum },
});

pub const Token = struct {
    t: T = .eof,
    pos: u32 = 0,
    end: u32 = 0,
    nl_before: bool = false,
    /// An identifier or keyword spelled with a unicode escape.
    escaped: bool = false,
    /// A string containing a legacy octal escape (forbidden in strict mode).
    legacy_octal: bool = false,
    /// A template chunk that ends the template.
    tail: bool = false,
    num: f64 = 0,
    /// Identifier/keyword name, cooked string, bigint digits, regex body, or template chunk.
    atom: ?*JSString = null,
    /// A template chunk's raw text, or a regex's flags.
    atom2: ?*JSString = null,
};

pub inline fn isIdStartAscii(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '$' or c == '_';
}
pub inline fn isIdPartAscii(c: u8) bool {
    return isIdStartAscii(c) or (c >= '0' and c <= '9');
}
/// Code points past ASCII are treated as identifier characters unless they are
/// whitespace or line terminators; the full ID_Start tables add nothing for real code.
pub fn isIdCp(cp: u32) bool {
    if (cp < 0x80) return isIdPartAscii(@intCast(cp));
    return !isSpaceCp(cp) and !isLineCp(cp);
}
pub fn isLineCp(cp: u32) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}
pub fn isSpaceCp(cp: u32) bool {
    return switch (cp) {
        ' ', '\t', 0x0B, 0x0C, 0xA0, 0xFEFF, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

pub const Lexer = struct {
    vm: *Vm,
    src: []const u8,
    i: u32 = 0,
    is_module: bool = false,
    tok: Token = .{},
    /// Scratch for cooking literals; reused to avoid churn.
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(l: *Lexer) void {
        l.buf.deinit(l.vm.gpa);
    }

    pub fn fail(l: *Lexer, msg: []const u8, pos: u32) Error {
        var line: u32 = 1;
        var col: u32 = 1;
        for (l.src[0..@min(pos, l.src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        var b: [256]u8 = undefined;
        const t = std.fmt.bufPrint(&b, "{s} ({d}:{d})", .{ msg[0..@min(msg.len, 200)], line, col }) catch msg;
        return l.vm.throwError(.SyntaxError, t);
    }

    /// Skips whitespace and comments. Returns whether a line terminator was crossed.
    fn skipTrivia(l: *Lexer, start_of_input: bool) Error!bool {
        const s = l.src;
        var nl = start_of_input;
        while (l.i < s.len) {
            const c = s[l.i];
            switch (c) {
                ' ', '\t', 0x0B, 0x0C => l.i += 1,
                '\n', '\r' => {
                    nl = true;
                    l.i += 1;
                },
                '/' => {
                    if (l.i + 1 >= s.len) return nl;
                    const d = s[l.i + 1];
                    if (d == '/') {
                        l.skipLine();
                    } else if (d == '*') {
                        const end = std.mem.indexOfPos(u8, s, l.i + 2, "*/") orelse return l.fail("Unterminated comment", l.i);
                        if (!nl) {
                            for (s[l.i..end]) |x| {
                                if (x == '\n' or x == '\r') nl = true;
                            }
                            if (std.mem.indexOf(u8, s[l.i..end], "\xE2\x80\xA8") != null or std.mem.indexOf(u8, s[l.i..end], "\xE2\x80\xA9") != null) nl = true;
                        }
                        l.i = @intCast(end + 2);
                    } else return nl;
                },
                '<' => {
                    if (!l.is_module and std.mem.startsWith(u8, s[l.i..], "<!--")) {
                        l.skipLine();
                    } else return nl;
                },
                '-' => {
                    if (!l.is_module and nl and std.mem.startsWith(u8, s[l.i..], "-->")) {
                        l.skipLine();
                    } else return nl;
                },
                else => {
                    if (c < 0x80) return nl;
                    const d = str.decode(s, l.i);
                    if (isLineCp(d.cp)) {
                        nl = true;
                    } else if (!isSpaceCp(d.cp)) return nl;
                    l.i += d.len;
                },
            }
        }
        return nl;
    }

    fn skipLine(l: *Lexer) void {
        const s = l.src;
        while (l.i < s.len) {
            const c = s[l.i];
            if (c == '\n' or c == '\r') return;
            if (c == 0xE2 and l.i + 2 < s.len and s[l.i + 1] == 0x80 and (s[l.i + 2] == 0xA8 or s[l.i + 2] == 0xA9)) return;
            l.i += 1;
        }
    }

    /// Advances to the next token, leaving it in `tok`.
    pub fn next(l: *Lexer) Error!void {
        const first = l.i == 0;
        if (first and std.mem.startsWith(u8, l.src, "#!")) l.skipLine();
        const nl = try l.skipTrivia(first);
        l.tok = .{ .pos = l.i, .nl_before = nl };
        if (l.i >= l.src.len) {
            l.tok.end = l.i;
            return;
        }
        const c = l.src[l.i];
        if (isIdStartAscii(c) or c >= 0x80 or c == '\\') {
            try l.identifier();
        } else if (c >= '0' and c <= '9') {
            try lit.number(l);
        } else if (c == '"' or c == '\'') {
            try lit.string(l, c);
        } else if (c == '`') {
            l.i += 1;
            try lit.templateChunk(l);
        } else if (c == '#') {
            l.i += 1;
            if (l.i >= l.src.len or !(isIdStartAscii(l.src[l.i]) or l.src[l.i] >= 0x80 or l.src[l.i] == '\\')) {
                return l.fail("Invalid or unexpected token", l.tok.pos);
            }
            try l.identifier();
            l.tok.t = .private_name;
            // The stored name keeps the '#', so private names cannot collide with variables.
            l.buf.clearRetainingCapacity();
            try l.buf.append(l.vm.gpa, '#');
            try l.buf.appendSlice(l.vm.gpa, try l.tok.atom.?.flat(l.vm));
            l.tok.atom = try str.intern(l.vm, l.buf.items);
        } else {
            l.tok.t = try l.punct(c);
        }
        l.tok.end = l.i;
    }

    fn identifier(l: *Lexer) Error!void {
        const s = l.src;
        const start = l.i;
        var i = l.i;
        while (i < s.len and isIdPartAscii(s[i])) i += 1;
        if (i < s.len and (s[i] == '\\' or s[i] >= 0x80)) {
            return l.slowIdentifier();
        }
        l.i = i;
        const name = s[start..i];
        l.tok.t = if (name.len <= 10 and name.len >= 2 and name[0] >= 'b' and name[0] <= 'w')
            keywords.get(name) orelse .ident
        else
            .ident;
        l.tok.atom = try str.intern(l.vm, name);
    }

    fn slowIdentifier(l: *Lexer) Error!void {
        const s = l.src;
        l.buf.clearRetainingCapacity();
        var escaped = false;
        while (l.i < s.len) {
            const c = s[l.i];
            if (isIdPartAscii(c)) {
                try l.buf.append(l.vm.gpa, c);
                l.i += 1;
            } else if (c == '\\') {
                l.i += 1;
                if (l.i >= s.len or s[l.i] != 'u') return l.fail("Invalid Unicode escape sequence", l.i);
                l.i += 1;
                const cp = try lit.unicodeEscape(l);
                if (!isIdCp(cp)) return l.fail("Invalid Unicode escape sequence", l.i);
                var t: [4]u8 = undefined;
                const n = str.encode(cp, &t);
                try l.buf.appendSlice(l.vm.gpa, t[0..n]);
                escaped = true;
            } else if (c >= 0x80) {
                const d = str.decode(s, l.i);
                if (!isIdCp(d.cp)) break;
                try l.buf.appendSlice(l.vm.gpa, s[l.i..][0..d.len]);
                l.i += d.len;
            } else break;
        }
        if (l.buf.items.len == 0) return l.fail("Invalid or unexpected token", l.i);
        l.tok.t = keywords.get(l.buf.items) orelse .ident;
        l.tok.escaped = escaped;
        l.tok.atom = try str.intern(l.vm, l.buf.items);
    }

    fn at(l: *Lexer, off: u32) u8 {
        return if (l.i + off < l.src.len) l.src[l.i + off] else 0;
    }

    fn punct(l: *Lexer, c: u8) Error!T {
        const c1 = l.at(1);
        const c2 = l.at(2);
        const c3 = l.at(3);
        const r: struct { T, u32 } = switch (c) {
            '{' => .{ .lbrace, 1 },
            '}' => .{ .rbrace, 1 },
            '(' => .{ .lparen, 1 },
            ')' => .{ .rparen, 1 },
            '[' => .{ .lbracket, 1 },
            ']' => .{ .rbracket, 1 },
            ';' => .{ .semi, 1 },
            ',' => .{ .comma, 1 },
            ':' => .{ .colon, 1 },
            '~' => .{ .tilde, 1 },
            '.' => blk: {
                if (c1 >= '0' and c1 <= '9') {
                    try lit.number(l);
                    return l.tok.t;
                }
                break :blk if (c1 == '.' and c2 == '.') .{ .ellipsis, 3 } else .{ .dot, 1 };
            },
            '?' => if (c1 == '?')
                (if (c2 == '=') .{ .nullish_assign, 3 } else .{ .nullish, 2 })
            else if (c1 == '.' and !(c2 >= '0' and c2 <= '9'))
                .{ .qdot, 2 }
            else
                .{ .question, 1 },
            '<' => if (c1 == '<')
                (if (c2 == '=') .{ .shl_assign, 3 } else .{ .shl, 2 })
            else if (c1 == '=')
                .{ .le, 2 }
            else
                .{ .lt, 1 },
            '>' => if (c1 == '>')
                (if (c2 == '>')
                    (if (c3 == '=') .{ .shr_assign, 4 } else .{ .shr, 3 })
                else if (c2 == '=')
                    .{ .sar_assign, 3 }
                else
                    .{ .sar, 2 })
            else if (c1 == '=')
                .{ .ge, 2 }
            else
                .{ .gt, 1 },
            '=' => if (c1 == '=')
                (if (c2 == '=') .{ .seq, 3 } else .{ .eq, 2 })
            else if (c1 == '>')
                .{ .arrow, 2 }
            else
                .{ .assign, 1 },
            '!' => if (c1 == '=') (if (c2 == '=') .{ .sne, 3 } else .{ .ne, 2 }) else .{ .bang, 1 },
            '+' => if (c1 == '+') .{ .inc, 2 } else if (c1 == '=') .{ .add_assign, 2 } else .{ .plus, 1 },
            '-' => if (c1 == '-') .{ .dec, 2 } else if (c1 == '=') .{ .sub_assign, 2 } else .{ .minus, 1 },
            '*' => if (c1 == '*')
                (if (c2 == '=') .{ .pow_assign, 3 } else .{ .pow, 2 })
            else if (c1 == '=')
                .{ .mul_assign, 2 }
            else
                .{ .star, 1 },
            '/' => if (c1 == '=') .{ .div_assign, 2 } else .{ .slash, 1 },
            '%' => if (c1 == '=') .{ .mod_assign, 2 } else .{ .percent, 1 },
            '&' => if (c1 == '&')
                (if (c2 == '=') .{ .land_assign, 3 } else .{ .land, 2 })
            else if (c1 == '=')
                .{ .and_assign, 2 }
            else
                .{ .amp, 1 },
            '|' => if (c1 == '|')
                (if (c2 == '=') .{ .lor_assign, 3 } else .{ .lor, 2 })
            else if (c1 == '=')
                .{ .or_assign, 2 }
            else
                .{ .pipe, 1 },
            '^' => if (c1 == '=') .{ .xor_assign, 2 } else .{ .caret, 1 },
            else => return l.fail("Invalid or unexpected token", l.i),
        };
        l.i += r[1];
        return r[0];
    }

    pub const rescanRegex = lit.rescanRegex;
    pub const rescanTemplate = lit.rescanTemplate;
};
