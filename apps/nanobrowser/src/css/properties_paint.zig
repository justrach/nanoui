//! Backgrounds and generated content: what is painted rather than laid out.
//! Shadows, transforms and filters are in `properties_effects.zig`.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");
const gradients = @import("gradient.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Len = style.Len;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    return switch (p) {
        .background => background(ctx, t),
        .background_color => {
            s.background = colors.of(ctx, t) orelse return false;
            return true;
        },
        .background_image => backgroundImage(ctx, t),
        .mask, .mask_image => mask(ctx, t),
        .background_clip => backgroundClip(ctx, t),
        .background_origin => backgroundOrigin(ctx, t),
        .background_attachment => backgroundAttachment(ctx, t),
        .background_size => backgroundSize(ctx, t),
        .background_repeat => backgroundRepeat(ctx, t),
        .background_position => backgroundPosition(ctx, t),
        .background_position_x => positionAxis(ctx, t, true),
        .background_position_y => positionAxis(ctx, t, false),
        .content => content(ctx, t),
        else => null,
    };
}

const Image = struct {
    url: []const u8 = "",
    gradient: ?style.Gradient = null,
    none: bool = false,
};

const Pos = struct { x_pct: f32 = 0, x_px: f32 = 0, y_pct: f32 = 0, y_px: f32 = 0 };
const Size = struct { kind: style.BackgroundSize = .auto, x: Len = Len.auto, y: Len = Len.auto };

/// `background-position`'s grammar, into its fields.
pub fn position(ctx: *Ctx, t: []const Token) bool {
    return backgroundPosition(ctx, t);
}

/// One image at `c`: a URL, a gradient, `none`, or null when it is not one.
fn imageAt(ctx: *Ctx, c: *Cur) ?Image {
    const t = c.peek() orelse return null;
    if (t.kind == .url) {
        c.i += 1;
        return .{ .url = t.text };
    }
    if (t.isIdent("none")) {
        c.i += 1;
        return .{ .none = true };
    }
    if (t.kind != .function) return null;
    const name = t.text;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "image-set") or eq(name, "-webkit-image-set")) {
        c.i += 1;
        var inner = Cur.of(c.body());
        const u = inner.next() orelse return null;
        if (u.kind == .url or u.kind == .string) return .{ .url = u.text };
        return null;
    }
    const is_gradient = std.ascii.findIgnoreCase(name, "gradient") != null;
    if (!is_gradient) return null;
    c.i += 1;
    const g = gradients.parse(ctx, name, c.body()) orelse return null;
    return .{ .gradient = g };
}

/// `mask-image`, or the first image of `mask`'s shorthand.
fn mask(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    while (c.next()) |k| {
        if (k.kind == .url) {
            ctx.style.mask_image = k.text;
            return true;
        }
    }
    ctx.style.mask_image = "";
    return true;
}

fn setImage(ctx: *Ctx, img: Image) void {
    ctx.style.background_image = img.url;
    ctx.style.background_gradient = img.gradient;
}

fn backgroundImage(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var chosen: ?Image = null;
    var more: std.ArrayList(style.BackgroundLayer) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        const img = imageAt(ctx, &part) orelse return false;
        if (!part.atEnd()) return false;
        if (chosen == null or (chosen.?.none and !img.none)) {
            chosen = img;
        } else if (!img.none) more.append(ctx.arena, .{ .url = img.url, .gradient = img.gradient }) catch return false;
    }
    setImage(ctx, chosen orelse return false);
    ctx.style.background_more = more.items;
    return true;
}

fn clipWord(c: *Cur) ?style.BackgroundClip {
    if (c.takeIdent("border-box")) return .border_box;
    if (c.takeIdent("padding-box")) return .padding_box;
    if (c.takeIdent("content-box")) return .content_box;
    if (c.takeIdent("text")) return .text;
    return null;
}

fn backgroundClip(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(style.BackgroundClip) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        out.append(ctx.arena, clipWord(&part) orelse return false) catch return false;
        if (!part.atEnd()) return false;
    }
    if (out.items.len == 0) return false;
    ctx.style.background_clip = out.items[0];
    ctx.style.bg_clips = if (out.items.len > 1) out.items else &.{};
    return true;
}

fn originWord(c: *Cur) ?style.BackgroundOrigin {
    if (c.takeIdent("border-box")) return .border_box;
    if (c.takeIdent("padding-box")) return .padding_box;
    if (c.takeIdent("content-box")) return .content_box;
    return null;
}

fn backgroundOrigin(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(style.BackgroundOrigin) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        out.append(ctx.arena, originWord(&part) orelse return false) catch return false;
        if (!part.atEnd()) return false;
    }
    if (out.items.len == 0) return false;
    ctx.style.background_origin = out.items[0];
    ctx.style.bg_origins = if (out.items.len > 1) out.items else &.{};
    return true;
}

fn backgroundAttachment(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(bool) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        const fixed = part.takeIdent("fixed");
        if (!fixed and !part.takeIdent("scroll") and !part.takeIdent("local")) return false;
        out.append(ctx.arena, fixed) catch return false;
    }
    if (out.items.len == 0) return false;
    ctx.style.background_fixed = out.items[0];
    ctx.style.bg_fixed = if (out.items.len > 1) out.items else &.{};
    return true;
}

fn sizeWord(ctx: *Ctx, c: *Cur) ?Size {
    if (c.takeIdent("cover")) return .{ .kind = .cover };
    if (c.takeIdent("contain")) return .{ .kind = .contain };
    const one = struct {
        fn at(x: *Ctx, k: *Cur) ?Len {
            if (k.takeIdent("auto")) return Len.auto;
            return values.lengthAt(x, k);
        }
    };
    const a = one.at(ctx, c) orelse return null;
    const b = one.at(ctx, c) orelse Len.auto;
    return .{ .x = a, .y = b };
}

fn setSize(s: *style.Style, z: Size) void {
    s.background_size = z.kind;
    s.background_size_x = z.x;
    s.background_size_y = z.y;
}

fn backgroundSize(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(style.BgSize) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        const z = sizeWord(ctx, &part) orelse return false;
        if (!part.atEnd()) return false;
        out.append(ctx.arena, .{ .kind = z.kind, .x = z.x, .y = z.y }) catch return false;
    }
    if (out.items.len == 0) return false;
    const f = out.items[0];
    setSize(ctx.style, .{ .kind = f.kind, .x = f.x, .y = f.y });
    ctx.style.bg_sizes = if (out.items.len > 1) out.items else &.{};
    return true;
}

fn repeatWord(c: *Cur) ?style.BackgroundRepeat {
    const r = struct {
        fn axis(k: *Cur) ?bool {
            if (k.takeIdent("repeat") or k.takeIdent("space") or k.takeIdent("round")) return true;
            if (k.takeIdent("no-repeat")) return false;
            return null;
        }
    };
    if (c.takeIdent("repeat-x")) return .repeat_x;
    if (c.takeIdent("repeat-y")) return .repeat_y;
    const a = r.axis(c) orelse return null;
    const b = r.axis(c) orelse a;
    if (a and b) return .repeat;
    if (a) return .repeat_x;
    if (b) return .repeat_y;
    return .no_repeat;
}

fn backgroundRepeat(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(style.BackgroundRepeat) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        out.append(ctx.arena, repeatWord(&part) orelse return false) catch return false;
        if (!part.atEnd()) return false;
    }
    if (out.items.len == 0) return false;
    ctx.style.background_repeat = out.items[0];
    ctx.style.bg_repeats = if (out.items.len > 1) out.items else &.{};
    return true;
}

const PosItem = union(enum) { kw: u8, len: Len };

fn posItem(ctx: *Ctx, c: *Cur) ?PosItem {
    const t = c.peek() orelse return null;
    if (t.kind == .ident) {
        const k: u8 = if (t.isIdent("left")) 'l' else if (t.isIdent("right")) 'r' else if (t.isIdent("top")) 't' else if (t.isIdent("bottom")) 'b' else if (t.isIdent("center")) 'c' else return null;
        c.i += 1;
        return .{ .kw = k };
    }
    const l = values.lengthAt(ctx, c) orelse return null;
    return .{ .len = l };
}

fn kwPct(k: u8) f32 {
    return switch (k) {
        'r', 'b' => 100,
        'c' => 50,
        else => 0,
    };
}

fn positionAt(ctx: *Ctx, c: *Cur) ?Pos {
    var items: [4]PosItem = undefined;
    var n: usize = 0;
    while (n < 4) : (n += 1) items[n] = posItem(ctx, c) orelse break;
    var p: Pos = .{};
    const isY = struct {
        fn f(i: PosItem) bool {
            return i == .kw and (i.kw == 't' or i.kw == 'b');
        }
    }.f;
    const isX = struct {
        fn f(i: PosItem) bool {
            return i == .kw and (i.kw == 'l' or i.kw == 'r');
        }
    }.f;
    const set = struct {
        fn f(pct: *f32, px: *f32, i: PosItem) void {
            switch (i) {
                .kw => |k| pct.* = kwPct(k),
                .len => |l| {
                    pct.* = l.pct;
                    px.* = l.px;
                },
            }
        }
    }.f;
    switch (n) {
        0 => return null,
        1 => {
            p.x_pct = 50;
            p.y_pct = 50;
            if (isY(items[0])) set(&p.y_pct, &p.y_px, items[0]) else set(&p.x_pct, &p.x_px, items[0]);
        },
        2 => {
            const swap = isY(items[0]) or isX(items[1]);
            set(&p.x_pct, &p.x_px, items[if (swap) 1 else 0]);
            set(&p.y_pct, &p.y_px, items[if (swap) 0 else 1]);
        },
        else => {
            // Edge offsets: `right 10px top 20px`.
            p.x_pct = 50;
            p.y_pct = 50;
            var i: usize = 0;
            while (i < n) {
                if (items[i] != .kw) return null;
                const k = items[i].kw;
                const y = k == 't' or k == 'b';
                var off: Len = .{};
                i += 1;
                if (i < n and items[i] == .len) {
                    off = items[i].len;
                    i += 1;
                }
                const sign: f32 = if (k == 'r' or k == 'b') -1 else 1;
                if (y) {
                    p.y_pct = kwPct(k) + off.pct * sign;
                    p.y_px = off.px * sign;
                } else {
                    p.x_pct = kwPct(k) + off.pct * sign;
                    p.x_px = off.px * sign;
                }
            }
        },
    }
    return p;
}

fn setPos(s: *style.Style, p: Pos) void {
    s.background_x = p.x_pct;
    s.background_x_px = p.x_px;
    s.background_y = p.y_pct;
    s.background_y_px = p.y_px;
}

fn backgroundPosition(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var out: std.ArrayList(style.BgPos) = .empty;
    while (!c.atEnd()) {
        var part = Cur.of(c.untilComma());
        const p = positionAt(ctx, &part) orelse return false;
        if (!part.atEnd()) return false;
        out.append(ctx.arena, .{ .x_pct = p.x_pct, .x_px = p.x_px, .y_pct = p.y_pct, .y_px = p.y_px }) catch return false;
    }
    if (out.items.len == 0) return false;
    const f = out.items[0];
    setPos(ctx.style, .{ .x_pct = f.x_pct, .x_px = f.x_px, .y_pct = f.y_pct, .y_px = f.y_px });
    ctx.style.bg_positions = if (out.items.len > 1) out.items else &.{};
    return true;
}

fn positionAxis(ctx: *Ctx, t: []const Token, x: bool) bool {
    var c = Cur.of(t);
    var part = Cur.of(c.untilComma());
    const i = posItem(ctx, &part) orelse return false;
    var pct: f32 = 0;
    var px: f32 = 0;
    switch (i) {
        .kw => |k| pct = kwPct(k),
        .len => |l| {
            pct = l.pct;
            px = l.px;
        },
    }
    const s = ctx.style;
    if (x) {
        s.background_x = pct;
        s.background_x_px = px;
    } else {
        s.background_y = pct;
        s.background_y_px = px;
    }
    return true;
}

fn background(ctx: *Ctx, t: []const Token) bool {
    var outer = Cur.of(t);
    var image: Image = .{};
    var have_image = false;
    var color: style.Color = style.Color.transparent;
    var more: std.ArrayList(style.BackgroundLayer) = .empty;
    var sizes: std.ArrayList(style.BgSize) = .empty;
    var positions: std.ArrayList(style.BgPos) = .empty;
    var repeats: std.ArrayList(style.BackgroundRepeat) = .empty;
    var clips: std.ArrayList(style.BackgroundClip) = .empty;
    var origins: std.ArrayList(style.BackgroundOrigin) = .empty;
    var fixeds: std.ArrayList(bool) = .empty;
    var first = true;
    const a = ctx.arena;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        var l_image: ?Image = null;
        var l_size: ?Size = null;
        var l_repeat: ?style.BackgroundRepeat = null;
        var l_pos: ?Pos = null;
        var l_clip: style.BackgroundClip = .border_box;
        var l_origin: style.BackgroundOrigin = .padding_box;
        var boxes: u8 = 0;
        var l_fixed = false;
        while (!c.atEnd()) {
            if (c.takeIdent("fixed")) {
                l_fixed = true;
                continue;
            }
            if (c.takeIdent("scroll") or c.takeIdent("local")) continue;
            const save = c.i;
            if (clipWord(&c)) |w| {
                // Two boxes name the origin, then the clip; one is both.
                if (boxes == 0 and w != .text) {
                    var again = Cur.of(c.t[save..]);
                    if (originWord(&again)) |o| l_origin = o;
                }
                l_clip = w;
                boxes += 1;
                continue;
            }
            if (l_image == null) if (imageAt(ctx, &c)) |img| {
                l_image = img;
                continue;
            };
            if (l_repeat == null) if (repeatWord(&c)) |r| {
                l_repeat = r;
                continue;
            };
            if (l_pos == null) if (positionAt(ctx, &c)) |p| {
                l_pos = p;
                if (c.takeDelim('/')) l_size = sizeWord(ctx, &c) orelse return false;
                continue;
            };
            if (colors.at(ctx, &c)) |v| {
                color = v;
                continue;
            }
            return false;
        }
        // What has an image is a layer; with none at all, the first counts.
        const has_image = if (l_image) |img| !img.none else false;
        const keep = has_image or (first and outer.atEnd());
        if (keep) {
            const z = l_size orelse Size{};
            const p = l_pos orelse Pos{};
            sizes.append(a, .{ .kind = z.kind, .x = z.x, .y = z.y }) catch return false;
            positions.append(a, .{ .x_pct = p.x_pct, .x_px = p.x_px, .y_pct = p.y_pct, .y_px = p.y_px }) catch return false;
            repeats.append(a, l_repeat orelse .repeat) catch return false;
            clips.append(a, l_clip) catch return false;
            origins.append(a, l_origin) catch return false;
            fixeds.append(a, l_fixed) catch return false;
            if (has_image) {
                const img = l_image.?;
                if (!have_image) {
                    image = img;
                    have_image = true;
                } else more.append(a, .{ .url = img.url, .gradient = img.gradient, .clip = l_clip }) catch return false;
            }
        }
        first = false;
    }
    const s = ctx.style;
    s.background = color;
    s.background_more = more.items;
    setImage(ctx, image);
    const layers = more.items.len + 1;
    const z0: style.BgSize = if (sizes.items.len > 0) sizes.items[0] else .{};
    const p0: style.BgPos = if (positions.items.len > 0) positions.items[0] else .{};
    setSize(s, .{ .kind = z0.kind, .x = z0.x, .y = z0.y });
    setPos(s, .{ .x_pct = p0.x_pct, .x_px = p0.x_px, .y_pct = p0.y_pct, .y_px = p0.y_px });
    s.background_repeat = if (repeats.items.len > 0) repeats.items[0] else .repeat;
    s.background_clip = if (clips.items.len > 0) clips.items[0] else .border_box;
    s.background_origin = if (origins.items.len > 0) origins.items[0] else .padding_box;
    s.background_fixed = fixeds.items.len > 0 and fixeds.items[0];
    s.bg_sizes = if (layers > 1) sizes.items else &.{};
    s.bg_positions = if (layers > 1) positions.items else &.{};
    s.bg_repeats = if (layers > 1) repeats.items else &.{};
    s.bg_clips = if (layers > 1) clips.items else &.{};
    s.bg_origins = if (layers > 1) origins.items else &.{};
    s.bg_fixed = if (layers > 1) fixeds.items else &.{};
    return true;
}

fn content(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (std.ascii.eqlIgnoreCase(w, "none") or std.ascii.eqlIgnoreCase(w, "normal")) {
            ctx.has_content = false;
            ctx.style.content = "";
            ctx.style.content_parts = &.{};
            ctx.style.marker_hidden = std.ascii.eqlIgnoreCase(w, "none");
            return true;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var parts: std.ArrayList(style.ContentPart) = .empty;
    var c = Cur.of(t);
    while (c.next()) |k| {
        switch (k.kind) {
            .string => out.appendSlice(ctx.arena, k.text) catch return false,
            .url => {},
            // The alternative text after the slash.
            .delim => {
                if (k.delim == '/') break;
                return false;
            },
            .function => {
                const name = k.text;
                var a = Cur.of(c.body());
                if (std.ascii.eqlIgnoreCase(name, "attr")) {
                    ctx.used_attr = true;
                    const n = a.next() orelse return false;
                    if (ctx.node) |node| if (node.attr(n.text)) |v| {
                        out.appendSlice(ctx.arena, v) catch return false;
                    };
                } else if (std.ascii.eqlIgnoreCase(name, "counter") or std.ascii.eqlIgnoreCase(name, "counters")) {
                    // What came before is one part, the counter the next.
                    if (out.items.len > 0) {
                        parts.append(ctx.arena, .{ .text = out.items }) catch return false;
                        out = .empty;
                    }
                    const part = counterPart(&a, std.ascii.eqlIgnoreCase(name, "counters")) orelse return false;
                    parts.append(ctx.arena, .{ .counter = part }) catch return false;
                } else if (std.ascii.findIgnoreCase(name, "gradient") == null and !std.ascii.eqlIgnoreCase(name, "image-set")) {
                    return false;
                }
            },
            .ident => {
                if (k.isIdent("open-quote")) {
                    out.appendSlice(ctx.arena, "\u{201C}") catch return false;
                } else if (k.isIdent("close-quote")) {
                    out.appendSlice(ctx.arena, "\u{201D}") catch return false;
                } else if (!k.isIdent("no-open-quote") and !k.isIdent("no-close-quote")) {
                    return false;
                }
            },
            else => return false,
        }
    }
    if (parts.items.len > 0 and out.items.len > 0) parts.append(ctx.arena, .{ .text = out.items }) catch return false;
    ctx.style.content = if (parts.items.len > 0) "" else out.items;
    ctx.style.content_parts = parts.items;
    ctx.has_content = true;
    return true;
}

/// `counter(name, style)` or `counters(name, "sep", style)`, at its arguments.
fn counterPart(a: *Cur, nested: bool) ?style.ContentPart.Counter {
    const n = a.next() orelse return null;
    if (n.kind != .ident) return null;
    var out: style.ContentPart.Counter = .{ .name = n.text };
    if (nested) {
        if (!a.takeComma()) return null;
        const sep = a.next() orelse return null;
        if (sep.kind != .string) return null;
        out.sep = sep.text;
    }
    if (a.takeComma()) {
        const k = a.next() orelse return null;
        if (k.kind != .ident) return null;
        if (k.isIdent("lower-latin")) {
            out.kind = .lower_alpha;
        } else if (k.isIdent("upper-latin")) {
            out.kind = .upper_alpha;
        } else out.kind = values.keyword(style.ListStyle, k.text) orelse .decimal;
    }
    return out;
}
