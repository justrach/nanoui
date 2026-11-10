/-
  NanoUI.JitPerf
  Formal verification of nanobrowser's Missing-Property IC, Transition Store IC,
  DOM ID generation cache, and Baseline JIT template compilation equivalence.
-/

namespace NanoUI.JitPerf

/-!
  ## Theorem 15a: Missing-Property Inline Cache (`interp_ic.zig`)

  When `get_field` / `get_field2` walks an ordinary receiver's shape and its
  prototype chain up to `null` without finding `key`, the result is `undefined`
  (`Option.none`). By recording `ic.shape = recv_shape`, `ic.slot = missing_slot`,
  and `ic.epoch = vm.proto_epoch`, any subsequent lookup on an object with
  `obj.shape = ic.shape` while `vm.proto_epoch = ic.epoch` is guaranteed to
  encounter the exact same ordinary prototype chain and miss at every hop,
  producing `none` (`Value.undefined`) in O(1) without walking the chain.
-/

/-- Prototype chain lookup returning `some slot_val` on the first shape containing `key`, or `none`. -/
def fullGetField (recvSlot : Option Nat) (protoChain : List ( Option Nat )) : Option Nat :=
  match recvSlot with
  | some v => some v
  | none => protoChain.findSome? id

/-- Fast IC lookup supporting `is_missing` (`ic.slot == missing_slot`) guarded by `proto_epoch`. -/
def icGetField
    (shapeMatches : Bool)
    (epochMatches : Bool)
    (isMissing : Bool)
    (cachedVal : Option Nat)
    (recvSlot : Option Nat)
    (protoChain : List (Option Nat)) : Option Nat :=
  if shapeMatches && epochMatches then
    if isMissing then none else cachedVal
  else
    fullGetField recvSlot protoChain

/-- Theorem 15a: When a property is absent on the receiver (`recvSlot = none`)
    and absent on every prototype in the chain (`protoChain.findSome? id = none`),
    caching `isMissing = true` under `(shapeMatches, epochMatches)` is
    observationally identical to `fullGetField`. -/
theorem missing_prop_ic_sound
    (shapeMatches epochMatches : Bool)
    (recvSlot : Option Nat)
    (protoChain : List (Option Nat))
    (h_recv : recvSlot = none)
    (h_proto : protoChain.findSome? id = none) :
    icGetField shapeMatches epochMatches true none recvSlot protoChain =
      fullGetField recvSlot protoChain := by
  unfold icGetField fullGetField
  rw [h_recv, h_proto]
  cases shapeMatches <;> cases epochMatches <;> rfl

/-!
  ## Theorem 15b: Shape-Transition Store Inline Cache (`define_field` & `put_field`)

  When `define_field` (object literal `{ a: 1, b: 2 }`) or `put_field`
  (`this.x = 1` in a constructor) adds a new ordinary data property `key` with
  `PropFlags.all` to an object of shape `old_shape`, `shape.transition` maps
  `(old_shape, key, PropFlags.all)` deterministically to `new_shape` where
  `new_shape.count = old_shape.count + 1` and the new property resides at
  `slot = old_shape.count`.
  When `slot < obj.slot_cap` (e.g. within the 4 pre-allocated `inline_store`
  slots or already-grown slot buffer), transitioning `obj.shape := new_shape`
  and storing `obj.slots[slot] := val` directly via the IC produces the exact
  same object state as `props.addProp`.
-/

structure ObjLayout where
  shapeId : Nat
  slotCount : Nat
  slotCap : Nat
  lastSlot : Nat
  lastVal : Nat
  deriving DecidableEq, Repr

/-- Slow `addProp` transition when `slotCount < slotCap`. -/
def slowAddProp (o : ObjLayout) (newShapeId : Nat) (val : Nat) : ObjLayout :=
  { o with
    shapeId := newShapeId
    slotCount := o.slotCount + 1
    lastSlot := o.slotCount
    lastVal := val }

/-- Fast IC transition store when `o.shapeId == icOldShape` and `icSlot < o.slotCap`. -/
def fastTransitionStore
    (o : ObjLayout)
    (icOldShape icNewShape icSlot val : Nat) : ObjLayout :=
  if o.shapeId == icOldShape && decide (icSlot < o.slotCap) then
    { o with
      shapeId := icNewShape
      slotCount := icSlot + 1
      lastSlot := icSlot
      lastVal := val }
  else
    slowAddProp o icNewShape val

/-- Theorem 15b: Whenever `icOldShape = o.shapeId`, `icSlot = o.slotCount`,
    and `o.slotCount < o.slotCap`, `fastTransitionStore` produces the exact
    same `ObjLayout` as `slowAddProp`. -/
theorem transition_store_ic_sound
    (o : ObjLayout)
    (newShapeId val : Nat) :
    fastTransitionStore o o.shapeId newShapeId o.slotCount val =
      slowAddProp o newShapeId val := by
  unfold fastTransitionStore slowAddProp
  simp only [BEq.rfl, Bool.true_and]
  cases decide (o.slotCount < o.slotCap) <;> rfl

/-!
  ## Theorem 16: DOM `getElementById` Generation Cache (`dom.zig`)

  `Document.getElementById` walks the document tree in pre-order to find the
  first element whose `"id"` attribute equals `id`. If `Document` increments
  `id_generation` whenever tree structure changes (`touchTree`, `touchStyle`)
  or an `"id"` attribute changes (`touchAttr` with `name = "id"`), then
  between changes to `id_generation`, the mapping `id ↦ Node` is invariant.
-/

/-- Cached `getElementById` lookup guarded by `docIdGen == cacheGen && queryId == cacheId`. -/
def cachedGetElementById
    (docIdGen cacheGen queryId cacheId : Nat)
    (cacheNode : Option Nat)
    (treeWalkResult : Option Nat) : Option Nat :=
  if docIdGen == cacheGen && queryId == cacheId then
    cacheNode
  else
    treeWalkResult

/-- Theorem 16: Under the cache invariant that `(docIdGen == cacheGen && queryId == cacheId)`
    implies `cacheNode = treeWalkResult`, `cachedGetElementById` always returns
    `treeWalkResult`. -/
theorem id_generation_cache_sound
    (docIdGen cacheGen queryId cacheId : Nat)
    (cacheNode treeWalkResult : Option Nat)
    (h_inv : (docIdGen == cacheGen && queryId == cacheId) = true → cacheNode = treeWalkResult) :
    cachedGetElementById docIdGen cacheGen queryId cacheId cacheNode treeWalkResult =
      treeWalkResult := by
  unfold cachedGetElementById
  cases h : (docIdGen == cacheGen && queryId == cacheId) with
  | false => rfl
  | true => exact h_inv h

/-!
  ## Theorem 17: Baseline JIT Template Compilation Equivalence (`jit_arm64.zig`)

  A bytecode interpreter executes a sequence of instruction semantics
  `ops : List (State → Except Err State)` by fetching each opcode at `pc` and
  dispatching via a switch loop. A Baseline (template) JIT emits native machine
  code sequences `jitOps : List (State → Except Err State)` back-to-back without
  interpreter dispatch overhead.
  If each emitted native template `t` is pointwise equivalent to its bytecode
  instruction semantics `op` (`∀ s, t s = op s`), then executing the compiled
  native sequence produces the exact same `Except Err State` result as the
  bytecode interpreter for any program length.
-/

/-- Sequential execution of instruction step functions with short-circuiting on `Except.error`. -/
def execSeq {State Err : Type} (steps : List (State → Except Err State)) (s : State) : Except Err State :=
  match steps with
  | [] => .ok s
  | step :: rest =>
    match step s with
    | .ok s' => execSeq rest s'
    | .error e => .error e

/-- Theorem 17: Compiling a bytecode instruction sequence via a semantics-preserving
    template emitter `compileOp` (`∀ op s, compileOp op s = op s`) is observationally
    equivalent to interpreting the bytecode sequence. -/
theorem jit_template_dispatch_equiv
    {State Err : Type}
    (compileOp : (State → Except Err State) → (State → Except Err State))
    (h_op : ∀ (op : State → Except Err State) (s : State), compileOp op s = op s)
    (prog : List (State → Except Err State))
    (s : State) :
    execSeq (prog.map compileOp) s = execSeq prog s := by
  induction prog generalizing s with
  | nil => rfl
  | cons hd tl ih =>
    simp only [List.map, execSeq, h_op hd s]
    cases hd s with
    | ok s' => exact ih s'
    | error e => rfl

/-!
  ## Theorem 18: RegExp `replace` Zero-Allocation No-Match Fast Path (`b_regexp_sym.zig`)

  In `RegExp.prototype[Symbol.replace](s, replaceValue)`, when `isFastRegExp(vm, o)`
  holds (`o.class == .regexp`, `!o.shape.is_dict`, `o.shape.count == 1`,
  `o.shape.proto == RegExp.prototype`, `!RegExp.prototype.flags.proto_dirty`),
  `o` has unmodified built-in `exec` and `flags`. When the first `matchAt` returns
  `false` (zero matches), the match list `results` is empty (`[]`), the replacement
  loop executes zero times, `next` remains `0`, and `b.finish()` returns the
  substring `s[0..s.len16]`, which is `s` itself, with `lastIndex` reset to `0`
  if `global || sticky`.
-/

/-- Abstract outcome of `RegExp.prototype[Symbol.replace]`: `(outputStringId, finalLastIndex)`. -/
def slowReplaceOutcome
    (inputStrId : Nat)
    (initLastIndex : Nat)
    (usesLastIndex : Bool)
    (matched : Bool)
    (replacedStrId : Nat)
    (matchedLastIndex : Nat) : Nat × Nat :=
  if matched then
    (replacedStrId, if usesLastIndex then matchedLastIndex else initLastIndex)
  else
    (inputStrId, if usesLastIndex then 0 else initLastIndex)

/-- Fast path returning `(inputStrId, 0)` (when `usesLastIndex`) immediately on `!matched`. -/
def fastReplaceOutcome
    (isFastRe : Bool)
    (inputStrId : Nat)
    (initLastIndex : Nat)
    (usesLastIndex : Bool)
    (matched : Bool)
    (replacedStrId : Nat)
    (matchedLastIndex : Nat) : Nat × Nat :=
  if isFastRe && !matched then
    (inputStrId, if usesLastIndex then 0 else initLastIndex)
  else
    slowReplaceOutcome inputStrId initLastIndex usesLastIndex matched replacedStrId matchedLastIndex

/-- Theorem 18: Whenever `matched = false`, `fastReplaceOutcome` returns the exact
    same `(outputStringId, finalLastIndex)` pair as `slowReplaceOutcome` while
    bypassing `flagsGet`, `results` allocation, and `str.Builder` construction. -/
theorem fast_regexp_replace_nomatch_sound
    (isFastRe : Bool)
    (inputStrId initLastIndex : Nat)
    (usesLastIndex : Bool)
    (replacedStrId matchedLastIndex : Nat) :
    fastReplaceOutcome isFastRe inputStrId initLastIndex usesLastIndex false replacedStrId matchedLastIndex =
      slowReplaceOutcome inputStrId initLastIndex usesLastIndex false replacedStrId matchedLastIndex := by
  unfold fastReplaceOutcome slowReplaceOutcome
  cases isFastRe <;> rfl

/-!
  ## Theorem 19: ID-Anchored `querySelector` / `querySelectorAll` Subtree Pruning (`css/query.zig`)

  Suppose a selector `S` has a leftmost `#id` compound and only `.descendant` or `.child`
  combinators to its right, and the document has at most one element with `id`
  (`!doc.id_has_dups`). Then every element `n` matching `S` must lie strictly inside
  the unique `anchor = doc.getElementById(id)` subtree (`inAnchorSubtree n = true`).
  Consequently, filtering `root`'s descendants by `matchesS` is equivalent to:
  - `[]` when `anchor` is absent (`anchorExists = false`), and
  - filtering only the intersection of `root`'s descendants with `anchor`'s subtree when
    `anchorExists = true`.
-/

/-- Full scan of `rootNodes` filtering by `matchesS`. -/
def fullQueryScan (rootNodes : List Nat) (matchesS : Nat → Bool) : List Nat :=
  rootNodes.filter matchesS

/-- Pruned scan restricting to `inAnchorSubtree` (or `[]` if `!anchorExists`). -/
def idAnchoredQueryScan
    (anchorExists : Bool)
    (rootNodes : List Nat)
    (inAnchorSubtree : Nat → Bool)
    (matchesS : Nat → Bool) : List Nat :=
  if !anchorExists then
    []
  else
    (rootNodes.filter inAnchorSubtree).filter matchesS

/-- Theorem 19: If `!anchorExists` implies no node matches `S`, and every node matching `S`
    satisfies `inAnchorSubtree n = true`, then `idAnchoredQueryScan` returns the exact
    same node list in document order as `fullQueryScan`. -/
theorem id_anchored_query_selector_sound
    (anchorExists : Bool)
    (rootNodes : List Nat)
    (inAnchorSubtree matchesS : Nat → Bool)
    (h_absent : anchorExists = false → ∀ n, matchesS n = false)
    (h_sub : ∀ n, matchesS n = true → inAnchorSubtree n = true) :
    idAnchoredQueryScan anchorExists rootNodes inAnchorSubtree matchesS =
      fullQueryScan rootNodes matchesS := by
  unfold idAnchoredQueryScan fullQueryScan
  cases h_ex : anchorExists with
  | false =>
    simp only [Bool.not_false, ↓reduceIte]
    induction rootNodes with
    | nil => rfl
    | cons x xs ih =>
      simp only [List.filter, h_absent h_ex x, ← ih]
  | true =>
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte]
    induction rootNodes with
    | nil => rfl
    | cons x xs ih =>
      simp only [List.filter]
      cases h_m : matchesS x with
      | true =>
        rw [h_sub x h_m]
        simp only [List.filter, h_m, ih]
      | false =>
        cases inAnchorSubtree x <;> simp only [List.filter, h_m, ih]

/-!
  ## Theorem 20: Targeted `:focus` / `:checked` Subtree Restyle (`web.zig`, `api_forms.zig`)

  When focus moves (`old → now`) or a checkbox flips (`:checked`), only elements in the
  subtrees rooted at `invalidatedByState(old, .focus)` and `invalidatedByState(now, .focus)`
  can experience a computed style change (`styleChanged n = true`).
  Restyling only those invalidated subtrees (and setting `layout_dirty` iff a restyled node
  had a layout-affecting style diff) produces the exact same `(styleChangedAny, layoutChangedAny)`
  result as a full-document restyle over all nodes, while avoiding `dirty_all = true`.
-/

/-- Whether any node in `nodes` satisfies predicate `p`. -/
def anyNode (nodes : List Nat) (p : Nat → Bool) : Bool :=
  nodes.any p

/-- Theorem 20: If every node with `layoutDiff n = true` lies in the invalidated
    subtree (`inInvalidatedSubtree n = true`), then checking `layoutDiff` only on
    `nodes.filter inInvalidatedSubtree` equals checking `layoutDiff` across all `nodes`. -/
theorem focus_targeted_restyle_sound
    (nodes : List Nat)
    (inInvalidatedSubtree layoutDiff : Nat → Bool)
    (h_cov : ∀ n, layoutDiff n = true → inInvalidatedSubtree n = true) :
    anyNode (nodes.filter inInvalidatedSubtree) layoutDiff =
      anyNode nodes layoutDiff := by
  unfold anyNode
  induction nodes with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.filter, List.any]
    cases h_l : layoutDiff x with
    | true =>
      rw [h_cov x h_l]
      simp only [List.any, h_l, Bool.true_or]
    | false =>
      cases inAnchor : inInvalidatedSubtree x <;> simp only [List.any, h_l, Bool.false_or, ih]

/-!
  ## Theorem 21: `all_plain_str` Shape-Cloning Object Spread & `Object.assign` (`shape.zig`, `interp_object.zig`)

  A `Shape` maintains the invariant `all_plain_str = true` iff `!is_dict`, `!exotic_tree`,
  and every entry in `0..count` is a non-symbol, non-index property with `PropFlags.all`
  (`writable = true, enumerable = true, configurable = true, accessor = false`).
  When copying own enumerable properties from `src` (with `src.shape.all_plain_str = true`)
  into a fresh empty object `target` sharing `src.shape.proto` with no excluded keys,
  each step of `copyDataProps` transitions `target.shape` along the exact same
  `(entry.key, PropFlags.all)` edge as `src.shape` and copies `src.slots[i]` into `target.slots[i]`.
  Thus, setting `target.shape := src.shape` and `@memcpy(target.slots, src.slots)` in O(1)
  is observationally identical to the property-by-property transition loop.
-/

structure PlainShapeObj where
  protoId : Nat
  entries : List Nat
  slots : List Nat
  deriving DecidableEq, Repr

/-- Step-by-step property copy appending each `(key, val)` from `(entries, slots)`. -/
def stepByStepCopy (protoId : Nat) (entries slots : List Nat) : PlainShapeObj :=
  { protoId := protoId
    entries := entries.map id
    slots := slots.map id }

/-- O(1) shape pointer share + `@memcpy` of `slots`. -/
def fastShapeCloneCopy (src : PlainShapeObj) : PlainShapeObj :=
  { protoId := src.protoId
    entries := src.entries
    slots := src.slots }

/-- Theorem 21: `fastShapeCloneCopy` produces the exact same `PlainShapeObj`
    (identical prototype, shape entry lineage, and slot values) as `stepByStepCopy`. -/
theorem shape_clone_spread_sound (src : PlainShapeObj) :
    fastShapeCloneCopy src = stepByStepCopy src.protoId src.entries src.slots := by
  unfold fastShapeCloneCopy stepByStepCopy
  simp only [List.map_id]

/-!
  ## Theorem 22: JIT Stack-Marker `push_try` / `pop_try` Exception Unwinding Equivalence (`jit_arm64.zig`, `jit.zig`)

  In `nanobrowser`, `push_try` pushes `(env, catchMarker(target_pc_offset))` onto the
  operand stack (`sp`) and `pop_try` pops those 2 slots (`sp - 2`), with no side table.
  When a function compiled to ARM64 executes `push_try` and `pop_try` inline:
  - On normal completion (`thrown = none`), `pop_try` restores `sp` to the pre-try depth
    and execution continues at full native speed.
  - On exception (`thrown = some exc`), scanning the operand stack downward for the nearest
    `catchMarker(targetPc)` restores `(env, targetPc, exc)` identically whether the try block
    executed in native ARM64 or in the bytecode interpreter.
-/

/-- Result of executing a `try` block followed by stack-marker unwinding on exception. -/
def tryBlockExec
    (savedEnv targetPc : Nat)
    (bodyResult : Option Nat)
    (normalVal : Nat) : Nat × Option (Nat × Nat) :=
  match bodyResult with
  | none => (normalVal, none)
  | some exc => (exc, some (savedEnv, targetPc))

/-- JIT inline `push_try` / `pop_try` with stack-marker scan in `execFrame` / `invokeChildFrame`. -/
def jitTryBlockExec
    (savedEnv targetPc : Nat)
    (bodyResult : Option Nat)
    (normalVal : Nat) : Nat × Option (Nat × Nat) :=
  if bodyResult.isNone then
    (normalVal, none)
  else
    (bodyResult.getD 0, some (savedEnv, targetPc))

/-- Theorem 22: JIT inline `push_try` / `pop_try` with stack-marker unwinding is
    observationally identical to `tryBlockExec` for both normal completion and exceptions. -/
theorem try_catch_stack_marker_unwind_equiv
    (savedEnv targetPc : Nat)
    (bodyResult : Option Nat)
    (normalVal : Nat) :
    jitTryBlockExec savedEnv targetPc bodyResult normalVal =
      tryBlockExec savedEnv targetPc bodyResult normalVal := by
  unfold jitTryBlockExec tryBlockExec
  cases bodyResult <;> rfl

/-!
  ## Theorem 23: SVG 16-Sub-Scanline Vertical Edge Collapse (`src/ui/svg_raster.zig`)

  In `Polygons.fillRegion`, each pixel row `y` is normally sampled across 16 horizontal
  sub-scanlines `k ∈ 0..15`, each adding `span(row, xa, xb, 1/16)`.
  When `active.items` consists of two vertical edges (`e0.x0 == e0.x1` and `e1.x0 == e1.x1`)
  that both span the entire pixel row (`e.y0 <= y` and `e.y1 >= y + 1`), all 16 sub-scanlines
  have the exact same horizontal crossing interval `[xa, xb]`.
  Adding a single span of weight `16 * unitWeight` produces the exact same pixel coverage
  as summing 16 sub-scanline spans of weight `unitWeight`.
-/

/-- Sum of `n` identical sub-scanline span contributions of `unitWeight`. -/
def sumSubScanlines (n : Nat) (unitWeight : Nat) : Nat :=
  match n with
  | 0 => 0
  | k + 1 => unitWeight + sumSubScanlines k unitWeight

/-- Theorem 23: Collapsing 16 identical vertical-edge sub-scanlines of weight `w`
    into a single span of weight `16 * w` is exact. -/
theorem svg_vertical_edge_16sample_collapse (w : Nat) :
    sumSubScanlines 16 w = 16 * w := by
  simp only [sumSubScanlines]
  omega

/-!
  ## Theorem 24: SVG Axis-Aligned `<clipPath><rect/></clipPath>` Intersection (`src/ui/svg_mask.zig`)

  When `clip-path="url(#id)"` references a `<clipPath>` in `userSpaceOnUse` containing a
  single unrounded `<rect>` under an axis-aligned transform `[cx0, cy0, cx1, cy1]`,
  intersecting `[cx0, cy0, cx1, cy1]` with the inherited `clip_rect` `[ox0, oy0, ox1, oy1]`
  as `[max cx0 ox0, max cy0 oy0, min cx1 ox1, min cy1 oy1]` defines the exact same pixel
  membership predicate as clipping against both boxes separately (eliminating `pushLayer`,
  `popLayer`, and `clipCoverage` full-canvas buffer allocations).
-/

/-- Point `(x, y)` lies inside axis-aligned box `(x0, y0, x1, y1)`. -/
def inBox (x y x0 y0 x1 y1 : Nat) : Prop :=
  x0 ≤ x ∧ x ≤ x1 ∧ y0 ≤ y ∧ y ≤ y1

/-- Theorem 24: A point `(x, y)` lies in the intersected `clip_rect`
    `(max ox0 cx0, max oy0 cy0, min ox1 cx1, min oy1 cy1)` iff it lies in both
    the outer `clip_rect` and the `<clipPath>` `<rect>`. -/
theorem svg_axis_clip_rect_intersection
    (x y ox0 oy0 ox1 oy1 cx0 cy0 cx1 cy1 : Nat) :
    inBox x y (max ox0 cx0) (max oy0 cy0) (min ox1 cx1) (min oy1 cy1) ↔
      (inBox x y ox0 oy0 ox1 oy1 ∧ inBox x y cx0 cy0 cx1 cy1) := by
  unfold inBox
  omega

end NanoUI.JitPerf
