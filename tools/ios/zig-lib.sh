#!/bin/sh
# Zig 0.17.0 and 0.17.1 can't build any program for iOS as they ship: its std says iOS
# can replace its process image (std.process.can_replace), so every
# program's std.Io pulls in posix_spawn's /dev/null handling, which std
# leaves out on iOS ("no field named 'fd' in struct ... NullFile").
#
# This makes Zig's lib folder again, out of links to the real one, with
# that one line fixed, and prints the flag that uses it, which goes first:
#
#   zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator
#
# A Zig whose std is fixed needs nothing: then it prints nothing.
set -eu
env="$(zig env)"
lib="$(printf '%s\n' "$env" | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')"
version="$(printf '%s\n' "$env" | sed -n 's/^ *\.version = "\(.*\)",$/\1/p')"
if [ ! -f "$lib/std/process.zig" ]; then
	echo "zig-lib.sh: no std/process.zig in Zig's lib folder ($lib)" >&2
	exit 1
fi
broken='    .windows, .haiku, .wasi => false,'
fixed='    .windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,'
# Zig 0.17.1 added tvOS and watchOS to the same arm but still omits iOS.
if grep -qxF '    .windows, .haiku, .wasi, .tvos, .watchos => false,' "$lib/std/process.zig"; then
	broken='    .windows, .haiku, .wasi, .tvos, .watchos => false,'
fi

grep -qxF "$broken" "$lib/std/process.zig" || exit 0

# One copy for each Zig (its version, where it is), made again when its
# links lead nowhere (that Zig moved), and made whole before it is used.
sum="$(printf '%s' "$lib" | cksum | cut -d ' ' -f 1)"
out="${XDG_CACHE_HOME:-$HOME/.cache}/nanoui/zig-lib-$version-$sum-ios"
if [ ! -e "$out/std/std.zig" ]; then
	tmp="$out.$$"
	rm -rf "$tmp"
	mkdir -p "$tmp/std"
	for f in "$lib"/*; do
		[ "$(basename "$f")" = std ] || ln -s "$f" "$tmp/"
	done
	for f in "$lib"/std/*; do
		[ "$(basename "$f")" = process.zig ] || ln -s "$f" "$tmp/std/"
	done
	awk -v broken="$broken" -v fixed="$fixed" '$0 == broken { print fixed; next } { print }' "$lib/std/process.zig" >"$tmp/std/process.zig"
	rm -rf "$out"
	mv "$tmp" "$out"
fi
echo "--zig-lib=$out"
