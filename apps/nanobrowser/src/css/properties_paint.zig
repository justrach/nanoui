//! What is painted rather than laid out: backgrounds and gradients, shadows,
//! transforms, and generated content. One background layer is kept (the first
//! with an image, and the color); one shadow (the first that shows).
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
        .background_size => backgroundSize(ctx, t),
        .background_repeat => backgroundRepeat(s, t),
        .background_position => backgroundPosition(ctx, t),
        .background_position_x => positionAxis(ctx, t, true),
        .background_position_y => positionAxis(ctx, t, false),
        .box_shadow => boxShadow(ctx, t),
        .transform => transform(ctx, t),
        .translate => translateProp(ctx, t),
        .scale => scaleProp(ctx, t),
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
    var part = Cur.of(c.untilComma());
    ctx.style.background_clip = clipWord(&part) orelse return false;
    return part.atEnd();
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
    var part = Cur.of(c.untilComma());
    const z = sizeWord(ctx, &part) orelse return false;
    if (!part.atEnd()) return false;
    setSize(ctx.style, z);
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

fn backgroundRepeat(s: *style.Style, t: []const Token) bool {
    var c = Cur.of(t);
    var part = Cur.of(c.untilComma());
    s.background_repeat = repeatWord(&part) orelse return false;
    return part.atEnd();
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
    var part = Cur.of(c.untilComma());
    const p = positionAt(ctx, &part) orelse return false;
    if (!part.atEnd()) return false;
    setPos(ctx.style, p);
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
    var size: Size = .{};
    var repeat: style.BackgroundRepeat = .repeat;
    var pos: Pos = .{};
    var first = true;
    var clip: style.BackgroundClip = .border_box;
    var more: std.ArrayList(style.BackgroundLayer) = .empty;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        var l_image: ?Image = null;
        var l_size: ?Size = null;
        var l_repeat: ?style.BackgroundRepeat = null;
        var l_pos: ?Pos = null;
        var l_clip: style.BackgroundClip = .border_box;
        while (!c.atEnd()) {
            if (c.takeIdent("fixed") or c.takeIdent("scroll") or c.takeIdent("local")) continue;
            if (clipWord(&c)) |w| {
                // Two boxes name the origin, then the clip: the last counts.
                l_clip = w;
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
        // The kept layer is the first with an image, else the first.
        var keep = first;
        if (l_image) |img| if (!img.none) {
            if (!have_image) {
                image = img;
                have_image = true;
                keep = true;
            } else more.append(ctx.arena, .{ .url = img.url, .gradient = img.gradient, .clip = l_clip }) catch return false;
        };
        if (keep) {
            size = l_size orelse .{};
            repeat = l_repeat orelse .repeat;
            pos = l_pos orelse .{};
            clip = l_clip;
        }
        first = false;
    }
    const s = ctx.style;
    s.background = color;
    s.background_clip = clip;
    s.background_more = more.items;
    setImage(ctx, image);
    setSize(s, size);
    s.background_repeat = repeat;
    setPos(s, pos);
    return true;
}

fn boxShadow(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.shadow = null;
        return true;
    }
    var outer = Cur.of(t);
    var chosen: ?style.Shadow = null;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        var nums: [4]f32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        var inset = false;
        var color: ?style.Color = null;
        while (!c.atEnd()) {
            if (c.takeIdent("inset")) {
                inset = true;
                continue;
            }
            if (n < 4) if (values.pxAt(ctx, &c)) |v| {
                nums[n] = v;
                n += 1;
                continue;
            };
            if (color == null) if (colors.at(ctx, &c)) |v| {
                color = v;
                continue;
            };
            return false;
        }
        if (n < 2) return false;
        const col = color orelse ctx.style.color;
        if (chosen == null and !inset and col.a > 0) {
            chosen = .{ .x = nums[0], .y = nums[1], .blur = nums[2], .spread = nums[3], .color = col };
        }
    }
    ctx.style.shadow = chosen;
    return true;
}

fn transform(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.transform = null;
        return true;
    }
    var c = Cur.of(t);
    var out: style.Transform = .{};
    var any = false;
    while (c.next()) |f| {
        if (f.kind != .function) return false;
        any = true;
        var a = Cur.of(c.body());
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(f.text, "translate") or eq(f.text, "translate3d")) {
            const x = values.lengthAt(ctx, &a) orelse return false;
            var y = Len.zero;
            if (a.takeComma()) y = values.lengthAt(ctx, &a) orelse return false;
            addLen(&out.x, x);
            addLen(&out.y, y);
        } else if (eq(f.text, "translateX")) {
            addLen(&out.x, values.lengthAt(ctx, &a) orelse return false);
        } else if (eq(f.text, "translateY")) {
            addLen(&out.y, values.lengthAt(ctx, &a) orelse return false);
        } else if (eq(f.text, "scale") or eq(f.text, "scale3d") or eq(f.text, "scaleX")) {
            out.scale *= values.numberAt(ctx, &a) orelse return false;
        }
        // scaleY alone, rotate, skew and matrix are not drawn.
    }
    if (!any) return false;
    ctx.style.transform = out;
    return true;
}

fn addLen(a: *Len, b: Len) void {
    a.px += b.px;
    a.pct += b.pct;
}

fn translateProp(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| return std.ascii.eqlIgnoreCase(w, "none");
    var c = Cur.of(t);
    var out = ctx.style.transform orelse style.Transform{};
    out.x = values.lengthAt(ctx, &c) orelse return false;
    out.y = values.lengthAt(ctx, &c) orelse Len.zero;
    ctx.style.transform = out;
    return true;
}

fn scaleProp(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| return std.ascii.eqlIgnoreCase(w, "none");
    var c = Cur.of(t);
    var out = ctx.style.transform orelse style.Transform{};
    out.scale = values.numberAt(ctx, &c) orelse return false;
    ctx.style.transform = out;
    return true;
}

fn content(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (std.ascii.eqlIgnoreCase(w, "none") or std.ascii.eqlIgnoreCase(w, "normal")) {
            ctx.has_content = false;
            ctx.style.content = "";
            return true;
        }
    }
    var out: std.ArrayList(u8) = .empty;
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
                    const n = a.next() orelse return false;
                    if (ctx.node) |node| if (node.attr(n.text)) |v| {
                        out.appendSlice(ctx.arena, v) catch return false;
                    };
                } else if (!std.ascii.eqlIgnoreCase(name, "counter") and !std.ascii.eqlIgnoreCase(name, "counters") and std.ascii.findIgnoreCase(name, "gradient") == null and !std.ascii.eqlIgnoreCase(name, "image-set")) {
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
    ctx.style.content = out.items;
    ctx.has_content = true;
    return true;
}
