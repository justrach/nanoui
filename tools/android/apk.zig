//! Android apps from build.zig: an app is a library NativeActivity loads,
//! built against the NDK's libraries, in an APK with its manifest and
//! theme (aapt2), the library stored for Android to map (`pack.zig`), and
//! signed (apksigner; the debug key unless one is given). nanoui's
//! build.zig makes its examples with it, and exports it for apps:
//!
//!     const android = @import("nanoui").android;
//!     const lib = android.library(b, .{ .name = "notes", .root_module = mod, .nanoui = nanoui_module });
//!     const apk = android.apk(b, lib, .{ .name = "Notes", .id = "com.example.notes" });
//!
//! It finds the SDK by ANDROID_HOME (or ANDROID_SDK_ROOT, else where
//! Android Studio puts it), the NDK by ANDROID_NDK_HOME (else the SDK's
//! newest), the target API's platform in it, and needs Java for apksigner
//! and keytool.
const std = @import("std");

pub const Options = struct {
    /// The name under the icon ("Gallery").
    name: []const u8,
    /// The application id ("dev.nanoui.gallery"): yours, reverse DNS.
    id: []const u8,
    version: []const u8 = "1.0",
    /// Each release's must be higher than the last's.
    version_code: u32 = 1,
    /// The launcher's icon (a PNG); Android's default without.
    icon: ?std.Build.LazyPath = null,
    /// What the app may do. nanoui.http needs the network.
    permissions: []const []const u8 = &.{"android.permission.INTERNET"},
    /// The Android the app is made for (its behaviors), whose platform
    /// must be installed: 34 at least, for the manifest's attributes.
    target_api: u32 = 36,
    /// A release's key; the debug key (Android Studio's, or one made for
    /// nanoui) when null.
    keystore: ?Keystore = null,
};

pub const Keystore = struct {
    path: std.Build.LazyPath,
    alias: []const u8,
    /// As apksigner takes it: "env:NAME" (a variable holding it) or
    /// "file:PATH"; "pass:..." works too, but shows in the build's command
    /// lines.
    password: []const u8,
    /// The key's own, when it isn't the store's (the same forms).
    key_password: ?[]const u8 = null,
};

pub const LibraryOptions = struct {
    /// The library's name: lib<name>.so.
    name: []const u8,
    /// The app's main.zig's module (its `main`, as on the desktop).
    root_module: *std.Build.Module,
    /// nanoui's module, as the app imports it.
    nanoui: *std.Build.Module,
};

/// The app's library for NativeActivity. A library's root is analyzed for
/// what it exports, not for `main`: its root is one made here, which has
/// the app's `main` (and its `std_options` and `panic`, if it has them)
/// and nanoui's entry.
pub fn library(b: *std.Build, opts: LibraryOptions) *std.Build.Step.Compile {
    const app = opts.root_module;
    const root = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("android_root.zig", root_source),
        .target = app.resolved_target,
        .optimize = app.optimize,
        .imports = &.{ .{ .name = "app", .module = app }, .{ .name = "nanoui", .module = opts.nanoui } },
    });
    const lib = b.addLibrary(.{ .name = opts.name, .linkage = .dynamic, .root_module = root });
    // LLVM and LLD (Zig's own x86_64 backend and linker would take a debug
    // build), with segments loadable on devices with 16 KiB pages.
    lib.use_llvm = true;
    lib.use_lld = true;
    lib.link_z_max_page_size = 16384;
    return lib;
}

const root_source =
    \\//! An app's library's root on Android (nanoui's `android.library`).
    \\const std = @import("std");
    \\const app = @import("app");
    \\const nanoui = @import("nanoui");
    \\
    \\pub const main = app.main;
    \\pub const std_options: std.Options = if (@hasDecl(app, "std_options")) app.std_options else .{};
    \\pub const panic = if (@hasDecl(app, "panic")) app.panic else nanoui.android.Panic;
    \\
    \\comptime {
    \\    // NativeActivity's entry (ANativeActivity_onCreate).
    \\    _ = nanoui.android;
    \\}
    \\
;

/// The SDK and NDK, as found on this machine.
pub const Sdk = struct {
    root: []const u8,
    ndk: []const u8,
    build_tools: []const u8,

    /// The SDK, or null (with what's missing logged), found once.
    pub fn find(b: *std.Build) ?Sdk {
        // What's installed decides: the configuration can't be kept.
        b.graph.poisonCache();
        if (searched) return found;
        searched = true;
        found = search(b);
        return found;
    }

    var searched = false;
    var found: ?Sdk = null;

    fn search(b: *std.Build) ?Sdk {
        const env = &b.graph.environ_map;
        const root = env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT") orelse defaultRoot(b) orelse {
            std.log.err("nanoui: no Android SDK: set ANDROID_HOME", .{});
            return null;
        };
        const ndk = env.get("ANDROID_NDK_HOME") orelse env.get("ANDROID_NDK_ROOT") orelse newest(b, b.pathJoin(&.{ root, "ndk" })) orelse {
            std.log.err("nanoui: no Android NDK in {s}/ndk: install it (Android Studio's SDK Manager), or set ANDROID_NDK_HOME", .{root});
            return null;
        };
        const tools = newest(b, b.pathJoin(&.{ root, "build-tools" })) orelse {
            std.log.err("nanoui: no Android build tools in {s}/build-tools", .{root});
            return null;
        };
        return .{ .root = root, .ndk = ndk, .build_tools = tools };
    }

    /// The android.jar of API level `api`'s platform: android-36, else its
    /// newest minor release or extension (android-36.1, android-36-ext19).
    pub fn jar(sdk: Sdk, b: *std.Build, api: u32) ?[]const u8 {
        const dir = b.pathJoin(&.{ sdk.root, "platforms" });
        const exact = b.fmt("android-{d}", .{api});
        var best: ?[]const u8 = null;
        var it_dir = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{ .iterate = true }) catch return null;
        defer it_dir.close(b.graph.io);
        var it = it_dir.iterate();
        while (it.next(b.graph.io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, exact)) continue;
            const rest = e.name[exact.len..];
            if (rest.len > 0 and rest[0] != '.' and rest[0] != '-') continue;
            if (rest.len == 0) {
                best = b.dupe(e.name);
                break;
            }
            if (best == null or newer(e.name, best.?)) best = b.dupe(e.name);
        }
        return b.pathJoin(&.{ dir, best orelse return null, "android.jar" });
    }

    /// The NDK's sysroot.
    pub fn sysroot(sdk: Sdk, b: *std.Build) ?[]const u8 {
        const prebuilt = b.pathJoin(&.{ sdk.ndk, "toolchains", "llvm", "prebuilt" });
        var dir = std.Io.Dir.cwd().openDir(b.graph.io, prebuilt, .{ .iterate = true }) catch return null;
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        // One host's: darwin-x86_64 (every Mac's), linux-x86_64, windows-x86_64.
        while (it.next(b.graph.io) catch null) |e| if (e.kind == .directory) return b.pathJoin(&.{ prebuilt, e.name, "sysroot" });
        return null;
    }

    /// The NDK's libraries for `target`, at its API level.
    pub fn libDir(sdk: Sdk, b: *std.Build, target: std.Target) ?[]const u8 {
        const root = sdk.sysroot(b) orelse return null;
        const api = target.os.version_range.linux.android;
        return b.pathJoin(&.{ root, "usr", "lib", triple(target) orelse return null, b.fmt("{d}", .{api}) });
    }

    /// One of the NDK's shared libraries for `target` (`libEGL.so`): the
    /// file itself, not a name to look up in `libDir`.
    ///
    /// Zig hands the linker every path in a library search dir as
    /// `-l:<path>`, and lld reads the colon of a Windows drive letter there
    /// as flag syntax: on Windows, `-L` finds nothing. A file named outright
    /// does. Elsewhere `-L`/`-l` is what a linker expects, and this is null.
    pub fn libFile(sdk: Sdk, b: *std.Build, target: std.Target, name: []const u8) ?[]const u8 {
        if (b.graph.host.result.os.tag != .windows) return null;
        const dir = sdk.libDir(b, target) orelse return null;
        return b.pathJoin(&.{ dir, b.fmt("lib{s}.so", .{name}) });
    }

    pub fn tool(sdk: Sdk, b: *std.Build, name: []const u8) []const u8 {
        const windows = b.graph.host.result.os.tag == .windows;
        const ext = if (!windows) "" else if (std.mem.eql(u8, name, "apksigner")) ".bat" else ".exe";
        return b.pathJoin(&.{ sdk.build_tools, b.fmt("{s}{s}", .{ name, ext }) });
    }
};

fn defaultRoot(b: *std.Build) ?[]const u8 {
    const env = &b.graph.environ_map;
    return switch (b.graph.host.result.os.tag) {
        .macos => b.pathJoin(&.{ env.get("HOME") orelse return null, "Library", "Android", "sdk" }),
        .windows => b.pathJoin(&.{ env.get("LOCALAPPDATA") orelse return null, "Android", "Sdk" }),
        else => b.pathJoin(&.{ env.get("HOME") orelse return null, "Android", "Sdk" }),
    };
}

/// The entry of `dir` with the highest version ("36.1.0" over "35.0.0").
fn newest(b: *std.Build, path: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(b.graph.io, path, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (best == null or newer(e.name, best.?)) best = b.dupe(e.name);
    }
    return b.pathJoin(&.{ path, best orelse return null });
}

/// `a`'s version is higher than `b`'s, number by number.
fn newer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, ".-_abcdefghijklmnopqrstuvwxyz");
    var ib = std.mem.tokenizeAny(u8, b, ".-_abcdefghijklmnopqrstuvwxyz");
    while (true) {
        const x = ia.next() orelse return false;
        const y = ib.next() orelse return true;
        const nx = std.fmt.parseUnsigned(u32, x, 10) catch 0;
        const ny = std.fmt.parseUnsigned(u32, y, 10) catch 0;
        if (nx != ny) return nx > ny;
    }
}

/// The NDK's name for `target`'s libraries, and the APK's for its ABI.
fn triple(target: std.Target) ?[]const u8 {
    return switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => null,
    };
}

pub fn abi(target: std.Target) ?[]const u8 {
    return switch (target.cpu.arch) {
        .aarch64 => "arm64-v8a",
        .x86_64 => "x86_64",
        .arm => "armeabi-v7a",
        .x86 => "x86",
        else => null,
    };
}

/// Links `lib` against the NDK's C library and system libraries for its
/// target: a libc file naming them (Zig has no Android libc of its own).
pub fn linkNdk(b: *std.Build, lib: *std.Build.Step.Compile, sdk: Sdk) bool {
    const target = lib.root_module.resolved_target.?.result;
    const dir = sdk.libDir(b, target) orelse return false;
    const root = sdk.sysroot(b).?;
    const libc = b.addWriteFiles().add("libc.txt", b.fmt(
        \\include_dir={0s}/usr/include
        \\sys_include_dir={0s}/usr/include/{1s}
        \\crt_dir={2s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir={2s}
        \\darwin_sdk_dir=
        \\
    , .{ root, triple(target) orelse return false, dir }));
    lib.setLibCFile(libc);
    return true;
}

/// The signed APK of `lib`, a dynamic library whose root has the app's
/// `main`, as a path in the cache.
pub fn apk(b: *std.Build, lib: *std.Build.Step.Compile, opts: Options) std.Build.LazyPath {
    const target = lib.root_module.resolved_target.?.result;
    const sdk = Sdk.find(b) orelse return failed(b, lib, "no Android SDK (see above)");
    if (!linkNdk(b, lib, sdk)) return failed(b, lib, b.fmt("the NDK at {s} has no libraries for {s} at API level {d}", .{ sdk.ndk, @tagName(target.cpu.arch), target.os.version_range.linux.android }));
    if (opts.target_api < 34) return failed(b, lib, b.fmt("target_api {d}: 34 at least (the manifest's attributes are 34's)", .{opts.target_api}));
    const jar = sdk.jar(b, opts.target_api) orelse return failed(b, lib, b.fmt("no Android {0d} platform in {1s}/platforms: install it (Android Studio's SDK Manager: Android SDK Platform {0d})", .{ opts.target_api, sdk.root }));

    // The manifest and the theme, compiled and linked by aapt2.
    const files = b.addWriteFiles();
    const manifest = files.add("AndroidManifest.xml", manifestXml(b, lib.name, target, opts));
    _ = files.add("res/values/themes.xml", themes);
    if (opts.icon) |icon| _ = files.addCopyFile(icon, "res/mipmap/icon.png");
    const compile = b.addSystemCommand(&.{ sdk.tool(b, "aapt2"), "compile", "--dir" });
    compile.addDirectoryArg(files.getDirectory().path(b, "res"));
    compile.addArg("-o");
    const res = compile.addOutputFileArg("res.zip");
    const link = b.addSystemCommand(&.{ sdk.tool(b, "aapt2"), "link", "-I", jar, "--min-sdk-version" });
    link.addArg(b.fmt("{d}", .{target.os.version_range.linux.android}));
    link.addArgs(&.{ "--target-sdk-version", b.fmt("{d}", .{opts.target_api}), "--manifest" });
    link.addFileArg(manifest);
    // A debug build is debuggable: adb's run-as, a debugger.
    if ((lib.root_module.optimize orelse .debug) == .debug) link.addArg("--debug-mode");
    link.addArg("-o");
    const base = link.addOutputFileArg("base.apk");
    link.addFileArg(res);

    // The library, stored for Android to map.
    const pack = b.addExecutable(.{ .name = "nanoui-pack", .root_module = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("pack.zig", @embedFile("pack.zig")),
        .target = b.graph.host,
    }) });
    const add = b.addRunArtifact(pack);
    const unsigned = add.addOutputFileArg(b.fmt("{s}-unsigned.apk", .{lib.name}));
    add.addFileArg(base);
    add.addArg(abi(target).?);
    add.addArtifactArg(lib);

    // Signed with the schemes apksigner picks for the minimum API level.
    const sign = b.addSystemCommand(&.{ sdk.tool(b, "apksigner"), "sign", "--ks" });
    if (opts.keystore) |ks| {
        sign.addFileArg(ks.path);
        sign.addArgs(&.{ "--ks-key-alias", ks.alias, "--ks-pass", ks.password });
        if (ks.key_password) |kp| sign.addArgs(&.{ "--key-pass", kp });
    } else {
        sign.addFileArg(debugKeystore(b));
        sign.addArgs(&.{ "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android" });
    }
    sign.addArg("--out");
    const signed = sign.addOutputFileArg(b.fmt("{s}.apk", .{lib.name}));
    sign.addFileArg(unsigned);
    return signed;
}

/// Android Studio's debug key, or one made for nanoui (in Zig's cache)
/// where there is none: debug builds install over each other.
fn debugKeystore(b: *std.Build) std.Build.LazyPath {
    const env = &b.graph.environ_map;
    const home = env.get("HOME") orelse env.get("USERPROFILE");
    if (home) |h| {
        const studio = b.pathJoin(&.{ h, ".android", "debug.keystore" });
        if (std.Io.Dir.cwd().access(b.graph.io, studio, .{})) |_| return .{ .cwd_relative = studio } else |_| {}
    }
    const keytool = b.addSystemCommand(&.{ "keytool", "-genkeypair", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-alias", "androiddebugkey", "-storepass", "android", "-keypass", "android", "-dname", "CN=Android Debug,O=Android,C=US", "-keystore" });
    return keytool.addOutputFileArg("debug.keystore");
}

/// A step that fails with `why`, standing in for the APK.
fn failed(b: *std.Build, lib: *std.Build.Step.Compile, why: []const u8) std.Build.LazyPath {
    const fail = b.addFail(b.fmt("nanoui: can't make an APK: {s}", .{why}));
    lib.step.dependOn(&fail.step);
    return lib.getEmittedBin();
}

/// A full-screen theme of the system's, light or dark with it, which
/// AlertDialogs follow too; bars see-through over the app's view.
const themes =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<resources>
    \\  <style name="NanoUI" parent="@android:style/Theme.DeviceDefault.DayNight">
    \\    <item name="android:windowActionBar">false</item>
    \\    <item name="android:windowNoTitle">true</item>
    \\    <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>
    \\    <item name="android:statusBarColor">@android:color/transparent</item>
    \\    <item name="android:navigationBarColor">@android:color/transparent</item>
    \\  </style>
    \\</resources>
    \\
;

/// The manifest: NativeActivity loading the app's library, every change
/// of configuration the app's own (no restart on rotation or dark mode),
/// Back the app's (Android 16 makes it the system's unless asked).
pub fn manifestXml(b: *std.Build, lib_name: []const u8, target: std.Target, opts: Options) []const u8 {
    var permissions: std.ArrayList(u8) = .empty;
    for (opts.permissions) |p| permissions.print(b.allocator, "  <uses-permission android:name=\"{s}\"/>\n", .{escape(b.allocator, p)}) catch @panic("OOM");
    return b.fmt(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}" android:versionCode="{d}" android:versionName="{s}">
        \\  <uses-sdk android:minSdkVersion="{d}" android:targetSdkVersion="{d}"/>
        \\  <uses-feature android:glEsVersion="0x00030000" android:required="false"/>
        \\{s}  <application android:label="{s}" android:hasCode="false" android:extractNativeLibs="false"
        \\      android:theme="@style/NanoUI" android:enableOnBackInvokedCallback="false"{s}>
        \\    <activity android:name="android.app.NativeActivity" android:exported="true"
        \\        android:launchMode="singleTask" android:windowSoftInputMode="adjustResize"
        \\        android:configChanges="mcc|mnc|locale|touchscreen|keyboard|keyboardHidden|navigation|screenLayout|fontScale|uiMode|orientation|density|screenSize|smallestScreenSize|layoutDirection|colorMode|grammaticalGender|fontWeightAdjustment">
        \\      <meta-data android:name="android.app.lib_name" android:value="{s}"/>
        \\      <intent-filter>
        \\        <action android:name="android.intent.action.MAIN"/>
        \\        <category android:name="android.intent.category.LAUNCHER"/>
        \\      </intent-filter>
        \\    </activity>
        \\  </application>
        \\</manifest>
        \\
    , .{
        escape(b.allocator, opts.id),
        opts.version_code,
        escape(b.allocator, opts.version),
        target.os.version_range.linux.android,
        opts.target_api,
        permissions.items,
        label(b, opts.name),
        if (opts.icon != null) " android:icon=\"@mipmap/icon\"" else "",
        escape(b.allocator, lib_name),
    });
}

/// `s` in an XML attribute.
fn escape(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => out.appendSlice(gpa, "&amp;") catch @panic("OOM"),
        '<' => out.appendSlice(gpa, "&lt;") catch @panic("OOM"),
        '>' => out.appendSlice(gpa, "&gt;") catch @panic("OOM"),
        '"' => out.appendSlice(gpa, "&quot;") catch @panic("OOM"),
        '\'' => out.appendSlice(gpa, "&apos;") catch @panic("OOM"),
        else => out.append(gpa, c) catch @panic("OOM"),
    };
    return out.items;
}

/// The app's name as a label: escaped, and as text even where it starts
/// as a resource would ("@string/...", "?attr").
fn label(b: *std.Build, name: []const u8) []const u8 {
    const e = escape(b.allocator, name);
    return if (e.len > 0 and (e[0] == '@' or e[0] == '?')) b.fmt("\\{s}", .{e}) else e;
}

/// A step that installs `apk` on the device adb sees (an emulator, a
/// phone) and runs it, its log in the terminal (`tools/android/run.sh`).
pub fn runOnDevice(b: *std.Build, apk_path: std.Build.LazyPath, opts: Options, nanoui_root: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(nanoui_root.path(b, "tools/android/run.sh"));
    run.addFileArg(apk_path);
    run.addArg(opts.id);
    run.setEnvironmentVariable("ANDROID_HOME", (Sdk.find(b) orelse return run).root);
    run.has_side_effects = true;
    return run;
}

test "names are escaped for the manifest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Notes &amp; &lt;Tasks&gt; &quot;1&quot; &apos;x&apos;", escape(arena.allocator(), "Notes & <Tasks> \"1\" 'x'"));
}

test "versions compare number by number" {
    try std.testing.expect(newer("36.1.0", "35.0.0"));
    try std.testing.expect(newer("android-36.1", "android-36"));
    try std.testing.expect(!newer("29.0.14206865", "30.0.16248370"));
    try std.testing.expect(newer("android-36", "android-9"));
}
