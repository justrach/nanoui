# iOS

How an app builds for an iPhone or iPad, and what goes in its bundle.
The overview is in the [README](../README.md#ios).

## Devices

`-Dtarget=aarch64-ios` builds for devices: sign the app with your team
(Xcode, or `codesign` and a provisioning profile) and install it with
`xcrun devicectl`. Zig compiles a device's program and Apple's linker
(`xcrun clang`) links it: an iPhone refuses a program Zig 0.17.0 links,
before it runs and without a crash report.

## Bundles

An app bundles itself in its own build.zig:

```zig
const bundle = @import("nanoui").ios.app(b, exe, .{ .name = "Notes", .id = "com.example.notes" });
```

An app that makes its own bundle takes its program from
`ios.executable(b, exe)`.

What a shipping app has goes in the same options:

| Option | What it does |
| --- | --- |
| `.info` | More of Info.plist, as XML: URL schemes, background modes, usage descriptions |
| `.assets`, `.app_icon` | An asset catalog, compiled with actool: the icon and `Assets.car` |
| `.resources` | Files by their name in the bundle: fonts, sounds, a privacy manifest |
| `.extensions` | Folders for `PlugIns/`: widgets, share extensions |
| `.watch` | A Watch app's folder for `Watch/` |
| `.entitlements` | Signed in: push, keychain groups, app groups |
| `.sign` | An identity and a provisioning profile, for a device |

nanoui draws no widgets or Watch faces: SwiftUI does, so build those with
Xcode and pass the folders it makes. Nested bundles with a good signature keep
it, since Xcode gave them their own profiles and entitlements; the app is signed
last, around them. Without `.sign`, a bundle that needs a signature gets an ad
hoc one, which is all the Simulator asks for.

```sh
zig build $(sh tools/ios/zig-lib.sh) test-bundle -Dtarget=aarch64-ios-simulator
```

checks every option on the fixture in `tools/ios/fixture`.

## iOS versions

Zig 0.17 makes iOS 18 the lowest an app runs on unless the target names
one, and the app's Info.plist follows it. nanoui runs on iOS 15 and
later: `-Dtarget=aarch64-ios.15.0` (or `aarch64-ios.15.0-simulator`)
reaches those devices.

## iPad windows

With `.multiple_windows = true` in `ios.app`, a person can open several windows
of the app, and the app can open them too:

```zig
_ = try app.newWindow(.{ .title = "Notes", .own_scene = true, .content = .{ .view = view } });
app.onNewWindow(&state, makeWindow); // the system's New Window, or a window restored
```

The first scene shows the app's stack of windows, as a phone does. Every other
shows one window, made with `.own_scene`. On a phone, a window asking for its
own scene goes on the stack like any other, so the same code runs on both.

Closing the window in the system's UI closes it in the app, through `on_close`.
Dialogs and `⌘W` still act on the first scene's stack, not the scene in front.
