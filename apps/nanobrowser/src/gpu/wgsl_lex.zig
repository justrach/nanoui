//! WGSL's tokens, and the sink every stage of the translator reports its one
//! error into. Identifiers starting with two underscores are WGSL errors, which is
//! what keeps the names the translator generates its own.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pos = struct { line: u32 = 1, col: u32 = 1, offset: u32 = 0, len: u32 = 0 };
pub const Diag = struct { pos: Pos, message: []const u8 };
pub const Error = error{ Wgsl, OutOfMemory };

pub const Sink = struct {
    arena: Allocator,
    diag: ?Diag = null,

    pub fn fail(s: *Sink, pos: Pos, comptime f: []const u8, args: anytype) Error {
        if (s.diag == null) s.diag = .{ .pos = pos, .message = try std.fmt.allocPrint(s.arena, f, args) };
        return error.Wgsl;
    }
};

pub const Tag = enum {
    eof,
    ident,
    keyword,
    int,
    float,
    at,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semicolon,
    colon,
    comma,
    dot,
    arrow,
    eq,
    eqeq,
    ne,
    lt,
    le,
    gt,
    ge,
    shl,
    shr,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    andand,
    oror,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    shl_eq,
    shr_eq,
    plusplus,
    minusminus,
};

pub const Token = struct { tag: Tag, text: []const u8, pos: Pos };

const keywords = [_][]const u8{ "alias", "break", "case", "const", "const_assert", "continue", "continuing", "default", "diagnostic", "discard", "else", "enable", "false", "fn", "for", "if", "let", "loop", "override", "requires", "return", "struct", "switch", "true", "var", "while" };

pub const Lexer = struct {
    src: []const u8,
    sink: *Sink,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    fn posAt(l: *const Lexer, start: usize, line: u32, line_start: usize) Pos {
        return .{ .line = line, .col = @intCast(start - line_start + 1), .offset = @intCast(start), .len = @intCast(l.i - start) };
    }

    fn peekAt(l: *const Lexer, k: usize) u8 {
        return if (l.i + k < l.src.len) l.src[l.i + k] else 0;
    }

    fn newline(l: *Lexer) void {
        l.line += 1;
        l.line_start = l.i;
    }

    fn skipSpace(l: *Lexer) Error!void {
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (c == '\n') {
                l.i += 1;
                l.newline();
            } else if (c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c) {
                l.i += 1;
            } else if (c == '/' and l.peekAt(1) == '/') {
                while (l.i < l.src.len and l.src[l.i] != '\n') l.i += 1;
            } else if (c == '/' and l.peekAt(1) == '*') {
                const start = l.i;
                const line = l.line;
                const ls = l.line_start;
                var depth: u32 = 1;
                l.i += 2;
                while (depth > 0) {
                    if (l.i >= l.src.len) return l.sink.fail(l.posAt(start, line, ls), "unterminated block comment", .{});
                    if (l.src[l.i] == '/' and l.peekAt(1) == '*') {
                        depth += 1;
                        l.i += 2;
                    } else if (l.src[l.i] == '*' and l.peekAt(1) == '/') {
                        depth -= 1;
                        l.i += 2;
                    } else {
                        if (l.src[l.i] == '\n') {
                            l.i += 1;
                            l.newline();
                        } else l.i += 1;
                    }
                }
            } else return;
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentCont(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn number(l: *Lexer) Error!Token {
        const start = l.i;
        var is_float = false;
        const hex = l.src[l.i] == '0' and (l.peekAt(1) == 'x' or l.peekAt(1) == 'X');
        if (hex) {
            l.i += 2;
            while (std.ascii.isHex(l.peekAt(0))) l.i += 1;
            if (l.peekAt(0) == '.') {
                is_float = true;
                l.i += 1;
                while (std.ascii.isHex(l.peekAt(0))) l.i += 1;
            }
            if (l.peekAt(0) == 'p' or l.peekAt(0) == 'P') {
                is_float = true;
                l.i += 1;
                if (l.peekAt(0) == '+' or l.peekAt(0) == '-') l.i += 1;
                while (std.ascii.isDigit(l.peekAt(0))) l.i += 1;
            }
        } else {
            while (std.ascii.isDigit(l.peekAt(0))) l.i += 1;
            if (l.peekAt(0) == '.') {
                is_float = true;
                l.i += 1;
                while (std.ascii.isDigit(l.peekAt(0))) l.i += 1;
            }
            if (l.peekAt(0) == 'e' or l.peekAt(0) == 'E') {
                is_float = true;
                l.i += 1;
                if (l.peekAt(0) == '+' or l.peekAt(0) == '-') l.i += 1;
                if (!std.ascii.isDigit(l.peekAt(0))) return l.sink.fail(l.posAt(start, l.line, l.line_start), "a float literal's exponent has no digits", .{});
                while (std.ascii.isDigit(l.peekAt(0))) l.i += 1;
            }
        }
        const s = l.peekAt(0);
        if (s == 'h') {
            l.i += 1;
            return l.sink.fail(l.posAt(start, l.line, l.line_start), "f16 literals are not supported", .{});
        }
        if (s == 'f') {
            if (hex and !is_float) {
                return l.sink.fail(l.posAt(start, l.line, l.line_start), "a hexadecimal integer can't take the suffix 'f'", .{});
            }
            is_float = true;
            l.i += 1;
        } else if ((s == 'i' or s == 'u') and !is_float) {
            l.i += 1;
        }
        if (isIdentCont(l.peekAt(0))) {
            while (isIdentCont(l.peekAt(0))) l.i += 1;
            return l.sink.fail(l.posAt(start, l.line, l.line_start), "bad number '{s}'", .{l.src[start..l.i]});
        }
        const digits = l.src[start..l.i];
        if (!hex and !is_float and digits.len > 1 and digits[0] == '0' and std.ascii.isDigit(digits[1])) {
            return l.sink.fail(l.posAt(start, l.line, l.line_start), "an integer literal can't start with a zero: '{s}'", .{digits});
        }
        return .{ .tag = if (is_float) .float else .int, .text = digits, .pos = l.posAt(start, l.line, l.line_start) };
    }

    pub fn next(l: *Lexer) Error!Token {
        try l.skipSpace();
        const start = l.i;
        if (l.i >= l.src.len) return .{ .tag = .eof, .text = "", .pos = l.posAt(start, l.line, l.line_start) };
        const c = l.src[l.i];
        if (isIdentStart(c)) {
            while (isIdentCont(l.peekAt(0))) l.i += 1;
            const text = l.src[start..l.i];
            const pos = l.posAt(start, l.line, l.line_start);
            if (text.len >= 2 and text[0] == '_' and text[1] == '_') return l.sink.fail(pos, "an identifier can't start with two underscores: '{s}'", .{text});
            for (keywords) |k| if (std.mem.eql(u8, k, text)) return .{ .tag = .keyword, .text = text, .pos = pos };
            return .{ .tag = .ident, .text = text, .pos = pos };
        }
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(l.peekAt(1)))) return l.number();
        if (c >= 0x80) {
            l.i += 1;
            return l.sink.fail(l.posAt(start, l.line, l.line_start), "identifiers outside ASCII are not supported", .{});
        }
        const Three = struct { s: []const u8, t: Tag };
        const ops = [_]Three{
            .{ .s = "<<=", .t = .shl_eq },    .{ .s = ">>=", .t = .shr_eq }, .{ .s = "->", .t = .arrow },    .{ .s = "==", .t = .eqeq },
            .{ .s = "!=", .t = .ne },         .{ .s = "<=", .t = .le },      .{ .s = ">=", .t = .ge },       .{ .s = "<<", .t = .shl },
            .{ .s = ">>", .t = .shr },        .{ .s = "&&", .t = .andand },  .{ .s = "||", .t = .oror },     .{ .s = "+=", .t = .plus_eq },
            .{ .s = "-=", .t = .minus_eq },   .{ .s = "*=", .t = .star_eq }, .{ .s = "/=", .t = .slash_eq }, .{ .s = "%=", .t = .percent_eq },
            .{ .s = "&=", .t = .amp_eq },     .{ .s = "|=", .t = .pipe_eq }, .{ .s = "^=", .t = .caret_eq }, .{ .s = "++", .t = .plusplus },
            .{ .s = "--", .t = .minusminus }, .{ .s = "@", .t = .at },       .{ .s = "(", .t = .lparen },    .{ .s = ")", .t = .rparen },
            .{ .s = "{", .t = .lbrace },      .{ .s = "}", .t = .rbrace },   .{ .s = "[", .t = .lbracket },  .{ .s = "]", .t = .rbracket },
            .{ .s = ";", .t = .semicolon },   .{ .s = ":", .t = .colon },    .{ .s = ",", .t = .comma },     .{ .s = ".", .t = .dot },
            .{ .s = "=", .t = .eq },          .{ .s = "<", .t = .lt },       .{ .s = ">", .t = .gt },        .{ .s = "+", .t = .plus },
            .{ .s = "-", .t = .minus },       .{ .s = "*", .t = .star },     .{ .s = "/", .t = .slash },     .{ .s = "%", .t = .percent },
            .{ .s = "&", .t = .amp },         .{ .s = "|", .t = .pipe },     .{ .s = "^", .t = .caret },     .{ .s = "~", .t = .tilde },
            .{ .s = "!", .t = .bang },
        };
        for (ops) |op| {
            if (std.mem.startsWith(u8, l.src[l.i..], op.s)) {
                l.i += op.s.len;
                return .{ .tag = op.t, .text = op.s, .pos = l.posAt(start, l.line, l.line_start) };
            }
        }
        l.i += 1;
        return l.sink.fail(l.posAt(start, l.line, l.line_start), "unexpected character '{c}'", .{c});
    }
};
