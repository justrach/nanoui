#!/bin/sh
# Installs an app bundle in the booted iOS Simulator and runs it, its
# output in this terminal.
# `zig build $(sh tools/ios/zig-lib.sh) run-gallery -Dtarget=aarch64-ios-simulator`
# runs it; by hand: sh tools/ios/sim.sh zig-out/ios/Gallery.app dev.nanoui.gallery
#
# The bundle is copied and signed ad hoc first (the Simulator wants a
# signature, any): the build's own copy stays as it was. Boot a simulator
# first (open -a Simulator, or xcrun simctl boot "iPhone 17").
set -eu
app="$1"
id="$2"
shift 2

if ! xcrun simctl list devices booted | grep -q Booted; then
	echo "nanoui: no simulator is booted: open -a Simulator, or xcrun simctl boot <device>" >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
name="$(basename "$app")"
cp -R "$app" "$tmp/$name"
chmod -R u+w "$tmp/$name"
chmod +x "$tmp/$name/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$tmp/$name/Info.plist")"
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$tmp/$name" >/dev/null

# The Simulator keeps its own copy.
xcrun simctl install booted "$tmp/$name"
rm -rf "$tmp"
# Under `zig build --watch` the step has to end for the build to watch
# again: the app runs on, its output in this terminal, until a change
# builds and launches it again (which ends the one before) or Ctrl-C.
case "$(ps -o args= -p "$PPID" 2>/dev/null)" in
*" --watch"*)
	xcrun simctl launch --console --terminate-running-process booted "$id" "$@" </dev/null &
	exit 0
	;;
esac
# Arguments after the bundle's id go to the app (--nanoui-snapshot=..., ...).
exec xcrun simctl launch --console-pty --terminate-running-process booted "$id" "$@"
