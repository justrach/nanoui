# nanocua

Lets AI agents see and use apps on your Mac, as far as you allow, without
taking over your screen. A small app built on
[nanoui](https://github.com/justrach/nanoui): a control panel, and an
[MCP](https://modelcontextprotocol.io) server any agent can add (Claude Code,
Codex, Cursor…). It is [codegraff](https://github.com/justrach/codegraff)'s
computer use: `graff` ships with it and offers it by default on macOS.

macOS first. Linux (X11 with XTest and AT-SPI) and Windows (UI Automation
and SendInput) come next; there the app builds and every tool says it isn't
supported yet.

## How it works

```
agent ──stdio──▶ nanocua mcp ──unix socket──▶ nanocua (the app)
                 (a pipe, nothing more)        the panel, the policy, the log,
                                               accessibility, input, screenshots
```

Everything goes to the one app, so a terminal `graff`, Harness's graff chats and
any other agent can use it at the same time. Calls run one at a time, and each
agent keeps its own refs and target app.

The app does all the work, and the agent's `nanocua mcp` only carries lines.
That matters on macOS: permissions (Accessibility, Screen Recording) belong
to the app that asks, so you grant them to nanocua once, not to each terminal
or agent that happens to start it, and you can take them back in one place.
`nanocua mcp` answers handshakes and the tool list itself, so adding it to an
agent starts nothing; the first real call opens the app, in the background.

Agents work from the **accessibility tree**, not from pixels: `get_ui_tree`
gives one line per element worth naming, with a ref to act on it, and
leaves out containers that say nothing. That's exact (no misclicks from a
guessed coordinate) and cheap (text, not images):

```
app "Notes" pid 812
[1] Window "Groceries" @0,25 1200x800
  [2] Button desc="New Note" @310,38 28x28
  [3] SearchField value="" @960,36 220x28
  [4] TextArea value="eggs\nmilk" @320,80 860x700 focused
```

Agents work **inside one app, in the background**: the app they last read or
named. `click` with a ref presses the element through accessibility when it can;
otherwise, and for keys, text and scrolling, events are posted to that app alone,
so your pointer stays where it is and your keyboard stays yours. Screenshots
capture that app's window, even behind others, with the mapping from image pixels
back to screen points. A window on another Space or minimized is out of reach:
macOS shows neither its picture nor its elements, and the reply says so. This isn't a sandbox: it's your real Mac, your apps and
your logins. Some apps may ignore events they get in the background, so a reply
says when a click isn't confirmed. Chrome works in the background: clicks, typing,
keys, `set_value` and scrolling all reached a test page. A button in a web page gets
a click event rather than an accessibility press, because Chrome reports a press
as done without acting on it. The first click in a window that wasn't key can be
spent on making it key.

## Tools

| tool | does | needs |
| --- | --- | --- |
| `list_apps` | running apps with windows, which is frontmost | |
| `get_ui_tree` | an app's elements, with refs | Accessibility |
| `screenshot` | a JPEG of an app's window, scaled | Screen Recording |
| `click` | by ref (pressed) or at x,y; right, double | input on |
| `type_text` | types Unicode text, into a ref if given | input on |
| `press_key` | `cmd+s`, `shift+tab`, `enter`, `f5`… | input on |
| `scroll` | at x,y or over a ref, by lines | input on |
| `move_mouse` | hovers at x,y | input on |
| `set_value` | sets a field's value through accessibility | input on |
| `open_app` | opens an app by name, behind your work | input on |

With `whole_screen: true`, once you've allowed it, `screenshot` takes the main
display or a region of it, input uses the real pointer and keyboard, and `open_app`
brings the app forward.

## What you control

- **Stop** refuses every call, even looking, including calls already waiting, and
  stops text being typed, until you press Resume. An agent may be moving the
  pointer, so it's also on a key, **⌃⌥⌘.**, and outside the panel (below).
- **Allow input** is off at launch: agents can look but not click, type or
  open apps until you turn it on.
- **Allow whole screen** is off at launch too: agents stay inside one app. Its
  switch asks first, on the same card as requests from outside: the click that
  brings this window forward also presses what's under it, and this switch hands
  over the real pointer.
- nanocua's own window is off limits: agents don't see it in trees and can't
  click, type or set values in it, so an agent can't press its own Resume.
- **Activity** lists every call: the tool, its arguments, how long it took,
  and whether it was done, failed or refused.

Calls run one at a time on a queue of their own, so a hung app never
freezes the panel (accessibility calls give up after two seconds).

## From graff and Harness

The switches also show in `graff computer`, `/computer` and Harness's MCP servers
settings page. All of them run the app's `nanocua ctl`:

```sh
nanocua ctl status [--json]                what's on, what macOS has granted
nanocua ctl stop                           refuse every call, at once
nanocua ctl off input                      turn a switch off, at once
nanocua ctl allow input                    ask; you answer in nanocua's window
nanocua ctl grant screen                   open macOS's prompt
nanocua ctl open                           bring the window forward
```

Anything can stop nanocua or turn things off. **Nothing outside the window can
turn things on.** `allow` only puts a question in nanocua's window, and it takes a
click there, from your own mouse or trackpad. Agents have shells and could run
this command too; if it turned input on, the switch would protect you from nothing.
Allow arms after 0.7s, so a click meant for something else can't answer it. A
question goes away after a minute, and a Deny refuses new ones for 15 seconds.

The same check covers the panel's own switches and Resume, on the way on only.
Switch Control and Voice Control post their own clicks, so they can turn things
off here but not on. Release builds refuse nanoui's `--nanoui-*` flags, which
would otherwise drive this window from a command line. None of this stops a
determined program running as you, which could tamper with the app itself: it
closes the easy route. macOS's own permissions stay in System Settings.

## Adding it to an agent

With `graff` there's nothing to add: on macOS its installer puts nanocua in
`~/Applications`, and `graff mcp disable nanocua` turns it off. Elsewhere, copy
the command from the panel. With Claude Code:

```sh
claude mcp add nanocua -- ~/Applications/nanocua.app/Contents/MacOS/nanocua mcp
```

Or as an MCP server over stdio:

```json
{ "mcpServers": { "nanocua": { "command": "/Users/you/Applications/nanocua.app/Contents/MacOS/nanocua", "args": ["mcp"] } } }
```

The socket is `~/Library/Application Support/nanocua/mcp.sock` (macOS) or
`$XDG_RUNTIME_DIR/nanocua.sock` (Linux), only usable by your user;
`NANOCUA_SOCKET` overrides it.

## Building

```sh
zig build                      # zig-out/bin/nanocua
zig build test                 # the tests, the panel through ui.Tester
zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux
zig build -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
sh macos/package.sh aarch64-macos /tmp   # /tmp/nanocua.app
```

Nothing in the tests moves the pointer, types or captures the screen: the policy,
where calls go, MCP sessions, keys, the tree's text, the socket (over a socket
pair), the switches from outside and the panel are tested; the macOS backend is
compiled, not run.

macOS keeps permissions across updates only for an app signed by the same
identity. Set `CODESIGN_IDENTITY` for `package.sh`; an ad hoc build is asked again
each time.

## License

codegraff's: see its `LICENSE`. nanoui's copy of this folder is generated from
codegraff's (`scripts/vendor-nanocua.sh`), and is not under nanoui's MIT license.

## Next

- A virtual Mac as a second mode: agents in a separate macOS guest, for real
  isolation, without your apps and logins.
- An icon, and a menu bar item while the window is closed.
- Asking before each action, per app or per tool, in the panel.
- Linux (X11: XTest, AT-SPI over D-Bus) and Windows (UI Automation, SendInput).
