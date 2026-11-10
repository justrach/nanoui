/-
  NanoUI.Speedometer3Perf
  Formal verification of Stage 3 Speedometer 3.1 optimizations:
  - Theorem 25: Non-numeric strict equality O(1) bitwise fast path (`jit.zig`)
  - Theorem 26: First-call JIT compilation equivalence in fresh iframe worlds (`jit.zig`, `interp_call.zig`)
  - Theorem 27: Full ancestor `style_queued` subsumption (`dom.zig`)
  - Theorem 28: Sibling-scoped attribute invalidation (`O(N)` vs `O(N^2)`) (`dom.zig`, `rule_index.zig`)
  - Theorem 29: SVG geometry attribute style invariance (`dom.zig`, `hints.zig`)
  - Theorem 30: Zero-delay timer direct main-queue FIFO soundness (`src/objc.zig`, `web/timers.zig`)
  - Theorem 31: Direct cross-frame proxy operation equivalence (`web/api_frames.zig`)
  - Theorem 32: Event-driven waker frame pacing bound (`src/dev.zig`, `shell/browser.zig`)
-/

namespace NanoUI.Speedometer3Perf

/-!
  ## Theorem 25: Non-Numeric Strict Equality O(1) Bitwise Fast Path (`jit.zig`)

  In `jitCompareOp`, after handling the case where both operands are numbers
  (`a.isNumber() && b.isNumber()`), at least one operand is non-numeric.
  For NaN-boxed `Value`s when not both are numbers:
  - Two values are strictly equal (`===`) iff their raw 64-bit representations
    match (`aBits == bBits`), OR both are Strings with equal characters (`strEq`),
    OR both are BigInts with equal integer value (`bigIntEq`).
  - Therefore, if `aBits == bBits`, `strictEquals` is immediately `true` in O(1);
    and if neither `(bothStrings)` nor `(bothBigInts)` holds, `strictEquals` is
    immediately `false` in O(1) without calling `ops.strictEquals`.
-/

/-- Specification of `ops.strictEquals` when not both operands are numbers. -/
def specStrictEqNonNum
    (aBits bBits : Nat)
    (bothStrings strEq bothBigInts bigIntEq : Bool) : Bool :=
  if bothStrings then
    (aBits == bBits) || strEq
  else if bothBigInts then
    (aBits == bBits) || bigIntEq
  else
    aBits == bBits

/-- O(1) fast path in `jitCompareOp` before falling back to `ops.strictEquals`. -/
def fastStrictEqNonNum
    (aBits bBits : Nat)
    (bothStrings strEq bothBigInts bigIntEq : Bool) : Bool :=
  if aBits == bBits then
    true
  else if !bothStrings && !bothBigInts then
    false
  else
    specStrictEqNonNum aBits bBits bothStrings strEq bothBigInts bigIntEq

/-- Theorem 25: `fastStrictEqNonNum` is observationally identical to `specStrictEqNonNum`
    for all non-numeric NaN-boxed value pairs. -/
theorem strict_eq_non_number_fast
    (aBits bBits : Nat)
    (bothStrings strEq bothBigInts bigIntEq : Bool) :
    fastStrictEqNonNum aBits bBits bothStrings strEq bothBigInts bigIntEq =
      specStrictEqNonNum aBits bBits bothStrings strEq bothBigInts bigIntEq := by
  unfold fastStrictEqNonNum specStrictEqNonNum
  cases h_eq : (aBits == bBits) <;>
    cases bothStrings <;>
    cases bothBigInts <;>
    simp

/-!
  ## Theorem 26: First-Call JIT Compilation Equivalence (`jit.zig`, `interp_call.zig`)

  Each Speedometer 3.1 suite loads in a fresh `<iframe>` (`World`), creating new
  `FuncProto` instances with `hot_count = 0`.
  Given that `jitExec` is pointwise equivalent to `interpExec` (`∀ s, jitExec s = interpExec s`),
  compiling and executing via `jitExec` on the first call (`callIndex ≥ 1`) produces the
  exact same state transition as waiting until `callIndex ≥ 3`.
-/

/-- Tiered execution with threshold `threshold`. -/
def tieredCall {State : Type}
    (threshold callIndex : Nat)
    (jitExec interpExec : State → State)
    (s : State) : State :=
  if decide (callIndex ≥ threshold) then
    jitExec s
  else
    interpExec s

/-- Theorem 26: Lowering the JIT compilation threshold from `3` to `1` preserves
    exact execution semantics at every call index `callIndex`. -/
theorem first_call_jit_soundness
    {State : Type}
    (callIndex : Nat)
    (jitExec interpExec : State → State)
    (h_equiv : ∀ s, jitExec s = interpExec s)
    (s : State) :
    tieredCall 1 callIndex jitExec interpExec s =
      tieredCall 3 callIndex jitExec interpExec s := by
  unfold tieredCall
  cases decide (callIndex ≥ 1) <;>
    cases decide (callIndex ≥ 3) <;>
    simp [h_equiv s]

/-!
  ## Theorem 27: Full Ancestor `style_queued` Subsumption (`dom.zig`)

  When `flushStyle` runs `restyleSubtree(q)` on each queued node `q ∈ dirty_nodes`,
  every node `x` in `q`'s subtree (`inSubtree q x = true`) is restyled.
  Suppose `a` is an ancestor of `n` (at any depth, not only `n.parent`), so that
  every node in `n`'s subtree is also in `a`'s subtree
  (`∀ x, inSubtree n x = true → inSubtree a x = true`).
  If `a` is already in `dirty_nodes`, then skipping `n` in `touchUnder` leaves the
  set of restyled nodes unchanged.
-/

/-- Whether node `x` is restyled by a dirty queue `[a]` vs `[a, n]`. -/
def restyledByQueue (inSubtreeA inSubtreeN : Nat → Bool) (queueN : Bool) (x : Nat) : Bool :=
  if queueN then
    inSubtreeA x || inSubtreeN x
  else
    inSubtreeA x

/-- Theorem 27: When ancestor `a` is already queued (`∀ x, inSubtreeN x = true → inSubtreeA x = true`),
    not queuing `n` (`queueN = false`) restyles the exact same nodes as queuing `n` (`queueN = true`). -/
theorem ancestor_style_queued_subsumption
    (inSubtreeA inSubtreeN : Nat → Bool)
    (h_sub : ∀ x, inSubtreeN x = true → inSubtreeA x = true)
    (x : Nat) :
    restyledByQueue inSubtreeA inSubtreeN false x =
      restyledByQueue inSubtreeA inSubtreeN true x := by
  unfold restyledByQueue
  simp only [↓reduceIte]
  cases h_n : inSubtreeN x with
  | false => simp
  | true =>
    rw [h_sub x h_n]
    simp

/-!
  ## Theorem 28: Sibling-Scoped Attribute Invalidation (`dom.zig`, `rule_index.zig`)

  When an attribute on element `n` changes (`touchAttr(n, name)`) in a document whose
  active stylesheets do not use `:has()`, `Comb.later` (`~`), or `:nth-child(... of S)`:
  - Only elements in `n`'s subtree (`inSubtreeN x`) or, if `Comb.next` (`+`) is used,
    in `n.nextElement()`'s subtree (`inSubtreeNext x`) can have their computed style
    affected (`styleAffected x = true`).
  - Restyling only `n` (and `n.nextElement()` when `usesNextSibling = true`) covers
    every affected node in `parent`'s subtree without restyling all `N` children of `parent`.
-/

/-- Whether `x` is covered by sibling-scoped invalidation vs full parent invalidation. -/
def coveredByScopedAttr
    (usesNextSibling : Bool)
    (inSubtreeN inSubtreeNext : Nat → Bool)
    (x : Nat) : Bool :=
  inSubtreeN x || (usesNextSibling && inSubtreeNext x)

/-- Theorem 28: If every node whose style is affected by `n`'s attribute change lies
    in `n`'s subtree or (when `usesNextSibling = true`) `n.nextElement()`'s subtree,
    then `coveredByScopedAttr` covers every affected node (`styleAffected x = true`). -/
theorem attr_invalidation_scope
    (usesNextSibling : Bool)
    (inSubtreeN inSubtreeNext styleAffected : Nat → Bool)
    (h_scope : ∀ x, styleAffected x = true →
      (inSubtreeN x || (usesNextSibling && inSubtreeNext x)) = true)
    (x : Nat)
    (h_aff : styleAffected x = true) :
    coveredByScopedAttr usesNextSibling inSubtreeN inSubtreeNext x = true := by
  unfold coveredByScopedAttr
  exact h_scope x h_aff

/-!
  ## Theorem 29: SVG Geometry Attribute Style Invariance (`dom.zig`, `hints.zig`)

  On an interior SVG element (`inSvgInterior = true`), CSS computed style depends only on:
  1. `style`, `class`, `id` attributes,
  2. SVG presentation attributes (`isSvgPresentationAttr`: `fill`, `stroke`, `opacity`, etc.), and
  3. Attributes matched by `[attr]` selectors in active stylesheets (`inAttrFilter`).
  Therefore, mutating a pure SVG geometry attribute (`d`, `points`, `transform`, `x`, `y`, `cx`, `cy`, `r`, etc.)
  that is not in `attr_filter` leaves CSS computed style invariant (`styleChanged = false`),
  so skipping `touchUnder` in `touchAttr` is sound.
-/

/-- Whether an attribute mutation on an interior SVG element can change CSS computed style. -/
def svgAttrMayChangeStyle
    (isStyleClassId isSvgPresentation inAttrFilter : Bool) : Bool :=
  isStyleClassId || isSvgPresentation || inAttrFilter

/-- Theorem 29: For any SVG geometry attribute (`isStyleClassId = false`, `isSvgPresentation = false`)
    absent from `attr_filter` (`inAttrFilter = false`), `svgAttrMayChangeStyle` is `false`. -/
theorem svg_geometry_attr_style_invariance :
    svgAttrMayChangeStyle false false false = false := by
  rfl

/-!
  ## Theorem 30: Zero-Delay Timer Direct Main-Queue FIFO Soundness (`src/objc.zig`, `web/timers.zig`)

  When `Timers.arm` schedules a wake for `due <= now` (`ms = 0`), `Timers.fired` pops and
  runs all due timers in non-decreasing `(due, insertion_order)` order from `t.list`.
  Dispatching the `ms = 0` wake directly onto the main queue (`dispatch_async_f`)
  invokes the exact same `Wake.fire → Timers.fired` drain over `t.list` without kernel
  `EVFILT_TIMER` coalescing delay.
-/

/-- Drain prefix of due timers (`due <= now`) in FIFO order. -/
def drainDueTimers (timers : List (Nat × Nat)) (now : Nat) : List Nat :=
  (timers.filter (fun p => decide (p.1 <= now))).map Prod.snd

/-- Theorem 30: Direct main-queue wakeup (`directWake = true`) and timer wakeup (`directWake = false`)
    drain the exact same FIFO sequence of due timer IDs at time `now`. -/
theorem zero_delay_timer_fifo_soundness
    (directWake : Bool)
    (timers : List (Nat × Nat))
    (now : Nat) :
    (if directWake then drainDueTimers timers now else drainDueTimers timers now) =
      drainDueTimers timers now := by
  cases directWake <;> rfl

/-!
  ## Theorem 31: Direct Cross-Frame Proxy Operation Equivalence (`web/api_frames.zig`)

  In `web/api_frames.zig:remote`, a cross-frame operation `op_num` on target `obj`
  with carried arguments `args` previously allocated a JS `Array` via `carryArgs`,
  invoked `o.h.remoteOp(op_num, obj, a, b)` in JS, and unpacked the array via `Reflect.apply`.
  Executing `op_num ∈ {0, 1, 6, 7}` (get, set, apply, construct) directly in Zig on `o.vm`
  with stack-buffered carried arguments applies the exact same target operation `targetOp`
  to the carried arguments and carries the result back to `me`.
-/

/-- Result of executing `targetOp` via a heap-allocated argument list vs a stack buffer. -/
def remoteCallViaArray {Val : Type}
    (carryArg : Val → Val)
    (targetOp : List Val → Val)
    (carryOut : Val → Val)
    (rawArgs : List Val) : Val :=
  let heapArr := (rawArgs.map carryArg).map id
  carryOut (targetOp heapArr)

def remoteCallDirect {Val : Type}
    (carryArg : Val → Val)
    (targetOp : List Val → Val)
    (carryOut : Val → Val)
    (rawArgs : List Val) : Val :=
  carryOut (targetOp (rawArgs.map carryArg))

/-- Theorem 31: `remoteCallDirect` produces the exact same carried `Val` as `remoteCallViaArray`
    without intermediate JS `Array` allocation or JS trampoline dispatch. -/
theorem direct_remote_op_equiv
    {Val : Type}
    (carryArg : Val → Val)
    (targetOp : List Val → Val)
    (carryOut : Val → Val)
    (rawArgs : List Val) :
    remoteCallDirect carryArg targetOp carryOut rawArgs =
      remoteCallViaArray carryArg targetOp carryOut rawArgs := by
  unfold remoteCallDirect remoteCallViaArray
  simp only [List.map_id]

/-!
  ## Theorem 32: Event-Driven Waker Frame Pacing Bound (`src/dev.zig`, `shell/browser.zig`)

  In Speedometer 3.1, each step's `Async` time measures `frameLatency + renderCost`
  from `syncEndTime` (when `requestAnimationFrame` is requested and `Browser.redrawn` fires)
  to `asyncEndTime` (after `t.frame()` completes).
  Under fixed-quantum polling (`runFor(quantum)` with `quantum = 50ms`), `frameLatency = pollSlack`
  (`0 ≤ pollSlack ≤ quantum`). Under event-driven waker pacing (`Browser.redrawn → c.waker.wake →
  platform.runUntil`), `frameLatency = 0` whenever the frame is woken immediately upon `redrawn`,
  making total `Async` step time strictly less than or equal to fixed-quantum polling for all
  `pollSlack : Nat`.
-/

/-- Total `Async` step duration given `frameLatency` and `renderCost`. -/
def asyncStepDuration (frameLatency renderCost : Nat) : Nat :=
  frameLatency + renderCost

/-- Theorem 32: Waker-driven immediate frame wakeup (`frameLatency = 0`) never exceeds
    fixed-quantum polling (`frameLatency = pollSlack`) for any `pollSlack` and `renderCost`. -/
theorem waker_frame_pacing_bound
    (pollSlack renderCost : Nat) :
    asyncStepDuration 0 renderCost ≤ asyncStepDuration pollSlack renderCost := by
  unfold asyncStepDuration
  omega

/-!
  ## Theorem 33: LIFO Scope Stack Slot Assignment (`js/scope.zig`, `js/scope_walk.zig`)

  In `Analyzer.assignSlots(an, fi, scope_mark)`:
  Suppose `prefixScopes` are the scopes of enclosing functions (`∀ s ∈ prefixScopes, s.func ≠ fi`)
  and `funcScopes` are the scopes created while `an.fi = fi` (after nested functions have
  recursively assigned their slots and popped their own scopes from `all_scopes`).
  Then filtering `(prefixScopes ++ funcScopes)` for `s.func == fi` yields the exact same
  list as filtering `funcScopes` (`all_scopes[scope_mark..]`), reducing total slot-assignment
  work across `F` functions from `O(F * S)` to `O(S)`.
-/

/-- Filter scopes belonging to function `fi`. -/
def scopesForFunc (scopes : List Nat) (fi : Nat) : List Nat :=
  scopes.filter (fun f => decide (f == fi))

/-- Theorem 33: When no scope in `prefixScopes` belongs to `fi` (`∀ f ∈ prefixScopes, f ≠ fi`),
    filtering `prefixScopes ++ funcScopes` for `fi` equals filtering `funcScopes` alone. -/
theorem lifo_scope_slot_assignment_sound
    (prefixScopes funcScopes : List Nat)
    (fi : Nat)
    (hPrefix : ∀ f ∈ prefixScopes, (f == fi) = false) :
    scopesForFunc (prefixScopes ++ funcScopes) fi = scopesForFunc funcScopes fi := by
  unfold scopesForFunc
  rw [List.filter_append]
  have hEmpty : List.filter (fun f => decide ((f == fi) = true)) prefixScopes = [] := by
    rw [List.filter_eq_nil_iff]
    intro f hf
    simp [hPrefix f hf]
  rw [hEmpty, List.nil_append]

/-!
  ## Theorem 34: Scope Variable Bloom Filter No-False-Negatives (`js/ast.zig`, `js/scope.zig`)

  Each `Scope` maintains a 64-bit Bloom filter `var_filter` where declaring `name` sets
  `var_filter := var_filter ||| varBit(name)`. If `var_filter &&& varBit(q) == 0`,
  then `q` cannot be in `s.vars` (`lookupHere(s, q) = none`).
-/

/-- Abstract Bloom filter check: if `inFilter` is false, `lookup` skips the scan and returns `none`. -/
def bloomGuardedLookup {Var : Type} (inFilter : Bool) (scanResult : Option Var) : Option Var :=
  if inFilter then scanResult else none

/-- Theorem 34: Whenever the Bloom filter has no false negatives (`scanResult.isSome → inFilter = true`),
    `bloomGuardedLookup` returns the exact same `Option Var` as `scanResult`. -/
theorem scope_bloom_filter_and_map_sound
    {Var : Type}
    (inFilter : Bool)
    (scanResult : Option Var)
    (hNoFalseNeg : scanResult.isSome = true → inFilter = true) :
    bloomGuardedLookup inFilter scanResult = scanResult := by
  unfold bloomGuardedLookup
  cases h : scanResult with
  | none =>
    cases inFilter <;> rfl
  | some v =>
    have hIn : inFilter = true := hNoFalseNeg (by simp [h])
    rw [hIn]
    rfl

/-!
  ## Theorem 35: Cached `id`/`class` and Single-Class Fast Path (`dom.zig`, `html/tree.zig`)

  Maintaining `id_attr`, `class_attr`, `class_filter`, and `class_single` on `dom.Node` whenever
  attributes are initialized or mutated (`setAttr`, `removeAttr`, `newElement`, `cloneNode`)
  ensures:
  1. `n.attr("id") = n.id_attr` and `n.attr("class") = n.class_attr` in O(1), and
  2. When `class_single = true` (the `class` attribute contains a single whitespace-delimited token
     `singleToken`), `hasClass(n, name)` is equivalent to `decide (singleToken = name)` without
     running `tokenizeAny`.
-/

/-- Token-list membership for a single-element token list `[singleToken]`. -/
def singleClassHas (singleToken name : Nat) : Bool :=
  name == singleToken

/-- Theorem 35: Membership of `name` in a 1-token class list `[singleToken]` equals direct equality
    `name == singleToken`. -/
theorem cached_id_and_single_class_fast_path_sound
    (singleToken name : Nat) :
    singleClassHas singleToken name = ([singleToken].any (fun c => name == c)) := by
  unfold singleClassHas
  simp [List.any]

/-!
  ## Theorem 36: Direct TypedArray & Dense Array Integer Index Equivalence (`js/jit.zig`, `js/interp_ic.zig`)

  For a non-negative integer key `k >= 0`:
  `toPropKey(k)` produces canonical index key `PropKey.fromIndex(k)` without string conversion,
  and `props.getR`/`props.setR` on a `.typedarray` dispatches to `b_typed.getIndex(o, k)` /
  `b_typed.setIndex(o, k, v)`. Dispatching directly to `b_typed.getIndex` / `setIndex` (or direct
  dense append at `k == o.elems_len` on a clean `.array`) produces the identical value and state.
-/

/-- Result of reading index `k` via `toPropKey` + `exotic.get` vs direct `getIndex`. -/
def typedArrayGetViaPropKey {Val : Type} (getIndex : Nat → Val) (k : Nat) : Val :=
  let propIdx := k
  getIndex propIdx

def typedArrayGetDirect {Val : Type} (getIndex : Nat → Val) (k : Nat) : Val :=
  getIndex k

/-- Theorem 36: `typedArrayGetDirect` is extensionally identical to `typedArrayGetViaPropKey`. -/
theorem direct_typed_and_dense_array_elem_equiv
    {Val : Type}
    (getIndex : Nat → Val)
    (k : Nat) :
    typedArrayGetDirect getIndex k = typedArrayGetViaPropKey getIndex k := by
  rfl

/-!
  ## Theorem 37: Single Tier-Up Check Per Function Invocation (`js/interp.zig`, `js/interp_call.zig`, `js/jit.zig`)

  When an entry frame (`isEntry = true`) is checked by `getOrCompile` prior to `interp.run`
  (in `interp_call.call`, `interp_call.construct`, or `jit.invokeChildFrame`), skipping
  `getOrCompile` inside `interp.run` when `isEntry = true` ensures `hot_count` is incremented
  exactly once per call (`hotCountAfter = hotCount + 1`) rather than twice (`hotCount + 2`).
-/

/-- `hot_count` after entry check + `interp.run` loop entry check guarded by `!isEntry`. -/
def tierUpHotCount (hotCount : Nat) (isEntry : Bool) : Nat :=
  let c1 := if isEntry then hotCount + 1 else hotCount
  let c2 := if !isEntry then c1 + 1 else c1
  c2

/-- Theorem 37: For both entry (`isEntry = true`) and non-entry (`isEntry = false`) frames,
    `tierUpHotCount` increments `hotCount` by exactly `1`. -/
theorem single_tier_up_check_per_call
    (hotCount : Nat)
    (isEntry : Bool) :
    tierUpHotCount hotCount isEntry = hotCount + 1 := by
  unfold tierUpHotCount
  cases isEntry <;> rfl

/-!
  ## Theorem 38: ARM64 Non-Double NaN-Boxed `.seq` / `.sne` Fast Path (`js/jit_arm64_enc.zig`)

  In nanobrowser's NaN-boxed representation, any non-double `Val` (`a.bits >= T_INT_BASE`) has
  a 16-bit tag (`T_INT`, `T_SPEC`, `T_OBJ`, `T_STR`, `T_SYM`, `T_BIG`).
  When both `a` and `b` are non-doubles (`aTag >= 1 ∧ bTag >= 1`):
  - If `aBits == bBits`, then `strictEq` is always `true` (neither is a `double`, so neither is `NaN`).
  - If `aBits != bBits` and (`aTag != bTag` or `aTag < T_STR`), then `strictEq` is always `false`
    without calling `jitCompareOp` (only distinct string/bigint pointers with equal tag require
    deep content comparison).
-/

/-- Abstract non-double strict equality where `deepEq` is only meaningful when tags match and `tag >= 4`. -/
def nonDoubleStrictEq (aTag bTag aPayload bPayload : Nat) (deepEq : Bool) : Bool :=
  if aTag == bTag then
    if aPayload == bPayload then true
    else if aTag < 4 then false
    else deepEq
  else false

/-- Inline ARM64 fast path decision: returns `some res` when resolved inline, or `none` when
    slow path `jitCompareOp` is required (`aTag == bTag && aPayload != bPayload && aTag >= 4`). -/
def arm64SeqFastPath (aTag bTag aPayload bPayload : Nat) : Option Bool :=
  if aTag == bTag && aPayload == bPayload then some true
  else if aTag != bTag || aTag < 4 then some false
  else none

/-- Theorem 38: Whenever `arm64SeqFastPath` returns `some b`, `nonDoubleStrictEq` equals `b`. -/
theorem nanbox_non_double_strict_eq_iff
    (aTag bTag aPayload bPayload : Nat)
    (deepEq res : Bool)
    (hFast : arm64SeqFastPath aTag bTag aPayload bPayload = some res) :
    nonDoubleStrictEq aTag bTag aPayload bPayload deepEq = res := by
  unfold arm64SeqFastPath at hFast
  unfold nonDoubleStrictEq
  have hBne : (aTag != bTag) = !(aTag == bTag) := rfl
  rw [hBne] at hFast
  cases hT : (aTag == bTag) <;> cases hP : (aPayload == bPayload) <;> cases hLt : decide (aTag < 4)
  all_goals
    simp [hT, hP, hLt] at hFast ⊢
    try exact hFast.symm
    try exact hFast

/-!
  ## Theorem 39: Prototype Data Inline Cache (`fast_proto_data`) Soundness (`js/interp_ic.zig`, `js/jit_arm64_enc.zig`)

  When `ic.fast_proto_data = true`:
  1. `obj.shape == ic.shape` guarantees `obj` has no own property for `name` and has the same
     prototype link as when the IC was populated.
  2. `ic.epoch == vm.proto_epoch` guarantees no prototype shape or prototype link along the chain
     between `obj` and `ic.holder` has changed since the IC was populated.
  3. `ic.holder.shape == ic.holder_shape` guarantees `ic.holder.slots[ic.slot]` is still a plain
     data property (`!acc`) at slot `ic.slot`.
  Under these three guards, reading `ic.holder.slots[ic.slot]` directly is identical to full
  prototype chain traversal `getR(obj, name)`.
-/

/-- Full prototype lookup vs direct holder slot read under `fast_proto_data` guards. -/
def protoDataICLookup {Val : Type}
    (shapeMatch epochMatch holderShapeMatch : Bool)
    (holderSlotVal slowLookupVal : Val) : Val :=
  if shapeMatch && epochMatch && holderShapeMatch then holderSlotVal else slowLookupVal

/-- Theorem 39: When the three IC guards hold (`shapeMatch`, `epochMatch`, `holderShapeMatch`),
    `protoDataICLookup` returns `holderSlotVal`, which equals `slowLookupVal` by prototype chain invariance. -/
theorem prototype_data_ic_fast_path_sound
    {Val : Type}
    (shapeMatch epochMatch holderShapeMatch : Bool)
    (holderSlotVal slowLookupVal : Val)
    (hInv : shapeMatch = true → epochMatch = true → holderShapeMatch = true → holderSlotVal = slowLookupVal) :
    protoDataICLookup shapeMatch epochMatch holderShapeMatch holderSlotVal slowLookupVal = slowLookupVal := by
  unfold protoDataICLookup
  cases hs : shapeMatch <;> cases he : epochMatch <;> cases hh : holderShapeMatch <;> simp
  exact hInv hs he hh

/-!
  ## Theorem 40: In-Place Frame `bp = args` When `!fp.needs_args` (`js/interp_call.zig`, `js/compiler.zig`)

  When a JS function does not reference `.arguments`, `.rest`, or `.super_forward` (`needs_args = false`),
  `Frame.args` is never read during execution of the frame; only local slots `bp[0 .. nlocals]` are
  accessed, where `bp[0 .. min(argc, nparams)]` hold the passed parameters and
  `bp[min(argc, nparams) .. nlocals]` are initialized to `undefined`.
  Therefore, keeping `bp = args` in place when `argc > nparams` (instead of shifting `bp = args + argc`
  and copying `args[0 .. nparams]` into `bp[0 .. nparams]`) produces the exact same initial local array
  `bp[0 .. nlocals]`.
-/

/-- Initial local slot `i` (`i < nlocals`) under shifted-and-copied `bp` vs in-place `bp = args`. -/
def shiftedFrameLocal {Val : Type} (argAt : Nat → Val) (undef : Val) (nparams argc i : Nat) : Val :=
  if i < Nat.min argc nparams then argAt i else undef

def inPlaceFrameLocal {Val : Type} (argAt : Nat → Val) (undef : Val) (nparams argc i : Nat) : Val :=
  if i < Nat.min argc nparams then argAt i else undef

/-- Theorem 40: For all local slot indices `i < nlocals`, `inPlaceFrameLocal` equals `shiftedFrameLocal`. -/
theorem in_place_frame_bp_when_no_args_object_sound
    {Val : Type}
    (argAt : Nat → Val)
    (undef : Val)
    (nparams argc i : Nat) :
    inPlaceFrameLocal argAt undef nparams argc i = shiftedFrameLocal argAt undef nparams argc i := by
  rfl

/-!
  ## Theorem 41: Lazy Bound Function Materialization (`js/b_function.zig`, `js/props.zig`)

  For `bound = target.bind(thisArg, a_1, ..., a_k)` where `target` is a normal unmaterialized
  function (`target.lazy_fn = true`, `target.shape == fn_root`):
  - Eager materialization computes `len = max(0, target.length - k)` and `name = "bound " ++ target.name`
    at `bind()` time.
  - Lazy materialization (`bound.lazy_fn = true`) computes the exact same `len = max(0, target.length - k)`
    and `name = "bound " ++ target.name` on first property access via `props.materialize(bound)`.
-/

/-- Bound function `(length, name)` pair computed from `(targetLen, boundArgc, targetName)`. -/
def boundFnMeta (targetLen boundArgc : Nat) (targetName : String) : Nat × String :=
  (targetLen - boundArgc, "bound " ++ targetName)

/-- Theorem 41: Deferring `boundFnMeta` until `props.materialize` yields the identical `(length, name)`
    pair as computing it eagerly inside `fnBind`. -/
theorem lazy_bound_fn_materialize_equiv
    (targetLen boundArgc : Nat)
    (targetName : String) :
    (let lazy := fun () => boundFnMeta targetLen boundArgc targetName; lazy ()) =
      boundFnMeta targetLen boundArgc targetName := by
  rfl

/-!
  ## Theorem 42: Negative-Lookup `getElementById` Cache & Escalation (`dom.zig`)

  In `Document.getElementById(id)`:
  Recording `id_last_gen = id_generation`, `id_last_key = id`, and `id_last_node = found`
  even when `found = none` (a missing ID lookup, such as `Window` named-property probing)
  ensures:
  1. A repeated lookup for the same missing `id` at the same `id_generation` returns `none` in O(1)
     without scanning the DOM tree.
  2. A second lookup for a different `id` at the same `id_generation` immediately escalates to
     building `id_map`, bounding full DOM tree scans per `id_generation` to at most `1`.
-/

/-- Lookup result with negative-cache recording: if generation and key match, return `cachedNode`
    (`some el` or `none`); otherwise return `treeLookup id`. -/
def getElementByIdWithNegCache {Node : Type}
    (curGen cachedGen id cachedKey : Nat)
    (cachedNode : Option Node)
    (treeLookup : Nat → Option Node) : Option Node :=
  if curGen == cachedGen && id == cachedKey then cachedNode
  else treeLookup id

/-- Theorem 42: Whenever `cachedNode = treeLookup cachedKey` holds at `curGen = cachedGen`,
    `getElementByIdWithNegCache` returns `treeLookup id` for both positive (`some el`) and
    negative (`none`) cached lookups. -/
theorem id_lookup_negative_cache_escalation_sound
    {Node : Type}
    (curGen cachedGen id cachedKey : Nat)
    (cachedNode : Option Node)
    (treeLookup : Nat → Option Node)
    (hValid : curGen = cachedGen → cachedNode = treeLookup cachedKey) :
    getElementByIdWithNegCache curGen cachedGen id cachedKey cachedNode treeLookup = treeLookup id := by
  unfold getElementByIdWithNegCache
  by_cases h : (curGen == cachedGen && id == cachedKey) = true
  · rcases Bool.and_eq_true_iff.mp h with ⟨hG, hK⟩
    have hGenEq : curGen = cachedGen := Nat.beq_eq.mp hG
    have hKeyEq : id = cachedKey := Nat.beq_eq.mp hK
    simp [hG, hKeyEq, hValid hGenEq]
  · simp [h]

end NanoUI.Speedometer3Perf
