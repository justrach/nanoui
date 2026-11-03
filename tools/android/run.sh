#!/bin/sh
# Installs an APK on the device adb sees (an emulator, a phone) and runs
# it, its log in this terminal (Ctrl-C ends that; the app runs on).
# `zig build run-gallery -Dtarget=aarch64-linux-android` runs it; by hand:
# sh tools/android/run.sh zig-out/android/Gallery.apk dev.nanoui.gallery
#
# Arguments after the id go to the app (--nanoui-dark, ...), and the
# environment's NANOUI_* variables to its environment, as the intent's
# extras. With several devices, ANDROID_SERIAL picks one; with none,
# boot an emulator without a window: sh tools/android/emulator.sh.
set -eu
apk="$1"
id="$2"
shift 2

adb=adb
if [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then adb="$ANDROID_HOME/platform-tools/adb"; fi
if [ -z "${ANDROID_SERIAL:-}" ] && [ "$("$adb" devices | grep -c '	device$')" -gt 1 ]; then
	echo "nanoui: more than one device: say which with ANDROID_SERIAL (adb devices lists them)" >&2
	exit 1
fi
if [ "$("$adb" get-state 2>/dev/null || true)" != device ]; then
	echo "nanoui: no device: plug in a phone, or boot an emulator (sh tools/android/emulator.sh)" >&2
	exit 1
fi

if ! out="$("$adb" install -r "$apk" 2>&1)"; then
	echo "$out" >&2
	case "$out" in
	*INSTALL_FAILED_UPDATE_INCOMPATIBLE*) echo "nanoui: signed with another key: adb uninstall $id, then run again" >&2 ;;
	esac
	exit 1
fi

# Each argument an extra of its own (src/android/launch.zig), in single
# quotes for the device's shell.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
extras=""
i=0
for a in "$@"; do
	extras="$extras --es nanoui.arg.$i $(quote "$a")"
	i=$((i + 1))
done
i=0
vars="$(env | grep '^NANOUI_' || true)"
while IFS= read -r v; do
	[ -n "$v" ] || continue
	extras="$extras --es nanoui.env.$i $(quote "$v")"
	i=$((i + 1))
done <<EOF
$vars
EOF

"$adb" shell am force-stop "$id"
# The log from now on (the device's own clock).
since="$("$adb" shell date "'+%m-%d %H:%M:%S.000'" | tr -d '\r')"
started="$("$adb" shell "am start -n $id/android.app.NativeActivity $extras" 2>&1)"
case "$started" in
*Error*)
	echo "$started" >&2
	exit 1
	;;
esac
# Under `zig build --watch` the step has to end for the build to watch
# again: the app runs on; its log is `adb logcat -s nanoui`.
case "$(ps -o args= -p "$PPID" 2>/dev/null)" in
*" --watch"*) exit 0 ;;
esac
# What the app prints, and a crash's report.
exec "$adb" logcat -T "$since" -v brief nanoui:V AndroidRuntime:E DEBUG:V libc:F '*:S'
