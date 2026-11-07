//! JPEG to pixels, where nanoui decodes images itself (Linux, Windows, Android,
//! and `-Dportable`): baseline and progressive, Huffman coded, 8 bits a sample;
//! gray, YCbCr, RGB, CMYK and YCCK; any integer chroma subsampling; restart
//! intervals; EXIF orientation applied, so the picture comes out upright as
//! ImageIO's does. Out: BGRA, opaque. This file reads the marker segments;
//! `jpeg_scan.zig` reads the coded data, `jpeg_pixels.zig` makes the pixels.
//!
//! Bytes come from arbitrary web servers, so every length is checked, and a
//! file that goes wrong after some of its scan data was read yields the picture
//! so far rather than an error. Arithmetic coding, 12 bits, lossless,
//! hierarchical and a height left to a later DNL marker return error.Unsupported.
const std = @import("std");
const scan = @import("jpeg_scan.zig");
const pixels = @import("jpeg_pixels.zig");

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Premultiplied BGRA, `width * 4` bytes a row.
    bgra: []u8,

    pub fn deinit(d: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(d.bgra);
    }
};

pub const Size = struct { width: u32, height: u32 };

pub const Error = error{ NotJpeg, Unsupported, Corrupt, TooLarge, OutOfMemory };

/// Larger images are refused rather than decoded (64 megapixels).
const max_pixels = 64 * 1024 * 1024;

/// Times a frame's every coefficient may be visited before decoding stops. An
/// honest file visits each at most once per bit of precision.
const max_visits = 16;

/// Whether `bytes` start as a JPEG: the start-of-image marker and another.
pub fn matches(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF;
}

/// The size the picture comes out at, with EXIF rotation accounted for, read
/// from the headers alone. Null if there is no complete frame header.
pub fn size(bytes: []const u8) ?Size {
    if (!matches(bytes)) return null;
    var it: Markers = .{ .bytes = bytes };
    var found: ?Size = null;
    var orientation: u8 = 0;
    while (it.next() catch null) |seg| {
        if (seg.marker == 0xDA) break;
        if (seg.marker == 0xE1 and orientation == 0) orientation = exifOrientation(seg.data) orelse 0;
        if (found == null and isFrameHeader(seg.marker)) {
            if (seg.data.len < 6) return null;
            const h: u32 = std.mem.readInt(u16, seg.data[1..3], .big);
            const w: u32 = std.mem.readInt(u16, seg.data[3..5], .big);
            if (w == 0 or h == 0) return null;
            found = .{ .width = w, .height = h };
        }
    }
    const s = found orelse return null;
    return if (orientation >= 5) .{ .width = s.height, .height = s.width } else s;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    if (!matches(bytes)) return error.NotJpeg;
    var st: State = .{ .gpa = gpa };
    defer st.deinit();
    st.parse(bytes) catch |err| {
        if (err == error.OutOfMemory or st.done == 0) return err;
    };
    if (st.done == 0) return error.Corrupt;

    if (st.frame == null) return error.Corrupt;
    const f = &st.frame.?;
    const comps = f.comps[0..f.count];
    if (f.progressive) {
        for (comps) |*c| {
            pixels.finishProgressive(c);
            gpa.free(c.coefs);
            c.coefs = &.{};
        }
    }
    const bgra = try pixels.render(gpa, comps, f.width, f.height, f.hmax, f.vmax, st.color());
    const orientation = st.orientation;
    if (orientation < 2 or orientation > 8) return .{ .width = f.width, .height = f.height, .bgra = bgra };
    errdefer gpa.free(bgra);
    const o = try pixels.orient(gpa, bgra, f.width, f.height, orientation);
    return .{ .width = o.width, .height = o.height, .bgra = o.bgra };
}

/// SOFn, except the three markers in that range that are not frame headers.
fn isFrameHeader(m: u8) bool {
    return m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC;
}

const Segment = struct { marker: u8, data: []const u8 };

/// Walks marker segments, skipping whatever bytes lie between them. Linear in
/// the input: every step moves forward.
const Markers = struct {
    bytes: []const u8,
    pos: usize = 2,

    /// The next segment that has a payload; null at EOI or the end of the file.
    fn next(it: *Markers) error{Corrupt}!?Segment {
        const b = it.bytes;
        while (true) {
            while (it.pos < b.len and b[it.pos] != 0xFF) it.pos += 1;
            while (it.pos < b.len and b[it.pos] == 0xFF) it.pos += 1;
            if (it.pos >= b.len) return null;
            const m = b[it.pos];
            it.pos += 1;
            switch (m) {
                0x00, 0x01, 0xD0...0xD8 => continue,
                0xD9 => return null,
                else => {},
            }
            if (it.pos + 2 > b.len) return error.Corrupt;
            const len: usize = std.mem.readInt(u16, b[it.pos..][0..2], .big);
            if (len < 2 or it.pos + len > b.len) return error.Corrupt;
            const data = b[it.pos + 2 .. it.pos + len];
            it.pos += len;
            return .{ .marker = m, .data = data };
        }
    }
};

const Frame = struct {
    progressive: bool,
    width: u32,
    height: u32,
    count: u8,
    comps: [4]scan.Component,
    hmax: u32 = 1,
    vmax: u32 = 1,
    mcux: u32 = 0,
    mcuy: u32 = 0,
    allocated: bool = false,
};

const State = struct {
    gpa: std.mem.Allocator,
    frame: ?Frame = null,
    quant: [4]?[64]u16 = @splat(null),
    dc: [4]?scan.Huffman = @splat(null),
    ac: [4]?scan.Huffman = @splat(null),
    restart: u16 = 0,
    adobe: ?u8 = null,
    jfif: bool = false,
    orientation: u8 = 0,
    work: u64 = 0,
    budget: u64 = 0,
    done: u64 = 0,

    fn deinit(st: *State) void {
        if (st.frame == null) return;
        const f = &st.frame.?;
        for (f.comps[0..f.count]) |c| {
            if (c.plane.len > 0) st.gpa.free(c.plane);
            if (c.coefs.len > 0) st.gpa.free(c.coefs);
        }
    }

    fn parse(st: *State, bytes: []const u8) Error!void {
        var it: Markers = .{ .bytes = bytes };
        while (try it.next()) |seg| {
            switch (seg.marker) {
                0xDB => try st.readQuant(seg.data),
                0xC4 => try st.readHuffman(seg.data),
                0xDD => {
                    if (seg.data.len < 2) return error.Corrupt;
                    st.restart = std.mem.readInt(u16, seg.data[0..2], .big);
                },
                0xE0 => if (std.mem.startsWith(u8, seg.data, "JFIF\x00")) {
                    st.jfif = true;
                },
                0xE1 => if (st.orientation == 0) {
                    st.orientation = exifOrientation(seg.data) orelse 0;
                },
                0xEE => if (seg.data.len >= 12 and std.mem.startsWith(u8, seg.data, "Adobe")) {
                    st.adobe = seg.data[11];
                },
                0xDA => {
                    it.pos = try st.readScan(seg.data, bytes, it.pos);
                    // A file past its allowance gets no more of a hearing.
                    if (st.work > st.budget) return;
                },
                else => if (isFrameHeader(seg.marker)) try st.readFrame(seg.marker, seg.data),
            }
        }
    }

    fn readQuant(st: *State, data: []const u8) Error!void {
        var at: usize = 0;
        while (at < data.len) {
            const pq = data[at] >> 4;
            const tq = data[at] & 15;
            at += 1;
            if (pq > 1 or tq > 3) return error.Corrupt;
            const entry: usize = if (pq == 1) 2 else 1;
            if (at + 64 * entry > data.len) return error.Corrupt;
            var table: [64]u16 = undefined;
            for (0..64) |i| {
                const p = data[at + i * entry..];
                table[scan.zigzag[i]] = if (pq == 1) std.mem.readInt(u16, p[0..2], .big) else p[0];
            }
            st.quant[tq] = table;
            at += 64 * entry;
        }
    }

    fn readHuffman(st: *State, data: []const u8) Error!void {
        var at: usize = 0;
        while (at < data.len) {
            if (at + 17 > data.len) return error.Corrupt;
            const class = data[at] >> 4;
            const id = data[at] & 15;
            if (class > 1 or id > 3) return error.Corrupt;
            const counts = data[at + 1 ..][0..16];
            var total: usize = 0;
            for (counts) |c| total += c;
            at += 17;
            if (total > 256 or at + total > data.len) return error.Corrupt;
            const table = try scan.Huffman.build(counts, data[at .. at + total]);
            if (class == 0) st.dc[id] = table else st.ac[id] = table;
            at += total;
        }
    }

    fn readFrame(st: *State, marker: u8, data: []const u8) Error!void {
        if (st.frame != null) return error.Corrupt;
        if (marker != 0xC0 and marker != 0xC1 and marker != 0xC2) return error.Unsupported;
        if (data.len < 6) return error.Corrupt;
        if (data[0] != 8) return error.Unsupported;
        const height: u32 = std.mem.readInt(u16, data[1..3], .big);
        const width: u32 = std.mem.readInt(u16, data[3..5], .big);
        const count = data[5];
        if (width == 0) return error.Corrupt;
        if (height == 0) return error.Unsupported;
        if (@as(u64, width) * height > max_pixels) return error.TooLarge;
        if (count != 1 and count != 3 and count != 4) return error.Unsupported;
        if (data.len < 6 + @as(usize, count) * 3) return error.Corrupt;

        var f: Frame = .{
            .progressive = marker == 0xC2,
            .width = width,
            .height = height,
            .count = count,
            .comps = undefined,
        };
        for (0..count) |i| {
            const p = data[6 + i * 3..][0..3];
            const h = p[1] >> 4;
            const v = p[1] & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4 or p[2] > 3) return error.Corrupt;
            f.comps[i] = .{ .id = p[0], .h = h, .v = v, .tq = p[2] };
            f.hmax = @max(f.hmax, h);
            f.vmax = @max(f.vmax, v);
        }
        f.mcux = divCeil(width, 8 * f.hmax);
        f.mcuy = divCeil(height, 8 * f.vmax);
        var blocks: u64 = 0;
        for (f.comps[0..count]) |*c| {
            c.blocks_w = f.mcux * c.h;
            c.blocks_h = f.mcuy * c.v;
            c.scan_w = divCeil(divCeil(width * c.h, f.hmax), 8);
            c.scan_h = divCeil(divCeil(height * c.v, f.vmax), 8);
            blocks += @as(u64, c.blocks_w) * c.blocks_h;
        }
        st.budget = blocks * 64 * max_visits;
        st.frame = f;
    }

    /// Makes the sample planes: only when a scan is about to use them, so a
    /// file that merely claims a big frame costs nothing.
    fn allocate(st: *State, f: *Frame) Error!void {
        if (f.allocated) return;
        f.allocated = true;
        for (f.comps[0..f.count]) |*c| {
            const blocks = @as(usize, c.blocks_w) * c.blocks_h;
            c.plane = try st.gpa.alloc(u8, blocks * 64);
            @memset(c.plane, 128);
            if (f.progressive) {
                c.coefs = try st.gpa.alloc(i16, blocks * 64);
                @memset(c.coefs, 0);
            }
        }
    }

    /// Reads an SOS header and the coded data after it; returns where the
    /// marker walk resumes.
    fn readScan(st: *State, data: []const u8, bytes: []const u8, start: usize) Error!usize {
        if (st.frame == null or data.len < 1) return error.Corrupt;
        const f = &st.frame.?;
        const count = data[0];
        if (count < 1 or count > f.count or data.len < 1 + @as(usize, count) * 2 + 3) return error.Corrupt;
        const tail = data[1 + @as(usize, count) * 2..][0..3];
        var s: scan.Scan = .{
            .reader = .{ .bytes = bytes, .pos = start },
            .comps = undefined,
            .dc = @splat(null),
            .ac = @splat(null),
            .count = count,
            .progressive = f.progressive,
            .restart = st.restart,
            .mcux = f.mcux,
            .mcuy = f.mcuy,
            .work = &st.work,
            .budget = st.budget,
            .done = &st.done,
        };
        if (f.progressive) {
            s.ss = tail[0];
            s.se = tail[1];
            const ah = tail[2] >> 4;
            const al = tail[2] & 15;
            if (s.ss > s.se or s.se > 63 or al > 13) return error.Corrupt;
            if (ah != 0 and ah != al + 1) return error.Corrupt;
            if (s.ss == 0 and s.se != 0) return error.Corrupt;
            if (s.ss != 0 and count != 1) return error.Corrupt;
            s.ah = @intCast(ah);
            s.al = @intCast(al);
        }
        const needs_dc = !f.progressive or (s.ss == 0 and s.ah == 0);
        const needs_ac = !f.progressive or s.ss != 0;
        for (0..count) |i| {
            const p = data[1 + i * 2..][0..2];
            const c = for (f.comps[0..f.count]) |*c| {
                if (c.id == p[0]) break c;
            } else return error.Corrupt;
            for (s.comps[0..i]) |other| if (other == c) return error.Corrupt;
            s.comps[i] = c;
            const td = p[1] >> 4;
            const ta = p[1] & 15;
            if (needs_dc) {
                if (td > 3) return error.Corrupt;
                s.dc[i] = if (st.dc[td]) |*h| h else return error.Corrupt;
            }
            if (needs_ac) {
                if (ta > 3) return error.Corrupt;
                s.ac[i] = if (st.ac[ta]) |*h| h else return error.Corrupt;
            }
            if (!c.latched) {
                c.quant = st.quant[c.tq] orelse return error.Corrupt;
                c.latched = true;
            }
        }
        if (start >= bytes.len) return error.Corrupt;
        try st.allocate(f);
        s.run();
        return s.reader.pos;
    }

    fn color(st: *const State) pixels.Color {
        const f = &st.frame.?;
        return switch (f.count) {
            1 => .gray,
            4 => if (st.adobe == 2) .ycck else .cmyk,
            else => blk: {
                if (st.adobe) |transform| break :blk if (transform == 0) .rgb else .ycc;
                if (st.jfif) break :blk .ycc;
                const named = f.comps[0].id == 'R' and f.comps[1].id == 'G' and f.comps[2].id == 'B';
                break :blk if (named) .rgb else .ycc;
            },
        };
    }
};

fn divCeil(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

/// The orientation (1..8) an APP1 segment's EXIF block gives, if it gives one.
fn exifOrientation(data: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, data, "Exif\x00\x00")) return null;
    const t = data[6..];
    if (t.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, t[0..2], "II")) .little else if (std.mem.eql(u8, t[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, t[2..4], endian) != 42) return null;
    const ifd: u64 = std.mem.readInt(u32, t[4..8], endian);
    if (ifd + 2 > t.len) return null;
    const at: usize = @intCast(ifd);
    const entries: usize = std.mem.readInt(u16, t[at..][0..2], endian);
    for (0..entries) |i| {
        const e = at + 2 + i * 12;
        if (e + 12 > t.len) return null;
        if (std.mem.readInt(u16, t[e..][0..2], endian) != 0x0112) continue;
        const value: u32 = switch (std.mem.readInt(u16, t[e + 2 ..][0..2], endian)) {
            3 => std.mem.readInt(u16, t[e + 8 ..][0..2], endian),
            4 => std.mem.readInt(u32, t[e + 8 ..][0..4], endian),
            else => return null,
        };
        return if (value >= 1 and value <= 8) @intCast(value) else null;
    }
    return null;
}

test {
    _ = @import("jpeg_decode_test.zig");
}
