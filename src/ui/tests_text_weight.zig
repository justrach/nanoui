//! Verifies that glyph coverage in the atlas matches AppKit's text rendering
//! within 3% across sizes (11, 12, 13, 15 pt), weights (regular, medium,
//! semibold) and appearances (light, dark).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("ui.zig");
const text_mod = @import("text.zig");

test "glyph weight matches AppKit within 3% across sizes, weights and appearances" {
    if (builtin.os.tag != .macos or text_mod.portable) return error.SkipZigTest;
    const objc = @import("../objc.zig");
    const cf = @import("cf.zig");
    const fonts = @import("fonts.zig");

    const sample = "Hamburgefonstiv 0123";
    const sizes = [_]f32{ 11, 12, 13, 15 };
    const weights = [_]ui.Weight{ .regular, .medium, .semibold };
    const looks = [_]bool{ false, true };

    const gpa = testing.allocator;
    const device = cf.MTLCreateSystemDefaultDevice() orelse return error.SkipZigTest;
    defer objc.release(device);
    var ts = text_mod.TextSystem.init(gpa, device);
    defer ts.deinit();
    ts.setScale(2);

    const wpx: usize = 400;
    const hpx: usize = 80;
    const ref_buf = try gpa.alloc(u8, wpx * hpx * 4);
    defer gpa.free(ref_buf);

    for (looks) |dark| {
        const pool = objc.Pool.push();
        defer pool.pop();
        for (weights) |weight| {
            for (sizes) |sz| {
                const style: ui.TextStyle = .{ .size = sz, .weight = weight };
                const lay = ts.layout(sample, style);
                for (lay.glyphs) |g| {
                    const pen = g.x * 2.0;
                    const px = @floor(pen);
                    const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, @floor((pen - px) * text_mod.subpixel_bins)));
                    _ = ts.glyph(g, bin);
                }
                const texels = try ts.atlas.read(gpa);
                defer gpa.free(texels);
                const as: f32 = @floatFromInt(ts.atlas.size);
                var atlas_sum: u64 = 0;
                for (lay.glyphs) |g| {
                    const pen = g.x * 2.0;
                    const px = @floor(pen);
                    const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, @floor((pen - px) * text_mod.subpixel_bins)));
                    const sp = ts.glyph(g, bin) orelse continue;
                    const du = if (dark) 0 else sp.uv[2] - sp.uv[0];
                    const x0: usize = @intFromFloat(@round((sp.uv[0] + du) * as));
                    const y0: usize = @intFromFloat(@round(sp.uv[1] * as));
                    const x1: usize = @intFromFloat(@round((sp.uv[2] + du) * as));
                    const y1: usize = @intFromFloat(@round(sp.uv[3] * as));
                    for (y0..y1) |y| for (x0..x1) |x| {
                        atlas_sum += texels[y * ts.atlas.size + x];
                    };
                }

                // Offscreen unattached layer-backed NSTextField drawn with cacheDisplayInRect:toBitmapImageRep:
                const nsfont = objc.msg(objc.Object, objc.class("NSFont"), "systemFontOfSize:weight:", .{ @as(f64, sz), fonts.weightValue(weight) });
                const tf = objc.msg(objc.Object, objc.class("NSTextField"), "labelWithString:", .{objc.nsString(sample)});
                objc.msg(void, tf, "setFont:", .{nsfont});
                const white = objc.msg(objc.Object, objc.class("NSColor"), "whiteColor", .{});
                const black = objc.msg(objc.Object, objc.class("NSColor"), "blackColor", .{});
                objc.msg(void, tf, "setTextColor:", .{if (dark) white else black});
                objc.msg(void, tf, "setDrawsBackground:", .{objc.YES});
                objc.msg(void, tf, "setBackgroundColor:", .{if (dark) black else white});
                objc.msg(void, tf, "setWantsLayer:", .{objc.YES});
                const app_name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
                if (objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{app_name})) |app| {
                    objc.msg(void, tf, "setAppearance:", .{app});
                }
                const bounds: objc.CGRect = .{ .origin = .{}, .size = .{ .width = 200, .height = 40 } };
                objc.msg(void, tf, "setFrame:", .{bounds});

                @memset(ref_buf, 0);
                var planes = [1]?[*]u8{ref_buf.ptr};
                const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
                    @as(*anyopaque, @ptrCast(&planes)),
                    @as(objc.NSInteger, wpx),
                    @as(objc.NSInteger, hpx),
                    @as(objc.NSInteger, 8),
                    @as(objc.NSInteger, 4),
                    objc.YES,
                    objc.NO,
                    objc.nsString("NSDeviceRGBColorSpace"),
                    @as(objc.NSInteger, wpx * 4),
                    @as(objc.NSInteger, 32),
                }) orelse return error.OutOfMemory;
                defer objc.release(rep);
                objc.msg(void, rep, "setSize:", .{bounds.size});
                objc.msg(void, tf, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, rep });

                var ref_sum: u64 = 0;
                for (0..wpx * hpx) |i| {
                    const v: u64 = ref_buf[i * 4];
                    ref_sum += if (dark) v else 255 - v;
                }

                const a_f: f64 = @floatFromInt(atlas_sum);
                const r_f: f64 = @floatFromInt(ref_sum);
                const diff = @abs(a_f - r_f) / @max(r_f, 1.0);
                try testing.expect(diff <= 0.03);
            }
        }
    }
}
