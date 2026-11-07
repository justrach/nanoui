#!/bin/sh
# Builds nanocua.app into a folder.
#
#   VERSION=0.1.0 sh apps/nanocua/macos/package.sh <aarch64-macos|x86_64-macos> <out-dir>
#
# Signs with $CODESIGN_IDENTITY (a "Developer ID Application" identity in the
# keychain) when it is set, else ad hoc. macOS keeps Accessibility and Screen
# Recording grants across updates only for the stable identity; an ad hoc build
# has to be granted again each time. Notarizing is the caller's: release builds
# notarize the app with the graff beside it (scripts/release-sign-macos.sh).
set -eu
target="$1"
out="$2"
cd "$(dirname "$0")/.."

app=nanocua
version="${VERSION:-0.1.0}"
version="${version#v}"
min_macos=13.0
case "$target" in
  aarch64-macos) cpu=apple_m1 ;;
  x86_64-macos) cpu=baseline ;;
  *) echo "unknown target: $target" >&2; exit 2 ;;
esac
prefix="zig-out/$target"
# Older than the machine building it, or it won't run on older Macs.
zig build -Doptimize=ReleaseFast "-Dtarget=$target.$min_macos" "-Dcpu=$cpu" --prefix "$prefix"
if ! vtool -show-build "$prefix/bin/$app" | grep -q "minos $min_macos\$"; then
  echo "$prefix/bin/$app is not built for macOS $min_macos" >&2
  exit 1
fi
bundle="$out/$app.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$prefix/bin/$app" "$bundle/Contents/MacOS/$app"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>$app</string>
  <key>CFBundleIdentifier</key><string>com.justrach.$app</string>
  <key>CFBundleExecutable</key><string>$app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>$min_macos</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
xattr -cr "$bundle"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --deep --strict "$bundle"
