//! MapKit for `nanoui.map` on iOS: an MKMapView under the surface's Metal
//! layer, placed each frame on its hole (`ui.hole`). The layer goes above
//! it (zPosition 1, not opaque) so the UI draws over the map, and the
//! view's hitTest gives the map the touches that land on its hole and
//! the UI the rest. Pins are annotation views with a label: a yellow chip
//! for a stop, a dark pill for a bus; one whose place changes glides.
const std = @import("std");
const objc = @import("../objc.zig");
const api = @import("../basics/map.zig");
const types = @import("../ui/types.zig");
const Surface = @import("surface.zig").Surface;

const Coordinate = extern struct { lat: f64, lng: f64 };
const Region = extern struct { center: Coordinate, lat_delta: f64, lng_delta: f64 };

const Entry = struct { want: api.Want, ann: objc.Object };

/// What MapKit holds for one map.
pub const Native = struct {
    view: ?objc.Object = null,
    delegate: ?objc.Object = null,
    surface: ?*Surface = null,
    entries: std.ArrayList(Entry) = .empty,
    overlay: ?objc.Object = null,
    line_hash: u64 = 0,
    camera: ?api.Camera = null,
    shown: bool = false,
    user: bool = false,
    muted: ?bool = null,
    frame: types.Rect = .{},

    pub fn deinit(n: *Native) void {
        const m: *api.Map = @fieldParentPtr("native", n);
        unregister(m);
        for (n.entries.items) |e| objc.release(e.ann);
        n.entries.deinit(m.gpa);
        if (n.overlay) |o| objc.release(o);
        if (n.view) |v| {
            objc.msg(void, v, "setDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, v, "removeFromSuperview", .{});
            objc.release(v);
        }
        if (n.delegate) |d| {
            objc.setZig(d, null);
            objc.release(d);
        }
    }
};

/// The maps drawn so far, for the surfaces to place after each frame.
var maps: [8]?*api.Map = @splat(null);

/// Called from `Map.view`: the map takes part in this frame.
pub fn want(m: *api.Map) void {
    for (maps) |e| if (e == m) return;
    for (&maps) |*e| if (e.* == null) {
        e.* = m;
        return;
    };
}

fn unregister(m: *api.Map) void {
    for (&maps) |*e| if (e.* == m) {
        e.* = null;
    };
}

/// After a frame is built and laid out: each map drawn in it goes where
/// its hole is and shows what it was asked to; one not drawn hides.
pub fn sync(s: *Surface) void {
    for (maps) |entry| {
        const m = entry orelse continue;
        const n = &m.native;
        if (n.surface != null and n.surface != s) continue;
        if (!m.seen) {
            if (n.shown) if (n.view) |v| objc.msg(void, v, "setHidden:", .{objc.YES});
            n.shown = false;
            continue;
        }
        m.seen = false;
        const r = s.ctx.rects.get(m.id) orelse continue;
        const v = n.view orelse attach(m, s);
        if (!n.shown) objc.msg(void, v, "setHidden:", .{objc.NO});
        n.shown = true;
        if (!std.meta.eql(r, n.frame)) {
            n.frame = r;
            objc.msg(void, v, "setFrame:", .{objc.CGRect{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } }});
            const layer = objc.msg(objc.Object, v, "layer", .{});
            objc.msg(void, layer, "setCornerRadius:", .{@as(objc.CGFloat, m.radius)});
        }
        apply(m, v);
    }
}

fn attach(m: *api.Map, s: *Surface) objc.Object {
    const n = &m.native;
    defineDelegate();
    const d = objc.msg(objc.Object, objc.alloc("NanouiMapDelegate"), "init", .{});
    objc.setZig(d, m);
    const v = objc.msg(objc.Object, objc.alloc("MKMapView"), "initWithFrame:", .{objc.CGRect{}});
    objc.msg(void, v, "setDelegate:", .{d});
    objc.msg(void, objc.msg(objc.Object, v, "layer", .{}), "setMasksToBounds:", .{objc.YES});
    objc.msg(void, v, "setShowsCompass:", .{objc.NO});
    objc.msg(void, v, "setPitchEnabled:", .{objc.NO});
    objc.msg(void, s.uiview, "insertSubview:atIndex:", .{ v, @as(objc.NSInteger, 0) });
    // The UI over the map: the layer above its view, seen through.
    objc.msg(void, s.renderer.layer, "setZPosition:", .{@as(objc.CGFloat, 1)});
    objc.msg(void, s.renderer.layer, "setOpaque:", .{objc.NO});
    n.view = v;
    n.delegate = d;
    n.surface = s;
    return v;
}

fn apply(m: *api.Map, v: objc.Object) void {
    const n = &m.native;
    if (n.muted != m.muted) {
        n.muted = m.muted;
        // Flat, muted (1) or default (0) emphasis, points of interest off.
        const cfg = objc.msg(objc.Object, objc.alloc("MKStandardMapConfiguration"), "initWithElevationStyle:emphasisStyle:", .{ @as(objc.NSInteger, 0), @as(objc.NSInteger, if (m.muted) 1 else 0) });
        defer objc.release(cfg);
        if (m.muted) objc.msg(void, cfg, "setPointOfInterestFilter:", .{objc.msg(objc.Object, objc.class("MKPointOfInterestFilter"), "filterExcludingAllCategories", .{})});
        objc.msg(void, v, "setPreferredConfiguration:", .{cfg});
    }
    if (n.user != m.user) {
        n.user = m.user;
        objc.msg(void, v, "setShowsUserLocation:", .{if (m.user) objc.YES else objc.NO});
    }
    pins(m, v);
    line(m, v);
    if (m.camera) |cam| if (n.camera == null or !std.meta.eql(cam.center, n.camera.?.center) or cam.span != n.camera.?.span) {
        n.camera = cam;
        const lng_delta = cam.span * @as(f64, if (n.frame.h > 0) n.frame.w / n.frame.h else 1);
        const region: Region = .{ .center = .{ .lat = cam.center.lat, .lng = cam.center.lng }, .lat_delta = cam.span, .lng_delta = lng_delta };
        objc.msg(void, v, "setRegion:animated:", .{ region, if (cam.animated) objc.YES else objc.NO });
    };
}

/// Adds, moves, restyles and removes annotations to match the pins.
fn pins(m: *api.Map, v: objc.Object) void {
    const n = &m.native;
    var i: usize = 0;
    while (i < n.entries.items.len) {
        const e = n.entries.items[i];
        if (find(m.pins.items, e.want.id) == null) {
            objc.msg(void, v, "removeAnnotation:", .{e.ann});
            objc.release(e.ann);
            _ = n.entries.swapRemove(i);
        } else i += 1;
    }
    for (m.pins.items) |w| {
        const at: Coordinate = .{ .lat = w.at.lat, .lng = w.at.lng };
        if (entryOf(n, w.id)) |e| {
            if (!std.meta.eql(e.want.at, w.at)) glide(e.ann, at);
            if (!e.want.same(w)) {
                e.want = w;
                if (objc.msg(?objc.Object, v, "viewForAnnotation:", .{e.ann})) |av| style(av, &e.want);
            }
            e.want = w;
            continue;
        }
        const ann = objc.new("MKPointAnnotation");
        objc.msg(void, ann, "setCoordinate:", .{at});
        n.entries.append(m.gpa, .{ .want = w, .ann = ann }) catch {
            objc.release(ann);
            continue;
        };
        objc.msg(void, v, "addAnnotation:", .{ann});
    }
}

fn find(ws: []const api.Want, id: u64) ?usize {
    for (ws, 0..) |w, i| if (w.id == id) return i;
    return null;
}

fn entryOf(n: *Native, id: u64) ?*Entry {
    for (n.entries.items) |*e| if (e.want.id == id) return e;
    return null;
}

/// Moves an annotation over a second, as a bus moves between fixes.
fn glide(ann: objc.Object, to: Coordinate) void {
    const Move = struct {
        ann: objc.Object,
        to: Coordinate,
        fn run(mv: *@This()) void {
            objc.msg(void, mv.ann, "setCoordinate:", .{mv.to});
        }
    };
    var mv: Move = .{ .ann = ann, .to = to };
    var block = objc.Block(Move, &.{}).init(&mv, Move.run);
    objc.msg(void, objc.class("UIView"), "animateWithDuration:animations:", .{ @as(f64, 1.0), @as(*anyopaque, @ptrCast(&block)) });
}

/// The route's polyline, replaced when its points change.
fn line(m: *api.Map, v: objc.Object) void {
    const n = &m.native;
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(m.line.items));
    h.update(std.mem.asBytes(&m.line_color));
    h.update(std.mem.asBytes(&m.line_width));
    const hash = h.final();
    if (hash == n.line_hash) return;
    n.line_hash = hash;
    if (n.overlay) |o| {
        objc.msg(void, v, "removeOverlay:", .{o});
        objc.release(o);
        n.overlay = null;
    }
    if (m.line.items.len < 2) return;
    const coords = m.gpa.alloc(Coordinate, m.line.items.len) catch return;
    defer m.gpa.free(coords);
    for (m.line.items, coords) |p, *c| c.* = .{ .lat = p.lat, .lng = p.lng };
    const poly = objc.retain(objc.msg(objc.Object, objc.class("MKPolyline"), "polylineWithCoordinates:count:", .{ @as(*const anyopaque, coords.ptr), @as(objc.NSUInteger, coords.len) }));
    n.overlay = poly;
    // Above roads (0), under the labels.
    objc.msg(void, v, "addOverlay:level:", .{ poly, @as(objc.NSInteger, 0) });
}

fn uiColor(c: types.Color) objc.Object {
    return objc.msg(objc.Object, objc.class("UIColor"), "colorWithRed:green:blue:alpha:", .{ @as(objc.CGFloat, c.r), @as(objc.CGFloat, c.g), @as(objc.CGFloat, c.b), @as(objc.CGFloat, c.a) });
}

const label_tag: objc.NSInteger = 7301;

/// A pin's look: the chip's colors, text and size.
fn style(av: objc.Object, w: *const api.Want) void {
    const lbl = objc.msg(?objc.Object, av, "viewWithTag:", .{label_tag}) orelse return;
    const bus = w.style == .bus;
    const fill: types.Color = if (bus) .hex(0x1C1C1E) else if (w.selected) .hex(0x111111) else .hex(0xFFD100);
    const ink: types.Color = if (bus) .hex(0xFFFFFF) else if (w.selected) .hex(0xFFD100) else .hex(0x111111);
    objc.msg(void, lbl, "setText:", .{objc.nsString(w.label())});
    objc.msg(void, lbl, "setTextColor:", .{uiColor(ink)});
    objc.msg(void, lbl, "setBackgroundColor:", .{uiColor(fill)});
    const font = objc.msg(objc.Object, objc.class("UIFont"), "monospacedDigitSystemFontOfSize:weight:", .{ @as(objc.CGFloat, if (bus) 12 else 11), @as(objc.CGFloat, 0.4) });
    objc.msg(void, lbl, "setFont:", .{font});
    objc.msg(void, lbl, "sizeToFit", .{});
    const fit = objc.msg(objc.CGRect, lbl, "bounds", .{});
    const hgt: objc.CGFloat = if (bus) 22 else 20;
    const wid = @max(fit.size.width + 12, hgt);
    const rect: objc.CGRect = .{ .size = .{ .width = wid, .height = hgt } };
    objc.msg(void, lbl, "setFrame:", .{rect});
    objc.msg(void, av, "setFrame:", .{rect});
    const layer = objc.msg(objc.Object, lbl, "layer", .{});
    objc.msg(void, layer, "setCornerRadius:", .{if (bus) hgt / 2 else @as(objc.CGFloat, 6)});
    objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    // Selected and buses above the rest.
    objc.msg(void, objc.msg(objc.Object, av, "layer", .{}), "setZPosition:", .{@as(objc.CGFloat, if (bus) 2 else if (w.selected) 1 else 0)});
}

fn defineDelegate() void {
    _ = objc.defineClass(.{
        .name = "NanouiMapDelegate",
        .protocols = &.{"MKMapViewDelegate"},
        .methods = &.{
            .{ .name = "mapView:viewForAnnotation:", .imp = &viewFor, .types = "@@:@@" },
            .{ .name = "mapView:rendererForOverlay:", .imp = &rendererFor, .types = "@@:@@" },
            .{ .name = "mapView:didSelectAnnotationView:", .imp = &selected, .types = "v@:@@" },
        },
    });
}

fn viewFor(obj: objc.Object, _: objc.SEL, _: objc.Object, ann: objc.Object) callconv(.c) ?objc.Object {
    const m = objc.getZig(api.Map, obj) orelse return null;
    // The device's own dot stays MapKit's.
    if (objc.msg(objc.BOOL, ann, "isKindOfClass:", .{objc.class("MKUserLocation")}) == objc.YES) return null;
    var it: ?*Entry = null;
    for (m.native.entries.items) |*e| if (e.ann == ann) {
        it = e;
    };
    const e = it orelse return null;
    const av = objc.msg(objc.Object, objc.alloc("MKAnnotationView"), "initWithAnnotation:reuseIdentifier:", .{ ann, @as(?objc.Object, null) });
    objc.autorelease(av);
    objc.msg(void, av, "setDisplayPriority:", .{@as(f32, 1000)});
    objc.msg(void, av, "setCollisionMode:", .{@as(objc.NSInteger, 1)});
    const shadow = objc.msg(objc.Object, av, "layer", .{});
    objc.msg(void, shadow, "setShadowOpacity:", .{@as(f32, 0.25)});
    objc.msg(void, shadow, "setShadowRadius:", .{@as(objc.CGFloat, 2)});
    objc.msg(void, shadow, "setShadowOffset:", .{objc.CGSize{ .width = 0, .height = 1 }});
    const lbl = objc.msg(objc.Object, objc.alloc("UILabel"), "initWithFrame:", .{objc.CGRect{}});
    defer objc.release(lbl);
    objc.msg(void, lbl, "setTag:", .{label_tag});
    objc.msg(void, lbl, "setTextAlignment:", .{@as(objc.NSInteger, 1)});
    objc.msg(void, av, "addSubview:", .{lbl});
    style(av, &e.want);
    return av;
}

fn rendererFor(obj: objc.Object, _: objc.SEL, _: objc.Object, overlay: objc.Object) callconv(.c) ?objc.Object {
    const m = objc.getZig(api.Map, obj) orelse return null;
    const r = objc.msg(objc.Object, objc.alloc("MKPolylineRenderer"), "initWithPolyline:", .{overlay});
    objc.autorelease(r);
    objc.msg(void, r, "setStrokeColor:", .{uiColor(m.line_color)});
    objc.msg(void, r, "setLineWidth:", .{@as(objc.CGFloat, m.line_width)});
    return r;
}

fn selected(obj: objc.Object, _: objc.SEL, mv: objc.Object, av: objc.Object) callconv(.c) void {
    const m = objc.getZig(api.Map, obj) orelse return;
    const ann = objc.msg(?objc.Object, av, "annotation", .{}) orelse return;
    // A tap, not a selection: the app says which pin looks chosen.
    objc.msg(void, mv, "deselectAnnotation:animated:", .{ ann, objc.NO });
    for (m.native.entries.items) |e| if (e.ann == ann) {
        m.tapped = e.want.id;
        if (m.native.surface) |s| s.requestFrame();
    };
}

/// For the surface's view: touches on a map's hole go to the map, unless
/// a box of the UI drawn over it is there; all others to the UI.
pub const view_methods = [_]objc.Method{
    .{ .name = "hitTest:withEvent:", .imp = &hitTest, .types = "@@:{CGPoint=dd}@" },
};

fn hitTest(obj: objc.Object, _: objc.SEL, point: objc.CGPoint, event: ?objc.Object) callconv(.c) ?objc.Object {
    const hit = objc.msgSuper(?objc.Object, obj, objc.class("UIView"), "hitTest:withEvent:", .{ point, event }) orelse return null;
    if (hit == obj) return hit;
    const s = objc.getZig(Surface, obj) orelse return hit;
    for (maps) |entry| {
        const m = entry orelse continue;
        const v = m.native.view orelse continue;
        if (m.native.surface != s or !m.native.shown) continue;
        if (objc.msg(objc.BOOL, hit, "isDescendantOfView:", .{v}) != objc.YES) continue;
        const p: types.Point = .{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
        var i = s.ctx.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = s.ctx.hits.items[i];
            if (h.scroll or !h.rect.contains(p)) continue;
            return if (h.id == m.id) hit else obj;
        }
        return hit;
    }
    return hit;
}
