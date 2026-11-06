//! Tray icons on Windows: an icon in the notification area
//! (`Shell_NotifyIconW`), the executable's own (resource ordinal 1) until
//! `setImage` gives it pixels, with a tooltip and a popup menu. A left click
//! calls `on_click` (or shows the menu when there is none); a right click
//! shows the menu. The menu can be replaced while the app runs
//! (`setMenu`/`updateMenu`) and its items' state changed (`menuItem`), shown
//! the next time it opens. The same API as the Mac's (`src/tray.zig`);
//! there is no title or SF Symbol here, so `setTitle` and `setSymbol` do
//! nothing. The platform-free half is `tray_model.zig`.
const std = @import("std");
const w = @import("win32.zig");
const menu_mod = @import("../menu_accel.zig");
const model = @import("tray_model.zig");

pub const Click = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, tray: *Tray) void };
/// Where the icon is, in screen pixels.
pub const Anchor = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Options = struct {
    /// Not shown on Windows (the notification area has no text).
    title: []const u8 = "",
    /// Not shown on Windows (no SF Symbols).
    symbol: []const u8 = "",
    /// The app's name when empty.
    tooltip: []const u8 = "",
    menu: []const menu_mod.MenuItem = &.{},
    /// Called on a left click; with none, a left click shows the menu.
    on_click: ?Click = null,
};

/// The app's hooks (`App.newTray` sets them): what a `.quit` item with no
/// click of its own calls, and who forgets the tray when it is destroyed.
pub const Owner = struct {
    ctx: *anyopaque,
    quit: *const fn (ctx: *anyopaque) void,
    forget: *const fn (ctx: *anyopaque, tray: *Tray) void,
};

const HMENU = *opaque {};
const Guid = extern struct { a: u32 = 0, b: u16 = 0, c: u16 = 0, d: [8]u8 = @splat(0) };

const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?w.HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: ?*anyopaque = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: Guid = .{},
    hBalloonIcon: ?*anyopaque = null,
};

comptime {
    // The shell checks `cbSize` against the layouts it knows.
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(NOTIFYICONDATAW) == 976);
}

const NOTIFYICONIDENTIFIER = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONIDENTIFIER),
    hWnd: ?w.HWND,
    uID: u32,
    guidItem: Guid = .{},
};

const ICONINFO = extern struct { fIcon: w.BOOL = 1, xHotspot: u32 = 0, yHotspot: u32 = 0, hbmMask: ?*anyopaque, hbmColor: ?*anyopaque };

extern "shell32" fn Shell_NotifyIconW(msg: u32, data: *NOTIFYICONDATAW) callconv(.winapi) w.BOOL;
extern "shell32" fn Shell_NotifyIconGetRect(id: *const NOTIFYICONIDENTIFIER, rect: *w.RECT) callconv(.winapi) i32;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
extern "user32" fn AppendMenuW(menu: HMENU, flags: u32, id: usize, label: ?[*:0]const u16) callconv(.winapi) w.BOOL;
extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) w.BOOL;
extern "user32" fn TrackPopupMenuEx(menu: HMENU, flags: u32, x: i32, y: i32, hwnd: w.HWND, params: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "user32" fn CheckMenuRadioItem(menu: HMENU, first: u32, last: u32, check: u32, flags: u32) callconv(.winapi) w.BOOL;
extern "user32" fn RegisterWindowMessageW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn GetCursorPos(p: *w.POINT) callconv(.winapi) w.BOOL;
extern "user32" fn LoadImageW(inst: ?w.HINSTANCE, name: usize, kind: u32, cx: i32, cy: i32, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn LoadIconW(inst: ?w.HINSTANCE, name: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn CreateIconIndirect(info: *const ICONINFO) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyIcon(icon: *anyopaque) callconv(.winapi) w.BOOL;
extern "gdi32" fn CreateDIBSection(hdc: ?w.HDC, bmi: *const w.BITMAPINFOHEADER, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateBitmap(width: i32, height: i32, planes: u32, bpp: u32, bits: ?*const anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) w.BOOL;

const NIM_ADD: u32 = 0;
const NIM_MODIFY: u32 = 1;
const NIM_DELETE: u32 = 2;
const NIM_SETVERSION: u32 = 4;
const NIF_MESSAGE: u32 = 0x1;
const NIF_ICON: u32 = 0x2;
const NIF_TIP: u32 = 0x4;
const NIF_SHOWTIP: u32 = 0x80;
const NOTIFYICON_VERSION_4: u32 = 4;
const TPM_RIGHTBUTTON: u32 = 0x2;
const TPM_RIGHTALIGN: u32 = 0x8;
const TPM_BOTTOMALIGN: u32 = 0x20;
const TPM_NONOTIFY: u32 = 0x80;
const TPM_RETURNCMD: u32 = 0x100;
const MF_BYCOMMAND: u32 = 0;
const WM_NULL: u32 = 0;
/// The icon's messages to its window.
const WM_TRAY: u32 = w.WM_APP + 0x51;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NanoUITray");
var registered = false;
/// Explorer broadcasts it when the taskbar is made again (it restarted, or
/// started after the app): every icon must be added anew.
var taskbar_created: u32 = 0;
var next_id: u32 = 1;

pub const Tray = struct {
    gpa: std.mem.Allocator,
    app_name: []const u8,
    /// A hidden top-level window that hears the icon (a message-only one
    /// misses Explorer's broadcast, and a menu needs a foreground owner).
    hwnd: w.HWND,
    id: u32,
    icon: ?*anyopaque = null,
    /// `setImage` made the icon, so it is destroyed with the tray.
    own_icon: bool = false,
    tip: [128]u16 = @splat(0),
    menu: ?*model.Model = null,
    on_click: ?Click = null,
    owner: ?Owner = null,
    /// The menu is up (`TrackPopupMenuEx` runs its own loop): a `destroy`
    /// meanwhile waits for it to close.
    tracking: bool = false,
    doomed: bool = false,
    /// Bumped by each `setMenu`: a command chosen from a menu replaced
    /// while it was up is dropped, not sent to a stranger.
    generation: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, opts: Options) !*Tray {
        const inst = w.GetModuleHandleW(null);
        if (!registered) {
            const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = class_name };
            if (w.RegisterClassExW(&wc) == 0) return error.RegisterClass;
            taskbar_created = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
            registered = true;
        }
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        const hwnd = w.CreateWindowExW(w.WS_EX_TOOLWINDOW, class_name, class_name, w.WS_POPUP, 0, 0, 0, 0, null, null, inst, null) orelse return error.CreateWindow;
        self.* = .{ .gpa = gpa, .app_name = app_name, .hwnd = hwnd, .id = next_id, .on_click = opts.on_click };
        next_id += 1;
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        errdefer _ = w.DestroyWindow(hwnd);
        // The executable's icon at the notification area's size, or the
        // system's; shared (`LR_SHARED`), so never destroyed here.
        const image_icon: u32 = 1;
        const lr_shared: u32 = 0x8000;
        self.icon = LoadImageW(inst, 1, image_icon, w.GetSystemMetrics(49), w.GetSystemMetrics(50), lr_shared) orelse LoadIconW(null, 32512);
        _ = w.wide(&self.tip, if (opts.tooltip.len > 0) opts.tooltip else app_name);
        if (opts.menu.len > 0) try self.setMenu(app_name, opts.menu);
        // Explorer may not be up yet (a launch at login): `TaskbarCreated`
        // adds the icon when it is.
        self.add();
        return self;
    }

    pub fn destroy(self: *Tray) void {
        // The app forgets it now, even when the menu is up and it goes later.
        if (self.owner) |o| o.forget(o.ctx, self);
        self.owner = null;
        if (self.tracking) {
            self.doomed = true;
            return;
        }
        var data = self.notifyData(0);
        _ = Shell_NotifyIconW(NIM_DELETE, &data);
        _ = w.SetWindowLongPtrW(self.hwnd, w.GWLP_USERDATA, 0);
        _ = w.DestroyWindow(self.hwnd);
        if (self.own_icon) if (self.icon) |i| {
            _ = DestroyIcon(i);
        };
        if (self.menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    fn notifyData(self: *Tray, flags: u32) NOTIFYICONDATAW {
        var d: NOTIFYICONDATAW = .{ .hWnd = self.hwnd, .uID = self.id, .uFlags = flags, .uCallbackMessage = WM_TRAY, .hIcon = self.icon };
        d.szTip = self.tip;
        return d;
    }

    fn add(self: *Tray) void {
        var d = self.notifyData(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        if (Shell_NotifyIconW(NIM_ADD, &d) == 0) return;
        d.uVersion = NOTIFYICON_VERSION_4;
        _ = Shell_NotifyIconW(NIM_SETVERSION, &d);
    }

    fn modify(self: *Tray, flags: u32) void {
        var d = self.notifyData(flags);
        _ = Shell_NotifyIconW(NIM_MODIFY, &d);
    }

    /// The notification area shows no text.
    pub fn setTitle(_: *Tray, _: []const u8) void {}

    /// No SF Symbols on Windows.
    pub fn setSymbol(_: *Tray, _: []const u8) void {}

    pub fn setTooltip(self: *Tray, tooltip: []const u8) void {
        self.tip = @splat(0);
        _ = w.wide(&self.tip, tooltip);
        self.modify(NIF_TIP | NIF_SHOWTIP);
    }

    /// Shows `bgra` (premultiplied, `width` × `height` pixels) as the icon.
    /// `scale` and `template` are the Mac's: the pixels are shown as they
    /// are, at the notification area's size.
    pub fn setImage(self: *Tray, bgra: []const u8, width: usize, height: usize, scale: f64, template: bool) void {
        _ = scale;
        _ = template;
        if (width == 0 or height == 0 or bgra.len < width * height * 4) return;
        const header: w.BITMAPINFOHEADER = .{ .biWidth = @intCast(width), .biHeight = -@as(i32, @intCast(height)) };
        var bits: ?*anyopaque = null;
        const color = CreateDIBSection(null, &header, 0, &bits, null, 0) orelse return;
        defer _ = DeleteObject(color);
        const px: [*]u8 = @ptrCast(bits orelse return);
        model.straightAlpha(px[0 .. width * height * 4], bgra[0 .. width * height * 4]);
        // The colour bitmap's alpha decides; the mask is ignored but required.
        const mask = CreateBitmap(@intCast(width), @intCast(height), 1, 1, null) orelse return;
        defer _ = DeleteObject(mask);
        const icon = CreateIconIndirect(&.{ .hbmMask = mask, .hbmColor = color }) orelse return;
        const old = self.icon;
        const owned = self.own_icon;
        self.icon = icon;
        self.own_icon = true;
        self.modify(NIF_ICON);
        if (owned) if (old) |o| {
            _ = DestroyIcon(o);
        };
    }

    /// Where the icon is, in screen pixels (zero when the shell won't say).
    pub fn anchor(self: *Tray) Anchor {
        var r: w.RECT = .{};
        if (Shell_NotifyIconGetRect(&.{ .hWnd = self.hwnd, .uID = self.id }, &r) != 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = @floatFromInt(r.left), .y = @floatFromInt(r.top), .width = @floatFromInt(r.right - r.left), .height = @floatFromInt(r.bottom - r.top) };
    }

    /// Replaces the menu with one built from `template`, which is copied:
    /// it may be a temporary.
    pub fn setMenu(self: *Tray, app_name: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try model.Model.create(self.gpa, app_name, template);
        if (self.menu) |old| old.destroy();
        self.menu = m;
        self.generation +%= 1;
    }

    /// `setMenu` under the app's name.
    pub fn updateMenu(self: *Tray, template: []const menu_mod.MenuItem) !void {
        return self.setMenu(self.app_name, template);
    }

    /// The menu's item whose template had `id`, to check or disable.
    pub fn menuItem(self: *Tray, id: []const u8) ?*menu_mod.Item {
        const m = self.menu orelse return null;
        return m.item(id);
    }

    fn handle(self: *Tray, wp: w.WPARAM, lp: w.LPARAM) void {
        // A click on the icon while the popup is up arrives inside
        // TrackPopupMenuEx's own loop; reopening there would clear
        // `tracking` under the outer frame and let a destroy free it.
        if (self.tracking) return;
        const cb = model.decode(wp, lp);
        switch (model.action(cb.event, self.on_click != null, self.menu != null)) {
            .none => {},
            .click => if (self.on_click) |c| c.func(c.ctx, self),
            .menu => self.showMenu(cb.x, cb.y),
        }
    }

    /// Shows the menu at (`x`, `y`) and runs the item chosen.
    pub fn showMenu(self: *Tray, x: i32, y: i32) void {
        const m = self.menu orelse return;
        const popup = buildPopup(m) orelse return;
        defer _ = DestroyMenu(popup);
        var at: w.POINT = .{ .x = x, .y = y };
        if (x == 0 and y == 0) _ = GetCursorPos(&at);
        // The owner must be in front, or the menu stays up after a click
        // elsewhere; the null message after it lets the next click count.
        _ = w.SetForegroundWindow(self.hwnd);
        const generation = self.generation;
        self.tracking = true;
        const align_right: u32 = if (w.GetSystemMetrics(40) != 0) TPM_RIGHTALIGN else 0;
        const cmd = TrackPopupMenuEx(popup, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | align_right, at.x, at.y, self.hwnd, null);
        self.tracking = false;
        _ = w.PostMessageW(self.hwnd, WM_NULL, 0, 0);
        if (self.doomed) return self.destroy();
        if (cmd <= 0 or generation != self.generation) return;
        const it = (self.menu orelse return).itemOf(@intCast(cmd)) orelse return;
        if (it.disabled) return;
        if (it.click == null and it.role == .quit) {
            if (self.owner) |o| o.quit(o.ctx);
            return;
        }
        menu_mod.Menu.activate(it);
    }

    fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
        const raw: usize = @bitCast(w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA));
        const self: *Tray = @ptrFromInt(if (raw == 0) return w.DefWindowProcW(hwnd, msg, wp, lp) else raw);
        if (msg == WM_TRAY) {
            self.handle(wp, lp);
            return 0;
        }
        if (msg == taskbar_created and taskbar_created != 0) {
            self.add();
            return 0;
        }
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }
};

/// The popup menu of `m`'s rows, with its items' state now.
fn buildPopup(m: *const model.Model) ?HMENU {
    const root = CreatePopupMenu() orelse return null;
    // The open submenus: each one's menu and the row that opened it.
    var stack: [16]struct { menu: HMENU, row: usize } = undefined;
    var depth: usize = 0;
    var cur = root;
    for (m.rows, 0..) |row, i| switch (row.kind) {
        .open => {
            const sub = CreatePopupMenu() orelse break;
            if (depth == stack.len) {
                _ = DestroyMenu(sub);
                break;
            }
            stack[depth] = .{ .menu = cur, .row = i };
            depth += 1;
            cur = sub;
        },
        .close => {
            if (depth == 0) continue;
            depth -= 1;
            const parent = stack[depth];
            const open = m.rows[parent.row];
            _ = AppendMenuW(parent.menu, model.flags(open, null), @intFromPtr(cur), open.label.ptr);
            cur = parent.menu;
        },
        .separator => _ = AppendMenuW(cur, model.MF_SEPARATOR, 0, null),
        .item => {
            const it = m.itemOf(row.command);
            _ = AppendMenuW(cur, model.flags(row, it), row.command, row.label.ptr);
            if (it) |x| if (x.kind == .radio and x.checked) {
                _ = CheckMenuRadioItem(cur, row.command, row.command, row.command, MF_BYCOMMAND);
            };
        },
    };
    // A submenu left open (rows cut short above) is attached as it is.
    while (depth > 0) {
        depth -= 1;
        const parent = stack[depth];
        const open = m.rows[parent.row];
        _ = AppendMenuW(parent.menu, model.flags(open, null), @intFromPtr(cur), open.label.ptr);
        cur = parent.menu;
    }
    return root;
}
