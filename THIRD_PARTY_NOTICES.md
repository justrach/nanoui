# Third-party notices

nanoui's own source code is licensed under the MIT License in
[`LICENSE`](LICENSE). The material below keeps its own copyright and license.

## mygo

nanoui began as a port of the core of [mygo](https://github.com/egoist/mygo)
to Zig, Copyright (c) 2026 MyGo contributors. It keeps mygo's architecture:
the Objective-C runtime called directly, runtime classes for delegates, a
batched outbox with one evaluation per main-loop turn, events held until the
page is ready, a generated typed client, and native UI drawn by the framework.
mygo's MIT license, with its permission and warranty notice, is kept verbatim
in [`third_party/licenses/mygo-MIT.txt`](third_party/licenses/mygo-MIT.txt)
(as of mygo
[`269e2f9`](https://github.com/egoist/mygo/tree/269e2f9aca82b742f67497e467a95f6adb54bf5d)).

Liquid Glass (`src/ui/glass.zig`, `src/ui/glass.metal`, `src/ui/metal_glass.zig`)
is ported from mygo's glass plugin, as of
[`c7361ec`](https://github.com/egoist/mygo/tree/c7361ec842f475ebc0c1c6145912a823b46af220/plugins/glass).
That covers the material measured from AppKit, the lens, the normal, the tone
curve, and the backdrop, averaged and blurred. It's under the same license.

## GPUI

nanoui's native UI follows designs from
[GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui), part of
Zed, Copyright 2022–2025 Zed Industries, Inc.:
- elements styled by method chains (`src/ui/div.zig`);
- the virtualized `uniform_list` (`src/ui/list.zig`);
- layouts cached across frames, with glyphs rasterized once into an atlas;
- Gaussian shadows (`src/ui/shader.metal`, `src/ui/raster.zig`).

GPUI is licensed under the Apache License 2.0, whose text is kept verbatim in
[`third_party/licenses/GPUI-Apache-2.0.txt`](third_party/licenses/GPUI-Apache-2.0.txt).

## gpui-motion

`ui.motion` (`src/ui/motion/`) follows
[gpui-motion](https://github.com/1bye/gpui-motion), Copyright (c) 2026 1keep
contributors, as of
[`fd9baf9`](https://github.com/1bye/gpui-motion/tree/fd9baf910ba0e88b06967bfb322d6be4b2d39723). That covers its
model (targets set every frame, interruptible transitions, presence with
exits, keyframes, stagger, layout animation), the exact spring solution and
its visual timing, and the easing curves with their derivatives.
gpui-motion is dual licensed under MIT or Apache 2.0. nanoui takes it under
MIT, whose text is kept verbatim in
[`third_party/licenses/gpui-motion-MIT.txt`](third_party/licenses/gpui-motion-MIT.txt).

## GPUI Kit

`nanoui.kit` (`src/kit/`) follows the components of
[GPUI Kit](https://github.com/longbridge/gpui-component) (gpui-component),
Copyright 2024–2026 Longbridge, as of
[`6c13c1f`](https://github.com/longbridge/gpui-component/tree/6c13c1fcd73fa4b2b67e6c6ceaec3ab608e65501). It
takes their set and names, the button variants and sizes, the tab styles,
and the shape of dialogs, popovers, menus, notifications, alerts, tags,
avatars and form fields, rewritten for nanoui. GPUI Kit is licensed under
the Apache License 2.0, kept verbatim with its copyright line in
[`third_party/licenses/GPUI-Kit-Apache-2.0.txt`](third_party/licenses/GPUI-Kit-Apache-2.0.txt).

## http-zig

On Linux and Windows, `nanoui.http` uses
[http-zig](https://github.com/justrach/http-zig), Copyright (c) 2026 Rach
Pradhan, under the MIT License; its `src/tls_client.zig` is derived from Zig's
standard library TLS client (MIT, Zig contributors). It is a dependency
(`build.zig.zon`), fetched only for those targets, not copied here.

## Windows Terminal

Windows text alpha correction (`src/ui/text_blend.zig`) is adapted from
Microsoft's [Windows Terminal renderer](https://github.com/microsoft/terminal/tree/98c8c795ebc2560af55e72beba3fa5fd31ceef64), `src/renderer/atlas/dwrite_helpers.cpp`
and `dwrite_helpers.hlsl`, Copyright (c) Microsoft Corporation. Its gamma
ratios and foreground-dependent contrast/alpha correction reproduce
Direct2D text compositing. The MIT license is kept verbatim in
[`third_party/licenses/Windows-Terminal-MIT.txt`](third_party/licenses/Windows-Terminal-MIT.txt).

## Apps

[nanoterm](https://github.com/justrach/nanoterm) and
[nanomon](https://github.com/justrach/nanomon), under `apps/`, are separate
repositories with their own licenses and notices. Both use CodeGraff's
colors and run graff as a separate program; CodeGraff is distributed under
its modified AGPLv3 terms, as their notices say.

## Stageshow (.agents/skills/stageshow)

Agent skill by Benji Taylor, MIT. Source: https://github.com/benjitaylor/skills/tree/802057409787133703c56001080169e347305572/stageshow. App icons and brand assets inside keep their own licenses; see that folder's NOTICE.md and kit/brands/SOURCES.md.
