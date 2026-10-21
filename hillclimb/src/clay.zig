//! Clay's twin (github.com/nicbarker/clay, v0.14, a C layout library): the
//! same scenes declared through Clay's element API, laid out and turned into
//! its render commands each frame. Clay draws nothing itself (its renderers
//! are separate), so it reports frame CPU (declaring, laying out, render
//! commands: what nanoui's build, layout and paint make) and the commands
//! a renderer would draw; no GPU columns. Its text is measured by nanoui's
//! text system, as nanoui's own is. Clay has no shadows or offsets: its
//! boxes are drawn flat, and the scroll scene moves Clay's child offset.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const c = @import("clay");
const main = @import("main.zig");
const scenes = @import("scenes.zig");


/// What Clay's measure function reads: nanoui's text system.
const TextSystem = @FieldType(ui.Tester, "text");
var text_system: *TextSystem = undefined;

fn measure(s: c.Clay_StringSlice, config: [*c]c.Clay_TextElementConfig, _: ?*anyopaque) callconv(.c) c.Clay_Dimensions {
    const str = s.chars[0..@intCast(s.length)];
    const style: ui.TextStyle = .{ .size = @floatFromInt(config.*.fontSize) };
    return .{ .width = text_system.width(str, style), .height = text_system.lineHeight(style) };
}

fn onError(e: c.Clay_ErrorData) callconv(.c) void {
    std.debug.print("clay: {s}\n", .{e.errorText.chars[0..@intCast(e.errorText.length)]});
}

fn fixed(px: f32) c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = px, .max = px } }, .type = c.CLAY__SIZING_TYPE_FIXED };
}

fn grow() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_GROW };
}

fn fit() c.Clay_SizingAxis {
    return .{ .size = .{ .minMax = .{ .min = 0, .max = 0 } }, .type = c.CLAY__SIZING_TYPE_FIT };
}

fn open(d: c.Clay_ElementDeclaration) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(d);
}

const close = c.Clay__CloseElement;

fn color(col: ui.Color) c.Clay_Color {
    return .{ .r = col.r * 255, .g = col.g * 255, .b = col.b * 255, .a = col.a * 255 };
}

fn radius(r: f32) c.Clay_CornerRadius {
    return .{ .topLeft = r, .topRight = r, .bottomLeft = r, .bottomRight = r };
}

fn pad(x: u16, y: u16) c.Clay_Padding {
    return .{ .left = x, .right = x, .top = y, .bottom = y };
}

/// A text element of `s` (kept until the frame's commands are read).
fn text(arena: std.mem.Allocator, size: u16, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    const config = c.Clay__StoreTextElementConfig(.{ .fontSize = size, .textColor = .{ .r = 20, .g = 20, .b = 20, .a = 255 }, .wrapMode = c.CLAY_TEXT_WRAP_NONE });
    c.Clay__OpenTextElement(.{ .isStaticallyAllocated = false, .length = @intCast(s.len), .chars = s.ptr }, config);
}

fn declare(arena: std.mem.Allocator, scene: scenes.Scene, frame: usize, t: f32) void {
    switch (scene) {
        .boxes => {
            open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = grow() }, .padding = pad(10, 10), .childGap = 4, .layoutDirection = c.CLAY_TOP_TO_BOTTOM } });
            for (0..20) |r| {
                open(.{ .layout = .{ .childGap = 4 } });
                for (0..30) |col| {
                    const i: f32 = @floatFromInt(r * 30 + col);
                    open(.{ .layout = .{ .sizing = .{ .width = fixed(24), .height = fixed(24) } }, .backgroundColor = color(scenes.hsl(@mod(t * 60 + i * 3, 360))), .cornerRadius = radius(6) });
                    close();
                }
                close();
            }
            close();
        },
        .text => {
            open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = grow() }, .padding = pad(10, 10), .childGap = 6, .layoutDirection = c.CLAY_TOP_TO_BOTTOM } });
            for (0..15) |r| {
                open(.{ .layout = .{ .childGap = 4 } });
                for (0..20) |col| {
                    const i = r * 20 + col;
                    open(.{ .layout = .{ .sizing = .{ .width = fixed(40), .height = fit() } } });
                    text(arena, 13, "{d}", .{(frame * 7 + i * 13) % 10000});
                    close();
                }
                close();
            }
            close();
        },
        .scroll => {
            const rows = 1000;
            const offset = @mod(t * 600, 28 * rows - 640);
            open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = grow() }, .layoutDirection = c.CLAY_TOP_TO_BOTTOM }, .clip = .{ .vertical = true, .childOffset = .{ .x = 0, .y = -offset } } });
            for (0..rows) |i| row(arena, i);
            close();
        },
        .list => {
            // Virtualized as nanoui's list is: only the rows in view.
            const first = (frame * 3) % (100_000 - 40);
            open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = grow() }, .layoutDirection = c.CLAY_TOP_TO_BOTTOM }, .clip = .{ .vertical = true } });
            for (first..first + main.height / 28 + 1) |i| row(arena, i);
            close();
        },
        .springs, .letters => {},
        .dashboard => {
            open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = grow() }, .padding = pad(16, 16), .childGap = 12, .layoutDirection = c.CLAY_TOP_TO_BOTTOM } });
            for (0..3) |r| {
                open(.{ .layout = .{ .childGap = 12 } });
                for (0..4) |col| {
                    const i = r * 4 + col;
                    const v = 0.5 + 0.5 * @sin(t * 2 + @as(f32, @floatFromInt(i)));
                    open(.{ .layout = .{ .sizing = .{ .width = fixed(200), .height = fit() }, .padding = pad(14, 14), .childGap = 8, .layoutDirection = c.CLAY_TOP_TO_BOTTOM }, .backgroundColor = color(.white), .cornerRadius = radius(12) });
                    text(arena, 13, "Metric {d}", .{i});
                    text(arena, 28, "{d}", .{@as(u32, @intFromFloat(v * 1000))});
                    open(.{ .layout = .{ .sizing = .{ .width = fixed(172), .height = fixed(6) } }, .backgroundColor = color(.hex(0xe0e0e5)), .cornerRadius = radius(3) });
                    open(.{ .layout = .{ .sizing = .{ .width = fixed(172 * v), .height = fixed(6) } }, .backgroundColor = color(.hex(0x0a84ff)), .cornerRadius = radius(3) });
                    close();
                    close();
                    text(arena, 11, "updated {d}s ago", .{frame % 60});
                    close();
                }
                close();
            }
            close();
        },
    }
}

/// A row of the scroll and list scenes: its label, a spacer, a number.
fn row(arena: std.mem.Allocator, i: usize) void {
    open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = fixed(28) }, .padding = pad(12, 0), .childGap = 8, .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER } } });
    text(arena, 13, "Row {d} \u{2014} a line of a long list", .{i});
    open(.{ .layout = .{ .sizing = .{ .width = grow(), .height = fit() } } });
    close();
    text(arena, 12, "{d}", .{i * 7 % 100});
    close();
}

/// Runs `scene` with Clay: declared, laid out and its render commands
/// made, frame after frame.
pub fn run(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize) !main.Result {
    // nanoui's text system, for Clay's measurements (no frames drawn).
    var page: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&page, struct {
        fn v(_: *u8, _: *ui.Context) void {}
    }.v), .{ .width = main.width, .height = main.height, .scale = main.scale });
    defer t.deinit();
    text_system = &t.text;

    c.Clay_SetMaxElementCount(16384);
    const size = c.Clay_MinMemorySize();
    const memory = try gpa.alloc(u8, size);
    defer gpa.free(memory);
    _ = c.Clay_Initialize(c.Clay_CreateArenaWithCapacityAndMemory(size, memory.ptr), .{ .width = main.width, .height = main.height }, .{ .errorHandlerFunction = onError });
    c.Clay_SetMeasureTextFunction(measure, null);

    const frame_ms = try gpa.alloc(f64, frames);
    defer gpa.free(frame_ms);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var commands: usize = 0;
    for (0..main.warmup + frames) |i| {
        _ = arena_state.reset(.retain_capacity);
        t.text.beginFrame();
        const time = @as(f32, @floatFromInt(i)) / 120;
        const t0 = ui.clock.now();
        c.Clay_SetLayoutDimensions(.{ .width = main.width, .height = main.height });
        c.Clay_BeginLayout();
        declare(arena_state.allocator(), scene, i, time);
        const cmds = c.Clay_EndLayout();
        const ft = (ui.clock.now() - t0) * 1000;
        commands = @intCast(cmds.length);
        if (i >= main.warmup) frame_ms[i - main.warmup] = ft;
    }
    return .{
        .fw = "clay",
        .scene = @tagName(scene),
        .frames = frames,
        .frame_ms = main.medianOf(frame_ms),
        .frame_p95 = main.p95Of(frame_ms),
        .encode_ms = 0,
        .gpu_ms = 0,
        // Its process time would be layout alone, no renderer's: not
        // comparable with the others', so not reported.
        .cpu_ms = 0,
        .ops = commands,
    };
}
