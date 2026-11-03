//! Words for the screen: OneMap's place names come in capitals ("JURONG
//! EAST MRT STATION (EW24 / NS1)"); shown in title case, with codes,
//! acronyms and what's in brackets kept as they are.
const std = @import("std");

const keep = [_][]const u8{ "MRT", "LRT", "HDB", "NUS", "NTU", "SMU", "SUTD", "SIT", "SUSS", "ITE", "SP", "NP", "TP", "RP", "NYP", "MBS", "CBD", "ION", "NEX", "SAFRA", "NTUC", "YMCA", "YWCA", "CHIJ", "ACS", "SJI", "PCF", "MOE", "ICA", "LTA", "URA", "UOB", "OCBC", "DBS", "KFC", "II", "III", "IV" };
const small = [_][]const u8{ "of", "the", "and", "at", "by", "in", "on", "to", "for", "de" };

/// `in` in title case into `buf`, if it has no lowercase letter; else `in`.
pub fn titleCase(buf: []u8, in: []const u8) []const u8 {
    for (in) |ch| if (std.ascii.isLower(ch)) return in;
    const n = @min(in.len, buf.len);
    @memcpy(buf[0..n], in[0..n]);
    const out = buf[0..n];
    var depth: u32 = 0;
    var i: usize = 0;
    var first = true;
    while (i < n) {
        const ch = out[i];
        if (ch == '(') depth += 1;
        if (ch == ')') depth -|= 1;
        if (!std.ascii.isAlphanumeric(ch)) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and (std.ascii.isAlphanumeric(out[j]) or out[j] == '\'')) j += 1;
        const word = out[i..j];
        if (depth == 0 and !hasDigit(word) and !isKept(word)) {
            for (word[1..]) |*w| w.* = std.ascii.toLower(w.*);
            if (!first and isSmall(word)) word[0] = std.ascii.toLower(word[0]);
        }
        first = false;
        i = j;
    }
    return out;
}

fn hasDigit(w: []const u8) bool {
    for (w) |ch| if (std.ascii.isDigit(ch)) return true;
    return false;
}

fn isKept(w: []const u8) bool {
    for (keep) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

fn isSmall(w: []const u8) bool {
    for (small) |k| if (std.ascii.eqlIgnoreCase(k, w)) return true;
    return false;
}

test "OneMap's capitals read as names" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Jurong East MRT Station (EW24 / NS1)", titleCase(&b, "JURONG EAST MRT STATION (EW24 / NS1)"));
    try std.testing.expectEqualStrings("Marina Bay Sands", titleCase(&b, "MARINA BAY SANDS"));
    try std.testing.expectEqualStrings("Blk 123 Ang Mo Kio Ave 6", titleCase(&b, "BLK 123 ANG MO KIO AVE 6"));
    try std.testing.expectEqualStrings("St. Andrew's Cathedral", titleCase(&b, "ST. ANDREW'S CATHEDRAL"));
    try std.testing.expectEqualStrings("The Shoppes at Marina Bay Sands", titleCase(&b, "THE SHOPPES AT MARINA BAY SANDS"));
    try std.testing.expectEqualStrings("NUS Faculty of Science", titleCase(&b, "NUS FACULTY OF SCIENCE"));
    // Already mixed case: left alone.
    try std.testing.expectEqualStrings("Suntec City", titleCase(&b, "Suntec City"));
}
