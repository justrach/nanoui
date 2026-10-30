const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const App = @import("app.zig").App;

const Page = struct {
    open: bool = false,

    fn view(p: *Page, c: *ui.Context) void {
        const root = ui.div(c).p(20);
        defer root.end();
        const f = ui.motion.frame(c, .{
            .target = .{
                .width = if (p.open) 280 else 180,
                .height = if (p.open) 150 else 96,
                .radius = if (p.open) 24 else 14,
                .background = if (p.open) c.theme.accent else c.theme.surface,
            },
            .press = .{ .scale = 0.96 },
            .transition = .{ .spring = ui.motion.Spring.bouncy },
        });
        const card = ui.div(c).column().p(16).border(c.theme.border).clip().control().motion(f);
        defer card.end();
        if (card.clicked()) p.open = !p.open;
        ui.text(c, if (p.open) "Open" else "Click me", .{ .weight = .semibold });
    }
};

test "a motion click and its animated frames draw through a hidden Windows surface" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var p: Page = .{};
    const win = try app.newWindow(.{
        .title = "hidden motion test",
        .width = 400,
        .height = 300,
        .visible = false,
        .content = .{ .view = .init(&p, Page.view) },
    });
    const s = win.surface.?;
    var at: ui.Point = .{};
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| {
            if (std.mem.eql(u8, t.str, "Click me")) at = .{ .x = n.rect.x + n.rect.w / 2, .y = n.rect.y + n.rect.h / 2 };
        },
        else => {},
    };
    try testing.expect(at.x > 0);
    s.ctx.input.mouse = at;
    s.ctx.updateHot();
    s.ctx.pointerDown();
    s.frame();
    s.ctx.pointerUp();
    s.frame();
    try testing.expect(p.open);
    for (0..120) |_| {
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(16), .awake) catch {};
        s.frame();
        s.pixels.draw(gpa, .{
            .instances = s.instances.items,
            .text = &s.text,
            .clear = s.ctx.theme.background,
            .size = s.size,
            .scale = s.scale,
            .textures = s.ctx.textures.items,
        });
    }
}

const Reenter = struct {
    /// Set on the surface the view reaches for, so the view can call back into
    /// it while it is building: what the shell's message pump does.
    surface: ?*@import("surface.zig").Surface = null,
    builds: u32 = 0,
    reentered: bool = false,

    fn view(r: *Reenter, c: *ui.Context) void {
        r.builds += 1;
        const root = ui.div(c).p(10);
        defer root.end();
        ui.text(c, "building", .{});
        // The first build calls back: asking for a frame while one is building
        // must be queued, not run inside it.
        if (r.builds == 1 and !r.reentered) {
            r.reentered = true;
            if (r.surface) |s| s.frame();
        }
    }
};

test "a frame asked for while one is building is queued, not run inside it" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var r: Reenter = .{};
    const win = try app.newWindow(.{
        .title = "hidden reentry test",
        .width = 200,
        .height = 120,
        .visible = false,
        .content = .{ .view = .init(&r, Reenter.view) },
    });
    const s = win.surface.?;
    r.surface = s;
    // Builds once here, then twice more inside the call the view makes.
    s.frame();
    try testing.expect(r.reentered);
    // The nested call was queued, not run inside the one that asked: the build
    // it asked for came after, so the view built twice and never recursed.
    try testing.expectEqual(@as(u32, 2), r.builds);
    try testing.expect(!s.in_frame);
}
