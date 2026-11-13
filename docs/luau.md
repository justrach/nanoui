# Optional Luau native UI

`-Dluau=true` exposes a separate `nanoui_luau` module. The default NanoUI
module does not fetch Luau, compile C++, or link a VM. Opting in builds the
pinned Luau 0.746 compiler/VM directly, with Zig's C++ toolchain. There is no
C shim, Rust toolchain, interpreter executable, JIT, or external process.

This first optional module supports **macOS, Linux and Windows**. Mobile
NanoUI core builds stay unchanged with Luau off. Opting in on iOS/Android
fails explicitly: the iOS C++ runtime link is not ready, and Android's NDK
integration is not verified. This is not a mobile plugin runtime.

```zig
const dep = b.dependency("nanoui", .{
    .target = target, .optimize = optimize, .luau = true,
});
exe.root_module.addImport("nanoui", dep.module("nanoui"));
exe.root_module.addImport("nanoui_luau", dep.module("nanoui_luau"));
```

Create a `Runtime` once from text and destroy it with its owner. Use a
frame/arena allocator for `render`; the returned tree owns its strings in
that allocator. Then `draw(context, tree)` under a host-owned box, with a
unique host key for each instance. No VM work is needed while native springs
settle: cache the tree until the host inputs change. A hidden host should
not render or draw its tree. NanoUI's existing motion store handles frame
requests, retargeting, settling, and `Context.reduced_motion`.

```lua
return function(c)
    return ui.layer {
        id = "scene", width = c.width, height = c.height,
        children = {
            ui.rect {
                id = "card", x = 20, y = 20, width = 180, height = 90,
                color = if c.dark then 0x465878 else 0xadc5df, radius = 18,
                motion = ui.spring { x = (c.pointer_x - .5) * 20, y = 0 },
            },
        },
    }
end
```

## Small, inert API

Source returns one render function. It receives a frozen table containing
`width`, `height` (points), normalized `pointer_x`/`pointer_y`, `dark`, and
`reduced_motion`. Only the host supplies inputs; scripts do not see the
window, pointer events, application state, chats, files, or credentials.

- `ui.column`, `ui.row`: flow containers; `ui.layer`: absolute container.
- `ui.rect`: absolute colored rounded rectangle; `ui.text`: native text.
- Common properties: unique `id`, `x`, `y`, `width`, `height`, `gap`,
  `radius`, `opacity`, `color` (integer RGB), `size`, `text`, `children`.
- `motion = ui.spring { x, y, stiffness = 140, damping = 20 }` or
  `ui.tween { x, y, duration = .18 }`: native offset targets in points.
  Motion offsets are limited to +/-128. They do not run Lua animation loops.

Unknown properties, duplicate/empty ids, sparse children, non-finite or
out-of-range numbers, excessive trees, and malformed UTF-8 are errors.
Parsing uses raw table access, never a script's metamethods. The bridge has
no buttons, callbacks, image loading, arbitrary shaders, UI selectors, plugin
installation, or host capabilities. Applications must build their own
extension/consent policy separately; this module is not a plugin manager.

## Limits and failure

Each VM is independent: 64 KiB source, 16 MiB VM allocations, 20 ms cooperative
setup/render deadlines, 128 nodes, depth 16, and 8 KiB combined tree strings.
Globals/libraries and input are frozen. No module/code loading, I/O, network,
processes, ambient clocks, environment access, output, or GC control is
exposed. There is no shared VM state between runtimes.

Luau interrupts run at VM safepoints. Compilation and native library calls
receive post-call deadline checks, **not hard real-time preemption**. Compiler
allocations are outside the VM's memory cap. Do not advertise this as process
isolation or run untrusted compilation on the UI thread. This first module
is intended for bounded bundled scripts; compile external source on a worker
or isolate it in a process if a hard resource boundary is required.

A failed render permanently retires its runtime. The host can display a
fallback and explicitly recreate it; do not auto-retry broken scripts every
frame. The host must keep the arena alive until drawing finishes. A runtime
is single-owner and non-reentrant; concurrent calls are not supported.

## Checks

```sh
zig build test-luau -Dluau=true -Doptimize=ReleaseSafe -j2
zig build check-luau -Dluau=true -Dtarget=aarch64-linux-gnu -Dportable=true
zig build test                    # core still works without Luau
zig build lines
```

Tests execute the real VM, validate its limits and capability boundary, and
exercise native interruptible springs, quiescence and Reduce Motion with
`ui.Tester`. No test opens a window or touches application/user state.
