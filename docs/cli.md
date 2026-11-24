# `nui` CLI

`nui` is the command-line tool for creating, building, testing, and
verifying nanoui apps — designed for both people and coding agents.
Every command accepts `--json` for machine-readable output and never opens
a GUI window unless you run `nui run` (or `nui dev`).

## Install

Requirements: **Zig 0.17.0** (plus the macOS SDK / Xcode on macOS, GTK 4 or
GTK 3 at run time on Linux).

From a nanoui checkout:

```sh
sh tools/install-nui.sh --from-source
# installs ReleaseSafe `nui` into ~/.local/bin (override with --dir PATH)
```

On Windows PowerShell:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tools/install-nui.ps1 -FromSource
# installs ReleaseSafe `nui.exe` into %LOCALAPPDATA%\nanoui\bin (override with -Dir PATH)
```

Or from a GitHub release (once published on a tag):

```sh
sh tools/install-nui.sh                 # macOS / Linux
pwsh -File tools/install-nui.ps1        # Windows
```

Or build directly into `zig-out/bin/nui`:

```sh
zig build nui -Doptimize=ReleaseSafe
```

Check your environment anytime:

```sh
nui doctor
nui doctor --target ios-sim
nui doctor --target android
```

## Create a project

```sh
nui start my-app                       # native counter starter (default)
nui start my-app --template kit        # nanoui.kit components + toasts + tabs
nui start my-app --template page       # system webview + typed Zig <-> JS IPC
```

Options:

- `--local PATH` — link a local nanoui checkout instead of fetching from GitHub
- `--nanoui REF` — pin a specific nanoui tag or commit (default: matching `nui` version)
- `--id BUNDLE_ID` — bundle/application id for iOS and Android (default: `dev.nanoui.<name>`)
- `--dir PATH` — target directory (default: `NAME`)
- `--no-build` — scaffold files without running the initial `zig build`

Generated apps include a cross-platform `build.zig` supporting desktop, iOS,
Android, and WebGPU (`wasm32-wasi`), plus offscreen `ui.Tester` specs and an
`AGENTS.md` with safe headless workflows.

## Build, check, and iterate

All project commands automatically find the nearest ancestor `build.zig.zon`
(or `build.zig`), so they work from `src/` or any subdirectory:

```sh
nui build                              # native debug build
nui build --release                    # ReleaseFast
nui build --small                      # ReleaseSmall
nui build --portable                   # portable TrueType text + CPU renderer
nui build --target linux               # x86_64-linux-gnu
nui build --target windows             # x86_64-windows-gnu
nui build --target ios-sim             # aarch64-ios-simulator (resolves zig-lib.sh)
nui build --target android             # aarch64-linux-android APK
nui build --target web                 # wasm32-wasi WebGPU bundle in zig-out/web/
```

Target aliases:

| Alias | Zig target |
|---|---|
| `macos` / `macos-arm64` | `aarch64-macos` |
| `macos-x64` | `x86_64-macos` |
| `linux` / `linux-x64` | `x86_64-linux-gnu` |
| `linux-arm64` | `aarch64-linux-gnu` |
| `windows` / `windows-x64` | `x86_64-windows-gnu` |
| `windows-arm64` | `aarch64-windows-gnu` |
| `ios-sim` / `ios-simulator` | `aarch64-ios-simulator` |
| `ios` | `aarch64-ios` |
| `android` / `android-arm64` | `aarch64-linux-android` |
| `android-x64` | `x86_64-linux-android` |
| `web` / `wasm` | `wasm32-wasi` |

Any full Zig triple containing `-` (for example `aarch64-macos.14.0`) is also
passed through directly.

Verification and watch loops:

```sh
nui test                               # run ui.Tester specs offscreen
nui test --portable                    # run with nanoui's CPU renderer
nui test --all                         # run both native and portable CPU suites
nui test --filter "Reset"              # filter tests by name
nui check --lines                      # zig fmt --check + <=600 lines/file + build + test
nui dev --test                         # watch and re-run tests headlessly on save
nui dev                                # watch and relaunch the app window (interactive)
nui run -- --nanoui-dark               # pass flags after `--` to the app
nui info                               # show project name, root, and nanoui source
```

## Headless snapshots and webview bindings

Render the first native UI window offscreen to a PNG without opening a window:

```sh
nui snapshot --out shots/light.png
nui snapshot --out shots/dark.png --dark --script "click:Increment;click:Increment"
nui snapshot --out shots/cpu.png --portable --wait 0.5
```

For webview (`--template page`) apps:

```sh
nui gen                                # emits src/frontend/nanoui.{js,d.ts} (or frontend/)
nui snapshot --eval 'import("/nanoui.js").then(async m => { nanoui.log(await m.Greeter.greet("Ada")); nanoui.window.close(); })'
```

## Machine-readable output (`--json`)

Place `--json` anywhere before `--`. Compiler diagnostics on failure are
captured into the JSON object's `"detail"` field so stdout stays valid JSON:

```sh
nui check --lines --json
nui snapshot --out shot.png --script "click:Increment" --json
```
