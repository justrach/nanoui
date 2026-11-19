# Cross-Compilation, Repository Checks, and Isolated Packaging

Build, verification, and release engineering practices from `nanoui` and Harness (`release.yml`, self-hosted runner isolation).

## 1. Single-Host Cross-Compilation Matrix

Every target compiles from macOS (or Linux) without C shims:

```sh
# Format & 600-line limit check
zig fmt src build.zig build.zig.zon examples tools
zig build lines

# Native macOS app & tests (Metal + CoreText + portable CPU)
zig build
zig build test
zig build test -Dportable=true

# Linux (GTK 3 / OpenGL / Xvfb test binary)
zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux

# Windows (Win32 / D3D11 / WebView2)
zig build -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
zig build -Dtarget=aarch64-windows-gnu --prefix zig-out/windows-arm64

# iOS Simulator & Device (requires Xcode SDK + tools/ios/zig-lib.sh)
zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator --prefix zig-out/ios-sim
zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios --prefix zig-out/ios

# Android APK & on-device test binary (requires Android SDK + NDK)
zig build -Dtarget=aarch64-linux-android
zig build test-bin -Dtarget=aarch64-linux-android --prefix zig-out/android-tests
zig build test-tools
```

Operational rules:
- Run heavy Zig builds **one at a time**; never combine `-fno-llvm` or `-fno-lld`.
- Add new app/skill directories to `roots` in `tools/lines.zig` so the 600-line gate protects them continuously.

## 2. Pre-Commit Snapshot Verification

Before committing or pushing, run `nanoui`'s hermetic snapshot verifier on an exported Git tree (`--staged` or `HEAD`):
```sh
sh tools/check-snapshot.sh --staged
```
This exports raw Git objects without working-tree artifacts, verifies `zig fmt --check`, and runs `zig run tools/lines.zig` under Zig 0.17.0.

## 3. Headless Bundle & Release Smoke Checks

When shipping signed/notarized `.app` bundles (as Harness does):
- Verify signatures & notarization cleanly (`codesign --verify --deep --strict`, `spctl -a -vvv -t exec App.app`).
- Verify the **actual packaged binary** headlessly without popping a window onto the screen by running `App.app/Contents/MacOS/app --nanoui-snapshot=/tmp/smoke.png` inside a temporary directory and inspecting the output PNG.
- Always check Info.plist `CFBundleShortVersionString` / `CFBundleVersion` and companion helper binaries inside `Contents/Resources/` or `Contents/MacOS/` after staging upgrades.

## 4. Isolating Local / Self-Hosted Builds from Developer State

If builds or release jobs execute on a developer Mac or self-hosted CI runner:
- **Sandbox environment variables per job:** Redirect `HOME`, `TMPDIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, and `ZIG_GLOBAL_CACHE_DIR` into the runner/worktree scratch directory so build steps or UI integration tests can never mutate `~/.config`, user Keychain defaults, user App Support DBs, or unrelated checkouts.
- **Use isolated git worktrees** (for example `.nanoui/wt-*`, gitignored) when building or fixing branches alongside active feature work so dirty local edits are never touched.
- **Avoid global process kills:** Never `pkill` app binaries or stop running developer tools broadly during build/install verification.
