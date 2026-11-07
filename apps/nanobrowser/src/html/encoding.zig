//! Decoding a page's bytes to UTF-8: the byte order mark, the Content-Type
//! charset, a `<meta charset>` in the first 1024 bytes, then a guess.
//! UTF-8, UTF-16 and windows-1252 (and its aliases) are decoded; any other
//! encoding is treated as UTF-8, with invalid sequences as U+FFFD.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Enc = enum { utf8, windows1252, utf16le, utf16be };

const high = [32]u21{
    0x20AC, 0x81,   0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D,   0x017D, 0x8F,
    0x90,   0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D,   0x017E, 0x0178,
};

fn label(raw: []const u8) ?Enc {
    const s = std.mem.trim(u8, raw, " \t\r\n\x0c\"'");
    var buf: [32]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return null;
    const l = std.ascii.lowerString(&buf, s);
    const map = std.StaticStringMap(Enc).initComptime(.{
        .{ "utf-8", .utf8 },               .{ "utf8", .utf8 },                  .{ "unicode-1-1-utf-8", .utf8 },
        .{ "windows-1252", .windows1252 }, .{ "cp1252", .windows1252 },         .{ "x-cp1252", .windows1252 },
        .{ "iso-8859-1", .windows1252 },   .{ "iso8859-1", .windows1252 },      .{ "iso_8859-1", .windows1252 },
        .{ "latin1", .windows1252 },       .{ "l1", .windows1252 },             .{ "ascii", .windows1252 },
        .{ "us-ascii", .windows1252 },     .{ "ansi_x3.4-1968", .windows1252 }, .{ "utf-16", .utf16le },
        .{ "utf-16le", .utf16le },         .{ "utf-16be", .utf16be },
    });
    return map.get(l);
}

fn charsetIn(content_type: []const u8) ?Enc {
    var buf: [128]u8 = undefined;
    const n = @min(content_type.len, buf.len);
    const low = std.ascii.lowerString(buf[0..n], content_type[0..n]);
    const at = std.mem.indexOf(u8, low, "charset") orelse return null;
    var i = at + 7;
    while (i < n and (low[i] == ' ' or low[i] == '\t')) : (i += 1) {}
    if (i >= n or low[i] != '=') return null;
    i += 1;
    while (i < n and (low[i] == ' ' or low[i] == '\t')) : (i += 1) {}
    var e = i;
    if (i < n and (low[i] == '"' or low[i] == '\'')) {
        e = i + 1;
        while (e < n and low[e] != low[i]) : (e += 1) {}
        return label(low[i + 1 .. e]);
    }
    while (e < n and low[e] != ';' and low[e] != ' ' and low[e] != '\t') : (e += 1) {}
    return label(low[i..e]);
}

/// A rough form of the prescan: `<meta` tags with `charset=` in the first
/// 1024 bytes; a comment hides what is inside it.
fn sniffMeta(bytes: []const u8) ?Enc {
    const n = @min(bytes.len, 1024);
    var low_buf: [1024]u8 = undefined;
    const low = std.ascii.lowerString(low_buf[0..n], bytes[0..n]);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, low, i, "<")) |lt| {
        if (std.mem.startsWith(u8, low[lt..], "<!--")) {
            const end = std.mem.indexOfPos(u8, low, lt + 4, "-->") orelse return null;
            i = end + 3;
            continue;
        }
        i = lt + 1;
        if (!std.mem.startsWith(u8, low[lt..], "<meta")) continue;
        const end = std.mem.indexOfScalarPos(u8, low, lt, '>') orelse low.len;
        const tag = low[lt..end];
        if (charsetIn(tag)) |e| {
            // A page that says UTF-16 in ASCII bytes is not UTF-16.
            return if (e == .utf16le or e == .utf16be) .utf8 else e;
        }
    }
    return null;
}

fn appendCp(arena: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch std.unicode.utf8Encode(0xFFFD, &b) catch unreachable;
    try out.appendSlice(arena, b[0..n]);
}

fn fromUtf8(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len + 16);
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c < 0x80) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const want = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (want != 0 and i + want <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + want])) {
            try out.appendSlice(arena, bytes[i .. i + want]);
            i += want;
            continue;
        }
        // One U+FFFD for the lead byte and the continuation bytes it may
        // have started: WHATWG's "maximal subpart" in the common cases.
        i += 1;
        if (want > 1) {
            var taken: usize = 1;
            while (taken < want and i < bytes.len and bytes[i] & 0xC0 == 0x80) : (taken += 1) {
                if (taken == 1 and !secondOk(c, bytes[i])) break;
                i += 1;
            }
        }
        try out.appendSlice(arena, "\u{FFFD}");
    }
    return out.items;
}

fn secondOk(lead: u8, c: u8) bool {
    return switch (lead) {
        0xE0 => c >= 0xA0,
        0xED => c <= 0x9F,
        0xF0 => c >= 0x90,
        0xF4 => c <= 0x8F,
        else => true,
    };
}

fn from1252(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len + bytes.len / 8);
    for (bytes) |c| {
        if (c < 0x80) {
            try out.append(arena, c);
        } else if (c < 0xA0) {
            try appendCp(arena, &out, high[c - 0x80]);
        } else {
            try appendCp(arena, &out, c);
        }
    }
    return out.items;
}

fn fromUtf16(arena: Allocator, bytes: []const u8, big: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, bytes.len / 2 + 16);
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const u = unit(bytes, i, big);
        if (u >= 0xD800 and u < 0xDC00 and i + 3 < bytes.len) {
            const v = unit(bytes, i + 2, big);
            if (v >= 0xDC00 and v < 0xE000) {
                const cp: u21 = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (v - 0xDC00);
                try appendCp(arena, &out, cp);
                i += 2;
                continue;
            }
        }
        try appendCp(arena, &out, if (u >= 0xD800 and u < 0xE000) 0xFFFD else u);
    }
    return out.items;
}

fn unit(b: []const u8, i: usize, big: bool) u16 {
    const hi: u16 = if (big) b[i] else b[i + 1];
    const lo: u16 = if (big) b[i + 1] else b[i];
    return hi << 8 | lo;
}

fn decodeAs(arena: Allocator, bytes: []const u8, enc: Enc) Allocator.Error![]const u8 {
    return switch (enc) {
        .utf8 => fromUtf8(arena, bytes),
        .windows1252 => from1252(arena, bytes),
        .utf16le => fromUtf16(arena, bytes, false),
        .utf16be => fromUtf16(arena, bytes, true),
    };
}

/// The page's text as UTF-8. Valid UTF-8 comes back unchanged and uncopied.
pub fn toUtf8(arena: Allocator, bytes: []const u8, content_type: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return decodeAs(arena, bytes[3..], .utf8);
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return decodeAs(arena, bytes[2..], .utf16be);
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return decodeAs(arena, bytes[2..], .utf16le);
    if (charsetIn(content_type)) |e| return decodeAs(arena, bytes, e);
    if (sniffMeta(bytes)) |e| return decodeAs(arena, bytes, e);
    // No label. Browsers fall to windows-1252 by locale; bytes that are
    // valid UTF-8 almost never were anything else.
    return decodeAs(arena, bytes, if (std.unicode.utf8ValidateSlice(bytes)) .utf8 else .windows1252);
}
