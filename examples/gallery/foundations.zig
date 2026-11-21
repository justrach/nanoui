//! The gallery's foundations: the theme's colors, light and dark side by
//! side, the kit's tokens, and every icon nanoui draws by name.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const page = @import("page.zig");

pub const Demo = struct {
    icon_search: ui.TextBuffer = .{},

    pub fn deinit(d: *Demo) void {
        d.icon_search.deinit();
    }

    pub fn colors(_: *Demo, c: *ui.Context) void {
        page.begin(c, "Colors", "ui.Theme.light · ui.Theme.dark_theme · kit.tokens(c)  ·  src/ui/theme.zig", null);
        defer page.end(c);
        {
            const s = page.section(c, "Theme");
            defer s.end();
            {
                const head = ui.div(c).row().gap(12).itemsCenter();
                defer head.end();
                const l = ui.div(c).w(name_w);
                l.end();
                for ([_][]const u8{ "Light", "Dark" }) |t| {
                    const col = ui.div(c).w(swatch_w);
                    defer col.end();
                    ui.text(c, t, .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
                }
            }
            const info = @typeInfo(ui.Theme).@"struct";
            inline for (info.field_names, info.field_types) |name, T| {
                if (T == ui.Color) {
                    ui.key(c, name);
                    themeRow(c, name, @field(ui.Theme.light, name), @field(ui.Theme.dark_theme, name));
                }
            }
        }
        {
            const s = page.section(c, "Kit tokens, in this theme");
            defer s.end();
            const t = kit.tokens(c);
            const info = @typeInfo(kit.Tokens).@"struct";
            inline for (info.field_names, info.field_types) |name, T| {
                if (T == ui.Color) {
                    ui.key(c, "kit-" ++ name);
                    const r = ui.div(c).row().gap(12).itemsCenter();
                    defer r.end();
                    nameCell(c, name);
                    swatch(c, @field(t, name));
                }
            }
        }
    }

    pub fn icons(d: *Demo, c: *ui.Context, sidebar: f32) void {
        const q = d.icon_search.text();
        const total = ui.icons.all.len;
        const shown = matchCount(q);
        const count = if (q.len == 0) c.print("{d} icons", .{total}) else c.print("{d} of {d} icons", .{ shown, total });
        page.begin(c, "Icons", c.print("{s}  ·  ui.icon(c, name, .{{ .size, .color }})  ·  src/ui/icons.zig", .{count}), .of(d, search));
        defer page.end(c);
        page.note(c, "SF Symbols' names: macOS and iOS draw the symbol itself, elsewhere nanoui draws these line icons.");
        if (shown == 0) {
            kit.empty(c, .{ .icon = "magnifyingglass", .title = "No icon matches", .description = "Try part of a name: arrow, doc, square." });
            return;
        }
        const cell: f32 = 116;
        const gap: f32 = 8;
        const width = page.contentWidth(c, sidebar);
        const per_row: usize = @max(1, @as(usize, @intFromFloat((width + gap) / (cell + gap))));
        var in_row: usize = 0;
        var r: ?ui.Div = null;
        for (ui.icons.all) |icon| {
            if (!matches(icon.name, q)) continue;
            if (in_row == 0) r = ui.div(c).row().gap(gap);
            ui.key(c, icon.name);
            const box = ui.div(c).column().w(cell).h(84).gap(8).center().rounded(8).bg(c.theme.surface).border(c.theme.border).tooltip(icon.name, .{});
            ui.icon(c, icon.name, .{ .size = 22, .frame = 28, .color = c.theme.text });
            {
                const label = ui.div(c).wFull().px(8).center();
                defer label.end();
                ui.text(c, icon.name, .{ .size = 10.5, .color = c.theme.muted, .truncate = .middle });
            }
            box.end();
            in_row += 1;
            if (in_row == per_row) {
                r.?.end();
                in_row = 0;
            }
        }
        if (in_row != 0) r.?.end();
    }

    fn search(d: *Demo, c: *ui.Context) void {
        if (c.focus != 0 and c.shortcut(.{ .key = ui.Shortcut.escape })) d.icon_search.clear();
        // One field, the glass inside it at the left.
        const box = ui.div(c).row().w(240).h(30).pl(8).pr(10).gap(6).itemsCenter().rounded(7).bg(c.theme.surface).border(c.theme.border);
        defer box.end();
        ui.icon(c, "magnifyingglass", .{ .size = 13, .frame = 16, .color = c.theme.muted });
        _ = ui.textField(c, &d.icon_search, .{ .placeholder = "Search icons", .width = .fill, .size = 13, .bare = true });
    }
};

const name_w: f32 = 150;
const swatch_w: f32 = 150;

fn nameCell(c: *ui.Context, name: []const u8) void {
    const l = ui.div(c).w(name_w);
    defer l.end();
    ui.text(c, name, .{ .size = 12.5, .mono = true });
}

fn themeRow(c: *ui.Context, name: []const u8, light: ui.Color, dark: ui.Color) void {
    const r = ui.div(c).row().gap(12).itemsCenter();
    defer r.end();
    nameCell(c, name);
    swatch(c, light);
    swatch(c, dark);
}

/// A chip of the color on a checkerboard-free plate, and its value.
fn swatch(c: *ui.Context, col: ui.Color) void {
    const cell = ui.div(c).row().w(swatch_w).gap(8).itemsCenter();
    defer cell.end();
    const chip = ui.div(c).w(28).h(20).rounded(5).bg(col).border(c.theme.border);
    chip.end();
    ui.text(c, hex(c, col), .{ .size = 11.5, .mono = true, .color = c.theme.muted });
}

fn hex(c: *ui.Context, col: ui.Color) []const u8 {
    const b = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    if (col.a >= 1) return c.print("#{x:0>2}{x:0>2}{x:0>2}", .{ b(col.r), b(col.g), b(col.b) });
    return c.print("#{x:0>2}{x:0>2}{x:0>2} · {d:.0}%", .{ b(col.r), b(col.g), b(col.b), col.a * 100 });
}

fn matches(name: []const u8, q: []const u8) bool {
    if (q.len > name.len) return false;
    var i: usize = 0;
    while (i + q.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i..][0..q.len], q)) return true;
    }
    return false;
}

fn matchCount(q: []const u8) usize {
    var n: usize = 0;
    for (ui.icons.all) |icon| n += @intFromBool(matches(icon.name, q));
    return n;
}
