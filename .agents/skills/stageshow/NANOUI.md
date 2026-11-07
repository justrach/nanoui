# Using Stageshow in nanoui

Vendored from https://github.com/benjitaylor/skills/tree/802057409787133703c56001080169e347305572/stageshow (MIT, by Benji Taylor; see LICENSE and NOTICE.md here, unmodified).

How to apply it to nanoui:
- Render stills and animations from real nanoui views on the iOS simulator / Metal, not from HTML mockups. Use Stageshow's framing, cropping, and motion rules on top of those captures.
- Cover iPhone Duo postures (folded, unfolded, half-open). Nothing crosses the hinge.
- Solid cards with shadows; glass only on floating elements.
- One item per screenshot.
- Duo layout guidance: see the duo-foldable branch (src/ios/fold.zig, examples/duo).
