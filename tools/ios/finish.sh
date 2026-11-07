#!/bin/sh
# The last of an app bundle, from build.zig (`ios.app`): a copy of the folder
# with its compiled asset catalog merged in, signed from the inside out.
#
#   finish.sh IN OUT IDENTITY PROFILE ENTITLEMENTS [COMPILED PARTIAL_PLIST]
#
# IDENTITY "-" signs ad hoc, for the Simulator. PROFILE and ENTITLEMENTS may be
# empty. An extension or Watch app that already has a good signature keeps it:
# Xcode gave it its own profile and entitlements, and signing it again here
# would lose them.
set -eu
in="$1"
out="$2"
identity="$3"
profile="$4"
entitlements="$5"
compiled="${6:-}"
partial="${7:-}"

rm -rf "$out"
cp -R "$in" "$out"
chmod -R u+w "$out"
chmod +x "$out/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$out/Info.plist")"

if [ -n "$compiled" ]; then
	cp -R "$compiled"/. "$out"/
	# The icon's entries (CFBundleIcons), which only actool can name.
	/usr/libexec/PlistBuddy -c "Merge $partial" "$out/Info.plist" >/dev/null
fi
[ -z "$profile" ] || cp "$profile" "$out/embedded.mobileprovision"

for nested in "$out"/PlugIns/*.appex "$out"/Watch/*.app; do
	[ -d "$nested" ] || continue
	chmod +x "$nested/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$nested/Info.plist")"
	codesign --verify --strict "$nested" 2>/dev/null && continue
	codesign --force --sign "$identity" --timestamp=none --preserve-metadata=entitlements "$nested" 2>/dev/null
done

if [ -n "$entitlements" ]; then
	codesign --force --sign "$identity" --timestamp=none --entitlements "$entitlements" "$out" 2>/dev/null
else
	codesign --force --sign "$identity" --timestamp=none "$out" 2>/dev/null
fi
codesign --verify --strict "$out"
