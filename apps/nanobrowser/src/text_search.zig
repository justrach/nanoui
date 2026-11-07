//! Finding text without regard to ASCII case.
const std = @import("std");

/// Where `needle` first appears in `hay` at or after `from`.
pub fn find(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return from;
    if (hay.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "found in any case" {
    try std.testing.expectEqual(@as(?usize, 2), find("a Bird", 0, "bIRD"));
    try std.testing.expectEqual(@as(?usize, null), find("a Bird", 3, "bird"));
    try std.testing.expectEqual(@as(?usize, null), find("", 0, "x"));
}
