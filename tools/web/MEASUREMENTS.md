# Current integration verification

The integration branch starts at nanoui `e14261c` (0.14.6), matching the
updated app-native dependency. The old 0.11 experiment's performance results
are not represented as measurements of this revision.

Hardware testing uses an Apple M5 Max, macOS 27.0.1, Zig 0.17.0, Node 26.9.0
and Playwright 1.63.0's Chromium headless shell. Pixel parity runs at scales
1 and 2 in both BGRA and RGBA. Current additions cover the 192-byte instance
matrix and explicit display/surface-linear texture encoding, alongside the
original renderer scenarios. Nested opacity groups and scroll-edge masks
are covered together with overlapping content. The limits remain the
native CPU/OpenGL ones.

The current revision passes 76 hardware Chromium cases, 68 SwiftShader
cases and 68 WebKit cases. Each includes both scales and texture formats.
The nested-group scene differs from the CPU by at most one channel level.

App-native's headless browser test checks real editor startup, workspace
switching, adding a track through the timeline control, zero idle frames,
DPR/resize, device recovery preserving the document, and resource cleanup.
No native platform build sweep is included in this web-focused iteration.

Physical 120/240 Hz displays and guaranteed hardware-decoder selection have
not been tested. H.264/HEVC tests use WebCodecs `no-preference`; external HDR
conversion belongs to the browser. Playwright WebKit is not installed Safari.
Firefox's headless build exposed WebGPU but no adapter on this machine.
