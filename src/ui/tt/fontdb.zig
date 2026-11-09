//! The fonts installed: found in the system's font folders once, each
//! face known by its family, weight, italics and width, and loaded when
//! first used. Matching a style picks the family's nearest face; a
//! character a font lacks is found in the fallback families, then in any
//! face that has it.
const std = @import("std");
const builtin = @import("builtin");
const font = @import("font.zig");
const registry = @import("../font_registry.zig");
const fontindex = @import("fontindex.zig");
const fontmap = @import("fontmap.zig");

pub const Face = struct {
    path: []const u8,
    index: u32,
    style: font.Style,
    /// The file fingerprint checked whenever a persistent cache is read.
    mtime: i128 = 0,
    size: u64 = 0,
    /// A font the app brought (`ui.registerFont`): its bytes, not a file.
    memory: ?[]const u8 = null,
    /// Brought with `ui.registerFontFace`: found only through its registration.
    private: bool = false,

    fn read(f: Face, db: *Db) !fontmap.Bytes {
        if (f.memory) |m| return .{ .data = try db.gpa.dupe(u8, m) };
        return fontmap.readFile(db.io, db.gpa, f.path);
    }
};

const Loaded = struct {
    bytes: fontmap.Bytes,
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

extern "kernel32" fn ExpandEnvironmentStringsW(src: [*:0]const u16, dst: [*]u16, size: u32) callconv(.winapi) u32;

/// The current user's own fonts on Windows, `%LOCALAPPDATA%\Microsoft\Windows\Fonts`,
/// in `buf`; null where there is no such folder to name.
pub fn userFontDir(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    // A code unit is at most three bytes of WTF-8: no more than `buf` takes.
    var wide: [341]u16 = undefined;
    const room: u32 = @intCast(@min(wide.len, buf.len / 3));
    const n = ExpandEnvironmentStringsW(std.unicode.utf8ToUtf16LeStringLiteral("%LOCALAPPDATA%\\Microsoft\\Windows\\Fonts"), &wide, room);
    // The count includes the terminator; a variable not set stays unexpanded.
    if (n < 2 or n > room or wide[0] == '%') return null;
    const dir = buf[0..std.unicode.wtf16LeToWtf8(buf, wide[0 .. n - 1])];
    return if (std.fs.path.isAbsolute(dir)) dir else null;
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
    /// Faces of `ui.registerFontFace`, added as first used.
    brought: std.AutoHashMapUnmanaged(*const registry.Face, u32) = .empty,
    disk_start: usize = 0,
    /// Persistent index, in the app's cache directory when enabled by the
    /// window surface. Tests and headless Testers leave `cache_path` null.
    cache_path: ?[]const u8 = null,
    owned_cache_path: ?[]u8 = null,
    /// A test/benchmark may scan one folder instead of the platform folders.
    fonts_dir: ?[]const u8 = null,
    cache: fontindex.Stats = .{},
    cache_dirs: std.ArrayList(fontindex.Directory) = .empty,
    cache_broken: bool = false,
    /// Instrumentation for proving a cache hit never walks or opens fonts.
    scan_files: usize = 0,
    scan_directories: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Db {
        return .{ .gpa = gpa, .io = io };
    }

    /// Enables the cross-process index below the app's own cache directory.
    pub fn enableCache(db: *Db, cache_dir: []const u8) void {
        if (db.owned_cache_path != null) return;
        const path = std.fs.path.join(db.gpa, &.{ cache_dir, "font-index-v2.bin" }) catch return;
        db.owned_cache_path = path;
        db.cache_path = path;
    }

    pub fn deinit(db: *Db) void {
        for (db.faces.items) |f| db.gpa.free(f.path);
        db.faces.deinit(db.gpa);
        var it = db.loaded.valueIterator();
        while (it.next()) |l| {
            fontmap.freeBytes(db.io, db.gpa, &l.*.bytes);
            db.gpa.destroy(l.*);
        }
        db.loaded.deinit(db.gpa);
        db.found.deinit(db.gpa);
        db.brought.deinit(db.gpa);
        for (db.cache_dirs.items) |dir| db.gpa.free(dir.path);
        db.cache_dirs.deinit(db.gpa);
        if (db.owned_cache_path) |path| db.gpa.free(path);
    }

    /// The face of a font the app brought, added the first time.
    pub fn addBrought(db: *Db, face: *const registry.Face) ?u32 {
        if (db.brought.get(face)) |i| return i;
        if (face.bytes.len == 0) return null;
        const t = font.Tables.read(face.bytes, 0) catch return null;
        const owned = db.gpa.dupe(u8, "") catch return null;
        db.faces.append(db.gpa, .{ .path = owned, .index = 0, .style = font.Style.read(face.bytes, t), .memory = face.bytes, .private = true }) catch {
            db.gpa.free(owned);
            return null;
        };
        const i: u32 = @intCast(db.faces.items.len - 1);
        db.brought.put(db.gpa, face, i) catch {};
        return i;
    }

    /// Faces the app brought may be gone: forgets them all, loaded copies
    /// too. Their numbers stay taken, so none now means another. Nothing may
    /// hold a run font of them (the text system dropped its own first).
    pub fn dropBrought(db: *Db) void {
        var it = db.brought.valueIterator();
        while (it.next()) |i| {
            db.faces.items[i.*].memory = "";
            if (db.loaded.fetchRemove(i.*)) |kv| {
                fontmap.freeBytes(db.io, db.gpa, &kv.value.bytes);
                db.gpa.destroy(kv.value);
            }
        }
        db.brought.clearRetainingCapacity();
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
    /// those the app brought. A valid persistent index replaces the scan.
    pub fn scan(db: *Db) void {
        db.addBundled();
        if (db.scanned) return;
        db.disk_start = db.faces.items.len;
        db.scanned = true;
        if (db.loadCached()) return;
        db.scanFonts();
        db.saveCached();
    }

    fn cacheScope(db: *const Db) []const u8 {
        return db.fonts_dir orelse "system";
    }

    fn loadCached(db: *Db) bool {
        const path = db.cache_path orelse return false;
        const entries = fontindex.read(db.gpa, db.io, path, db.cacheScope()) catch |err| {
            db.cache.state = switch (err) {
                error.NotFound => .miss,
                error.Stale => .stale,
                error.OutOfMemory, error.Unreadable => .unreadable,
                else => .damaged,
            };
            return false;
        };
        defer db.gpa.free(entries);
        for (entries) |entry| {
            db.faces.append(db.gpa, .{
                .path = entry.path,
                .index = entry.index,
                .style = entry.style,
                .mtime = entry.mtime,
                .size = entry.size,
            }) catch {
                db.gpa.free(entry.path);
                continue;
            };
        }
        db.cache.state = .hit;
        db.cache.faces = entries.len;
        return true;
    }

    fn saveCached(db: *Db) void {
        const path = db.cache_path orelse return;
        if (db.cache_broken) {
            db.cache.state = .write_failed;
            return;
        }
        const faces = db.faces.items[db.disk_start..];
        const written = fontindex.write(db.gpa, db.io, path, db.cacheScope(), db.cache_dirs.items, faces) orelse {
            db.cache.state = .write_failed;
            return;
        };
        db.cache.state = .written;
        db.cache.faces = faces.len;
        db.cache.directories = db.cache_dirs.items.len;
        db.cache.bytes = written;
    }

    fn scanFonts(db: *Db) void {
        if (db.fonts_dir) |dir| {
            db.scanDir(dir);
            return;
        }
        var buf: [1024]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => {
                db.scanDir("C:\\Windows\\Fonts");
                // Under Wine, the Linux system's fonts are on drive Z:.
                if (db.faces.items.len < 8) db.scanDir("Z:\\usr\\share\\fonts");
                // Where Windows installs a font unless asked to for all users.
                if (userFontDir(&buf)) |dir| db.scanDir(dir);
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

    /// Records a directory without enumerating it. A missing optional folder
    /// is part of the key too; other stat failures suppress only the write.
    fn recordDir(db: *Db, path: []const u8) void {
        if (db.cache_path == null) return;
        var record: fontindex.Directory = .{ .path = db.gpa.dupe(u8, path) catch {
            db.cache_broken = true;
            return;
        } };
        const stat = std.Io.Dir.cwd().statFile(db.io, path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                record.present = false;
            } else {
                db.gpa.free(record.path);
                db.cache_broken = true;
                return;
            }
            db.cache_dirs.append(db.gpa, record) catch {
                db.gpa.free(record.path);
                db.cache_broken = true;
            };
            return;
        };
        if (stat.kind != .directory) {
            db.gpa.free(record.path);
            db.cache_broken = true;
            return;
        }
        record.mtime = stat.mtime.nanoseconds;
        record.size = stat.size;
        db.cache_dirs.append(db.gpa, record) catch {
            db.gpa.free(record.path);
            db.cache_broken = true;
        };
    }

    pub fn scanDir(db: *Db, path: []const u8) void {
        db.recordDir(path);
        var dir = std.Io.Dir.cwd().openDir(db.io, path, .{ .iterate = true }) catch |err| {
            // A folder that isn't there is recorded as absent: the index holds.
            if (err != error.FileNotFound) db.cache_broken = true;
            return;
        };
        defer dir.close(db.io);
        db.scan_directories += 1;
        var walker = dir.walk(db.gpa) catch {
            db.cache_broken = true;
            return;
        };
        defer walker.deinit();
        while (true) {
            const next = walker.next(db.io) catch {
                db.cache_broken = true;
                break;
            };
            const e = next orelse break;
            if (e.kind == .directory) {
                var sub: [1024]u8 = undefined;
                const p = std.fmt.bufPrint(&sub, "{s}{c}{s}", .{ path, std.fs.path.sep, e.path }) catch continue;
                db.recordDir(p);
                continue;
            }
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
        db.scan_files += 1;
        var file = std.Io.Dir.cwd().openFile(db.io, path, .{}) catch {
            db.cache_broken = true;
            return;
        };
        defer file.close(db.io);
        const stat = file.stat(db.io) catch {
            db.cache_broken = true;
            return;
        };
        const len = stat.size;
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
            db.faces.append(db.gpa, .{
                .path = owned,
                .index = @intCast(i),
                .style = style,
                .mtime = stat.mtime.nanoseconds,
                .size = stat.size,
            }) catch db.gpa.free(owned);
        }
    }

    /// The face of `family` nearest `weight` and `italic`, null when the
    /// family has none; of two as near, one that isn't variable.
    pub fn family(db: *Db, name: []const u8, weight: u16, italic: bool) ?u32 {
        db.scan();
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |f, i| {
            if (f.private or !std.ascii.eqlIgnoreCase(f.style.name(), name)) continue;
            const dw: u32 = @abs(@as(i32, f.style.weight) - @as(i32, weight));
            const score = 2 * (dw + @as(u32, if (f.style.italic != italic) 1000 else 0)) + @intFromBool(f.style.variable);
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Whether every face of `family` is a variable font's.
    fn onlyVariable(db: *Db, name: []const u8) bool {
        for (db.faces.items) |f| {
            if (!f.private and !f.style.variable and std.ascii.eqlIgnoreCase(f.style.name(), name)) return false;
        }
        return true;
    }

    /// As `family`, a width in `font-stretch` percent counted first. OS/2's
    /// classes 1 to 9 stand for 50% to 200%.
    pub fn familyStretch(db: *Db, name: []const u8, weight: u16, italic: bool, stretch: u16) ?u32 {
        if (stretch == 100) return db.family(name, weight, italic);
        db.scan();
        const percent = [_]u16{ 100, 50, 62, 75, 87, 100, 112, 125, 150, 200 };
        var best: ?u32 = null;
        var best_score: u32 = std.math.maxInt(u32);
        for (db.faces.items, 0..) |f, i| {
            if (f.private or !std.ascii.eqlIgnoreCase(f.style.name(), name)) continue;
            const have = percent[@min(f.style.width, 9)];
            const score = @as(u32, @abs(@as(i32, have) - @as(i32, stretch))) * 100_000 + @as(u32, @intFromBool(f.style.italic != italic)) * 2000 + @abs(@as(i32, f.style.weight) - @as(i32, weight));
            if (score < best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// The face for a style: its family if installed, else the first
    /// installed of the defaults. A variable font is read at its default
    /// instance only, its other weights synthesized, so among the defaults a
    /// family with faces of its own goes first (Consolas over Windows 11's
    /// variable Cascadia Mono); one installed only as a variable font when
    /// no other is.
    pub fn match(db: *Db, name: ?[]const u8, weight: u16, italic: bool, mono: bool) ?u32 {
        if (name) |n| if (db.family(n, weight, italic)) |f| return f;
        var variable: ?u32 = null;
        for (if (mono) &monos else &sans) |n| if (db.family(n, weight, italic)) |f| {
            if (!db.onlyVariable(n)) return f;
            if (variable == null) variable = f;
        };
        if (variable) |f| return f;
        db.scan();
        for (db.faces.items, 0..) |f, i| if (!f.private and f.style.mono == mono) return @intCast(i);
        for (db.faces.items, 0..) |f, i| if (!f.private) return @intCast(i);
        return null;
    }

    /// Only a changed or missing file invalidates the persistent index. A
    /// stable unsupported face (for example, no usable cmap) stays cached;
    /// otherwise every startup would rescan and rewrite the whole index.
    fn discardFailedFace(db: *Db, face: u32) void {
        if (face < db.disk_start or db.faces.items[face].memory != null) return;
        const path = db.cache_path orelse return;
        const f = db.faces.items[face];
        const changed = changed: {
            const stat = std.Io.Dir.cwd().statFile(db.io, f.path, .{}) catch break :changed true;
            break :changed stat.kind != .file or stat.size != f.size or stat.mtime.nanoseconds != f.mtime;
        };
        if (!changed) return;
        std.Io.Dir.cwd().deleteFile(db.io, path) catch |err| {
            if (err != error.FileNotFound) std.Io.Dir.cwd().writeFile(db.io, .{ .sub_path = path, .data = "invalid" }) catch {};
        };
        if (db.cache.state != .off) db.cache.state = .stale;
    }

    /// A face's font, loaded on first use (null if it cannot be read).
    pub fn load(db: *Db, face: u32) ?*const font.Font {
        if (db.loaded.get(face)) |l| return &l.font;
        const f = db.faces.items[face];
        var bytes = f.read(db) catch {
            db.discardFailedFace(face);
            return null;
        };
        const parsed = font.Font.init(bytes.data, f.index) catch {
            fontmap.freeBytes(db.io, db.gpa, &bytes);
            db.discardFailedFace(face);
            return null;
        };
        const l = db.gpa.create(Loaded) catch {
            fontmap.freeBytes(db.io, db.gpa, &bytes);
            return null;
        };
        l.* = .{ .bytes = bytes, .font = parsed };
        l.font.data = l.bytes.data;
        db.loaded.put(db.gpa, face, l) catch {
            fontmap.freeBytes(db.io, db.gpa, &l.bytes);
            db.gpa.destroy(l);
            return null;
        };
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
        while (it.next()) |e| if (!db.faces.items[e.key_ptr.*].private and e.value_ptr.*.font.glyphIndex(cp) != 0) return e.key_ptr.*;
        // Read, checked and let go unless it has it; a few dozen at most.
        var tries: usize = 0;
        for (0..db.faces.items.len) |i| {
            if (tries >= 48) break;
            if (db.loaded.contains(@intCast(i)) or db.faces.items[i].private) continue;
            if (i > 0 and std.mem.eql(u8, db.faces.items[i - 1].style.name(), db.faces.items[i].style.name())) continue;
            tries += 1;
            const face = db.faces.items[i];
            var bytes = face.read(db) catch {
                db.discardFailedFace(@intCast(i));
                continue;
            };
            defer fontmap.freeBytes(db.io, db.gpa, &bytes);
            const f = font.Font.init(bytes.data, face.index) catch {
                db.discardFailedFace(@intCast(i));
                continue;
            };
            if (f.glyphIndex(cp) != 0) return @intCast(i);
        }
        return null;
    }
};
