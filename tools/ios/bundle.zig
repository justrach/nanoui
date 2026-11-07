//! iOS app bundles from build.zig: an executable and its Info.plist in a
//! `Name.app` folder, which the Simulator installs as is and a device
//! installs once signed. nanoui's build.zig bundles its examples with it,
//! and exports it for apps (`@import("nanoui").ios.app(b, exe, .{...})`).
const std = @import("std");

pub const Options = struct {
    /// The name under the icon ("Gallery").
    name: []const u8,
    /// The bundle identifier ("dev.nanoui.gallery"): yours, reverse DNS.
    id: []const u8,
    version: []const u8 = "1.0",
    /// Files the Files app shows (the app's Documents).
    file_sharing: bool = false,
    /// Why the app asks for the location while in use, shown in iOS's
    /// prompt (NSLocationWhenInUseUsageDescription). Without it, iOS refuses.
    location_usage: ?[]const u8 = null,
    /// iPad: the person can open several windows of the app, and windows made
    /// with `.own_scene` get theirs (UIApplicationSupportsMultipleScenes).
    multiple_windows: bool = false,
    /// More of Info.plist, as plist XML: `<key>…</key><string>…</string>`
    /// (URL schemes, background modes, usage descriptions). A key the
    /// bundle already sets mustn't appear again.
    info: []const u8 = "",
    /// An asset catalog (`.xcassets`), compiled with Xcode's actool: its
    /// `app_icon` set becomes the icon, the rest `Assets.car`.
    assets: ?std.Build.LazyPath = null,
    app_icon: []const u8 = "AppIcon",
    /// Files the app reads from its bundle (fonts, sounds, a privacy
    /// manifest), by the name they have there.
    resources: []const Part = &.{},
    /// Folders for `PlugIns/`, as Xcode builds them: an app's widgets, share
    /// extensions and the like (`.name = "Widgets.appex"`).
    extensions: []const Part = &.{},
    /// A Watch app's folder for `Watch/` (`.name = "Notes Watch.app"`).
    watch: ?Part = null,
    /// The signature's entitlements (push, keychain groups, app groups).
    entitlements: ?std.Build.LazyPath = null,
    /// Signs for a device. Without it the bundle is signed ad hoc, for the
    /// Simulator, when any of the options above need a signature at all.
    sign: ?Sign = null,
};

/// A file or folder that goes in the bundle, and its name there.
pub const Part = struct { path: std.Build.LazyPath, name: []const u8 };

pub const Sign = struct {
    /// As `security find-identity` names it ("Apple Development: …").
    identity: []const u8,
    /// Becomes `embedded.mobileprovision`.
    profile: std.Build.LazyPath,
};

/// The folder `<name>.app` holding `exe` and an Info.plist made for its
/// target (the Simulator's or a device's), as a path in the cache.
pub fn app(b: *std.Build, exe: *std.Build.Step.Compile, opts: Options) std.Build.LazyPath {
    const target = exe.root_module.resolved_target.?.result;
    const dir = b.fmt("{s}.app", .{opts.name});
    const wf = b.addWriteFiles();
    _ = wf.add(b.fmt("{s}/Info.plist", .{dir}), infoPlist(b, exe.name, target, opts));
    _ = wf.addCopyFile(executable(b, exe), b.fmt("{s}/{s}", .{ dir, exe.name }));
    for (opts.resources) |r| _ = wf.addCopyFile(r.path, b.fmt("{s}/{s}", .{ dir, r.name }));
    for (opts.extensions) |e| _ = wf.addCopyDirectory(e.path, b.fmt("{s}/PlugIns/{s}", .{ dir, e.name }), .{});
    if (opts.watch) |w| _ = wf.addCopyDirectory(w.path, b.fmt("{s}/Watch/{s}", .{ dir, w.name }), .{});
    const made = wf.getDirectory().path(b, dir);
    if (opts.assets == null and opts.entitlements == null and opts.sign == null and opts.extensions.len == 0 and opts.watch == null) return made;
    return finished(b, made, target, opts);
}

/// The app with what takes Xcode's tools: its catalog compiled and merged
/// in, then signed from the inside out (finish.sh).
fn finished(b: *std.Build, made: std.Build.LazyPath, target: std.Target, opts: Options) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "sh", "-c", @embedFile("finish.sh"), "finish" });
    run.addDirectoryArg(made);
    const out = run.addOutputDirectoryArg(b.fmt("{s}.app", .{opts.name}));
    run.addArg(if (opts.sign) |s| s.identity else "-");
    if (opts.sign) |s| run.addFileArg(s.profile) else run.addArg("");
    if (opts.entitlements) |e| run.addFileArg(e) else run.addArg("");
    if (opts.assets) |catalog| {
        const simulator = target.abi == .simulator;
        const min = target.os.version_range.semver.min;
        const actool = b.addSystemCommand(&.{ "xcrun", "actool", "--notices", "--warnings", "--errors", "--output-format", "human-readable-text" });
        actool.addArgs(&.{ "--platform", if (simulator) "iphonesimulator" else "iphoneos", "--minimum-deployment-target", b.fmt("{d}.{d}", .{ min.major, min.minor }) });
        actool.addArgs(&.{ "--target-device", "iphone", "--target-device", "ipad", "--app-icon", opts.app_icon, "--output-partial-info-plist" });
        const partial = actool.addOutputFileArg("partial.plist");
        actool.addArg("--compile");
        const compiled = actool.addOutputDirectoryArg("compiled");
        // A step's cache doesn't hash a folder argument's contents; WriteFiles
        // does, so an edited catalog is compiled again.
        actool.addDirectoryArg(b.addWriteFiles().addCopyDirectory(catalog, "Assets.xcassets", .{}));
        run.addDirectoryArg(compiled);
        run.addFileArg(partial);
    }
    return out;
}

/// `exe` as an app's program. For the Simulator, as Zig links it. For a
/// device, Zig compiles it and Apple's linker links it: an iPhone won't
/// start a program Zig 0.17.0 links (it is refused before it runs, with
/// no crash report), while the Simulator runs the same. Apple's linker
/// gets what `exe`'s modules ask for: frameworks, system and static
/// libraries, and where to find them.
pub fn executable(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const target = exe.root_module.resolved_target.?.result;
    if (target.abi == .simulator) return stamped(b, exe, stripped(b, exe, exe.getEmittedBin()));
    const obj = b.addObject(.{ .name = exe.name, .root_module = exe.root_module, .use_llvm = exe.use_llvm, .zig_lib_dir = exe.zig_lib_dir });
    obj.bundle_compiler_rt = true;
    const min = target.os.version_range.semver.min;
    const link = b.addSystemCommand(&.{ "xcrun", "-sdk", "iphoneos", "clang", "-target", b.fmt("arm64-apple-ios{d}.{d}", .{ min.major, min.minor }) });
    link.addFileArg(obj.getEmittedBin());
    for (exe.root_module.getGraph().modules) |m| {
        for (m.lib_paths.items) |p| link.addPrefixedDirectoryArg("-L", p);
        for (m.include_dirs.items) |d| switch (d) {
            .framework_path, .framework_path_system => |p| link.addPrefixedDirectoryArg("-F", p),
            else => {},
        };
        for (m.frameworks.keys(), m.frameworks.values()) |name, f| {
            if (f.weak) link.addArg(b.fmt("-Wl,-weak_framework,{s}", .{name})) else if (f.needed) link.addArg(b.fmt("-Wl,-needed_framework,{s}", .{name})) else link.addArgs(&.{ "-framework", name });
        }
        for (m.link_objects.items) |o| switch (o) {
            .system_lib => |l| if (l.use_pkg_config == .force)
                std.debug.panic("ios: {s} asks for pkg-config, which has no iPhoneOS answer", .{l.name})
            else
                link.addArg(b.fmt("{s}{s}", .{ if (l.weak) "-Wl,-weak-l" else if (l.needed) "-Wl,-needed-l" else "-l", l.name })),
            .static_path => |p| link.addFileArg(p),
            .other_step => |s| link.addArtifactArg(s),
            else => {},
        };
    }
    // As Zig's linker does unless told not to: unused code left out.
    if (exe.link_gc_sections orelse true) link.addArg("-Wl,-dead_strip");
    link.addArg("-o");
    return stripped(b, exe, link.addOutputFileArg(exe.name));
}

/// The Simulator's program, marked as built with the installed SDK, and
/// signed again. Zig's linker writes its own idea of the SDK (27.0 with
/// Zig 0.17.0), and UIKit keeps what is new in a later SDK from a program
/// built with an earlier one: on iOS 27.1, the iPhone Duo's full inner
/// screen (a narrower window without it) and its fold's reserved regions.
fn stamped(b: *std.Build, exe: *std.Build.Step.Compile, bin: std.Build.LazyPath) std.Build.LazyPath {
    const min = exe.root_module.resolved_target.?.result.os.version_range.semver.min;
    const run = b.addSystemCommand(&.{
        "sh",    "-c",
        \\set -e
        \\sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
        \\xcrun vtool -set-build-version iossim "$1" "$sdk" -replace -output "$3" "$2" 2>/dev/null
        \\codesign -f -s - "$3" 2>/dev/null
        ,
        "stamp", b.fmt("{d}.{d}", .{ min.major, min.minor }),
    });
    run.addFileArg(bin);
    return run.addOutputFileArg(exe.name);
}

/// A release's program without its local symbols (about a tenth of it),
/// which Zig's linker keeps however it is asked; a debug build's as it
/// is. Xcode's strip: any iOS build has Xcode for the SDK.
fn stripped(b: *std.Build, exe: *std.Build.Step.Compile, bin: std.Build.LazyPath) std.Build.LazyPath {
    if (exe.root_module.optimize.? == .debug) return bin;
    const strip = b.addSystemCommand(&.{ "xcrun", "strip", "-x", "-o" });
    const out = strip.addOutputFileArg(exe.name);
    strip.addFileArg(bin);
    return out;
}

/// A step that installs `bundle` in the booted Simulator and runs it,
/// its output in the terminal (`tools/ios/sim.sh`).
pub fn runInSimulator(b: *std.Build, bundle: std.Build.LazyPath, opts: Options, nanoui_root: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(nanoui_root.path(b, "tools/ios/sim.sh"));
    run.addDirectoryArg(bundle);
    run.addArg(opts.id);
    run.has_side_effects = true;
    return run;
}

/// The Info.plist: a full screen app (a launch screen), scenes from code
/// (nanoui's scene delegate), ProMotion's 120 Hz, every orientation.
pub fn infoPlist(b: *std.Build, exe_name: []const u8, target: std.Target, opts: Options) []const u8 {
    const simulator = target.abi == .simulator;
    const min = target.os.version_range.semver.min;
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundleDisplayName</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>CFBundleSupportedPlatforms</key><array><string>{s}</string></array>
        \\  <key>LSRequiresIPhoneOS</key><true/>
        \\  <key>MinimumOSVersion</key><string>{d}.{d}</string>
        \\  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
        \\  <key>UILaunchScreen</key><dict/>
        \\  <key>UIApplicationSceneManifest</key>
        \\  <dict><key>UIApplicationSupportsMultipleScenes</key><{s}/></dict>
        \\  <key>UIApplicationSupportsIndirectInputEvents</key><true/>
        \\  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
        \\  <key>UIFileSharingEnabled</key><{s}/>
        \\  <key>LSSupportsOpeningDocumentsInPlace</key><{s}/>
        \\{s}
        \\{s}
        \\  <key>UISupportedInterfaceOrientations</key>
        \\  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\  <key>UISupportedInterfaceOrientations~ipad</key>
        \\  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\</dict>
        \\</plist>
        \\
    , .{
        exe_name,
        opts.id,
        opts.name,
        opts.name,
        opts.version,
        opts.version,
        if (simulator) "iPhoneSimulator" else "iPhoneOS",
        min.major,
        min.minor,
        if (opts.multiple_windows) "true" else "false",
        if (opts.file_sharing) "true" else "false",
        if (opts.file_sharing) "true" else "false",
        if (opts.location_usage) |why| b.fmt("  <key>NSLocationWhenInUseUsageDescription</key><string>{s}</string>", .{escaped(b, why)}) else "",
        opts.info,
    });
}

/// `text` with XML's special characters escaped, for a plist string.
fn escaped(b: *std.Build, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| switch (ch) {
        '&' => out.appendSlice(b.allocator, "&amp;") catch @panic("OOM"),
        '<' => out.appendSlice(b.allocator, "&lt;") catch @panic("OOM"),
        '>' => out.appendSlice(b.allocator, "&gt;") catch @panic("OOM"),
        else => out.append(b.allocator, ch) catch @panic("OOM"),
    };
    return out.items;
}
