# WebGPU: implemented subset

This is an offscreen, synchronous Metal implementation, not WebGPU conformance.
`navigator.gpu` is installed only on macOS when a Metal device and command queue
can actually be created. No windows or layers are created. Other platforms leave
it absent. Shader, pipeline, command and allocation failures are reported rather
than replaced by fabricated successful results.

## Implemented

- Adapter/device requests, features (empty), bounded limits, queue completion,
  explicit device destruction/lost promise, validation/out-of-memory/internal
  error scopes and uncaptured-error events.
- Zero-initialized buffers, writeBuffer, mapped-at-creation, mapAsync READ/WRITE,
  nonoverlapping mapped ranges, unmap detachment and destroy. Actual Metal blits
  implement buffer copies; actual Metal compute dispatches implement compute.
- Shader modules compile parsed WGSL into Metal source and a Metal library.
  Compilation information includes diagnostic messages. Entry names are mangled
  so WGSL `main` does not collide with Metal's reserved entry name.
- Automatic and explicit buffer bind-group/pipeline layouts, group 0, bindings
  0–7, whole-buffer scalar storage
  arrays; unsigned, signed and float 32-bit elements. Runtime array lengths are
  passed separately. Shader array accesses clamp to valid bounds. Writable
  binding aliases, invalid resources, mapped buffers and wrong usages fail.
- Whole-buffer uniform structs containing f32/i32/u32 scalar fields, with native
  usage/minimum-size validation and entry-specific binding reflection. Vertex and
  fragment buffers are bound independently; unused explicit-layout entries are
  accepted. Struct vertex outputs and fragment inputs preserve position and
  interpolated location varyings (including the rotating diagnostic triangle).
- Single-layer, single-mip, single-sample `bgra8unorm` render-attachment textures.
  Nonindexed, noninstanced triangle-list draws with vertex_index, no vertex
  buffers. One unblended color target, clear/load/store, whole-target viewport.
- `canvas.getContext('webgpu')`, configure/unconfigure, identity, resize-aware
  current texture, and lazy canvas-source readback. Bytes are BGRA, top row first;
  opaque canvases force alpha to 255; premultiplied mode expects shader output in
  premultiplied form, as WebGPU does.
- Command encoders/passes, single-use command buffers, pre-submission validation
  of the entire submission (including native reflected bindings).

## WGSL grammar and translation boundary

The tokenizer handles comments, identifiers, numeric literals and punctuation;
recursive-descent parsing builds an AST before Metal emission. Supported emitted
constructs include stage functions, IO structs, explicitly typed module constants,
local declarations, assignments, returns, if/else, scalar/vector constructors,
fixed local arrays, runtime storage arrays, arithmetic/comparison expressions,
arrayLength, selected scalar/vector math builtins, and fragment discard.

Loops, helper functions, overrides, aliases, pointers (except arrayLength's
storage-array address), atomics, textures/samplers, matrices, nested/vector/array
uniform fields, subrange/dynamic bindings, render storage bindings, and non-ASCII
identifiers are rejected with diagnostics. Only named fixed local and storage
arrays can be indexed. Shadowing array/buffer names is rejected. The parser's
accepted grammar is broader than the emitter: parsing never implies support.
Metal validates emitted types and stages; this is not a complete WGSL semantic
validator or a promise of full WGSL numerical conformance.

## Deliberate limits / outstanding work

Resources are retained until destroy/device destruction/page teardown, not JS GC.
The page permits 4096 total resource IDs and 256 MiB of live buffer/texture storage;
a buffer is nonempty and at most 64 MiB; uniform bindings are at most 64 KiB.
Textures are at most 4096². Compute has
at most 256 threads per workgroup and one million threads per dispatch. Shader
source is at most 64 KiB, 4096 tokens, and 64 levels of delimiter nesting.

Submission waits for Metal completion on the calling thread. Mapping returns a
copy; writable mapped ranges are uploaded on unmap. Canvas current textures are
retained until resize/reconfigure/destroy rather than expiring after each browser
frame. Color-space conversions, texture copies, depth/stencil, blending,
multisampling, indexed/indirect/instanced draws, vertex attributes, queries,
render bundles, external images, optional features and full WebIDL/conformance
validation are not implemented. Unsupported methods either fail validation or
are absent; they do not claim work was performed. Secure-context exposure rules
are not yet implemented by this bounded browser API.
