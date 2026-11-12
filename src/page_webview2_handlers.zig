//! WebView2's callbacks: COM owns boxes with detachable page targets.
const std = @import("std");
const wv = @import("windows/webview2.zig");
const serve = @import("page_webview2_serve.zig");
const page = @import("page.zig");
const Page = @import("page_webview2.zig").Page;
const Window = @import("windows/window.zig").Window;
const App = @import("windows/app.zig").App;
const ipc = @import("ipc.zig").ipc(Window, App);
const Com = wv.Com;
const HRESULT = wv.HRESULT;

/// One handler object: the COM vtable first, so `Invoke` can find its page.
pub fn Box(comptime T: type) type {
    return struct {
        com: Com,
        target: *Page.Target,
        /// The references alive: 1 at birth (the maker's, released the
        /// moment the call that takes the handler returns), then WebView2's
        /// own. All calls on it are the UI thread's, where the runtime runs
        /// its callbacks.
        refs: u32 = 1,
        gpa: std.mem.Allocator,

        /// The vtable WebView2 keeps: `vtable_storage` is a container whose
        /// address is the compile-time constant itself, not a copy.
        pub const vtable_storage: [wv.handler_slots + 1]*const anyopaque = wv.HandlerVtable(@This(), invoke);

        const Arg = @typeInfo(@TypeOf(T.invoke)).@"fn".param_types[1].?;

        fn invoke(self: *@This(), a: Arg, b: ?*Com) callconv(.winapi) HRESULT {
            // Removing registrations during a reentrant close can release
            // the runtime's last reference to this very handler.
            _ = self.com.addRef();
            defer self.com.release();
            const p = self.target.page orelse {
                if (@hasDecl(T, "cancel")) T.cancel(a, b);
                return wv.S_OK;
            };
            if (!p.enter()) return wv.S_OK;
            defer p.leave();
            return T.invoke(p, a, b);
        }

        /// The last reference gone: free. Nothing of the page is touched —
        /// the page may already be gone (a window closed under a callback).
        pub fn release_free(self: *@This()) void {
            self.target.release();
            self.gpa.destroy(self);
        }
    };
}

/// `ICoreWebView2ExecuteScriptCompletedHandler`: `Invoke(HRESULT errorCode,
/// LPCWSTR result)` — the result is the JSON text itself, not an object.
pub const ScriptDone = struct {
    pub fn invoke(p: *Page, _: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        // The second argument is the wide string, passed where a pointer goes.
        const wide: [*:0]const u16 = @ptrCast(@alignCast(result orelse return wv.S_OK));
        if (!p.queue.window.app.debug) return wv.S_OK;
        const units = std.mem.span(wide);
        var buf: [4096]u8 = undefined;
        const m = std.unicode.utf16LeToUtf8(&buf, units) catch 0;
        std.debug.print("nanoui: eval returned {s}\n", .{buf[0..m]});
        return wv.S_OK;
    }
};

// ---------------------------------------------------------------------------
// The three callbacks. Each is `Invoke` at slot 3 of its own interface.
// ---------------------------------------------------------------------------

pub const EnvCreated = struct {
    pub fn invoke(p: *Page, err: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        if (p.queue.window.app.debug) std.debug.print("nanoui: webview2 environment callback 0x{x}\n", .{@as(u32, @bitCast(err))});
        if (err >= 0) if (result) |env| p.environmentReady(env);
        // `result` is WebView2's only for the length of this call: the page
        // took its own reference (`environmentReady`), so none is released here.
        return wv.S_OK;
    }
};

test "the environment handler takes an HRESULT and a result" {
    // `invoke(box, errorCode, result)`: the three the shim calls it with.
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@TypeOf(EnvCreated.invoke)).@"fn".param_types.len);
}

pub const CtlCreated = struct {
    pub fn cancel(_: HRESULT, result: ?*Com) void {
        // Borrowed result: close it, but never release the runtime's reference.
        if (result) |ctl| _ = wv.Controller.close(ctl);
    }

    pub fn invoke(p: *Page, err: HRESULT, result: ?*Com) callconv(.winapi) HRESULT {
        p.endHiddenShow();
        if (p.queue.dead) {
            cancel(err, result);
            return wv.S_OK;
        }
        if (err >= 0) if (result) |ctl| p.controllerReady(ctl);
        return wv.S_OK;
    }
};

pub const NavigationCompleted = struct {
    pub fn invoke(p: *Page, sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        _ = args;
        if (p.queue.window.app.debug) {
            // What the view is showing, and what is in it: a document that
            // is not the app's page shows here as `about:blank` or an error.
            var src: wv.PWSTR = null;
            if (p.webview) |v| if (wv.WebView.source(v, &src) >= 0) {
                defer wv.coTaskMemFree(src);
                if (src) |s| {
                    var buf: [1024]u8 = undefined;
                    const units = std.mem.span(s);
                    buf[0] = 0;
                    const n = std.unicode.utf16LeToUtf8(&buf, units) catch 0;
                    std.debug.print("nanoui: navigation completed, source={s}\n", .{buf[0..n]});
                }
            };
        }
        if (p.queue.dead) return wv.S_OK;
        // With a document to run in, the app's `--nanoui-eval` goes now:
        // `dom-ready` (the bridge's) comes before the document is there.
        if (p.pending_eval) |js| {
            p.pending_eval = null;
            p.queue.eval(js);
        }
        return wv.S_OK;
    }
};

pub const MessageReceived = struct {
    pub fn invoke(p: *Page, sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        const a = args orelse return wv.S_OK;
        const gpa = p.queue.gpa;
        var raw: wv.PWSTR = null;
        if (wv.MessageArgs.getWebMessageAsJson(a, &raw) < 0) return wv.S_OK;
        defer wv.coTaskMemFree(raw);
        if (p.queue.dead) return wv.S_OK;
        const wide = raw orelse return wv.S_OK;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        // UTF-16 is at most as long as UTF-8 in bytes, never longer.
        const units = std.mem.span(wide);
        buf.ensureTotalCapacity(gpa, units.len * 3) catch return wv.S_OK;
        const n = std.unicode.utf16LeToUtf8(buf.allocatedSlice(), units) catch return wv.S_OK;
        // The document that posted it: where the page is now, which may not
        // be where it was last sent.
        var src_buf: std.ArrayList(u8) = .empty;
        defer src_buf.deinit(gpa);
        const source = wv.MessageArgs.sourceUtf8(a, gpa, &src_buf);
        if (p.queue.dead) return wv.S_OK;
        // Said before the call: a method may close the window and its page.
        if (p.queue.window.app.debug)
            std.debug.print("nanoui: page said: {s}\n", .{buf.allocatedSlice()[0..n]});
        // The page that sent it, which need not be the window's `page`.
        ipc.handlePageMessage(p.queue.window, p, buf.allocatedSlice()[0..n], source);
        return wv.S_OK;
    }
};

pub const ResourceRequested = struct {
    pub fn invoke(p: *Page, sender: ?*Com, args: ?*Com) callconv(.winapi) HRESULT {
        _ = sender;
        const a = args orelse return wv.S_OK;
        const page_self = p;

        var req: ?*Com = null;
        if (wv.ResourceArgs.request(a, &req) < 0) return wv.S_OK;
        const r = req orelse return wv.S_OK;
        defer r.release();
        if (p.queue.dead) return wv.S_OK;

        var uri: wv.PWSTR = null;
        if (wv.ResourceRequest.uri(r, &uri) < 0) return wv.S_OK;
        defer wv.coTaskMemFree(uri);
        if (p.queue.dead) return wv.S_OK;
        const wide = uri orelse return wv.S_OK;

        const gpa = page_self.queue.gpa;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const units = std.mem.span(wide);
        buf.ensureTotalCapacity(gpa, units.len * 3) catch return wv.S_OK;
        const n = std.unicode.utf16LeToUtf8(buf.allocatedSlice(), units) catch return wv.S_OK;

        const served = page_self.queue.serve(page.pathOf(buf.allocatedSlice()[0..n]));
        if (p.queue.window.app.debug)
            std.debug.print("nanoui: resource {s} -> {d} {s} ({d} bytes)\n", .{ buf.allocatedSlice()[0..n], served.status, served.mime, served.data.len });
        const env = page_self.environment orelse return wv.S_OK;
        var resp: ?*Com = null;
        const cr = serve.makeResponse(env, served, gpa, &resp);
        if (cr < 0 or resp == null) {
            if (cr < 0) std.log.warn("nanoui: CreateWebResourceResponse failed (0x{x})", .{@as(u32, @bitCast(cr))});
            return wv.S_OK;
        }
        defer resp.?.release();
        if (p.queue.dead) return wv.S_OK;
        const pr = wv.ResourceArgs.setResponse(a, resp.?);
        if (pr < 0) std.log.warn("nanoui: put_Response failed (0x{x})", .{@as(u32, @bitCast(pr))});
        return wv.S_OK;
    }
};
