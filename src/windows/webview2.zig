//! WebView2 as Zig sees it: the interfaces, the GUIDs and the callbacks,
//! called through each vtable by slot, in the order `WebView2.h` declares
//! them (1.0.4191.47), as `ui/d3d11_glue.zig` calls Direct3D's. No C
//! headers and no `@cImport`: `CreateCoreWebView2EnvironmentWithOptions`
//! and the rest of the loader come from the SDK's `WebView2Loader.dll`.
//!
//! WebView2 is asynchronous where WKWebView is not: making a page takes two
//! callbacks (the environment, then the controller inside it). A `Host`
//! carries the callbacks' state, and the UI thread owns every call.
const std = @import("std");

pub const HRESULT = i32;
pub const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const BOOL = i32;
/// The window handle, as `win32.zig` declares it: one type across the backend.
pub const HWND = @import("win32.zig").HWND;

/// S_OK: a handler's return when it took the call.
pub const S_OK: HRESULT = 0;

// The interfaces, by IID.
pub const iid_environment: Guid = .{ .a = 0xb96d755e, .b = 0x0319, .c = 0x4e92, .d = .{ 0xa2, 0x96, 0x23, 0x43, 0x6f, 0x46, 0xa1, 0xfc } };
pub const iid_controller: Guid = .{ .a = 0x4d00c0d1, .b = 0x9434, .c = 0x4eb6, .d = .{ 0x80, 0x78, 0x86, 0x97, 0xa5, 0x60, 0x33, 0x4f } };
pub const iid_webview2: Guid = .{ .a = 0x76eceacd, .b = 0x1167, .c = 0x4b1d, .d = .{ 0x9a, 0x3b, 0xd9, 0xba, 0x0b, 0x6e, 0x6d, 0x3b } };
pub const iid_webview2_3: Guid = .{ .a = 0xa0d6df20, .b = 0x3b92, .c = 0x416d, .d = .{ 0xaa, 0x0c, 0x43, 0x7a, 0x9c, 0x72, 0x78, 0x57 } };
pub const iid_texture2d: Guid = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/// A COM object: its first field points at its vtable. The same shape
/// `ui/d3d11_glue.zig` uses.
pub const Com = extern struct {
    vtable: [*]const *const anyopaque,

    pub fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }

    pub fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }

    pub fn addRef(c: *Com) u32 {
        return c.slot(*const fn (*Com) callconv(.winapi) u32, 1)(c);
    }
};

/// A string WebView2 hands out: COM's `CoTaskMemFree` frees it.
pub const PWSTR = ?[*:0]u16;

/// The loader's one entry point; the rest of the SDK's free functions too.
pub const CreateEnvironmentFn = *const fn (
    browser_executable_folder: ?[*:0]const u16,
    user_data_folder: ?[*:0]const u16,
    environment_options: ?*Com,
    environment_created_handler: ?*Com,
) callconv(.winapi) HRESULT;

pub const GetVersionFn = *const fn (?[*:0]const u16, *PWSTR) callconv(.winapi) HRESULT;

const HMODULE = *opaque {};
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const Guid, outer: ?*anyopaque, ctx: u32, iid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT;

/// The loader, once: `null` when there is no WebView2 on this machine (no
/// SDK DLL beside the app and no runtime installed).
pub const Loader = struct {
    module: HMODULE,
    create_environment: CreateEnvironmentFn,
    get_version: ?GetVersionFn,

    var loader: ?Loader = null;
    var tried: bool = false;

    /// The loader's DLL, looked for beside the executable first (where the
    /// build installs it) and then by name: the SDK ships it, the runtime
    /// does not. The process's own directory is on the search path, so the
    /// plain name finds it too; the explicit path is what makes a friend's
    /// copy in the current directory irrelevant.
    pub fn get() ?*const Loader {
        if (tried) return if (loader) |*l| l else null;
        tried = true;
        const module = loadBeside() orelse
            LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll")) orelse return null;
        const create = GetProcAddress(module, "CreateCoreWebView2EnvironmentWithOptions") orelse return null;
        const version_proc = GetProcAddress(module, "GetAvailableCoreWebView2BrowserVersionString");
        loader = .{
            .module = module,
            .create_environment = @ptrCast(@alignCast(create)),
            .get_version = if (version_proc) |v| @ptrCast(@alignCast(v)) else null,
        };
        return &loader.?;
    }

    /// `WebView2Loader.dll` in the executable's own folder: the build puts it
    /// there, so an app runs from `zig-out/bin` with nothing else installed.
    fn loadBeside() ?HMODULE {
        var exe_buf: [1024]u16 = undefined;
        const len = GetModuleFileNameW(null, &exe_buf, exe_buf.len);
        if (len == 0) return null;
        // Back to the folder: the last separator, then the name.
        var cut = len;
        while (cut > 0) : (cut -= 1) {
            if (exe_buf[cut - 1] == '\\' or exe_buf[cut - 1] == '/') break;
        }
        if (cut == 0) return null;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");
        var path: [1024 + 20]u16 = undefined;
        @memcpy(path[0..cut], exe_buf[0..cut]);
        @memcpy(path[cut .. cut + name.len], name[0..name.len]);
        path[cut + name.len] = 0;
        return LoadLibraryW(path[0 .. cut + name.len :0].ptr);
    }

    /// The runtime's version ("156.0.4314.56"), or null where none is installed.
    pub fn runtimeVersion(l: *const Loader, gpa: std.mem.Allocator) ?[]u8 {
        const get_fn = l.get_version orelse return null;
        var raw: PWSTR = null;
        if (get_fn(null, &raw) < 0) return null;
        const wide = raw orelse return null;
        defer CoTaskMemFree(raw);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var i: usize = 0;
        while (wide[i] != 0) : (i += 1) {
            const c: u16 = wide[i];
            if (c < 0x80) buf.append(gpa, @intCast(c)) catch return null;
        }
        return buf.toOwnedSlice(gpa) catch null;
    }
};

// ---------------------------------------------------------------------------
// ICoreWebView2Environment (vtable slots after IUnknown's 0, 1, 2)
// ---------------------------------------------------------------------------
pub const Environment = struct {
    /// 3: `CreateCoreWebView2Controller(HWND, handler)`.
    pub fn createController(e: *Com, parent: HWND, handler: *Com) HRESULT {
        return e.slot(*const fn (*Com, HWND, *Com) callconv(.winapi) HRESULT, 3)(e, parent, handler);
    }

    /// 4: `CreateWebResourceResponse(content, status, reason, headers)`.
    pub fn createResponse(e: *Com, content: ?*Com, status: i32, reason: [*:0]const u16, headers: [*:0]const u16, out: *?*Com) HRESULT {
        return e.slot(
            *const fn (*Com, ?*Com, i32, [*:0]const u16, [*:0]const u16, *?*Com) callconv(.winapi) HRESULT,
            4,
        )(e, content, status, reason, headers, out);
    }
};

// ---------------------------------------------------------------------------
// ICoreWebView2Controller
// ---------------------------------------------------------------------------
pub const Controller = struct {
    /// 4: `put_IsVisible`.
    pub fn setIsVisible(c: *Com, visible: BOOL) HRESULT {
        return c.slot(*const fn (*Com, BOOL) callconv(.winapi) HRESULT, 4)(c, visible);
    }

    /// 6: `put_Bounds(RECT)`.
    pub fn setBounds(c: *Com, rect: Rect) HRESULT {
        return c.slot(*const fn (*Com, Rect) callconv(.winapi) HRESULT, 6)(c, rect);
    }

    /// 22: `put_ParentWindow`.
    pub fn setParentWindow(c: *Com, parent: HWND) HRESULT {
        return c.slot(*const fn (*Com, HWND) callconv(.winapi) HRESULT, 22)(c, parent);
    }

    /// 24: `Close`.
    pub fn close(c: *Com) HRESULT {
        return c.slot(*const fn (*Com) callconv(.winapi) HRESULT, 24)(c);
    }

    /// 25: `get_CoreWebView2`.
    pub fn webView(c: *Com, out: *?*Com) HRESULT {
        return c.slot(*const fn (*Com, *?*Com) callconv(.winapi) HRESULT, 25)(c, out);
    }
};

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

// ---------------------------------------------------------------------------
// ICoreWebView2
// ---------------------------------------------------------------------------
pub const WebView = struct {
    /// 3: `get_Settings`.
    pub fn settings(w: *Com, out: *?*Com) HRESULT {
        return w.slot(*const fn (*Com, *?*Com) callconv(.winapi) HRESULT, 3)(w, out);
    }

    /// 4: `get_Source`: the URL the view is showing.
    pub fn source(w: *Com, out: *PWSTR) HRESULT {
        return w.slot(*const fn (*Com, *PWSTR) callconv(.winapi) HRESULT, 4)(w, out);
    }

    /// 5: `Navigate(uri)`.
    pub fn navigate(w: *Com, uri: [*:0]const u16) HRESULT {
        return w.slot(*const fn (*Com, [*:0]const u16) callconv(.winapi) HRESULT, 5)(w, uri);
    }

    /// 27: `AddScriptToExecuteOnDocumentCreated(js, handler)`.
    pub fn addScript(w: *Com, js: [*:0]const u16, handler: ?*Com) HRESULT {
        return w.slot(*const fn (*Com, [*:0]const u16, ?*Com) callconv(.winapi) HRESULT, 27)(w, js, handler);
    }

    /// 29: `ExecuteScript(js, handler)`.
    pub fn executeScript(w: *Com, js: [*:0]const u16, handler: ?*Com) HRESULT {
        return w.slot(*const fn (*Com, [*:0]const u16, ?*Com) callconv(.winapi) HRESULT, 29)(w, js, handler);
    }

    /// 32: `PostWebMessageAsJson(json)`.
    pub fn postJson(w: *Com, json: [*:0]const u16) HRESULT {
        return w.slot(*const fn (*Com, [*:0]const u16) callconv(.winapi) HRESULT, 32)(w, json);
    }

    /// 34: `add_WebMessageReceived(handler, token)`.
    pub fn addWebMessageReceived(w: *Com, handler: *Com, token: ?*i64) HRESULT {
        return w.slot(*const fn (*Com, *Com, ?*i64) callconv(.winapi) HRESULT, 34)(w, handler, token);
    }

    /// 15: `add_NavigationCompleted(handler, token)`.
    pub fn addNavigationCompleted(w: *Com, handler: *Com, token: ?*i64) HRESULT {
        return w.slot(*const fn (*Com, *Com, ?*i64) callconv(.winapi) HRESULT, 15)(w, handler, token);
    }

    /// 55: `add_WebResourceRequested(handler, token)`.
    pub fn addWebResourceRequested(w: *Com, handler: *Com, token: ?*i64) HRESULT {
        return w.slot(*const fn (*Com, *Com, ?*i64) callconv(.winapi) HRESULT, 55)(w, handler, token);
    }

    /// 56: `remove_WebResourceRequested(token)`: releases the handler now,
    /// where the runtime would otherwise hold it until teardown.
    pub fn removeWebResourceRequested(w: *Com, token: i64) HRESULT {
        return w.slot(*const fn (*Com, i64) callconv(.winapi) HRESULT, 56)(w, token);
    }

    /// 35: `remove_WebMessageReceived(token)`.
    pub fn removeWebMessageReceived(w: *Com, token: i64) HRESULT {
        return w.slot(*const fn (*Com, i64) callconv(.winapi) HRESULT, 35)(w, token);
    }

    /// 16: `remove_NavigationCompleted(token)`.
    pub fn removeNavigationCompleted(w: *Com, token: i64) HRESULT {
        return w.slot(*const fn (*Com, i64) callconv(.winapi) HRESULT, 16)(w, token);
    }

    /// 57: `AddWebResourceRequestedFilter(uri, resourceContext)`.
    pub fn addResourceFilter(w: *Com, uri: [*:0]const u16, context: u32) HRESULT {
        return w.slot(*const fn (*Com, [*:0]const u16, u32) callconv(.winapi) HRESULT, 57)(w, uri, context);
    }
};

/// `COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL`.
pub const resource_context_all: u32 = 0;

/// `CoTaskMemFree`, for the strings WebView2 hands out.
pub fn coTaskMemFree(p: ?*anyopaque) void {
    CoTaskMemFree(p);
}

/// `ICoreWebView2WebMessageReceivedEventArgs`: 3 = `get_Source`,
/// 4 = `get_WebMessageAsJson`, 5 = `TryGetWebMessageAsString`.
pub const MessageArgs = struct {
    /// The message as JSON text. `bridge.js` posts an object, so this is the
    /// JSON it becomes (`{"t":"call",...}`), not a quoted string.
    pub fn getWebMessageAsJson(a: *Com, out: *PWSTR) HRESULT {
        return a.slot(*const fn (*Com, *PWSTR) callconv(.winapi) HRESULT, 4)(a, out);
    }
};
/// `ICoreWebView2WebResourceRequestedEventArgs`: 3 = `get_Request`,
/// 5 = `put_Response`.
pub const ResourceArgs = struct {
    pub fn request(a: *Com, out: *?*Com) HRESULT {
        return a.slot(*const fn (*Com, *?*Com) callconv(.winapi) HRESULT, 3)(a, out);
    }

    pub fn setResponse(a: *Com, response: *Com) HRESULT {
        return a.slot(*const fn (*Com, *Com) callconv(.winapi) HRESULT, 5)(a, response);
    }
};

/// `ICoreWebView2WebResourceRequest`: 3 = `get_Uri`.
pub const ResourceRequest = struct {
    pub fn uri(r: *Com, out: *PWSTR) HRESULT {
        return r.slot(*const fn (*Com, *PWSTR) callconv(.winapi) HRESULT, 3)(r, out);
    }
};

/// `ICoreWebView2ExecuteScriptCompletedHandler`'s `Invoke` args:
/// 3 = `get_ResultAsJson`.
// ---------------------------------------------------------------------------
// ICoreWebView2Settings
// ---------------------------------------------------------------------------
pub const Settings = struct {
    /// 12: `put_AreDevToolsEnabled`.
    pub fn setDevTools(s: *Com, on: BOOL) HRESULT {
        return s.slot(*const fn (*Com, BOOL) callconv(.winapi) HRESULT, 12)(s, on);
    }

    /// 14: `put_AreDefaultContextMenusEnabled`.
    pub fn setContextMenus(s: *Com, on: BOOL) HRESULT {
        return s.slot(*const fn (*Com, BOOL) callconv(.winapi) HRESULT, 14)(s, on);
    }

    /// 18: `put_IsZoomControlEnabled`.
    pub fn setZoomControl(s: *Com, on: BOOL) HRESULT {
        return s.slot(*const fn (*Com, BOOL) callconv(.winapi) HRESULT, 18)(s, on);
    }
};

// ---------------------------------------------------------------------------
// Handlers: a COM object whose only method (after IUnknown) is `Invoke`.
// ---------------------------------------------------------------------------

/// What a handler's `Invoke` sees besides its arguments: the dispatch slot
/// numbers `IUnknown` leaves for the interface itself.
pub const handler_slots = 3;

/// Builds the vtable of a handler, at comptime. `T` is the handler's box:
/// it has `com` first (`@fieldParentPtr` finds it), a `refs` count the
/// vtable keeps, and `release_free`, which frees the box when the count
/// reaches zero — so a handler outlives the page that made it, exactly as
/// long as WebView2 still holds it. `invoke` is `T.invoke`: it takes the
/// box a handler's `Invoke` was called on, then that interface's own
/// arguments. The signatures WebView2 has are `(HRESULT, result)` and
/// `(sender, args)`, so the shim is chosen by the second parameter's type.
pub fn HandlerVtable(comptime T: type, comptime invoke: anytype) [handler_slots + 1]*const anyopaque {
    // `invoke` takes the box first, so the environment's `(errorCode, result)`
    // is the one whose second parameter is an integer.
    const Impl = struct {
        fn query(this: *Com, iid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            _ = iid;
            _ = addRef(this);
            out.* = @ptrCast(this);
            return 0;
        }

        fn addRef(this: *Com) callconv(.winapi) u32 {
            const box: *T = @fieldParentPtr("com", this);
            box.refs += 1;
            return box.refs;
        }

        fn release(this: *Com) callconv(.winapi) u32 {
            const box: *T = @fieldParentPtr("com", this);
            box.refs -= 1;
            const refs = box.refs;
            if (refs == 0) box.release_free();
            return refs;
        }

        fn invokeThree(this: *Com, a: ?*Com, b: ?*Com) callconv(.winapi) HRESULT {
            const box: *T = @fieldParentPtr("com", this);
            return invoke(box, a, b);
        }

        fn invokeHr(this: *Com, a: ?*Com, b: ?*Com) callconv(.winapi) HRESULT {
            const box: *T = @fieldParentPtr("com", this);
            // `(HRESULT errorCode, result)`: the error code arrives in the
            // first argument's low 32 bits, as the x64 ABI passes a 4-byte
            // value in an 8-byte slot.
            const raw: usize = @intFromPtr(a);
            const err: HRESULT = @bitCast(@as(u32, @truncate(raw)));
            return invoke(box, err, b);
        }
    };
    // The environment's own callback takes `(box, HRESULT, result)`; every
    // other handler takes `(box, sender, args)`.
    const takes_hr = switch (@typeInfo(@typeInfo(@TypeOf(invoke)).@"fn".param_types[1].?)) {
        .int => true,
        else => false,
    };
    const shim = if (takes_hr) &Impl.invokeHr else &Impl.invokeThree;
    return .{ &Impl.query, &Impl.addRef, &Impl.release, shim };
}

test "the handler vtable is IUnknown then Invoke" {
    try std.testing.expectEqual(@as(usize, 4), handler_slots + 1);
}

/// A `[*:0]const u16` from a comptime string, for the literals WebView2 takes.
pub fn utf8LitZ(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
