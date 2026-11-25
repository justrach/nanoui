//! Dialogs on iOS, with the desktop's calls: they return the user's answer.
//! UIKit's are not modal, so each runs the main run loop until answered,
//! as AppKit's `runModal` does. A message is an alert; opening is the
//! document picker (files are copied into the app's sandbox, folders are
//! opened in place); saving asks for a name in an alert and answers a path
//! in the app's Documents, which the app then writes. A dialog waits for
//! a window still coming or going; one UIKit won't show answers as if
//! closed: canceled, or a message's last button. Call them from `App.soon`:
//! inside a GCD main-queue block (`App.onMain`) UIKit never attaches the
//! document picker, so it would answer canceled. `App.soon` exists only on
//! macOS and iOS, so cross-platform code calls it behind a comptime branch.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("../ui/cf.zig");
const App = @import("app.zig").App;
const dialog_types = @import("../dialog_types.zig");
pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after: bool) i32;
extern "c" const kCFRunLoopDefaultMode: *const anyopaque;

/// Counts the scenes that went (`App.detach`), each taking the dialog up
/// with it: no answer comes for that one.
pub var scene_gone: u32 = 0;

/// A dialog's answer, waited for.
const Wait = struct {
    done: bool = false,
    /// The button pressed (alerts), or 0 for canceled (pickers).
    button: usize = 0,
    /// The picked URLs, retained (pickers).
    urls: ?objc.Object = null,

    /// True once answered; false if the scene went first.
    fn run(w: *Wait) bool {
        const scene = scene_gone;
        while (!w.done and scene == scene_gone) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        return w.done;
    }
};

/// One button of an alert: which one, and the wait it ends.
const Button = struct {
    wait: *Wait,
    index: usize,

    fn pressed(b: *Button, _: objc.Object) void {
        b.wait.button = b.index;
        b.wait.done = true;
    }
};

const ButtonBlock = objc.Block(Button, &.{objc.Object});

/// An alert's wait and buttons, which its button blocks point to. On the
/// heap: an alert abandoned before it attached (`Shown.abandoned`) keeps
/// them, so pressing a button after a late attach writes into live memory.
const AlertState = struct {
    wait: Wait = .{},
    buttons: [8]Button = undefined,

    fn create() ?*AlertState {
        const st = std.heap.c_allocator.create(AlertState) catch return null;
        st.* = .{};
        return st;
    }

    /// Frees the state unless the alert was abandoned: its blocks may
    /// still run.
    fn finish(st: *AlertState, shown: Shown) void {
        if (shown != .abandoned) std.heap.c_allocator.destroy(st);
    }
};

/// What `present` did with a controller.
const Shown = enum {
    /// Answered: the wait is done.
    answered,
    /// Not shown, or its scene went: no answer will come.
    unanswered,
    /// Presented but never attached within the limit, then withdrawn. UIKit
    /// may still attach it later, so whatever its callbacks reach must stay
    /// valid.
    abandoned,
};

fn presenter() ?objc.Object {
    const app = App.shared() orelse return null;
    return app.topController();
}

fn alert(title: []const u8, detail: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("UIAlertController"), "alertControllerWithTitle:message:preferredStyle:", .{
        objc.nsString(title), if (detail.len > 0) objc.nsString(detail) else @as(?objc.Object, null), @as(objc.NSInteger, 1),
    });
}

fn addButton(a: objc.Object, title: []const u8, style: objc.NSInteger, b: *Button) void {
    var block = ButtonBlock.init(b, Button.pressed);
    const action = objc.msg(objc.Object, objc.class("UIAlertAction"), "actionWithTitle:style:handler:", .{
        objc.nsString(title), style, @as(*anyopaque, @ptrCast(&block)),
    });
    objc.msg(void, a, "addAction:", .{action});
}

/// Shows `a` and waits for its answer.
fn present(a: objc.Object, w: *Wait) Shown {
    // UIKit queues a presentation asked for during a transition: let it
    // end first. Not shown at all rather than queued for after this call,
    // its answer written into a wait gone by then.
    var top = presenter() orelse return .unanswered;
    const until = cf.CACurrentMediaTime() + 2;
    while (App.moving(top)) {
        if (cf.CACurrentMediaTime() > until) return .unanswered;
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        top = presenter() orelse return .unanswered;
    }
    objc.msg(void, top, "presentViewController:animated:completion:", .{ a, objc.YES, @as(?*anyopaque, null) });
    // A remote view controller such as the document picker attaches after
    // this call returns (about 1-2 s in the iOS 26 simulator). Inside a GCD
    // main-queue block it never does, so open dialogs from `App.soon`.
    // Refused only if nothing attaches: no answer would ever come.
    const scene = scene_gone;
    const attach_by = cf.CACurrentMediaTime() + 10;
    while (!w.done and scene == scene_gone and objc.msg(?objc.Object, a, "presentingViewController", .{}) == null) {
        if (cf.CACurrentMediaTime() > attach_by) {
            // Withdraw the pending presentation so it doesn't appear later
            // with nobody waiting. Should UIKit attach it anyway, its
            // callbacks must not reach this caller's stack: the caller
            // keeps their targets alive (`AlertState`, the picker delegate
            // cleared).
            // Only if `top` holds it: with nothing presented, UIKit would
            // dismiss `top` itself.
            if (objc.msg(?objc.Object, top, "presentedViewController", .{}) == a)
                objc.msg(void, top, "dismissViewControllerAnimated:completion:", .{ objc.NO, @as(?*anyopaque, null) });
            return .abandoned;
        }
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    if (scene != scene_gone and !w.done) return .unanswered;
    const answered = w.run();
    // Windows shown or closed meanwhile waited for it (`App.arrange`).
    if (App.shared()) |app| app.scheduleArrange();
    return if (answered) .answered else .unanswered;
}

/// A message with buttons; the answer is the button pressed. An alert has
/// no checkbox: `checked` stays false.
pub fn message(opts: MessageOptions) MessageResult {
    const pool = objc.Pool.push();
    defer pool.pop();
    const labels: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
    const st = AlertState.create() orelse return .{ .button = @min(labels.len, 8) - 1 };
    const a = alert(opts.title, opts.detail);
    const n = @min(labels.len, st.buttons.len);
    for (labels[0..n], 0..) |label, i| {
        st.buttons[i] = .{ .wait = &st.wait, .index = i };
        // A critical message's first button is the destructive one.
        const style: objc.NSInteger = if (i == 0 and opts.kind == .critical) 2 else 0;
        addButton(a, label, style, &st.buttons[i]);
    }
    const shown = present(a, &st.wait);
    defer st.finish(shown);
    // Not shown: as a dialog closed without a choice (Linux's answer).
    if (shown != .answered) return .{ .button = n - 1 };
    return .{ .button = st.wait.button };
}

/// The paths the user chose, or null if they canceled. Free with
/// `freePaths`.
pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const types = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const ut = objc.class("UTType");
    if (opts.directories) {
        objc.msg(void, types, "addObject:", .{objc.msg(objc.Object, ut, "typeWithIdentifier:", .{objc.nsString("public.folder")})});
    } else if (opts.extensions.len > 0) {
        for (opts.extensions) |ext| if (objc.msg(?objc.Object, ut, "typeWithFilenameExtension:", .{objc.nsString(ext)})) |t| objc.msg(void, types, "addObject:", .{t});
    }
    if (objc.msg(objc.NSUInteger, types, "count", .{}) == 0) objc.msg(void, types, "addObject:", .{objc.msg(objc.Object, ut, "typeWithIdentifier:", .{objc.nsString("public.item")})});
    // Files are copied into the sandbox, readable as plain paths; a folder
    // can only be opened in place.
    const copy = !opts.directories;
    const picker = objc.msg(objc.Object, objc.alloc("UIDocumentPickerViewController"), "initForOpeningContentTypes:asCopy:", .{ types, copy });
    defer objc.release(picker);
    objc.msg(void, picker, "setAllowsMultipleSelection:", .{opts.multiple});
    if (opts.directory.len > 0) objc.msg(void, picker, "setDirectoryURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(opts.directory)})});
    const cls = objc.defineClass(.{
        .name = "NanoUIDocumentPickerDelegate",
        .protocols = &.{"UIDocumentPickerDelegate"},
        .methods = &.{
            .{ .name = "documentPicker:didPickDocumentsAtURLs:", .imp = &picked, .types = "v@:@@" },
            .{ .name = "documentPickerWasCancelled:", .imp = &pickCanceled, .types = "v@:@" },
        },
    });
    var w: Wait = .{};
    // The picker holds its delegate weakly: this one lives until the answer.
    const delegate = objc.msg(objc.Object, cls, "new", .{});
    defer objc.release(delegate);
    objc.setZig(delegate, &w);
    objc.msg(void, picker, "setDelegate:", .{delegate});
    const shown = present(picker, &w);
    // Its callbacks find no wait from now on, even if it attaches late.
    objc.setZig(delegate, null);
    if (shown != .answered) return null;
    const urls = w.urls orelse return null;
    defer objc.release(urls);
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    const out = try gpa.alloc([]u8, n);
    var filled: usize = 0;
    errdefer freePaths(gpa, out[0..filled]);
    for (0..n) |i| {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
        // Opened in place: readable while the app runs.
        if (!copy) _ = objc.msg(objc.BOOL, url, "startAccessingSecurityScopedResource", .{});
        out[i] = try gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{})));
        filled += 1;
    }
    return out;
}

fn picked(obj: objc.Object, _: objc.SEL, _: objc.Object, urls: objc.Object) callconv(.c) void {
    const w = objc.getZig(Wait, obj) orelse return;
    w.urls = objc.retain(urls);
    w.done = true;
}

fn pickCanceled(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Wait, obj) orelse return;
    w.done = true;
}

/// A path in the app's Documents (or `directory`) named by the user, or
/// null if they canceled. Caller frees it.
pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const st = AlertState.create() orelse return null;
    const a = alert(if (opts.title.len > 0) opts.title else "Save", opts.message);
    objc.msg(void, a, "addTextFieldWithConfigurationHandler:", .{@as(?*anyopaque, null)});
    const fields = objc.msg(objc.Object, a, "textFields", .{});
    const field = objc.msg(objc.Object, fields, "firstObject", .{});
    objc.msg(void, field, "setText:", .{objc.nsString(opts.name)});
    st.buttons[0] = .{ .wait = &st.wait, .index = 0 };
    st.buttons[1] = .{ .wait = &st.wait, .index = 1 };
    addButton(a, "Cancel", 1, &st.buttons[0]);
    addButton(a, if (opts.button.len > 0) opts.button else "Save", 0, &st.buttons[1]);
    const shown = present(a, &st.wait);
    const pressed = st.wait.button;
    st.finish(shown);
    if (shown != .answered or pressed != 1) return null;
    const name = std.mem.trim(u8, objc.fromNSString(objc.msg(?objc.Object, field, "text", .{})), " ");
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const dir = if (opts.directory.len > 0) try gpa.dupe(u8, opts.directory) else try @import("desktop.zig").path(gpa, .documents, "");
    defer gpa.free(dir);
    // The first extension allowed, when the name has none.
    const ext = if (opts.extensions.len > 0 and std.fs.path.extension(name).len == 0) opts.extensions[0] else "";
    const file = if (ext.len > 0) try std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, ext }) else try gpa.dupe(u8, name);
    defer gpa.free(file);
    return try std.fs.path.join(gpa, &.{ dir, file });
}
