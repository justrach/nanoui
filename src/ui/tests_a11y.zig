//! Accessibility elements' payloads (macOS): labels and values of any length.
const std = @import("std");
const a11y = @import("a11y.zig");
const testing = std.testing;

test "label longer than 128 bytes survives" {
    const gpa = testing.allocator;
    var p: a11y.ElementPayload = .{ .surface = undefined, .id = 1, .role = .button };
    defer p.deinit(gpa);
    const long = "A page title that goes on and on, as titles of news articles and documentation pages do, well past what a fixed buffer of 128 bytes kept";
    try testing.expect(long.len > 128);
    p.update(gpa, .{ .id = 1, .node_index = 0, .role = .row, .label = long, .value = "v" });
    try testing.expectEqualStrings(long, p.label);
    try testing.expectEqualStrings("v", p.value);
    try testing.expectEqual(.row, p.role);
    // Updated in place, the old copy freed (the allocator checks).
    p.update(gpa, .{ .id = 1, .node_index = 0, .role = .row, .label = "short" });
    try testing.expectEqualStrings("short", p.label);
    try testing.expectEqualStrings("", p.value);
}
