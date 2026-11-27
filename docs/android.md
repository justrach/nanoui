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

Not yet: pages, TalkBack accessibility, more than three buttons in a message, and predictive Back's animation. See the [Android roadmap](roadmap.md#android) and [benchmarks](benchmarks.md#android).

## Document picker

The stock NativeActivity cannot receive a document picker's result. An app can
supply `dev.nanoui.android.NanoUIActivity` or a subclass through
`android.apk`'s `activity` option. The app's source handles the provider and
implements the following class contract:

```java
public boolean nanouiOpenDocument(String[] extensions, long maxBytes);
public String nanouiTakeDocument();
private static native void nanouiDocumentAnswered();
```

`nanouiOpenDocument` queues one system document picker on Android's UI
thread and returns false if it cannot start. The activity copies the selected
file into private staging within the supplied byte limit and checks its type
against the extensions. An empty list permits every file type. It calls `nanouiDocumentAnswered` after publishing a
result. A picker already in progress refuses nested requests.
`nanouiTakeDocument` consumes one result: null while pending, an empty
string for cancel, an absolute staged path on success, or the status
`:too_large`, `:unsupported`, `:unavailable` or `:failed`.

Call `dialog.open` on the app thread, outside a view frame. It returns one
staged path. After reading the copy, remove it and its staging folder and
release the paths with `dialog.freePaths`. The activity owns unfinished
copies and cleanup on activity teardown. This entry point is for one file.
