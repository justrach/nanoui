//! A page's frame: style and layout if they are stale, the display list, the
//! pointer and wheel, and the drawing. Called from the window's view, on the
//! main thread. Nothing here polls: frames come from input and from `redraw`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const css = @import("css/css.zig");
const box = @import("layout/box.zig");
const layout = @import("layout/layout.zig");
const display = @import("paint/display.zig");
const replay = @import("paint/replay.zig");
const controls = @import("paint/controls.zig");
const loader = @import("loader.zig");
const input = @import("page_input.zig");
const frames = @import("frames.zig");
const web = @import("web/web.zig");
const Page = @import("page.zig").Page;

/// What layout measures with during a frame.
const Fonts = struct {
    p: *Page,
    c: *ui.Context,

    fn width(ctx: *anyopaque, text: []const u8, font: box.Font) f32 {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        // CoreText reads size 0 as its default: `font-size: 0` takes no room.
        if (font.size <= 0) return 0;
        var h = std.hash.Wyhash.init(@intFromBool(font.italic) + 2 * @as(u64, @intFromBool(font.mono)) + 4 * @as(u64, @intFromBool(font.serif)) + 8 * @as(u64, font.weight));
        h.update(std.mem.asBytes(&font.size));
        h.update(text);
        const k = h.final();
        if (f.p.widths.get(k)) |w| return w;
        const w = f.c.text.width(text, replay.textStyle(font));
        f.p.widths.put(f.p.gpa, k, w) catch {};
        return w;
    }

    fn metrics(ctx: *anyopaque, font: box.Font) box.Metrics {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (font.size <= 0) return .{ .ascent = 0, .descent = 0, .gap = 0 };
        const m = f.c.text.font(replay.textStyle(font));
        return .{ .ascent = m.ascent, .descent = m.descent, .gap = m.leading };
    }

    fn image(ctx: *anyopaque, node: *dom.Node) ?box.Size {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (node.image.len == 0) return null;
        if (replay.isSvg(node.image)) {
            const v = replay.svgSize(node.image) orelse return null;
            return .{ .w = v[0], .h = v[1] };
        }
        const s = ui.imageSize(f.c, node.image_key, node.image) orelse return null;
        return .{ .w = s.w, .h = s.h };
    }

    fn measurer(f: *Fonts) box.Measurer {
        return .{ .ctx = f, .width = width, .metrics = metrics, .image = image };
    }
};

/// Style and layout brought up to date for a viewport of `w` × `h`.
pub fn prepare(p: *Page, c: *ui.Context, w: f32, h: f32) void {
    if (w != p.viewport_w or h != p.viewport_h or c.theme.dark != p.dark) {
        p.viewport_w = w;
        p.viewport_h = h;
        p.dark = c.theme.dark;
        p.engine.setViewport(.{ .width = w, .height = h, .dark = p.dark });
        p.doc.touchStyle();
    }
    flushStyle(p);
    if (p.doc.layout_dirty or p.list == null) relayout(p, c);
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
        if (change != .none) d.layout_dirty = true;
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
    var tree = layout.run(a, p.doc, .{ .width = p.viewport_w, .height = p.viewport_h }, m) catch {
        p.tree = null;
        p.list = null;
        return;
    };
    // A container's size decides its contents' style. Each pass settles a level.
    var passes: u8 = 0;
    while (passes < 4 and layout.updateContainers(&p.engine)) : (passes += 1) {
        _ = p.layout_arena.reset(.retain_capacity);
        tree = layout.run(a, p.doc, .{ .width = p.viewport_w, .height = p.viewport_h }, m) catch {
            p.tree = null;
            p.list = null;
            return;
        };
    }
    p.doc.layout_dirty = false;
    p.tree = tree;
    p.list = display.build(a, tree, p.doc.node, m, &p.scrolls) catch null;
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

    pub fn gradient(h: Replay, g: @import("css/style.zig").Gradient) ?[]const u8 {
        return h.p.gradients.get(g);
    }

    pub fn control(h: Replay, c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
        controls.draw(h.p, c, b, x, y, opacity);
    }

    /// An `<iframe>`: what its page came to, drawn in its box.
    pub fn frame(h: Replay, c: *ui.Context, n: *dom.Node, x: f32, y: f32, r: box.Rect) void {
        const child = frames.childPage(h.p, n) orelse return;
        drawFrame(child, c, x, y, r);
    }
};

/// Everything a frame's page does before anything is drawn: scripts' turn, style and
/// layout, then the same for the frames in it. Nothing draws, so what scripts do can't
/// pull a list out from under its replay.
fn advanceFrames(p: *Page, c: *ui.Context) void {
    const l = if (p.list) |*x| x else return;
    frames.schedule(p);
    for (l.frames) |it| {
        const child = frames.childPage(p, it.kind.image.node) orelse continue;
        const clip = l.clips[it.clip];
        const r = l.placed(it);
        const f = child.frame.?;
        f.rect = r;
        child.origin = .{ r.x, r.y };
        if (clip.visible.w <= 0 or clip.visible.h <= 0) continue;
        if (r.x >= clip.visible.x + clip.visible.w or r.x + r.w <= clip.visible.x or r.y >= clip.visible.y + clip.visible.h or r.y + r.h <= clip.visible.y) continue;
        if (r.w <= 0 or r.h <= 0) continue;
        child.busy += 1;
        web.frameStart(child);
        if (!child.dead) {
            prepare(child, c, r.w, r.h);
            if (child.list != null) child.list.?.resolve(r.x, r.y, r.w, r.h);
            web.frameLaid(child);
        }
        if (!child.dead) {
            prepare(child, c, r.w, r.h);
            if (child.list != null) {
                const cl = &child.list.?;
                cl.resolve(r.x, r.y, r.w, r.h);
                clampScrolls(child, cl);
                cl.resolve(r.x, r.y, r.w, r.h);
            }
            advanceFrames(child, c);
        }
        child.busy -= 1;
        child.maybeFree();
        // A script in it may have changed this page: this frame shows that.
        if (p.doc.layout_dirty or p.doc.style_dirty) return;
    }
}

fn drawFrame(p: *Page, c: *ui.Context, x: f32, y: f32, r: box.Rect) void {
    if (p.dead) return;
    const l = if (p.list) |*q| q else return;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    c.next_key_int = @intFromPtr(p);
    var st: ui.Style = .{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = r.w }, .height = .{ .px = r.h }, .clip = true };
    if (l.canvas.a > 0) st.background = replay.color(l.canvas);
    _ = c.open(st, null);
    defer c.end();
    web.paintStart(p);
    replay.replay(c, l, Replay{ .p = p }, r);
    scrollbar(c, l, r);
    controls.selectList(p, c, r);
    web.paintEnd(p);
    web.frameEnd(p, c);
}

/// The page under a point, and the element in it, going down through frames.
const Under = struct { page: *Page, node: ?*dom.Node };

fn underPointer(p: *Page, x: f32, y: f32) Under {
    const l = if (p.list) |*q| q else return .{ .page = p, .node = null };
    var hit = l.hit(x, y);
    // While a modal dialog shows, what's outside it takes no input.
    if (p.doc.modalDialog()) |d| {
        if (hit == null or !d.contains(hit.?)) hit = null;
    }
    const n = hit orelse return .{ .page = p, .node = null };
    if (n.isTag("iframe")) if (frames.childPage(p, n)) |child| {
        if (child.list != null and child.frame.?.rect.contains(x, y)) return underPointer(child, x, y);
    };
    return .{ .page = p, .node = n };
}

/// A wheel over a frame scrolls it while it can, then what holds it.
fn wheelThrough(p: *Page, x: f32, y: f32, dx: f32, dy: f32) void {
    const l = if (p.list) |*q| q else return;
    const n = l.hit(x, y);
    if (n) |e| if (e.isTag("iframe")) if (frames.childPage(p, e)) |child| {
        if (child.list != null and child.frame.?.rect.contains(x, y) and canScroll(child, x, y, dx, dy)) return wheelThrough(child, x, y, dx, dy);
    };
    wheel(p, l, x, y, dx, dy);
}

fn canScroll(p: *Page, x: f32, y: f32, dx: f32, dy: f32) bool {
    const l = if (p.list) |*q| q else return false;
    const n = l.hit(x, y);
    if (n) |e| if (e.isTag("iframe")) if (frames.childPage(p, e)) |child| {
        if (child.list != null and canScroll(child, x, y, dx, dy)) return true;
    };
    const i = l.scrollerAt(x, y);
    const k = l.clips[i];
    if (i == 1 and !k.scrolls) return false;
    const m = l.maxScroll(i);
    if (dy != 0 and ((dy < 0 and k.scroll_y < m[1]) or (dy > 0 and k.scroll_y > 0))) return true;
    if (dx != 0 and ((dx < 0 and k.scroll_x < m[0]) or (dx > 0 and k.scroll_x > 0))) return true;
    return false;
}

/// Draws the page in `rect` (window coordinates) and takes its input.
pub fn view(p: *Page, c: *ui.Context, rect: box.Rect) void {
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    p.origin = .{ rect.x, rect.y };
    web.frameStart(p);
    defer web.frameEnd(p, c);
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
    if (l.frames.len > 0 or p.frames.list.items.len > 0) {
        advanceFrames(p, c);
        if (p.dead) return;
        if (p.doc.layout_dirty or p.doc.style_dirty) {
            prepare(p, c, rect.w, rect.h);
            if (p.list == null) return;
            p.list.?.resolve(rect.x, rect.y, rect.w, rect.h);
        }
    }

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
    const under: Under = if (inside) underPointer(p, mouse.x, mouse.y) else .{ .page = p, .node = null };
    const hovered = if (under.page == p) under.node else null;
    if (under.page != p) {
        // Over a frame: its page hears, and this one sees the pointer leave.
        input.pointer(p, c, it, null, mouse.x, mouse.y, inside and false);
        input.pointer(under.page, c, it, under.node, mouse.x, mouse.y, inside);
        if (c.input.pressed and it.hovered) frames.focusChain(under.page);
    } else {
        input.pointer(p, c, it, hovered, mouse.x, mouse.y, inside);
        if (c.input.pressed and it.hovered) frames.focusChain(p);
    }
    if (p.dead) return;
    if (p.doc.layout_dirty or p.doc.style_dirty) {
        // What the pointer did restyled it, or a script changed it: this
        // frame shows that.
        prepare(p, c, rect.w, rect.h);
        if (p.list == null) return;
        p.list.?.resolve(rect.x, rect.y, rect.w, rect.h);
    }
    const typing = frames.keyboardPage(p);
    web.keys(typing, c);
    if (p.dead) return;
    if (c.input.key == .escape) web.escape(typing);
    if (p.dead) return;
    var wheel_taken = false;
    if (inside and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) {
        wheel_taken = web.wheel(under.page, under.node, mouse.x, mouse.y, -c.input.scroll.x, -c.input.scroll.y, .{ .ctrl = c.input.ctrl, .shift = c.input.shift, .alt = c.input.alt, .meta = c.input.cmd });
        if (p.dead) return;
    }
    if (p.doc.layout_dirty or p.doc.style_dirty) prepare(p, c, rect.w, rect.h);
    if (p.list == null) return;
    const shown = &p.list.?;
    shown.resolve(rect.x, rect.y, rect.w, rect.h);
    if (inside and !wheel_taken and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) wheelThrough(p, mouse.x, mouse.y, c.input.scroll.x, c.input.scroll.y);
    if (inside) {
        if (typing == p) {
            keyScroll(p, c, shown, rect.h);
        } else if (typing.list) |*tl| keyScroll(typing, c, tl, typing.viewport_h);
    }
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
    if (i == 1 and !l.clips[1].scrolls) return;
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
    if (c.focus != 0 or !l.clips[1].scrolls) return;
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
