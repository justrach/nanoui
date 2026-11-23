# Android

How nanoui builds for Android, what an app needs, and what isn't there yet.
The overview is in the [README](../README.md#android).

You need Android's SDK with its NDK, build tools and Android 16's platform
(API 36; Android Studio installs them, and `ANDROID_HOME`, `ANDROID_NDK_HOME`
say where if elsewhere) and Java, to sign. The build links the NDK's C
library, as Zig has none for Android. An app is a library NativeActivity
loads, in an APK signed with the debug key (or `.keystore`):

```zig
const android = @import("nanoui").android;
const lib = android.library(b, .{ .name = "notes", .root_module = mod, .nanoui = nanoui_module });
const apk = android.apk(b, lib, .{ .name = "Notes", .id = "com.example.notes" });
```

Apps run on Android 10 (API 29) and later; `-Dtarget=x86_64-linux-android`
builds for x86 emulators and Chromebooks. A release build of the gallery
(`-Doptimize=ReleaseSmall`) is about 730 KB. Arguments reach a debuggable
build (a debug APK) as the intent's extras (`run-*` passes them, and
`NANOUI_*` variables); a release build ignores them, as any app could send
them, and says so in the log. What it prints goes to `adb logcat -s nanoui`,
and `--nanoui-snapshot` works on a device too, into a path of the app's
(`adb shell run-as` reads it). Zig 0.17.0's std lays out `struct sigaction`
as glibc does and looks host names up in /etc/resolv.conf, neither of which
fits Android: nanoui translates the one and asks Android's resolver instead.

Opening a file needs an activity of nanoui's own: Android answers a picker
in the activity's result, which NativeActivity drops. Name
`dev.nanoui.android.NanoUIActivity` (or a subclass of it, with its source)
as `.activity`, and `dialog.open` shows the system's document picker. The
chosen file is copied, at most `OpenOptions.copy_limit` bytes, into a
folder of its own in the app's cache; the path returned is the caller's,
who deletes the copy and its folder once read. One file, no folders. The
examples use it:

```zig
const apk = android.apk(b, lib, .{ .name = "Notes", .id = "com.example.notes",
    .activity = .{ .name = "dev.nanoui.android.NanoUIActivity" } });
```

Not yet: pages, choosing several files or a folder, TalkBack accessibility, more than three buttons in a message, and predictive Back's animation. See the [Android roadmap](roadmap.md#android) and [benchmarks](benchmarks.md#android).
