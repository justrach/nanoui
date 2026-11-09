# Caret lifecycle

A text field keeps its blink phase in its edit state. Input starts a full
500 ms visible phase; the next half-second edge is the only frame the
caret requests. Moving a field preserves its edit state and phase.

An unfocused field, inactive host window, or nonempty selection has no
visible caret and schedules no caret frame. Reactivation starts a new full
visible phase. IME composition and Vim's block caret stay solid without
periodic redraws; ending composition restarts the blink.

`Input.window_active` is persistent host state, not an event edge.
`clearEdges` must not reset it. macOS, Windows, and GTK hosts update it from
window activation and cancel or replace superseded frame timers. The
existing `Context.window_focused` flag is still honored.

Bare fields do not animate an invisible focus border. A multiline field
uses the same lifecycle as a single-line field, building on the existing
bare-caret clipping and blinking fix rather than implementing it twice.

`tests_caret_activity.zig` exercises synthetic offscreen fields, including
reactivation, selection, composition, and Vim blocks. Its guards allow the
same tests to run against the preceding API. `caret.zig` tests the pure
clock separately; none of these tests reads application data or drives a
real window.
