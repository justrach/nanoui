//! What a WebView2 page's requests to the app's origin are answered with:
//! the served bytes in a stream WebView2 owns, the status's reason, and the
//! headers, as `CreateWebResourceResponse` takes them (`page_webview2.zig`).
const std = @import("std");
const wv = @import("windows/webview2.zig");
const page = @import("page.zig");
const w = @import("windows/win32.zig");

const Com = wv.Com;
const HRESULT = wv.HRESULT;

/// `env.CreateWebResourceResponse(stream, status, reason, headers)`.
pub fn makeResponse(env: *Com, served: page.Served, gpa: std.mem.Allocator, out: *?*Com) HRESULT {
    const headers = headersZ(gpa, served.mime) orelse return -1;
    defer gpa.free(headers);
    var stream: ?*Com = null;
    if (served.data.len > 0) stream = shMemStream(served.data.ptr, served.data.len);
    // WebView2 takes the stream: it owns the reference it was given, so the
    // one made here is not released by us.
    return wv.Environment.createResponse(env, stream, @intCast(served.status), reasonZ(served.status), headers.ptr, out);
}

/// An `IStream` over a copy of `bytes`.
///
/// `CreateStreamOnHGlobal`: the stream owns the memory (WebView2 reads it
/// after this returns, and asks its size), so the bytes go into an HGLOBAL
/// the stream takes.
fn shMemStream(bytes: [*]const u8, len: usize) ?*Com {
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, len) orelse return null;
    const dest = w.GlobalLock(h) orelse {
        _ = w.GlobalFree(h);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(dest))[0..len], bytes[0..len]);
    _ = w.GlobalUnlock(h);
    var stream: ?*Com = null;
    const hr = CreateStreamOnHGlobal(h, 1, &stream); // fDeleteOnRelease
    if (hr < 0) {
        _ = w.GlobalFree(h);
        return null;
    }
    return stream;
}

extern "ole32" fn CreateStreamOnHGlobal(mem: ?*anyopaque, delete_on_release: i32, out: *?*Com) callconv(.winapi) HRESULT;

/// The reason phrase WebView2 takes, by status.
fn reasonZ(status: u16) [*:0]const u16 {
    return switch (status) {
        200 => std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        else => std.unicode.utf8ToUtf16LeStringLiteral("Not Found"),
    };
}

/// `Content-Type: <mime>\r\nCache-Control: no-cache\r\n`, as WebView2 takes
/// its headers. `mime` is one of ours or an asset's, so it is built here.
fn headersZ(gpa: std.mem.Allocator, mime: []const u8) ?[:0]u16 {
    const text = std.fmt.allocPrint(gpa, "Content-Type: {s}\r\nCache-Control: no-cache\r\n", .{mime}) catch return null;
    defer gpa.free(text);
    const n = std.unicode.calcUtf16LeLen(text) catch return null;
    const buf = gpa.alloc(u16, n + 1) catch return null;
    _ = std.unicode.utf8ToUtf16Le(buf, text) catch {
        gpa.free(buf);
        return null;
    };
    buf[n] = 0;
    return buf[0..n :0];
}
