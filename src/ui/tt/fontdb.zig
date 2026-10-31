//! The fonts installed: found in the system's font folders once, each
//! face known by its family, weight, italics and width, and loaded when
//! first used. Matching a style picks the family's nearest face; a
//! character a font lacks is found in the fallback families, then in any
//! face that has it.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("font.zig");

pub const Face = struct {
    path: []const u8,
    index: u32,
    style: font.Style,
    /// A font the app brought (`ui.registerFont`): its bytes, not a file.
    memory: ?[]const u8 = null,

    fn read(f: Face, db: *Db) ![]u8 {
        if (f.memory) |m| return db.gpa.dupe(u8, m);
        return std.Io.Dir.cwd().readFileAlloc(db.io, f.path, db.gpa, .limited(256 << 20));
    }
};

const Loaded = struct {
    data: []u8,
    font: font.Font,
};

const android = builtin.abi.isAndroid();
/// Families tried when the theme names none (or one not installed):
/// Android's own first there.
const sans = (if (android) [_][]const u8{"Roboto"} else [_][]const u8{}) ++ [_][]const u8{ "Inter", "Geist", "Segoe UI", "Noto Sans", "Cantarell", "Ubuntu", "DejaVu Sans", "Liberation Sans", "Arial", "Helvetica" };
const monos = (if (android) [_][]const u8{ "Droid Sans Mono", "Cutive Mono" } else [_][]const u8{}) ++ [_][]const u8{ "JetBrains Mono", "Geist Mono", "Cascadia Mono", "Consolas", "Noto Sans Mono", "DejaVu Sans Mono", "Ubuntu Mono", "Liberation Mono", "Menlo", "Courier New" };
/// Families a CJK string needs when the UI family has no glyph for it:
/// Windows, macOS and Linux each name theirs. Kept ahead of the symbol
/// fallbacks so a hanzi never lands in a partial-coverage font.
const cjk = [_][]const u8{ "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Noto Sans SC", "Source Han Sans SC", "SimSun", "MS Gothic" };
/// Where characters a font lacks are looked for first.
const fallbacks = cjk ++ [_][]const u8{ "Noto Sans", "DejaVu Sans", "Segoe UI Symbol", "Noto Sans Symbols", "Noto Sans Symbols2", "Arial Unicode MS", "Symbola" };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

pub const Db = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    faces: std.ArrayList(Face) = .empty,
    loaded: std.AutoHashMapUnmanaged(u32, *Loaded) = .empty,
    scanned: bool = false,
    /// Characters' fallback faces, found once (null: none has it).
    found: std.AutoHashMapUnmanaged(u21, ?u32) = .empty,
    /// How many of the app's fonts (`font_registry`) are added.
    bundled: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Db {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(db: *Db) void {
        for (db.faces.items) |f| db.gpa.free(f.path);
        db.faces.deinit(db.gpa);
        var it = db.loaded.valueIterator();
        while (it.next()) |l| {
            db.gpa.free(l.*.data);
            db.gpa.destroy(l.*);
        }
        db.loaded.deinit(db.gpa);
        db.found.deinit(db.gpa);
    }

    /// Adds the faces of fonts the app registered since last asked.
    fn addBundled(db: *Db) void {
        const all = @import("../font_registry.zig").registered();
        while (db.bundled < all.len) : (db.bundled += 1) db.addMemory(all[db.bundled]);
    }

    /// Adds the faces of a font file's bytes, kept by the caller.
    pub fn addMemory(db: *Db, data: []const u8) void {
        for (0..font.faces(data)) |i| {
            const t = font.Tables.read(data, i) catch continue;
            const style = font.Style.read(data, t);
            if (style.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, "") catch return;
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = style, .memory = data }) catch db.gpa.free(owned);
        }
    }

    /// Adds the faces of the fonts in the system's font folders, after
    /// those the app brought.
    pub fn scan(db: *Db) void {
        db.addBundled();
        if (db.scanned) return;
        db.scanned = true;
        var buf: [1024]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => {
                db.scanDir("C:\\Windows\\Fonts");
                // Under Wine, the Linux system's fonts are on drive Z:.
                if (db.faces.items.len < 8) db.scanDir("Z:\\usr\\share\\fonts");
            },
            .macos => {
                for ([_][]const u8{ "/System/Library/Fonts", "/Library/Fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| db.scanDir(std.fmt.bufPrint(&buf, "{s}/Library/Fonts", .{home}) catch return);
            },
            else => if (android) {
                for ([_][]const u8{ "/system/fonts", "/product/fonts" }) |d| db.scanDir(d);
            } else {
                for ([_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" }) |d| db.scanDir(d);
                if (env("HOME")) |home| {
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.local/share/fonts", .{home}) catch return);
                    db.scanDir(std.fmt.bufPrint(&buf, "{s}/.fonts", .{home}) catch return);
                }
            },
        }
    }

    pub fn scanDir(db: *Db, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(db.io, path, .{ .iterate = true }) catch return;
        defer dir.close(db.io);
        var walker = dir.walk(db.gpa) catch return;
        defer walker.deinit();
        while (walker.next(db.io) catch null) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            const ext = std.fs.path.extension(e.basename);
            if (!std.ascii.eqlIgnoreCase(ext, ".ttf") and !std.ascii.eqlIgnoreCase(ext, ".ttc")) continue;
            var full: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&full, "{s}{c}{s}", .{ path, std.fs.path.sep, e.path }) catch continue;
            db.addFile(p);
        }
    }

    /// Reads a file's faces' styles, touching only the tables they need.
    pub fn addFile(db: *Db, path: []const u8) void {
        var file = std.Io.Dir.cwd().openFile(db.io, path, .{}) catch return;
        defer file.close(db.io);
        const len = file.length(db.io) catch return;
        if (len < 12 or len > 256 << 20) return;
        // Untouched pages of an anonymous mapping cost nothing: the
        // tables read land at their offsets, the rest stays unread.
        const data = std.heap.page_allocator.alloc(u8, len) catch return;
        defer std.heap.page_allocator.free(data);
        _ = file.readPositionalAll(db.io, data[0..@min(len, 64 * 1024)], 0) catch return;
        for (0..font.faces(data)) |i| {
            const t = font.Tables.read(data, i) catch continue;
            inline for (.{ "head", "os2", "name" }) |name| {
                const off = @field(t, name);
                const want: usize = if (std.mem.eql(u8, name, "name")) t.name_len else 100;
                if (off != 0 and off < len) _ = file.readPositionalAll(db.io, data[off..@min(len, off + want)], off) catch {};
            }
            const style = font.Style.read(data, t);
            if (style.family_len == 0) continue;
            const owned = db.gpa.dupe(u8, path) catch return;
            db.faces.append(db.gpa, .{ .path = owned, .index = @intCast(i), .style = style }) catch db.gpa.free(owned);
        }
    }

    /// The face of `family` nearest `weight` and `italic`, null when the
    /// family has none.
    pub fn family(db: *Db, name: []const u8, weight: u16, italic: bool) ?u32 {
        db.scan();
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |f, i| {
            if (!std.ascii.eqlIgnoreCase(f.style.name(), name)) continue;
            const dw: u32 = @abs(@as(i32, f.style.weight) - @as(i32, weight));
            const score = dw + @as(u32, if (f.style.italic != italic) 1000 else 0);
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// The face for a style: its family if installed, else the first
    /// installed of the defaults.
    pub fn match(db: *Db, name: ?[]const u8, weight: u16, italic: bool, mono: bool) ?u32 {
        if (name) |n| if (db.family(n, weight, italic)) |f| return f;
        for (if (mono) &monos else &sans) |n| if (db.family(n, weight, italic)) |f| return f;
        db.scan();
        for (db.faces.items, 0..) |f, i| if (f.style.mono == mono) return @intCast(i);
        return if (db.faces.items.len > 0) 0 else null;
    }

    /// A face's font, loaded on first use (null if it cannot be read).
    pub fn load(db: *Db, face: u32) ?*const font.Font {
        if (db.loaded.get(face)) |l| return &l.font;
        const f = db.faces.items[face];
        const data = f.read(db) catch return null;
        const parsed = font.Font.init(data, f.index) catch {
            db.gpa.free(data);
            return null;
        };
        const l = db.gpa.create(Loaded) catch {
            db.gpa.free(data);
            return null;
        };
        l.* = .{ .data = data, .font = parsed };
        l.font.data = l.data;
        db.loaded.put(db.gpa, face, l) catch {};
        return &l.font;
    }

    /// A face that has `cp`, for text its font lacks.
    pub fn fallback(db: *Db, cp: u21, weight: u16) ?u32 {
        if (db.found.get(cp)) |f| return f;
        const f = db.findFallback(cp, weight);
        db.found.put(db.gpa, cp, f) catch {};
        return f;
    }

    fn findFallback(db: *Db, cp: u21, weight: u16) ?u32 {
        for (fallbacks) |n| if (db.family(n, weight, false)) |face| {
            if (db.load(face)) |f| if (f.glyphIndex(cp) != 0) return face;
        };
        // Any face at all: the loaded first, then the rest.
        var it = db.loaded.iterator();
        while (it.next()) |e| if (e.value_ptr.*.font.glyphIndex(cp) != 0) return e.key_ptr.*;
        // Read, checked and let go unless it has it; a few dozen at most.
        var tries: usize = 0;
        for (0..db.faces.items.len) |i| {
            if (tries >= 48) break;
            if (db.loaded.contains(@intCast(i))) continue;
            if (i > 0 and std.mem.eql(u8, db.faces.items[i - 1].style.name(), db.faces.items[i].style.name())) continue;
            tries += 1;
            const face = db.faces.items[i];
            const data = face.read(db) catch continue;
            defer db.gpa.free(data);
            const f = font.Font.init(data, face.index) catch continue;
            if (f.glyphIndex(cp) != 0) return @intCast(i);
        }
        return null;
    }
};
