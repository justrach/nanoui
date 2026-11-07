#!/bin/sh
# Checks an app bundle made with every option of `ios.app`, the fixture in
# tools/ios/fixture (`zig build test-bundle`): all of it landed, and it's signed.
set -eu
app="$1"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist"; }
fail() { echo "check-bundle: $1" >&2; exit 1; }

[ "$(cat "$app/resource.txt")" = "a resource" ] || fail "the resource is missing"
[ -f "$app/Assets.car" ] || [ -n "$(ls "$app"/AppIcon* 2>/dev/null)" ] || fail "no compiled catalog"
plist CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName | grep -qx AppIcon || fail "actool's icon entry wasn't merged"
plist CFBundleURLTypes:0:CFBundleURLSchemes:0 | grep -qx fixture || fail "the extra Info.plist keys are missing"
plutil -lint "$app/Info.plist" >/dev/null || fail "Info.plist doesn't parse"

codesign --verify --strict "$app" || fail "the app's signature doesn't verify"
for nested in "$app/PlugIns/Widgets.appex" "$app/Watch/Fixture Watch.app"; do
	[ -d "$nested" ] || fail "$nested is missing"
	codesign --verify --strict "$nested" || fail "$nested isn't signed"
done
codesign -d --entitlements - "$app" 2>/dev/null | grep -q aps-environment || fail "the entitlements weren't signed in"
echo "check-bundle: ok"
