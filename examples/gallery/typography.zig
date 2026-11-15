//! The gallery's Typography page: type scale and wrapping, Unicode 17
//! UAX #29 double-click selection (grapheme clusters, emoji, scripts), and
//! rich spans with live `.ellipsis`, `.middle`, and `.fade` truncation.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const phone = @import("phone.zig");

const s_pre = "Build native interfaces with ";
const s_bold = "semibold emphasis";
const s_mid = ", ";
const s_italic = "italic rhythm";
const s_and = ", ";
const s_mono = "ui.richText";
const s_in = " spans, and ";
const s_link = "accented highlights";
const s_end = " inside one shaped paragraph.";
const rich_line = s_pre ++ s_bold ++ s_mid ++ s_italic ++ s_and ++ s_mono ++ s_in ++ s_link ++ s_end;

pub const Demo = struct {
    box_width: f32 = 300,

    pub fn view(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Typography");

        ui.card(c, .{ .width = .fill, .gap = 10, .max_width = 640, .selectable = true });
        {
            defer ui.end(c);
            ui.text(c, "Large Title", .{ .size = 30, .weight = .bold });
            ui.text(c, "Title, semibold", .{ .size = 20, .weight = .semibold });
            ui.text(c, "Body text in the system font, at 14 points.", .{});
            ui.text(c, "const mono = \"monospaced, for code\";", .{ .mono = true, .size = 13 });
            ui.text(c, "Unicode: naïve café — 日本語 — Ελληνικά — ✓ ★ →", .{});
            ui.divider(c);
            ui.text(c, "Text wraps to the width its box gets. Resize the window to watch these lines break " ++
                "again: layout runs every frame, measured with CoreText, and each line is rasterized once into a " ++
                "glyph atlas at the display's scale, then drawn as textured quads by one instanced Metal draw " ++
                "call together with every rectangle, border and shadow on screen.", .{ .wrap = true, .color = th.muted });
        }

        ui.card(c, .{ .width = .fill, .gap = 10, .max_width = 640, .selectable = true });
        {
            defer ui.end(c);
            const hdr = ui.div(c).row().wFull().gap(8).itemsCenter();
            ui.text(c, "Selection · Unicode 17", .{ .weight = .semibold });
            ui.spacer(c);
            kit.kbd(c, "Double-click");
            kit.kbd(c, ui.keys.label("⌘C"));
            hdr.end();
            ui.text(c, "Double-clicking a word or symbol stops at UAX #29 extended grapheme and word boundaries.", .{ .size = 12.5, .wrap = true, .color = th.muted });
            ui.text(c, "Emoji clusters: \u{1f469}\u{200d}\u{1f4bb}  \u{1f680}  \u{1f1ef}\u{1f1f5}  \u{1f44d}\u{1f3fd}  \u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", .{});
            ui.text(c, "Scripts & words: naïve café · 日本語の単語 · Ελληνικά", .{});
            ui.text(c, "Code & numbers: std.mem.eql(a, b) · don't · 1,024.50", .{ .mono = true, .size = 13 });
        }

        ui.card(c, .{ .width = .fill, .gap = 12, .max_width = 640 });
        {
            defer ui.end(c);
            ui.text(c, "Rich spans & truncation", .{ .weight = .semibold });
            const p0: u32 = s_pre.len;
            const p1: u32 = p0 + s_bold.len;
            const p2: u32 = p1 + s_mid.len;
            const p3: u32 = p2 + s_italic.len;
            const p4: u32 = p3 + s_and.len;
            const p5: u32 = p4 + s_mono.len;
            const p6: u32 = p5 + s_in.len;
            const p7: u32 = p6 + s_link.len;
            const spans = c.alloc().dupe(ui.Span, &.{
                .{ .start = p0, .end = p1, .weight = .semibold },
                .{ .start = p2, .end = p3, .italic = true, .color = th.muted },
                .{ .start = p4, .end = p5, .mono = true, .background = th.surface_hover },
                .{ .start = p6, .end = p7, .color = th.accent, .underline = true },
            }) catch &.{};
            ui.richText(c, rich_line, spans, .{ .wrap = true });

            ui.divider(c);
            const max_w: f32 = if (phone.compact(c)) 280 else 520;
            const min_w: f32 = 180;
            d.box_width = std.math.clamp(d.box_width, min_w, max_w);
            {
                const ctrl = ui.div(c).row().wFull().gap(10).itemsCenter();
                defer ctrl.end();
                ui.text(c, "Preview width", .{ .size = 12.5, .color = th.muted });
                _ = ui.slider(c, &d.box_width, .{
                    .label = "Preview width",
                    .min = min_w,
                    .max = max_w,
                    .width = .{ .px = if (phone.compact(c)) 140 else 220 },
                });
                ui.textf(c, .{ .size = 12, .mono = true, .color = th.muted }, "{d:.0} pt", .{d.box_width});
            }

            const sample = "/Users/ada/Projects/nanoui/src/ui/text_selection_breaks_smp.zig";
            const modes = [_]struct { label: []const u8, mode: ui.Truncate }{
                .{ .label = ".ellipsis", .mode = .ellipsis },
                .{ .label = ".middle", .mode = .middle },
                .{ .label = ".fade", .mode = .fade },
            };
            for (modes) |m| {
                ui.key(c, m.label);
                const r = ui.div(c).row().gap(10).itemsCenter();
                defer r.end();
                const tag = ui.div(c).w(66);
                ui.text(c, m.label, .{ .size = 12, .mono = true, .color = th.muted });
                tag.end();
                const box = ui.div(c).row().w(d.box_width).px(10).py(6).rounded(6).bg(th.background).border(th.border).clip();
                defer box.end();
                ui.text(c, sample, .{ .size = 13, .mono = true, .truncate = m.mode });
            }
        }
    }
};
