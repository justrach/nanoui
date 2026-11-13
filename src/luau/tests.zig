const std = @import("std");
const ui = @import("nanoui").ui;
const mod = @import("luau.zig");
const testing = std.testing;
const input: mod.Input = .{ .width = 320, .height = 220 };

const scene =
    \\return function(c)
    \\ return ui.layer { id = "scene", width = c.width, height = c.height, children = {
    \\  ui.rect { id = "land", width = 200, height = 100, color = 0x506070,
    \\   motion = ui.spring { x = (c.pointer_x - .5) * 24, y = 0 } },
    \\  ui.text { id = "title", text = "Synthetic scene", color = 0xffffff },
    \\ } }
    \\end
;

test "Luau renders owned native trees with host inputs and typed motion" {
    const vm = try mod.Runtime.create(testing.allocator, scene);
    defer vm.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try vm.render(arena.allocator(), input);
    try testing.expectEqual(@as(f32, 320), n.width);
    try testing.expectEqualStrings("Synthetic scene", n.children[1].text);
    const moved = try vm.render(arena.allocator(), .{ .width = 320, .height = 220, .pointer_x = 1 });
    try testing.expectEqual(@as(f32, 12), moved.children[0].motion.?.x);
    // Earlier strings remain owned even after another render and VM teardown.
    try testing.expectEqualStrings("Synthetic scene", n.children[1].text);
}

test "Luau sandbox has no ambient host capabilities and freezes globals and input" {
    for ([_][]const u8{
        "assert(os == nil and io == nil and debug == nil and require == nil and loadstring == nil and getfenv == nil and print == nil); return function(c) return ui.rect{id='ok'} end",
        "return function(c) assert(not pcall(function() c.width=4 end)); return ui.rect{id='ok'} end",
        "return function(c) assert(not pcall(function() math.pi=0 end)); return ui.rect{id='ok'} end",
    }) |source| {
        const vm = try mod.Runtime.create(testing.allocator, source);
        defer vm.destroy();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        _ = try vm.render(arena.allocator(), input);
    }
}

test "Luau rejects bad trees and retires a failing runtime" {
    for ([_][]const u8{
        "return function() return ui.rect{id='x', width=0/0} end",
        "return function() return ui.rect{id='x', color=1/0} end",
        "return function() return ui.rect{id='x', width='12'} end",
        "return function() return ui.rect{id='x', onClick=function()end} end",
        "return function() return ui.column{id='x',children={[2]=ui.rect{id='y'}}} end",
        "return function() return ui.column{id='x',children={ui.rect{id='x'}}} end",
        "return function() return ui.rect{id='x',motion=ui.spring{x=9999}} end",
        "return function() local t={};t[1]=ui.column{id='y',children=t};return ui.column{id='x',children=t} end",
        "return function() return setmetatable({kind='rect',id='x'},{__index=function()while true do end end}) end",
    }, 0..) |source, i| {
        const vm = try mod.Runtime.create(testing.allocator, source);
        defer vm.destroy();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const result = vm.render(arena.allocator(), input);
        if (i == 8) {
            // Missing properties use raw nil, not the hostile __index.
            _ = try result;
        } else {
            if (result) |_| return error.AcceptedInvalidTree else |_| {}
            try testing.expectError(error.RuntimeFailed, vm.render(arena.allocator(), input));
        }
    }
}

test "Luau cooperative execution and VM memory budgets fail closed" {
    for ([_][]const u8{
        "return function() while true do end end",
        "return function() while true do pcall(function() while true do end end) end end",
        "return function() local a={}; while true do table.insert(a,string.rep('x',1000000)) end end",
    }) |source| {
        const vm = try mod.Runtime.create(testing.allocator, source);
        defer vm.destroy();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        if (vm.render(arena.allocator(), input)) |_| return error.UnboundedScript else |_| {}
        try testing.expect(vm.used <= mod.max_memory);
        try testing.expectError(error.RuntimeFailed, vm.render(arena.allocator(), input));
    }
}

test "Luau source, geometry, depth and node limits" {
    const source = try testing.allocator.alloc(u8, mod.max_source + 1);
    defer testing.allocator.free(source);
    try testing.expectError(error.SourceLimit, mod.Runtime.create(testing.allocator, source));
    const vm = try mod.Runtime.create(testing.allocator, "return function() local n=ui.rect{id='leaf'};for i=1,20 do n=ui.column{id=tostring(i),children={n}} end;return n end");
    defer vm.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidInput, vm.render(arena.allocator(), .{ .width = std.math.nan(f64), .height = 10 }));
    try testing.expectError(error.TreeLimit, vm.render(arena.allocator(), input));
}

const Demo = struct {
    node: mod.Node,
    fn view(self: *Demo, c: *ui.Context) void {
        const host = ui.div(c).column().size(320, 220).clip();
        defer host.end();
        mod.draw(c, self.node);
    }
};

test "Luau native motion interrupts, settles without idle frames, and honors Reduce Motion" {
    const vm = try mod.Runtime.create(testing.allocator, scene);
    defer vm.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var demo = Demo{ .node = try vm.render(arena.allocator(), input) };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&demo, Demo.view), .{ .width = 320, .height = 220 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(t.hasText("Synthetic scene"));
    demo.node = try vm.render(arena.allocator(), .{ .width = 320, .height = 220, .pointer_x = 1 });
    t.settle(0.03);
    try testing.expect(t.ctx.animating);
    demo.node = try vm.render(arena.allocator(), .{ .width = 320, .height = 220, .pointer_x = 0 });
    t.settle(2);
    try testing.expect(!t.ctx.animating);
    t.ctx.reduced_motion = true;
    demo.node = try vm.render(arena.allocator(), .{ .width = 320, .height = 220, .pointer_x = 1 });
    t.settle(0.02);
    try testing.expect(!t.ctx.animating);
}
