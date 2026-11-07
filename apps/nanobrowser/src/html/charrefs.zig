//! Character references: `&#123;`, `&#x1F;`, `&amp;`, and the legacy forms
//! with no semicolon, as the WHATWG tokenizer decides them.
const std = @import("std");
const entities = @import("entities.zig");

pub const Decoded = struct {
    /// Bytes of source taken, from the `&` inclusive.
    consumed: usize,
    bytes: [4]u8 = undefined,
    len: u3 = 0,

    pub fn slice(d: *const Decoded) []const u8 {
        return d.bytes[0..d.len];
    }
};

/// The Windows-1252 meanings of the C1 range numeric references name.
const c1 = [32]u21{
    0x20AC, 0x81,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D,   0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D,   0x017E, 0x0178,
};

fn make(consumed: usize, cp: u21) Decoded {
    var d: Decoded = .{ .consumed = consumed };
    const n = std.unicode.utf8Encode(cp, &d.bytes) catch blk: {
        d.bytes[0] = 0xEF;
        d.bytes[1] = 0xBF;
        d.bytes[2] = 0xBD;
        break :blk @as(u3, 3);
    };
    d.len = n;
    return d;
}

fn numeric(s: []const u8, at: usize) ?Decoded {
    var i = at + 2;
    var base: u32 = 10;
    if (i < s.len and (s[i] == 'x' or s[i] == 'X')) {
        base = 16;
        i += 1;
    }
    const digits_at = i;
    var value: u32 = 0;
    while (i < s.len) : (i += 1) {
        const v = std.fmt.charToDigit(s[i], @intCast(base)) catch break;
        if (value <= 0x10FFFF) value = value * base + v;
    }
    if (i == digits_at) return null;
    if (i < s.len and s[i] == ';') i += 1;
    var cp: u21 = 0xFFFD;
    if (value >= 0x80 and value <= 0x9F) {
        cp = c1[value - 0x80];
    } else if (value != 0 and value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF)) {
        cp = @intCast(value);
    }
    return make(i - at, cp);
}

/// Decodes the reference at `s[at]`, an `&`; null when it is not one and the
/// `&` is literal. `in_attr` applies the attribute rule: a legacy name
/// followed by `=` or an alphanumeric stays as written.
pub fn decode(s: []const u8, at: usize, in_attr: bool) ?Decoded {
    const n = at + 1;
    if (n >= s.len) return null;
    if (s[n] == '#') return numeric(s, at);
    if (!std.ascii.isAlphanumeric(s[n])) return null;
    var e = n;
    while (e < s.len and e - n < 40 and std.ascii.isAlphanumeric(s[e])) : (e += 1) {}
    if (e < s.len and s[e] == ';') {
        if (entities.lookup(s[n..e])) |cp| return make(e + 1 - at, cp);
    }
    // The longest legacy name that prefixes the run.
    var len = @min(e - n, entities.legacy_max);
    while (len > 1) : (len -= 1) {
        const cp = entities.lookupLegacy(s[n .. n + len]) orelse continue;
        const after = n + len;
        if (in_attr and after < s.len and (s[after] == '=' or std.ascii.isAlphanumeric(s[after]))) return null;
        return make(after - at, cp);
    }
    return null;
}
