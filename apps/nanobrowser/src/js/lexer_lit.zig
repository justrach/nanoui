//! Literal tokens: numbers (with separators, legacy octal, bigint suffix), strings
//! with every escape, template chunks, and the regular expression rescan.

const std = @import("std");
const lexer = @import("lexer.zig");
const Lexer = lexer.Lexer;
const vm_mod = @import("vm.zig");
const Error = vm_mod.Error;
const str = @import("string.zig");

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parses after `\u`: XXXX or {X...}. Returns the code point.
pub fn unicodeEscape(l: *Lexer) Error!u32 {
    const s = l.src;
    if (l.i < s.len and s[l.i] == '{') {
        l.i += 1;
        var cp: u32 = 0;
        var n: u32 = 0;
        while (l.i < s.len and s[l.i] != '}') : (l.i += 1) {
            const h = hexVal(s[l.i]) orelse return l.fail("Invalid Unicode escape sequence", l.i);
            cp = cp * 16 + h;
            if (cp > 0x10FFFF) return l.fail("Undefined Unicode code-point", l.i);
            n += 1;
        }
        if (n == 0 or l.i >= s.len) return l.fail("Invalid Unicode escape sequence", l.i);
        l.i += 1;
        return cp;
    }
    if (l.i + 4 > s.len) return l.fail("Invalid Unicode escape sequence", l.i);
    var cp: u32 = 0;
    for (s[l.i..][0..4]) |c| {
        cp = cp * 16 + (hexVal(c) orelse return l.fail("Invalid Unicode escape sequence", l.i));
    }
    l.i += 4;
    return cp;
}

fn digitsVal(l: *Lexer, radix: u32) Error!f64 {
    const s = l.src;
    const start = l.i;
    var v: f64 = 0;
    var last_sep = true;
    while (l.i < s.len) : (l.i += 1) {
        const c = s[l.i];
        if (c == '_') {
            if (last_sep) return l.fail("Numeric separators are not allowed here", l.i);
            last_sep = true;
            continue;
        }
        const h = hexVal(c) orelse break;
        if (h >= radix) break;
        v = v * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(h));
        last_sep = false;
    }
    if (l.i == start or last_sep) return l.fail("Invalid or unexpected token", l.i);
    return v;
}

fn skipDigits(l: *Lexer) Error!bool {
    const s = l.src;
    var any = false;
    var last_sep = false;
    while (l.i < s.len) : (l.i += 1) {
        const c = s[l.i];
        if (c >= '0' and c <= '9') {
            any = true;
            last_sep = false;
        } else if (c == '_') {
            if (!any or last_sep) return l.fail("Numeric separators are not allowed here", l.i);
            last_sep = true;
        } else break;
    }
    if (last_sep) return l.fail("Numeric separators are not allowed here", l.i);
    return any;
}

pub fn number(l: *Lexer) Error!void {
    const s = l.src;
    const start = l.i;
    l.tok.t = .num;
    if (s[l.i] == '0' and l.i + 1 < s.len) {
        const x = s[l.i + 1] | 0x20;
        const radix: u32 = switch (x) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 0,
        };
        if (radix != 0) {
            l.i += 2;
            l.tok.num = try digitsVal(l, radix);
            if (l.i < s.len and s[l.i] == 'n') {
                l.tok.t = .bigint;
                l.tok.atom = try str.intern(l.vm, s[start..l.i]);
                l.i += 1;
            }
            try endOfNumber(l);
            return;
        }
        if (s[l.i + 1] >= '0' and s[l.i + 1] <= '9') {
            // Legacy octal, or a decimal with a leading zero when it has an 8 or 9.
            var j = l.i + 1;
            var octal = true;
            while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
                if (s[j] >= '8') octal = false;
            }
            l.tok.legacy_octal = true;
            if (octal) {
                var v: f64 = 0;
                for (s[l.i + 1 .. j]) |c| v = v * 8 + @as(f64, @floatFromInt(c - '0'));
                l.i = j;
                l.tok.num = v;
                try endOfNumber(l);
                return;
            }
        }
    }
    _ = try skipDigits(l);
    if (l.i < s.len and s[l.i] == 'n') {
        l.tok.t = .bigint;
        l.tok.atom = try str.intern(l.vm, s[start..l.i]);
        l.i += 1;
        try endOfNumber(l);
        return;
    }
    if (l.i < s.len and s[l.i] == '.') {
        l.i += 1;
        _ = try skipDigits(l);
    }
    if (l.i < s.len and (s[l.i] | 0x20) == 'e') {
        l.i += 1;
        if (l.i < s.len and (s[l.i] == '+' or s[l.i] == '-')) l.i += 1;
        if (!try skipDigits(l)) return l.fail("Invalid or unexpected token", l.i);
    }
    const text = s[start..l.i];
    if (std.mem.indexOfScalar(u8, text, '_') != null) {
        l.buf.clearRetainingCapacity();
        for (text) |c| if (c != '_') try l.buf.append(l.vm.gpa, c);
        l.tok.num = std.fmt.parseFloat(f64, l.buf.items) catch return l.fail("Invalid number", start);
    } else {
        l.tok.num = fastDecimal(text) orelse (std.fmt.parseFloat(f64, text) catch return l.fail("Invalid number", start));
    }
    try endOfNumber(l);
}

fn fastDecimal(text: []const u8) ?f64 {
    if (text.len > 15) return null;
    var v: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return @floatFromInt(v);
}

fn endOfNumber(l: *Lexer) Error!void {
    if (l.i < l.src.len) {
        const c = l.src[l.i];
        if (lexer.isIdPartAscii(c)) return l.fail("Invalid or unexpected token", l.i);
    }
}

/// Appends a code point to the scratch buffer, merging a surrogate pair split
/// across two escapes into one WTF-8 sequence.
fn appendCp(l: *Lexer, cp: u32) Error!void {
    const b = &l.buf;
    if (cp >= 0xDC00 and cp < 0xE000 and b.items.len >= 3) {
        const n = b.items.len;
        const t = b.items[n - 3 ..];
        if (t[0] == 0xED and t[1] >= 0xA0 and t[1] < 0xB0) {
            const hi = 0xD000 + ((@as(u32, t[1]) & 0x3F) << 6) + (t[2] & 0x3F);
            b.items.len = n - 3;
            const full = 0x10000 + ((hi - 0xD800) << 10) + (cp - 0xDC00);
            return appendCp(l, full);
        }
    }
    var t: [4]u8 = undefined;
    const n = str.encode(cp, &t);
    try b.appendSlice(l.vm.gpa, t[0..n]);
}

const EscapeResult = enum { ok, bad };

/// Handles one escape; `l.i` is just past the backslash. In templates a bad escape
/// is not an error but makes the cooked value undefined.
fn escape(l: *Lexer, in_template: bool) Error!EscapeResult {
    const s = l.src;
    if (l.i >= s.len) return l.fail("Invalid or unexpected token", l.i);
    const c = s[l.i];
    l.i += 1;
    switch (c) {
        'n' => try appendCp(l, '\n'),
        't' => try appendCp(l, '\t'),
        'r' => try appendCp(l, '\r'),
        'b' => try appendCp(l, 8),
        'v' => try appendCp(l, 11),
        'f' => try appendCp(l, 12),
        '\r' => {
            if (l.i < s.len and s[l.i] == '\n') l.i += 1;
        },
        '\n' => {},
        'x' => {
            const h1 = if (l.i < s.len) hexVal(s[l.i]) else null;
            const h2 = if (l.i + 1 < s.len) hexVal(s[l.i + 1]) else null;
            if (h1 == null or h2 == null) {
                if (in_template) return .bad;
                return l.fail("Invalid hexadecimal escape sequence", l.i);
            }
            l.i += 2;
            try appendCp(l, h1.? * 16 + h2.?);
        },
        'u' => {
            if (in_template) {
                const save = l.i;
                const cp = badUnicodeProbe(l);
                if (cp == null) {
                    l.i = save;
                    return .bad;
                }
                try appendCp(l, cp.?);
            } else {
                try appendCp(l, try unicodeEscape(l));
            }
        },
        '0'...'9' => {
            if (c == '0' and !(l.i < s.len and s[l.i] >= '0' and s[l.i] <= '9')) {
                try appendCp(l, 0);
            } else if (in_template) {
                return .bad;
            } else if (c >= '8') {
                l.tok.legacy_octal = true;
                try appendCp(l, c);
            } else {
                l.tok.legacy_octal = true;
                var v: u32 = c - '0';
                if (l.i < s.len and s[l.i] >= '0' and s[l.i] <= '7') {
                    v = v * 8 + (s[l.i] - '0');
                    l.i += 1;
                    if (v < 32 and l.i < s.len and s[l.i] >= '0' and s[l.i] <= '7') {
                        v = v * 8 + (s[l.i] - '0');
                        l.i += 1;
                    }
                }
                try appendCp(l, v);
            }
        },
        else => {
            if (c >= 0x80) {
                const d = str.decode(s, l.i - 1);
                l.i = l.i - 1 + d.len;
                if (d.cp != 0x2028 and d.cp != 0x2029) try appendCp(l, d.cp);
            } else try appendCp(l, c);
        },
    }
    return .ok;
}

fn badUnicodeProbe(l: *Lexer) ?u32 {
    const s = l.src;
    if (l.i < s.len and s[l.i] == '{') {
        var j = l.i + 1;
        var cp: u32 = 0;
        var n: u32 = 0;
        while (j < s.len and s[j] != '}') : (j += 1) {
            cp = cp * 16 + (hexVal(s[j]) orelse return null);
            if (cp > 0x10FFFF) return null;
            n += 1;
        }
        if (n == 0 or j >= s.len) return null;
        l.i = j + 1;
        return cp;
    }
    if (l.i + 4 > s.len) return null;
    var cp: u32 = 0;
    for (s[l.i..][0..4]) |c| cp = cp * 16 + (hexVal(c) orelse return null);
    l.i += 4;
    return cp;
}

pub fn string(l: *Lexer, quote: u8) Error!void {
    const s = l.src;
    l.tok.t = .string;
    l.i += 1;
    const start = l.i;
    // The common case has no escapes: intern the source bytes directly.
    while (l.i < s.len) {
        const c = s[l.i];
        if (c == quote) {
            l.tok.atom = try str.intern(l.vm, s[start..l.i]);
            l.i += 1;
            return;
        }
        if (c == '\\') break;
        if (c == '\n' or c == '\r') return l.fail("Invalid or unexpected token", l.tok.pos);
        l.i += 1;
    }
    l.buf.clearRetainingCapacity();
    try l.buf.appendSlice(l.vm.gpa, s[start..l.i]);
    while (true) {
        if (l.i >= s.len) return l.fail("Invalid or unexpected token", l.tok.pos);
        const c = s[l.i];
        if (c == quote) {
            l.i += 1;
            break;
        }
        if (c == '\n' or c == '\r') return l.fail("Invalid or unexpected token", l.tok.pos);
        if (c == '\\') {
            l.i += 1;
            _ = try escape(l, false);
        } else {
            try l.buf.append(l.vm.gpa, c);
            l.i += 1;
        }
    }
    l.tok.atom = try str.intern(l.vm, l.buf.items);
}

/// Scans one template chunk; `l.i` is just past the opening backtick or `}`.
pub fn templateChunk(l: *Lexer) Error!void {
    const s = l.src;
    l.tok.t = .template;
    const raw_start = l.i;
    l.buf.clearRetainingCapacity();
    var bad = false;
    while (true) {
        if (l.i >= s.len) return l.fail("Unterminated template literal", l.tok.pos);
        const c = s[l.i];
        if (c == '`') {
            l.tok.tail = true;
            break;
        }
        if (c == '$' and l.i + 1 < s.len and s[l.i + 1] == '{') break;
        if (c == '\\') {
            l.i += 1;
            if (try escape(l, true) == .bad) bad = true;
        } else if (c == '\r') {
            try l.buf.append(l.vm.gpa, '\n');
            l.i += 1;
            if (l.i < s.len and s[l.i] == '\n') l.i += 1;
        } else {
            try l.buf.append(l.vm.gpa, c);
            l.i += 1;
        }
    }
    l.tok.atom = if (bad) null else try str.intern(l.vm, l.buf.items);
    const raw = s[raw_start..l.i];
    if (std.mem.indexOfScalar(u8, raw, '\r') != null) {
        l.buf.clearRetainingCapacity();
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            if (raw[j] == '\r') {
                try l.buf.append(l.vm.gpa, '\n');
                if (j + 1 < raw.len and raw[j + 1] == '\n') j += 1;
            } else try l.buf.append(l.vm.gpa, raw[j]);
        }
        l.tok.atom2 = try str.intern(l.vm, l.buf.items);
    } else {
        l.tok.atom2 = try str.intern(l.vm, raw);
    }
    l.i += if (l.tok.tail) 1 else 2;
    l.tok.end = l.i;
}

/// The current token is `}` closing a template substitution: rescan it as a chunk.
pub fn rescanTemplate(l: *Lexer) Error!void {
    const pos = l.tok.pos;
    l.i = pos + 1;
    l.tok = .{ .pos = pos };
    try templateChunk(l);
}

/// The current token is `/` or `/=` where an expression must start: rescan as a regex.
pub fn rescanRegex(l: *Lexer) Error!void {
    const s = l.src;
    const pos = l.tok.pos;
    const nl = l.tok.nl_before;
    var i = pos + 1;
    var in_class = false;
    while (true) {
        if (i >= s.len) return l.fail("Invalid regular expression: missing /", pos);
        const c = s[i];
        if (c == '\n' or c == '\r') return l.fail("Invalid regular expression: missing /", pos);
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '[') {
            in_class = true;
        } else if (c == ']') {
            in_class = false;
        } else if (c == '/' and !in_class) break;
        i += 1;
    }
    const body = s[pos + 1 .. i];
    i += 1;
    const fstart = i;
    while (i < s.len and lexer.isIdPartAscii(s[i])) i += 1;
    l.i = i;
    l.tok = .{ .t = .regex, .pos = pos, .end = i, .nl_before = nl };
    l.tok.atom = try str.intern(l.vm, body);
    l.tok.atom2 = try str.intern(l.vm, s[fstart..i]);
}
