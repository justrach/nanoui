# The Windows IME: why the candidate list never showed

What was found, what is still open, and where the evidence for each claim is.
Written down because this ground was covered several times without a record, and
every attempt started from scratch because of it.

Symbols are `src/windows/surface_ime.zig` unless said otherwise.

## The symptom

Typing Chinese with Microsoft Pinyin committed the characters on Space (so the
composition → commit path works), but:

- the candidate list never appeared, at any position;
- the composition window (the pinyin being typed) was never seen either;
- Doubao IME could not type at all — Shift did nothing, only Latin letters came
  out.

`ImmSetCompositionWindow` and `ImmSetCandidateWindow` were both being called and
both returned TRUE, measured by printing their results. A TRUE return with no
window means the call was accepted and ignored, not that it was refused.

## What the code did, before this note

`place()` built its two forms like this:

    comp.style = CFS_POINT,            pt = caret
    cand.style = CFS_CANDIDATEPOS,     pt = caret + line height

`handle()` answered every `WM_IME_*` message with `0` and never with `lp`, and
`WM_IME_SETCONTEXT` in particular was answered with a bare `0` in some revisions
and with `lp` in others — the fix was committed once (`bf9f447`) and then lost in
a reset, which is why the symptom came back identical after "fixing" it.

`notify()` was an empty function. `focusGained()` opened the IME but did not
look at `lParam`'s `ISC_*` bits at all.

`WM_IME_REQUEST` was declared and never handled. `IMR_COMPOSITIONFONT` was
declared as `0x000A`, which is `IMN_SETCOMPOSITIONFONT`, not an `IMR_*` at all.

## The facts, with where each comes from

1. **`CANDIDATEFORM.dwStyle` decides what `ptCurrentPos` means.**
   `CFS_CANDIDATEPOS` puts the list's *upper left corner* at `ptCurrentPos`.
   `CFS_EXCLUDE` means "keep the list out of `rcArea`, and `ptCurrentPos` is the
   caret". Source: Microsoft, `CANDIDATEFORM structure (imm.h)`.
   Both take coordinates **relative to the upper left of the window that
   contains the list** — client coordinates, not screen coordinates.

2. **`COMPOSITIONFORM` is the same story**, and it has one more style the
   candidate form does not: `CFS_FORCE_POSITION` puts the composition window
   exactly at `ptCurrentPos` and the IME may not adjust it, where `CFS_POINT`
   lets the IME move it. Source: Microsoft, `COMPOSITIONFORM structure (imm.h)`.

3. **The `IMR_*` values are not message numbers.** They are `WM_IME_REQUEST`'s
   `wParam`. Checked against zigwin32's generated `win32/ui/input/ime.zig`:
   `IMR_COMPOSITIONWINDOW = 1`, `IMR_CANDIDATEWINDOW = 2`,
   `IMR_COMPOSITIONFONT = 3`, `IMR_RECONVERTSTRING = 4`,
   `IMR_CONFIRMRECONVERTSTRING = 5`, `IMR_QUERYCHARPOSITION = 6`,
   `IMR_DOCUMENTFEED = 7`.

4. **The `IMN_*` values** (same source, and matching Microsoft's `imm.h`):
   `IMN_CLOSESTATUSWINDOW = 1`, `IMN_OPENSTATUSWINDOW = 2`,
   `IMN_CHANGECANDIDATE = 3`, `IMN_CLOSECANDIDATE = 4`, `IMN_OPENCANDIDATE = 5`,
   `IMN_SETCONVERSIONMODE = 6`, `IMN_SETSENTENCEMODE = 7`,
   `IMN_SETOPENSTATUS = 8`, `IMN_SETCANDIDATEPOS = 9`,
   `IMN_SETCOMPOSITIONFONT = 10`, `IMN_SETCOMPOSITIONWINDOW = 11`,
   `IMN_SETSTATUSWINDOWPOS = 12`, `IMN_GUIDELINE = 13`, `IMN_PRIVATE = 14`.

5. **`ISC_*` in `WM_IME_SETCONTEXT`'s `lParam`** says which of the IME's own
   windows the system may draw: `ISC_SHOWUICOMPOSITIONWINDOW = 0x80000000`,
   `ISC_SHOWUICANDIDATEWINDOW = 1`, `ISC_SHOWUIALLCANDIDATEWINDOW = 0xF`,
   `ISC_SHOWUIGUIDELINE = 0x40000000`. An app that draws the composition itself
   clears the composition bit and draws it; an app that does not must leave the
   bits alone and let `DefWindowProc` see the message.

6. **`ImmSetCandidateWindow` "causes an `IMN_SETCANDIDATEPOS` command to be
   sent".** Source: Microsoft, `ImmSetCandidateWindow function (imm.h)`. So a
   `WM_IME_NOTIFY` that answers `0` without letting the default handling run
   can undo the placement that was just made.

7. **TSF is a different framework, not a newer IMM32.** An IME built on TSF
   (Microsoft Pinyin since Windows 8, and Doubao) reports its candidate list
   through `ITfUIElementSink` and asks `ITextStoreACP::GetTextExt` where to put
   it. It accepts `ImmSetCandidateWindow` and ignores it, which is exactly what
   was measured. A TSF text store is the only way to place a TSF IME's list —
   but it is also a large surface (COM life cycle, cross-thread callbacks,
   vtable ABI), and a first attempt at one hung the window on the first click
   into a field. See "What went wrong with TSF" below.

## The bugs found, in the order they were fixed

- [ ] **`IMR_COMPOSITIONFONT` was `0x000A`.** Should be `3`. Nothing read it yet,
      so nothing was broken by it — but the first handler that did would have
      compared against the wrong number and silently matched nothing.
      (`src/windows/win32.zig`)
- [ ] **`CANDIDATEFORM.style` was `CFS_CANDIDATEPOS`,** which pins the list's
      corner to a point the IME may still adjust. `CFS_EXCLUDE` with the caret
      as the point of interest and the caret's line as the area to avoid is what
      a text editor uses.
- [ ] **`WM_IME_SETCONTEXT` did not hand `lParam` back.** The `ISC_*` bits were
      cleared, which tells the system the app draws the composition window — it
      does not.
- [ ] **`WM_IME_NOTIFY` was empty.** `IMN_OPENCANDIDATE`,
      `IMN_CHANGECANDIDATE`, `IMN_SETCANDIDATEPOS` and
      `IMN_SETCOMPOSITIONWINDOW` were ignored, so a list that opened was never
      known about and a position the IME chose was never corrected.
- [ ] **`WM_IME_REQUEST` was not handled.** `IMR_CANDIDATEWINDOW` is a direct
      question from the IME — "give me a `CANDIDATEFORM` for this list" — and
      answering nothing makes a modern IME fall back to a default position or
      give up.
- [ ] **The two windows were placed in one function with no way to tell which
      was which.** `place()` wrote both forms every time, so a `WM_IME_NOTIFY`
      for one of them could not be answered without touching the other.

## What was already right, and does not need touching

- **The composition string is drawn in the field, underlined.**
  `textfield.zig` paints a rule under `e.marked` (the marked range), so the
  pinyin being typed is visible where it will commit. That is why "typing works"
  was true even with no candidate list: the text is there, the list is not.
- **`WM_CHAR` is ignored while composing** (`if (self.ime_composing) return;`),
  which is what stopped the pinyin being inserted twice. Removing or reordering
  that is how "sa d'sa d'萨达" comes back.
- **`GCS_RESULTSTR` is inserted without an `.unmark` first**, because `.insert`
  already replaces the marked range. Unmarking first appends instead of
  replacing, which is the same double-text bug by another route.
- **The caret rectangle is in client points, scaled by `self.scale`** — the same
  space IMM32 wants. It is not a screen coordinate and must not be converted to
  one: `CANDIDATEFORM` and `COMPOSITIONFORM` are both relative to the window.
- **D3D11 renders into this same `HWND`** (`CreateSwapChainForHwnd`), so there is
  no child window between the IME and the message loop.
- **`TranslateMessage` is called** in both message loops (`app.zig`, `loop.zig`),
  which is what generates `WM_CHAR`/`WM_IME_*` dispatch in the first place.

## What went wrong with TSF, so it is not repeated

The first text store was written in one go, ~1700 lines, and switched on by
default. Clicking a field froze the window. The causes, in order of certainty:

1. `SetText` called `notifyTextChange` on the sink it was called *from*. TSF
   answers a text change by asking for a lock, `RequestLock` granted it
   synchronously, `OnLockGranted` wrote again → unbounded recursion on the UI
   thread. A store must not report the IME's own write back to the IME.
2. `RequestLock` granted the lock from inside the call with no re-entrance
   guard, so even without (1) a nested request recursed.
3. `replaceRange` took its slice of the buffer before `ensureUnusedCapacity`,
   which may move it — a use-after-free on every write.

Any future attempt must: be off by default, be switchable at runtime, report
only the app's own edits to the sink, guard re-entrance, and be verified on a
field that is clicked before it is typed into.

## The freeze: found, and it was not TSF

The window froze on the first click into a field **after the IMM32 fixes above**, with
no TSF code in the build at all. The cause is in Microsoft's own documentation of
`ImmSetCandidateWindow`:

> This function causes an `IMN_SETCANDIDATEPOS` command to be sent.

and the same holds for `ImmSetCompositionWindow` and `IMN_SETCOMPOSITIONWINDOW`.
Both notifications are delivered **synchronously, to this window, on this
thread**, from inside the `Imm*Set*Window` call. A `WM_IME_NOTIFY` handler that
answers those two by placing the window again is therefore:

    frame() → placeWindows() → ImmSetCandidateWindow()
            → IMN_SETCANDIDATEPOS → notify() → placeCandidateWindow()
            → ImmSetCandidateWindow() → IMN_SETCANDIDATEPOS → …

an unbounded recursion on the UI thread. The window stops pumping messages, so
nothing responds and it has to be killed. Headless snapshots never see it: they
do not run a real message loop, so `WM_IME_NOTIFY` is never delivered and the
recursion cannot start. **That is why every offscreen check passed while the
real window froze.**

This is the second time this project was bitten by re-entrancy from an IME
callback — the TSF attempt died of the same shape (`SetText` →
`OnTextChange` → `RequestLock` → `OnLockGranted` → `SetText`). The rule to carry
forward:

> **A notification that an IME sends from inside a call must never call that
> same function again.**

## What was changed on this branch, and how each is checked

One fix at a time, each with the reason it is believed to be a bug. Nothing here
is a rewrite; the whole change is IMM32 plus constants.

1. **`IMR_COMPOSITIONFONT` 0x000A → 3**, and `IMR_COMPOSITIONWINDOW` (1) and
   `IMR_CANDIDATEWINDOW` (2) declared. Checked against zigwin32's generated
   `win32/ui/input/ime.zig`. *Check:* the values are read from a generated
   binding, not from memory.
2. **`CFS_CANDIDATEPOS` → `CFS_EXCLUDE`**, with the caret as the point of
   interest and its line as the area to avoid. Microsoft documents the first as
   "put the list's corner here, subject to adjustment" and the second as "keep
   the list out of this area", which is what an editor wants. *Check:* a list
   that appears now has a line to sit under.
3. **`CFS_POINT` → `CFS_FORCE_POSITION`** for the composition window, so the IME
   cannot move it away from the caret. *Check:* documented difference between the
   two styles.
4. **`WM_IME_SETCONTEXT` returns `null`** so `DefWindowProc` sees the `ISC_*` bits.
   Answering 0 cleared them, which says "the app draws these windows". *Check:*
   the app draws neither.
5. **`WM_IME_NOTIFY` implemented** (it was empty): `IMN_OPENCANDIDATE`,
   `IMN_CHANGECANDIDATE`, `IMN_SETCANDIDATEPOS` place the list;
   `IMN_SETCOMPOSITIONWINDOW` places the composition; `IMN_CLOSECANDIDATE`
   redraws. *Check:* `ImmSetCandidateWindow` is documented to send
   `IMN_SETCANDIDATEPOS`, so this is the loop that keeps the placement.
6. **`WM_IME_REQUEST` handled** for `IMR_CANDIDATEWINDOW` and
   `IMR_COMPOSITIONWINDOW`: the IME asks a direct question and a `0` answer means
   "no position". *Check:* these are the only two queries that concern placement;
   the rest (reconversion, document feed) are for editors that support them.
7. **`WM_IME_CHAR` handled.** Some IMEs commit text through it instead of
   `WM_CHAR`, and nothing listened. *Check:* its wParam is a UTF-16 unit, the same
   as what `char()` already takes.
8. **The IME is no longer force-opened** in `WM_IME_SETCONTEXT`. `ImmSetOpenStatus`
   on every focus change overrides the user's Shift state and is one explanation
   for a TSF-based IME (Doubao) refusing to compose. *Check:* Shift and the
   taskbar own that state, not the app.
9. **`IMN_SETCANDIDATEPOS` and `IMN_SETCOMPOSITIONWINDOW` place nothing.**
   They are the echo of `ImmSetCandidateWindow`/`ImmSetCompositionWindow` and
   handling them by placing is the freeze described above. This is the fix that
   matters most: without it the app is unusable, with it the rest can be tested.
   *Check:* the call graph has no cycle — `place()` is reached from a frame, a
   composition message, or `IMN_OPENCANDIDATE`/`IMN_CHANGECANDIDATE`, and the
   notifications those calls raise are on the ignored arm.

Order matters if one of these has to be backed out: 9 first (a frozen window
makes every other check impossible), then 1 and 2 (placement), then 4–6 (the
messages that carry the placement), then 7 (text), then 8 (state). Back out 8
first if an IME stops composing at all, and 2/3 first if the windows are in the
wrong place.

## How this is verified

Nothing here can be confirmed by reading. The checks that work:

- `gallery --nanoui-snapshot=out.png --nanoui-script=click:Tasks;at:X,Y;type:ni"`
  renders offscreen, takes input, and shows whether the field took the text.
  Coordinates are points: a 900x640 window at 2x renders 1800x1280.
- A real run with Microsoft Pinyin and with Doubao, typing and watching for the
  list. There is no substitute for this one.
