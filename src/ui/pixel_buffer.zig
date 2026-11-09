//! CVPixelBuffers (Apple platforms): what format a buffer is, read the way
//! the real app's monitor reads it (its pixel format type, then its matrix
//! and transfer attachments), and its planes' bytes for the CPU renderer.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu.zig");

pub const enabled = builtin.os.tag == .macos or builtin.os.tag == .ios;

extern "c" fn CVPixelBufferGetPixelFormatType(pb: *anyopaque) u32;
extern "c" fn CVPixelBufferGetWidth(pb: *anyopaque) usize;
extern "c" fn CVPixelBufferGetHeight(pb: *anyopaque) usize;
extern "c" fn CVPixelBufferIsPlanar(pb: *anyopaque) u8;
extern "c" fn CVPixelBufferGetWidthOfPlane(pb: *anyopaque, plane: usize) usize;
extern "c" fn CVPixelBufferGetHeightOfPlane(pb: *anyopaque, plane: usize) usize;
extern "c" fn CVPixelBufferGetBytesPerRowOfPlane(pb: *anyopaque, plane: usize) usize;
extern "c" fn CVPixelBufferGetBaseAddressOfPlane(pb: *anyopaque, plane: usize) ?[*]u8;
extern "c" fn CVPixelBufferGetBaseAddress(pb: *anyopaque) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: *anyopaque) usize;
extern "c" fn CVPixelBufferLockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVBufferGetAttachment(buffer: *anyopaque, key: *anyopaque, mode: ?*u32) ?*anyopaque;
extern "c" fn CFEqual(a: *anyopaque, b: *anyopaque) u8;
extern "c" const kCVImageBufferYCbCrMatrixKey: *anyopaque;
extern "c" const kCVImageBufferYCbCrMatrix_ITU_R_601_4: *anyopaque;
extern "c" const kCVImageBufferYCbCrMatrix_ITU_R_2020: *anyopaque;
extern "c" const kCVImageBufferTransferFunctionKey: *anyopaque;
extern "c" const kCVImageBufferTransferFunction_sRGB: *anyopaque;
extern "c" const kCVImageBufferTransferFunction_Linear: *anyopaque;
extern "c" const kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ: *anyopaque;
extern "c" const kCVImageBufferTransferFunction_ITU_R_2100_HLG: *anyopaque;

fn code(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// A pixel format type's texture format and range; null for one nanoui
/// doesn't draw.
pub fn classify(type_code: u32) ?struct { format: gpu.Format, range: gpu.Range } {
    return switch (type_code) {
        code("BGRA") => .{ .format = .bgra8, .range = .full },
        code("420v") => .{ .format = .ycbcr420_8, .range = .video },
        code("420f") => .{ .format = .ycbcr420_8, .range = .full },
        code("x420") => .{ .format = .ycbcr420_10, .range = .video },
        code("xf20") => .{ .format = .ycbcr420_10, .range = .full },
        code("x422") => .{ .format = .ycbcr422_10, .range = .video },
        code("xf22") => .{ .format = .ycbcr422_10, .range = .full },
        code("x444") => .{ .format = .ycbcr444_10, .range = .video },
        code("xf44") => .{ .format = .ycbcr444_10, .range = .full },
        code("RGhA") => .{ .format = .rgba16f, .range = .full },
        else => null,
    };
}

fn attached(pb: *anyopaque, key: *anyopaque, value: *anyopaque) bool {
    const v = CVBufferGetAttachment(pb, key, null) orelse return false;
    return CFEqual(v, value) != 0;
}

/// A texture showing `pb`, its format and range from its pixel format
/// type and its matrix and transfer from its attachments (BT.709 and
/// Rec. 709 when it has none), as the real app's monitor reads them.
pub fn texture(pb: *anyopaque) gpu.Texture {
    var t: gpu.Texture = .{ .width = @intCast(CVPixelBufferGetWidth(pb)), .height = @intCast(CVPixelBufferGetHeight(pb)), .pixel_buffer = pb };
    if (classify(CVPixelBufferGetPixelFormatType(pb))) |c| {
        t.format = c.format;
        t.range = c.range;
    }
    t.matrix = if (attached(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) .bt601 else if (attached(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)) .bt2020 else .bt709;
    const tk = kCVImageBufferTransferFunctionKey;
    t.transfer = if (attached(pb, tk, kCVImageBufferTransferFunction_sRGB)) .srgb else if (attached(pb, tk, kCVImageBufferTransferFunction_Linear)) .linear else if (attached(pb, tk, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) .pq else if (attached(pb, tk, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) .hlg else .rec709;
    return t;
}

/// A plane's size in texels.
pub fn planeSize(pb: *anyopaque, plane: usize) [2]usize {
    if (CVPixelBufferIsPlanar(pb) == 0) return .{ CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb) };
    return .{ CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane) };
}

/// A plane's bytes, while the buffer is locked.
pub const Plane = struct {
    bytes: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
};

/// The buffer's planes, locked for reading until `Locked.unlock`.
pub const Locked = struct {
    pb: *anyopaque,
    planes: [2]?Plane = .{ null, null },

    pub fn lock(pb: *anyopaque) ?Locked {
        if (CVPixelBufferLockBaseAddress(pb, 1) != 0) return null; // read only
        var l: Locked = .{ .pb = pb };
        if (CVPixelBufferIsPlanar(pb) == 0) {
            const base = CVPixelBufferGetBaseAddress(pb) orelse return l.fail();
            l.planes[0] = .{ .bytes = base, .width = CVPixelBufferGetWidth(pb), .height = CVPixelBufferGetHeight(pb), .stride = CVPixelBufferGetBytesPerRow(pb) };
            return l;
        }
        for (0..2) |k| {
            const base = CVPixelBufferGetBaseAddressOfPlane(pb, k) orelse return l.fail();
            l.planes[k] = .{ .bytes = base, .width = CVPixelBufferGetWidthOfPlane(pb, k), .height = CVPixelBufferGetHeightOfPlane(pb, k), .stride = CVPixelBufferGetBytesPerRowOfPlane(pb, k) };
        }
        return l;
    }

    fn fail(l: Locked) ?Locked {
        _ = CVPixelBufferUnlockBaseAddress(l.pb, 1);
        return null;
    }

    pub fn unlock(l: Locked) void {
        _ = CVPixelBufferUnlockBaseAddress(l.pb, 1);
    }
};
