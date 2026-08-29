# Quill MenuBar App — Quick Reference Cheatsheet

## Project setup (Xcode 16)
| Setting | Value | Where |
|---|---|---|
| Template | macOS → App, SwiftUI, Swift | New Project dialog |
| Deployment target | macOS 15.0 | Target → General |
| `Application is agent (UIElement)` / `LSUIElement` | `YES` | Target → Info tab |
| `NSMicrophoneUsageDescription` | "Quill records meeting audio locally." | Info tab |
| App Sandbox → Audio Input | checked | Signing & Capabilities |
| App Sandbox → User Selected File (Read/Write) | checked | Signing & Capabilities |
| Hardened Runtime → Audio Input | checked (release builds) | Signing & Capabilities |

Screen Recording permission has NO Info.plist key — the OS prompts when
ScreenCaptureKit is first used (or via `CGRequestScreenCaptureAccess()`).

## Core API one-liners
```swift
// Menu-bar-only app (no Dock icon), programmatic form:
NSApp.setActivationPolicy(.accessory)

// Status item:
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "Quill")

// Popover with SwiftUI content:
popover.contentViewController = NSHostingController(rootView: PopoverView())
popover.behavior = .transient
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// Mic permission:
let ok = await AVCaptureDevice.requestAccess(for: .audio)

// Screen-recording permission (system audio gate):
CGPreflightScreenCaptureAccess()      // check silently
CGRequestScreenCaptureAccess()        // prompt once

// Security-scoped bookmark save/restore:
let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
let url  = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
url.startAccessingSecurityScopedResource()   // balance with stop…()

// Global hotkey (no Accessibility permission):
RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
// teardown: UnregisterEventHotKey(ref); RemoveEventHandler(handlerRef)
```

## Memory-leak checklist
- `NSEvent.addGlobalMonitorForEvents` → must call `NSEvent.removeMonitor(_:)`.
- Stored closures on long-lived objects → `[weak self]`.
- `Task { }` loops → check `Task.isCancelled`, cancel in `stop()`/`deinit`.
- Carbon hotkeys → `UnregisterEventHotKey` + `RemoveEventHandler` in `deinit`.
- `NSStatusItem` → `NSStatusBar.system.removeStatusItem(_:)` if removed at runtime.
- Verify with: Xcode → Product → Profile → Leaks; Debug Memory Graph button.

## Debug commands
```bash
# Reset TCC permission state for re-testing onboarding:
tccutil reset Microphone com.yourteam.Quill
tccutil reset ScreenCapture com.yourteam.Quill

# Watch memory of the running app:
top -pid $(pgrep -x Quill) -stats mem,cpu
```

## Vocabulary
- **AppKit** — the classic macOS UI framework (NSWindow, NSStatusItem…).
- **SwiftUI** — declarative UI framework; hosted inside AppKit via NSHostingController.
- **TCC** — "Transparency, Consent, and Control", the macOS permission database.
- **Carbon** — pre-Mac-OS-X-era C API; RegisterEventHotKey still lives there.
- **Security-scoped bookmark** — persistable token letting a sandboxed app reopen a user-chosen file/folder after relaunch.
- **@MainActor** — Swift Concurrency annotation pinning code to the main thread.
