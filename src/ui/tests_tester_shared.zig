//! Testers lent one renderer and text system (`ui.TesterShared`): what was
//! found and shaped stays warm from one to the next, and nothing a view set
//! reaches the view after it.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Page = struct {
    zoom: f32 = 1,
    fn view(p: *Page, c: *ui.Context) void {
        if (p.zoom != 1) c.setZoom(p.zoom);
        ui.text(c, "Shared caches, a fresh context", .{ .size = 13 });
    }
};

fn themed(family: []const u8) ui.Theme {
    var th = ui.Theme.light;
    th.font = family;
    return th;
}

test "Testers lent one renderer and text system keep its caches, not a view's settings" {
    const gpa = testing.allocator;
    var shared: ui.TesterShared = undefined;
    try shared.init(gpa);
    defer shared.deinit();

    // A view that zooms, under a theme whose family is gone when it is.
    {
        const family = try gpa.dupe(u8, "No Such Family");
        defer gpa.free(family);
        var page: Page = .{ .zoom = 2 };
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&page, Page.view), .{ .shared = &shared, .theme = themed(family) });
        defer t.deinit();
        try testing.expect(t.text == &shared.text);
        try testing.expect(t.hasText("Shared caches, a fresh context"));
        try testing.expectEqual(@as(f32, 2), shared.text.zoom);
    }
    // The family's name is the shared copy's now, the zoom put back.
    try testing.expectEqualStrings("No Such Family", shared.text.family.?);
    try testing.expect(shared.text.family.?.ptr == &shared.family);

    var page: Page = .{};
    {
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&page, Page.view), .{ .shared = &shared });
        defer t.deinit();
        try testing.expectEqual(@as(f32, 1), shared.text.zoom);
        try testing.expect(t.hasText("Shared caches, a fresh context"));
    }
    // What the last view shaped is still there for the next.
    const shaped = shared.text.layouts.count();
    try testing.expect(shaped > 0);
    {
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&page, Page.view), .{ .shared = &shared });
        defer t.deinit();
        try testing.expect(shared.text.layouts.count() >= shaped);
        try testing.expect(t.hasText("Shared caches, a fresh context"));
    }
    // A picture is known by its view's key: none outlives its Tester.
    try testing.expectEqual(@as(usize, 0), shared.text.images.pixels.len);
}

test "a shared renderer and text system go to one Tester at a time" {
    const gpa = testing.allocator;
    var shared: ui.TesterShared = undefined;
    try shared.init(gpa);
    defer shared.deinit();
    var page: Page = .{};
    var a: ui.Tester = undefined;
    try a.init(gpa, .init(&page, Page.view), .{ .shared = &shared });
    defer a.deinit();
    var b: ui.Tester = undefined;
    try testing.expectError(error.SharedInUse, b.init(gpa, .init(&page, Page.view), .{ .shared = &shared }));
}

test "the process's shared renderer and text system wait while a Tester has them" {
    const gpa = testing.allocator;
    const shared = (try ui.TesterShared.process()).?;
    var page: Page = .{};
    {
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&page, Page.view), .{ .shared = shared });
        defer t.deinit();
        // A second window open at once makes its own.
        try testing.expect(try ui.TesterShared.process() == null);
    }
    try testing.expect(try ui.TesterShared.process() == shared);
}
