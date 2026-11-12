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
const glide = @import("page_glide.zig");
const resize = @import("page_resize.zig");
const motion = @import("page_motion.zig");
const frames = @import("frames.zig");
const web = @import("web/web.zig");
const webfonts = @import("webfonts.zig");
const font_cache = @import("font_cache.zig");
const perf = @import("perf_rules.zig");
const Page = @import("page.zig").Page;

fn needsPrepare(p: *const Page) bool {
    return perf.needsPrepare(p.doc.style_dirty, p.doc.layout_dirty or p.doc.oof_dirty_node != null, p.list_dirty, p.doc.svg_dirty, p.list != null);
}

const Fonts = font_cache.Fonts;
pub const lineMetrics = font_cache.lineMetrics;

/// Style and box layout (`p.tree`) brought up to date for a viewport of `w` × `h`,
/// deferring display-list construction (`makeList`) until `prepare`.
pub fn flushLayoutOnly(p: *Page, c: *ui.Context, w: f32, h: f32) void {
    loader.sheetsDue(p, c);
    webfonts.catchUp(p, c);
    p.engine.now = c.time;
    // Pictures on the web are as large as the screen is dense; the budget is
    // what scrolling back past them shouldn't decode again.
    ui.imageLimits(c, .{ .picture_side = 8192, .atlas_side = 8192, .decoded_bytes = 256 * 1024 * 1024 });
    var resize_from: ?f64 = null;
    // Over a dark change a window isn't being dragged, and nothing should wait for it.
    if (c.theme.dark != p.dark or ((w != p.viewport_w or h != p.viewport_h) and resize.due(p, c))) {
        resize_from = resize.now();
        p.viewport_w = w;
        p.viewport_h = h;
        p.dark = c.theme.dark;
        p.engine.setViewport(.{ .width = w, .height = h, .dark = p.dark });
    }
    defer if (resize_from) |from| resize.done(p, from);
    flushStyle(p);
    if (!p.doc.layout_dirty and p.tree != null) {
        if (p.doc.oof_dirty_node) |oof_n| {
            p.doc.oof_dirty_node = null;
            var fonts: Fonts = .{ .p = p, .c = c };
            if (layout.relayoutOutOfFlow(p.layout_arena.allocator(), p.doc, &p.tree.?, .{ .width = p.viewport_w, .height = p.viewport_h }, fonts.measurer(), oof_n) catch false) {
                p.list_dirty = true;
            } else {
                p.doc.layout_dirty = true;
            }
        }
    }
    if (p.doc.layout_dirty or p.tree == null) relayoutTree(p, c);
}

/// Style, layout and display list brought up to date for a viewport of `w` × `h`.
pub fn prepare(p: *Page, c: *ui.Context, w: f32, h: f32) void {
    if (p.js) |jw| if (jw.in_frame) { jw.redraw_due = false; jw.redraw_asked = false; };
    flushLayoutOnly(p, c, w, h);
    if (p.tree) |tree| if (p.list == null or p.list_dirty or p.doc.svg_dirty) {
        var fonts: Fonts = .{ .p = p, .c = c };
        makeList(p, tree, fonts.measurer());
    };
}

/// What the page wants of frames from what runs on it, and the changes they made.
fn runAnimations(p: *Page, c: *ui.Context) void {
    p.engine.now = c.time;
    const plan = p.engine.anim.tick(&p.engine, c.time);
    if (plan.layout) p.doc.touchLayout();
    p.motion_unseen = p.engine.anim.states.count() > 0 and !motion.anyShown(p);
    if (plan.paint) {
        if (p.motion_unseen) p.list_stale = true else p.list_dirty = true;
    }
    // Back in view, or over: the list catches up.
    if (p.list_stale and !p.motion_unseen) p.list_dirty = true;
    web.animationEvents(p);
}

fn wantFrames(p: *Page, c: *ui.Context) void {
    if (p.dead) return;
    const plan = p.engine.anim.plan(c.time);
    if (plan.frames and p.motion_unseen) {
        c.frameIn(motion.unseen_pace);
    } else if (plan.frames) {
        c.animationFrame();
    } else if (plan.wake_in) |seconds| c.frameIn(@max(seconds, 0.001));
}

fn recordStyleChange(p: *Page, change: css.Change) void {
    const d = p.doc;
    switch (change) {
        .none => {},
        // Boxes hold the very styles that changed.
        .paint => p.list_dirty = true,
        .layout => {
            if (!d.layout_dirty and p.tree != null and p.engine.containers.count() == 0 and !p.engine.layout_change_many and p.engine.layout_change_node != null) {
                const cand = p.engine.layout_change_node.?;
                if (d.oof_dirty_node == null or d.oof_dirty_node == cand) {
                    d.oof_dirty_node = cand;
                } else if (d.oof_dirty_node.?.contains(cand)) {
                    // already covered
                } else if (cand.contains(d.oof_dirty_node.?)) {
                    d.oof_dirty_node = cand;
                } else {
                    d.oof_dirty_node = null;
                    d.layout_dirty = true;
                }
            } else {
                d.oof_dirty_node = null;
                d.layout_dirty = true;
            }
        },
    }
}

/// Theorem 75 (`NanoUI.Speedometer3Apex.cone_scoped_style_flush_and_exotic_index_equiv`):
/// Brings `n`'s computed style up to date without flushing disjoint dirty subtrees.
pub fn flushStyleForNode(p: *Page, n: *dom.Node) void {
    const d = p.doc;
    if (!d.style_dirty) return;
    if (d.dirty_all or d.scan_dirty or p.engine.generation == 0 or p.engine.index_dirty or p.engine.containers.count() > 0 or (p.engine.index != null and p.engine.index.?.uses_has)) {
        flushStyle(p);
        return;
    }
    var top: ?*dom.Node = null;
    var connected = false;
    var at: ?*dom.Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.kind == .document) connected = true;
        if (x.style_queued) top = x;
    }
    if (!connected) return;
    const target = top orelse {
        if (n.style_generation == p.engine.generation) return;
        flushStyle(p);
        return;
    };
    if (target.kind == .document or d.documentElement() == target) {
        flushStyle(p);
        return;
    }
    const t0 = perf.nowNs();
    defer perf.prof_style_ns += perf.nowNs() -| t0;
    p.engine.layout_change_node = null;
    p.engine.layout_change_many = false;
    const change = p.engine.restyleChanged(target) catch .layout;
    recordStyleChange(p, change);
    var write_idx: usize = 0;
    for (d.dirty_nodes.items) |q| {
        if (!q.style_queued) continue;
        if (q == target or target.contains(q)) {
            q.style_queued = false;
        } else {
            d.dirty_nodes.items[write_idx] = q;
            write_idx += 1;
        }
    }
    d.dirty_nodes.items.len = write_idx;
    if (write_idx == 0) d.style_dirty = false;
}

/// Style brought up to date, as far as what changed reaches. Layout follows
/// when the style is any different, or the tree was already.
pub fn flushStyle(p: *Page) void {
    const d = p.doc;
    if (!d.style_dirty) return;
    loader.scan(p);
    const t0 = perf.nowNs();
    defer perf.prof_style_ns += perf.nowNs() -| t0;
    p.title_stale = true;
    d.style_dirty = false;
    if (d.dirty_all) {
        for (d.dirty_nodes.items) |n| n.style_queued = false;
        p.engine.restyleAll() catch {};
        d.dirty_all = false;
        d.dirty_nodes.clearRetainingCapacity();
        d.oof_dirty_node = null;
        d.layout_dirty = true;
        return;
    }
    p.engine.beginFlush();
    defer p.engine.in_batch_flush = false;
    for (d.dirty_nodes.items) |n| {
        if (!n.style_queued) continue;
        // Under one already done, or no longer in the document: nothing to do.
        var covered = false;
        var connected = false;
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) {
            if (x.kind == .document) connected = true;
            if (x != n and x.style_queued) covered = true;
        }
        if (covered or !connected) continue;
        const target = if (n.kind == .document) d.documentElement() orelse continue else n;
        p.engine.layout_change_node = null;
        p.engine.layout_change_many = d.layout_dirty;
        const change = p.engine.restyleChanged(target) catch .layout;
        recordStyleChange(p, change);
    }
    for (d.dirty_nodes.items) |n| n.style_queued = false;
    d.dirty_nodes.clearRetainingCapacity();
    d.style_dirty = false;
}

pub fn relayoutTree(p: *Page, c: *ui.Context) void {
    const t0 = perf.nowNs();
    defer perf.prof_layout_ns += perf.nowNs() -| t0;
    const had_prev = p.tree != null;
    std.mem.swap(std.heap.ArenaAllocator, &p.layout_arena, &p.prev_layout_arena);
    _ = p.layout_arena.reset(.retain_capacity);
    const a = p.layout_arena.allocator();
    var fonts: Fonts = .{ .p = p, .c = c };
    const m = fonts.measurer();
    p.layouts +%= 1;
    p.doc.layout_dirty = false;
    p.doc.oof_dirty_node = null;
    var tree = layout.runCached(a, p.doc, .{ .width = p.viewport_w, .height = p.viewport_h }, m, had_prev) catch {
        p.tree = null;
        p.list = null;
        return;
    };
    // A container's size decides its contents' style. Each pass settles a level.
    var passes: u8 = 0;
    while (passes < 4 and layout.updateContainers(&p.engine)) : (passes += 1) {
        p.doc.invalidateLayoutCache();
        _ = p.layout_arena.reset(.retain_capacity);
        tree = layout.runCached(a, p.doc, .{ .width = p.viewport_w, .height = p.viewport_h }, m, false) catch {
            p.tree = null;
            p.list = null;
            return;
        };
    }
    p.doc.layout_dirty = false;
    p.tree = tree;
    p.list_dirty = true;
}

pub fn relayout(p: *Page, c: *ui.Context) void {
    relayoutTree(p, c);
    if (p.tree) |tree| {
        var fonts: Fonts = .{ .p = p, .c = c };
        makeList(p, tree, fonts.measurer());
    }
}

fn makeList(p: *Page, tree: box.Tree, m: box.Measurer) void {
    const t0 = perf.nowNs();
    defer perf.prof_list_ns += perf.nowNs() -| t0;
    p.list_dirty = false;
    p.list_stale = false;
    p.lists +%= 1;
    const ts = perf.nowNs();
    svg_markup.refresh(p);
    perf.prof_svg_ns += perf.nowNs() -| ts;
    _ = p.list_arena.reset(.retain_capacity);
    p.list = display.build(p.list_arena.allocator(), tree, p.doc.node, m, &p.scrolls) catch null;
    if (p.restore_scroll > 0) if (p.list) |*l| {
        l.clips[1].scroll_y = p.restore_scroll;
        l.scroll_rev +%= 1;
    };
}

/// The picture of a background, for `replay`.
const Replay = struct {
    p: *Page,

    pub fn picture(h: Replay, url: []const u8) ?[]const u8 {
        return loader.background(h.p, url);
    }

    pub fn canvas(h: Replay, n: *dom.Node) ?ui.Texture {
        return h.p.canvases.pixelsOf(n);
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
        // A frame's CSS motion has the same clock and wakeups as its owner.
        runAnimations(child, c);
        if (!child.dead) web.frameStart(child);
        if (!child.dead) {
            prepare(child, c, r.w, r.h);
            if (child.list != null) child.list.?.resolve(r.x, r.y, r.w, r.h);
            web.frameLaid(child);
        }
        if (!child.dead) {
            if (needsPrepare(child)) prepare(child, c, r.w, r.h);
            if (child.list != null) {
                const cl = &child.list.?;
                cl.resolve(r.x, r.y, r.w, r.h);
                clampScrolls(child, cl);
                glide.step(child, c, cl);
                cl.resolve(r.x, r.y, r.w, r.h);
            }
            advanceFrames(child, c);
        }
        wantFrames(child, c);
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
    if (!noScrolling(p)) scrollbar(c, l, r);
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
    if (needsPrepare(p)) prepare(p, c, rect.w, rect.h);
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
        if (needsPrepare(p)) {
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
        under.page.hover_held_until = @max(under.page.hover_held_until, p.hover_held_until);
        input.pointer(under.page, c, it, under.node, mouse.x, mouse.y, inside);
        if (c.input.pressed and it.hovered) frames.focusChain(under.page);
    } else {
        input.pointer(p, c, it, hovered, mouse.x, mouse.y, inside);
        if (c.input.pressed and it.hovered) frames.focusChain(p);
    }
    if (p.dead) return;
    if (needsPrepare(p)) {
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
    if (needsPrepare(p)) prepare(p, c, rect.w, rect.h);
    if (p.list == null) return;
    const shown = &p.list.?;
    shown.resolve(rect.x, rect.y, rect.w, rect.h);
    if (inside and !wheel_taken and (c.input.scroll.y != 0 or c.input.scroll.x != 0)) wheelThrough(p, c, mouse.x, mouse.y, c.input.scroll.x, c.input.scroll.y);
    if (inside) {
        if (typing == p) {
            keyScroll(p, c, shown, rect.h);
        } else if (typing.list) |*tl| keyScroll(typing, c, tl, typing.viewport_h);
    }
    glide.step(p, c, shown);
    shown.resolve(rect.x, rect.y, rect.w, rect.h);
    if (inside and p.hover_held_until > c.time) {
        const now_under = underPointer(p, mouse.x, mouse.y);
        if (perf.shouldWakeForHoverHold(true, now_under.page.doc.hover, now_under.node)) {
            c.frameIn(@floatCast(@max(p.hover_held_until - c.time, 0.001)));
        }
    }
    web.paintStart(p);
    const rep_t0 = perf.nowNs();
    replay.replay(c, shown, Replay{ .p = p }, rect);
    perf.prof_replay_ns += perf.nowNs() -| rep_t0;
    @import("find.zig").draw(p, c, shown, rect);
    scrollbar(c, shown, rect);
    controls.selectList(p, c, rect);
    web.paintEnd(p);
}

pub const scrollBy = glide.scrollBy;
pub const moveBy = glide.moveBy;
pub const scrollPageTo = glide.scrollPageTo;
const clampScrolls = glide.clampScrolls;
const keyScroll = glide.keyScroll;
const scrollbar = glide.scrollbar;
const wheelThrough = glide.wheelThrough;
const noScrolling = glide.noScrolling;
