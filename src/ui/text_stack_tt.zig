//! The fonts of a text that names families (`TextStyle.family`) where nanoui reads
//! fonts itself: each name to its face at this style, a font the app brought or
//! an installed one, and a character to the first of them that has it.
const std = @import("std");
const registry = @import("font_registry.zig");
const types = @import("types.zig");

pub const Entry = struct {
    /// The run font: its face at this size.
    id: u16,
    /// The characters it serves, empty for all (owned).
    ranges: []const [2]u21 = &.{},
};

pub const Stack = struct {
    entries: []Entry,
    /// The first entry with the space: the one whose metrics a line takes.
    primary: u8 = 0,

    pub fn destroy(st: *Stack, gpa: std.mem.Allocator) void {
        for (st.entries) |e| gpa.free(e.ranges);
        gpa.free(st.entries);
        gpa.destroy(st);
    }

    /// The entry that draws `cp` and its glyph; null when none has it.
    pub fn pick(st: *const Stack, run_fonts: anytype, cp: u21) ?struct { id: u16, glyph: u16 } {
        for (st.entries) |e| {
            if (!registry.rangesCover(e.ranges, cp) or e.id >= run_fonts.len) continue;
            const g = run_fonts[e.id].font.glyphIndex(cp);
            if (g != 0) return .{ .id = e.id, .glyph = g };
        }
        return null;
    }
};

const serifs = [_][]const u8{ "New York", "Times New Roman", "Liberation Serif", "Noto Serif", "DejaVu Serif", "Georgia", "Times" };

/// The face a name means when no font was brought under it.
fn installed(ts: anytype, name: []const u8, weight: u16, style: types.TextStyle) ?u32 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "system-ui") or eq(name, "ui-rounded")) return ts.db.match(null, weight, style.italic, false);
    if (eq(name, "ui-monospace")) return ts.db.match(null, weight, style.italic, true);
    if (eq(name, "ui-serif")) {
        for (serifs) |n| if (ts.db.family(n, weight, style.italic)) |f| return f;
        return null;
    }
    return ts.db.familyStretch(name, weight, style.italic, style.stretch);
}

/// The fonts of a family list, at a style. Null when not one of them exists.
pub fn build(ts: anytype, list: []const u8, style: types.TextStyle) ?*Stack {
    const gpa = ts.gpa;
    const size = style.size * ts.zoom;
    const weight = style.weightValue();
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0 or entries.items.len >= 200) continue;
        var chosen: [64]*const registry.Face = undefined;
        const n = registry.best(name, weight, style.italic, style.stretch, &chosen);
        if (n > 0) {
            for (chosen[0..n]) |face| {
                const fc = if (face.local) |l| ts.db.family(l, weight, style.italic) else ts.db.addBrought(face);
                const db_face = fc orelse continue;
                // A face said to be this heavy is taken at its word; a variable
                // font's range isn't reachable here, so its one instance thickens.
                const id = ts.runFont(db_face, size, style.italic, if (face.weight[0] == face.weight[1] and face.weight[1] >= 600) 400 else weight);
                if (id == 0xffff) continue;
                const ranges = gpa.dupe([2]u21, face.ranges) catch continue;
                entries.append(gpa, .{ .id = id, .ranges = ranges }) catch gpa.free(ranges);
            }
            continue;
        }
        const db_face = installed(ts, name, weight, style) orelse continue;
        const id = ts.runFont(db_face, size, style.italic, weight);
        if (id != 0xffff) entries.append(gpa, .{ .id = id }) catch {};
    }
    if (entries.items.len == 0) return null;
    const st = gpa.create(Stack) catch return null;
    const owned = entries.toOwnedSlice(gpa) catch {
        gpa.destroy(st);
        return null;
    };
    st.* = .{ .entries = owned };
    for (owned, 0..) |e, i| if (registry.rangesCover(e.ranges, ' ') and i < 255) {
        st.primary = @intCast(i);
        break;
    };
    return st;
}
