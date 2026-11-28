# Webview File Drops (`PageOptions.file_drop`)

`PageOptions.file_drop` lets a Zig host intercept OS file drops aimed at a `nanoui` webview page (both whole-window `.page` windows and macOS docked `Window.dockPage` views) without relying on internal Objective-C class names or private WebView patches.

## Routing & Opt-In Semantics

- **Default (`file_drop == null`):** Existing webview drag/drop behavior is preserved verbatim (HTML `dragover`/`drop` events, `DataTransfer.files`, file inputs, and default navigation).
- **Opt-in (`file_drop != null`):** On drag enter/update, `on_offer` returns a `PageDropDecision`:
  - `.host`: nanoui accepts the drag for the host and calls `on_drop` once when released, suppressing webview default navigation/upload handling for that drop.
  - `.webview`: nanoui forwards the drag/drop directly to the underlying webview.
  - `.reject`: nanoui declines the drag and does not deliver it to the webview or `on_drop`.
- If `on_offer == null`, nanoui defaults to `.host` when at least one `file://` URL is present and `.webview` otherwise.
- When `on_offer` returns `.host` (or `.reject`), that routing choice applies immediately at drop time for desktop synchronous pasteboards.

## Coordinates, Data & Ownership

- **Coordinates (`x`, `y`):** Top-left, page-view-local logical points, independent of backing DPI scale. Docked pages receive coordinates relative to the docked page view, not the outer native window. Note that browser page zoom, CSS transforms, scroll offsets, or nested iframes inside the web document are not reflected in view-local logical points.
- **Data (`urls`):** Borrowed slice of normalized `file://` URL strings (UTF-8 / percent-encoded; NOT decoded filesystem paths). Multiple files and directories are included as multiple entries. Non-file drops produce an empty slice (`urls.len == 0`) or are ignored when filtering `text/uri-list`.
- **Ownership:** `urls` and each URL string are valid **only until the callback returns**. Applications must duplicate any strings they retain past callback return and run heavy file importing off the UI thread. Copying a URL does not extend sandbox/security-scoped temporary access lifetimes.

## Lifecycle & Host Security Boundary

- **UI-thread execution:** All `on_offer`, `on_drop`, and `on_cancel` callbacks run on nanoui's UI thread.
- **Cancellation & Navigation:** Drag exit (`draggingExited` / `drag-leave`), page close, or navigating the page cancels any active offer (`on_cancel`) and bumps the internal drag epoch so stale drops or delayed asynchronous payload completions never deliver to a different document. Reentrant `window.close()` inside any drop callback is safe.
- **Host security boundary:** Host-consumed drops are delivered solely to Zig (`on_drop`). nanoui never injects dropped paths into page JavaScript; applications decide what sanitized metadata (for example filenames, counts, or workspace IDs) to expose over typed IPC.

## Platform Support Matrix

| Platform | Whole-window `.page` | Docked page (`dockPage`) | Notes |
|---|---|---|---|
| **macOS** (`WKWebView`) | Supported (`NSDraggingDestination`) | Supported | Uses `NSPasteboardURLReadingFileURLsOnlyKey` (`file://` URLs). |
| **Linux** (`WebKitGTK`, GTK 3 & GTK 4) | Supported (`GtkDropTarget` / `drag-motion`+`drag-data-received`) | — (native surface docking not yet on Linux) | Normalizes `GdkFileList` (GTK 4) & `text/uri-list` (GTK 3). |
| **Windows** (`WebView2`) | Follow-up | Follow-up | `AllowExternalDrop` only toggles browser drops; host callback interception needs dedicated WebView2/COM work. |
| **iOS** (`WKWebView` / UIKit) | Follow-up | Follow-up | UIKit uses asynchronous `UIDropInteraction` / `NSItemProvider` file promises & access scopes. |
| **Android** | Unsupported (`.PagesUnsupported`) | Unsupported | Android has no webview page backend yet. |

## Outbound prepared files on macOS

Set `PageOptions.file_drag = true` and invoke
`Window.startPageFileDrag(offer)` from trusted app code during a live
left-button gesture in the page. For a docked page use `Page.startFileDrag`.
An offer carries a caller token, an array of 1 to 64 prepared absolute
paths, and a terminal callback. The array may be released when the call
returns. Hold the file contents in application storage so a receiver can
read them after accepting, after the callback, or after the app exits.

The call returns an error if the gesture has ended, the offer is invalid,
or a session cannot start. A live page receives one terminal result for a
started drag. Closing the page detaches the callback while AppKit may
continue its native session. A copy result means the receiver accepted the
offer. Keep a keyboard-accessible Save action for the same prepared files.
