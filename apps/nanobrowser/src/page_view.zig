//! A page's frame: style and layout if they are stale, the display list, the
//! pointer and wheel, and the drawing. Called from the window's view, on the
//! main thread. Nothing here polls: frames come from input and from `redraw`.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const css = @import("css/css.zig");
const box = @import("layout/box.zig");
const layout = @import("layout/layout.zig");
const display = @import("paint/display.zig");
const replay = @import("paint/replay.zig");
const controls = @import("paint/controls.zig");
const svg_markup = @import("paint/svg_markup.zig");
const loader = @import("loader.zig");
const input = @import("page_input.zig");
const web = @import("web/web.zig");
const webfonts = @import("webfonts.zig");
const Page = @import("page.zig").Page;

/// What layout measures with during a frame.
const Fonts = struct {
    p: *Page,
    c: *ui.Context,

    fn width(ctx: *anyopaque, text: []const u8, font: box.Font) f32 {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        // CoreText reads size 0 as its default: `font-size: 0` takes no room.
        if (font.size <= 0) return 0;
        var h = fontHash(font);
        h.update(text);
        const k = h.final();
        if (f.p.widths.get(k)) |w| return w;
        webfonts.need(f.p, f.c, font, text);
        const w = f.c.text.width(text, replay.textStyle(font));
        // A font that came just now isn't in this measure.
        if (!f.p.faces.changed) f.p.widths.put(f.p.gpa, k, w) catch {};
        return w;
    }

    fn metrics(ctx: *anyopaque, font: box.Font) box.Metrics {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (font.size <= 0) return .{ .ascent = 0, .descent = 0, .gap = 0 };
        var h = fontHash(font);
        const k = h.final();
        if (f.p.font_metrics.get(k)) |m| return m;
        webfonts.need(f.p, f.c, font, "");
        const m = lineMetrics(f.c, replay.textStyle(font));
        if (!f.p.faces.changed) f.p.font_metrics.put(f.p.gpa, k, m) catch {};
        return m;
    }

    fn fontHash(font: box.Font) std.hash.Wyhash {
        var h = std.hash.Wyhash.init(@intFromBool(font.italic) + 2 * @as(u64, @intFromBool(font.mono)) + 4 * @as(u64, @intFromBool(font.serif)) + 8 * @as(u64, font.weight) + (@as(u64, font.stretch) << 16) + (@as(u64, @intFromBool(font.tabular)) << 32) + (@as(u64, @intFromBool(font.ligatures)) << 33));
        h.update(std.mem.asBytes(&font.size));
        h.update(font.family);
        return h;
    }

    fn image(ctx: *anyopaque, node: *dom.Node) ?box.Size {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (node.image.len == 0) return null;
        if (replay.isSvg(node.image)) return svgNatural(node.image);
        const s = ui.imageSize(f.c, node.image_key, node.image) orelse return null;
        return .{ .w = s.w, .h = s.h };
    }

    /// An SVG picture's own size; with only a viewBox, its shape alone
    /// (`Measurer.image`); with neither, what any picture without one is.
    fn svgNatural(bytes: []const u8) box.Size {
        const own = replay.svgOwn(bytes);
        if (own.size) |v| return .{ .w = v[0], .h = v[1] };
        if (own.ratio) |r| return .{ .w = -1, .h = r };
        return .{ .w = 300, .h = 150 };
    }

    fn measurer(f: *Fonts) box.Measurer {
        return .{ .ctx = f, .width = width, .metrics = metrics, .image = image };
    }
};

/// A font's line metrics as Chromium has them: each rounded to whole pixels, and on
/// the Mac the ascent of the three classic faces raised to match their Windows
/// counterparts (`FontMetrics::AscentDescentWithHacks`).
pub fn lineMetrics(c: *ui.Context, style: ui.TextStyle) box.Metrics {
    const m = c.text.font(style);
    var ascent = @round(m.ascent);
    const descent = @round(m.descent);
    if (builtin.os.tag == .macos) {
        var buf: [64]u8 = undefined;
        const name = c.text.familyName(style, &buf);
        if (std.mem.eql(u8, name, "Times") or std.mem.eql(u8, name, "Helvetica") or std.mem.eql(u8, name, "Courier")) {
            ascent += @floor((ascent + descent) * 0.15 + 0.5);
        }
    }
    return .{ .ascent = ascent, .descent = descent, .gap = @round(m.leading), .x_height = m.x_height };
}

/// Style and layout brought up to date for a viewport of `w` × `h`.
pub fn prepare(p: *Page, c: *ui.Context, w: f32, h: f32) void {
    webfonts.catchUp(p, c);
    p.engine.now = c.time;
    // Pictures on the web are as large as the screen is dense; the budget is
    // what scrolling back past them shouldn't decode again.
    ui.imageLimits(c, .{ .picture_side = 8192, .atlas_side = 8192, .decoded_bytes = 256 * 1024 * 1024 });
    if (w != p.viewport_w or h != p.viewport_h or c.theme.dark != p.dark) {
        p.viewport_w = w;
        p.viewport_h = h;
        p.dark = c.theme.dark;
        p.engine.setViewport(.{ .width = w, .height = h, .dark = p.dark });
        p.doc.touchStyle();
    }
    flushStyle(p);
    if (p.doc.layout_dirty or p.list == null) {
        relayout(p, c);
    } else if (p.list_dirty or p.doc.svg_dirty) {
        // What an SVG's markup comes to is on the list.
        if (p.doc.svg_dirty) svg_markup.refresh(p);
        var fonts: Fonts = .{ .p = p, .c = c };
        makeList(p, p.tree.?, fonts.measurer());
    }
}

/// What the page wants of frames from what runs on it, and the changes they made.
fn runAnimations(p: *Page, c: *ui.Context) void {
    p.engine.now = c.time;
    const plan = p.engine.anim.tick(&p.engine, c.time);
    if (plan.layout) p.doc.layout_dirty = true;
    if (plan.paint) p.list_dirty = true;
    web.animationEvents(p);
}

fn wantFrames(p: *Page, c: *ui.Context) void {
    if (p.dead) return;
    const plan = p.engine.anim.plan(c.time);
    if (plan.frames) {
        c.animationFrame();
    } else if (plan.wake_in) |seconds| c.frameIn(@max(seconds, 0.001));
}

/// Style brought up to date, as far as what changed reaches. Layout follows
/// when the style is any different, or the tree was already.
pub fn flushStyle(p: *Page) void {
    const d = p.doc;
    if (!d.style_dirty) return;
    loader.scan(p);
    p.title_stale = true;
    d.style_dirty = false;
    if (d.dirty_all) {
        p.engine.restyleAll() catch {};
        d.dirty_all = false;
        d.dirty_nodes.clearRetainingCapacity();
        d.layout_dirty = true;
        return;
    }
    var seen: std.AutoHashMapUnmanaged(*dom.Node, void) = .empty;
    defer seen.deinit(p.gpa);
    for (d.dirty_nodes.items) |n| seen.put(p.gpa, n, {}) catch {};
    for (d.dirty_nodes.items) |n| {
        if (!seen.remove(n)) continue;
        // Under one already done, or no longer in the document: nothing to do.
        var covered = false;
        var connected = false;
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) {
            if (x.kind == .document) connected = true;
            if (x != n and seen.contains(x)) covered = true;
        }
        if (covered or !connected) continue;
        const target = if (n.kind == .document) d.documentElement() orelse continue else n;
        const change = p.engine.restyleChanged(target) catch .layout;
        switch (change) {
            .none => {},
            // Boxes hold the very styles that changed.
            .paint => p.list_dirty = true,
            .layout => d.layout_dirty = true,
        }
    }
    d.dirty_nodes.clearRetainingCapacity();
    d.style_dirty = false;
}

pub fn relayout(p: *Page, c: *ui.Context) void {
    _ = p.layout_arena.reset(.retain_capacity);
    const a = p.layout_arena.allocator();
    var fonts: Fonts = .{ .p = p, .c = c };
    const m = fonts.measurer();
    p.doc.layout_dirty = false;
    const tree = layout.run(a, p.doc, .{ .width = p.viewport_w, .height = p.viewport_h }, m) catch {
        p.tree = null;
        p.list = null;
        return;
    };
    p.tree = tree;
    makeList(p, tree, m);
}

fn makeList(p: *Page, tree: box.Tree, m: box.Measurer) void {
    p.list_dirty = false;
    svg_markup.refresh(p);
    _ = p.list_arena.reset(.retain_capacity);
    p.list = display.build(p.list_arena.allocator(), tree, p.doc.node, m, &p.scrolls) catch null;
    if (p.restore_scroll > 0) if (p.list) |*l| {
        l.clips[1].scroll_y = p.restore_scroll;
    };
}

/// The picture of a background, for `replay`.
const Replay = struct {
    p: *Page,

    pub fn picture(h: Replay, url: []const u8) ?[]const u8 {
        return loader.background(h.p, url);
    }

    /// A `loading=lazy` picture has come near the window.
    pub fn nearLazy(h: Replay, n: *dom.Node) void {
        loader.askImage(h.p, n);
    }

    pub fn gradient(h: Replay, g: @import("css/style.zig").Gradient, w: f32, tile_h: f32, nx: u32, ny: u32, scale: f32) ?[]const u8 {
        return h.p.gradients.get(g, w, tile_h, nx, ny, scale);
    }

    pub fn control(h: Replay, c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
        controls.draw(h.p, c, b, x, y, opacity);
    }
};

/// Draws the page in `rect` (window coordinates) and takes its input.
pub fn view(p: *Page, c: *ui.Context, rect: box.Rect) void {
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    p.origin = .{ rect.x, rect.y };
    p.gradients.beginFrame();
    runAnimations(p, c);
    if (p.dead) return;
    web.frameStart(p);
    defer web.frameEnd(p, c);
    defer wantFrames(p, c);
    if (p.dead) return;
    prepare(p, c, rect.w, rect.h);
    if (p.list != null) p.list.?.resolve(rect.x, rect.y, rect.w, rect.h);
    web.frameLaid(p);
    if (p.dead) return;
    prepare(p, c, rect.w, rect.h);
    if (p.list == null) {
        _ = c.leaf(.{ .absolute = true, .fixed = true, .offset = .{ .x = rect.x, .y = rect.y }, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .background = c.theme.background }, .none, null);
        return;
    }
    const l = &p.list.?;
    l.resolve(rect.x, rect.y, rect.w, rect.h);
    clampScrolls(p, l);
    l.resolve(rect.x, rect.y, rect.w, rect.h);

    const canvas = if (l.canvas.a > 0) replay.color(l.canvas) else if (c.theme.dark and p.state == .failed) c.theme.background else ui.Color.white;
    c.next_key_int = @intFromPtr(p);
    const root = c.open(.{
        .absolute = true,
        .fixed = true,
        .offset = .{ .x = rect.x, .y = rect.y },
        .width = .{ .px = rect.w },
        .height = .{ .px = rect.h },
        .clip = true,
        .wheel = true,
        .selectable = true,
        .background = canvas,
    }, null);
    defer c.end();
    const it = c.interact(root, .{});
    c.wants_moves = true;
    c.wants_wheel = true;
    const mouse = c.input.mouse;
    const inside = rect.contains(mouse.x, mouse.y);
    var hovered: ?*dom.Node = null;
    if (inside) hovered = l.hit(mouse.x, mouse.y);
    input.pointer(p, c, it, hovered, mouse.x, mouse.y, inside);
    if (p.dead) return;
    if (p.doc.layout_dirty or p.doc.style_dirty) {
        // What the pointer did restyled it, or a script changed it: this
        // frame shows that.
        prepare(p, c, rect.w, rect.h);
        if (p.list == null) return;
        p.list.?.resolve(rect.x, rect.y, rect.w, rect.h);
    }
    web.keys(p, c);
    if (p.dead) return;
    var wheel_taken = false;
    if (inside and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) {
        wheel_taken = web.wheel(p, hovered, mouse.x, mouse.y, -c.input.scroll.x, -c.input.scroll.y, .{ .ctrl = c.input.ctrl, .shift = c.input.shift, .alt = c.input.alt, .meta = c.input.cmd });
        if (p.dead) return;
    }
    if (p.doc.layout_dirty or p.doc.style_dirty) prepare(p, c, rect.w, rect.h);
    if (p.list == null) return;
    const shown = &p.list.?;
    shown.resolve(rect.x, rect.y, rect.w, rect.h);
    if (inside and !wheel_taken and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) wheel(p, shown, mouse.x, mouse.y, c.input.scroll.x, c.input.scroll.y);
    if (inside) keyScroll(p, c, shown, rect.h);
    shown.resolve(rect.x, rect.y, rect.w, rect.h);
    web.paintStart(p);
    replay.replay(c, shown, Replay{ .p = p }, rect);
    @import("find.zig").draw(p, c, shown, rect);
    scrollbar(c, shown, rect);
    controls.selectList(p, c, rect);
    web.paintEnd(p);
}

fn wheel(p: *Page, l: *display.List, x: f32, y: f32, dx: f32, dy: f32) void {
    const i = l.scrollerAt(x, y);
    scrollBy(p, l, i, -dx, -dy);
}

pub fn scrollBy(p: *Page, l: *display.List, i: u32, dx: f32, dy: f32) void {
    const c = &l.clips[i];
    const m = l.maxScroll(i);
    c.scroll_x = std.math.clamp(c.scroll_x + dx, 0, m[0]);
    c.scroll_y = std.math.clamp(c.scroll_y + dy, 0, m[1]);
    p.restore_scroll = 0;
    const key = if (i == 1) p.doc.node else c.node orelse return;
    p.scrolls.put(p.gpa, key, .{ c.scroll_x, c.scroll_y }) catch {};
    web.scrolled(p, key);
}

/// Goes to a place in the document: a fragment, a found word.
pub fn scrollPageTo(p: *Page, y: f32) void {
    const l = if (p.list) |*x| x else return;
    const c = &l.clips[1];
    scrollBy(p, l, 1, 0, y - c.scroll_y);
}

fn clampScrolls(p: *Page, l: *display.List) void {
    _ = p;
    for (l.clips, 0..) |*c, i| {
        if (i == 0) continue;
        const m = l.maxScroll(@intCast(i));
        c.scroll_x = std.math.clamp(c.scroll_x, 0, m[0]);
        c.scroll_y = std.math.clamp(c.scroll_y, 0, m[1]);
    }
}

/// The keys that move a page when nothing is being typed in.
fn keyScroll(p: *Page, c: *ui.Context, l: *display.List, h: f32) void {
    if (c.focus != 0) return;
    const step: f32 = 48;
    if (c.input.key) |k| switch (k) {
        .up => scrollBy(p, l, 1, 0, -step),
        .down => scrollBy(p, l, 1, 0, step),
        .left => scrollBy(p, l, 1, -step, 0),
        .right => scrollBy(p, l, 1, step, 0),
        .page_up => scrollBy(p, l, 1, 0, -(h - step)),
        .page_down => scrollBy(p, l, 1, 0, h - step),
        .home => scrollBy(p, l, 1, 0, -1e9),
        .end => scrollBy(p, l, 1, 0, 1e9),
        else => {},
    };
    if (c.shortcut(.{ .key = ' ' })) scrollBy(p, l, 1, 0, h - step);
    if (c.shortcut(.{ .key = ' ', .shift = true })) scrollBy(p, l, 1, 0, -(h - step));
}

/// A slim bar along the right while there's more page than window.
fn scrollbar(c: *ui.Context, l: *const display.List, rect: box.Rect) void {
    const page = l.clips[1];
    if (page.content_h <= rect.h + 1) return;
    const k = rect.h / page.content_h;
    const bar_h = @max(24, rect.h * k);
    const y = (rect.h - bar_h) * page.scroll_y / @max(1, page.content_h - rect.h);
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = rect.w - 7, .y = y + 2 },
        .width = .{ .px = 5 },
        .height = .{ .px = bar_h - 4 },
        .radius = 2.5,
        .corner_circular = true,
        .background = if (c.theme.dark) ui.Color.white.alpha(0.25) else ui.Color.black.alpha(0.22),
    }, .none, null);
}
