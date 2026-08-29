---
name: quill-menubar-app
description: Zero-to-undergrad teaching module for building Quill's Component 1 — a macOS menu bar (NSStatusItem) app with a SwiftUI popover (record/stop, live level meters, Obsidian vault selector), global hotkeys, status indicators, app lifecycle, and mic + screen-recording permission onboarding. Assumes no prior macOS/Swift experience. Xcode 16+, Swift 5.10+, macOS 15.
---

# Quill Component 1: The MenuBar App Core

You are going to build the "face" of Quill: the little icon in the macOS menu bar, the popover that drops down from it, the keyboard shortcut that toggles recording from anywhere, and the onboarding flow that asks the user for microphone and screen-recording permission. Everything runs locally; nothing here talks to a network — ever.

Complete reference code lives in [`code/`](code/) — you will type it in piece by piece below. A one-page API summary is in [`CHEATSHEET.md`](CHEATSHEET.md).

---

## 1. Concepts (from zero)

**Swift** is Apple's programming language. It is compiled, strongly typed, and uses *Automatic Reference Counting* (ARC) for memory: every class instance keeps a count of how many things point at it; when the count hits zero it is freed. There is no garbage collector. This matters constantly on macOS: if two objects point at each other ("retain cycle"), neither count ever hits zero and you have a **memory leak**. The fix is marking one side `weak` (a pointer that doesn't count and becomes `nil` when the target dies).

**Xcode** is Apple's IDE. It compiles your code, signs the app, and contains **Instruments**, the profiler you'll use to prove there are no leaks.

**AppKit** is the original macOS UI framework (1990s NeXT lineage). Classes start with `NS` (NeXTSTEP): `NSApplication` (the app itself), `NSStatusItem` (an icon in the menu bar), `NSPopover` (the floating panel), `NSEvent` (mouse/keyboard events). Menu bar items *only* exist in AppKit — SwiftUI's `MenuBarExtra` exists but gives you less control over icon state and popover behavior, so Quill uses the AppKit primitive directly. That's also more instructive.

**SwiftUI** is Apple's modern declarative UI framework: you describe *what* the UI looks like as a function of state, and the framework re-renders when state changes. We use SwiftUI for the popover's *contents* and AppKit for the *chrome* around it. The bridge is `NSHostingController`, an AppKit view controller that hosts a SwiftUI view.

**`ObservableObject` / `@Published` / `@EnvironmentObject`** — SwiftUI's oldest observation mechanism (still the most explicit for teaching). A class conforming to `ObservableObject` announces changes through its `@Published` properties; views that read it via `@EnvironmentObject` re-render automatically. (macOS 14+ also offers the `@Observable` macro; we use `ObservableObject` here because the ownership rules are visible rather than magic.)

**Swift Concurrency** — `async/await` and `Task`. A `Task { }` is a unit of asynchronous work you can **cancel**; a well-behaved loop checks `Task.isCancelled`. `@MainActor` pins code to the main thread — UI state must only mutate there. Quill's rule: *every* long-running Task is stored, cancelled on stop, and set to `nil`. That is what "concurrency cancellation cleanup" means in the project's verification list.

**The app lifecycle** — `NSApplicationDelegate` gets callbacks like `applicationDidFinishLaunching` (build your UI here) and `applicationWillTerminate` (tear down here). A SwiftUI `App` adopts an AppKit delegate through `@NSApplicationDelegateAdaptor`.

**LSUIElement / activation policy `.accessory`** — makes the app a background "agent": no Dock icon, no menu bar of its own, lives only as its status item.

**TCC (Transparency, Consent & Control)** — the macOS permission system. Two permissions matter to Quill:
- *Microphone*: requested via `AVCaptureDevice.requestAccess(for: .audio)`; requires an `NSMicrophoneUsageDescription` string in Info.plist or the app crashes on request.
- *Screen Recording*: macOS gates **system-audio loopback** (what ScreenCaptureKit captures) behind this permission even if you never touch pixels. There is no result-returning prompt API — `CGRequestScreenCaptureAccess()` shows the dialog once; `CGPreflightScreenCaptureAccess()` silently checks.

**App Sandbox & security-scoped bookmarks** — a sandboxed app can only touch files the user explicitly picks (`NSOpenPanel`). That grant dies on relaunch unless you persist a *security-scoped bookmark* and call `startAccessingSecurityScopedResource()` after resolving it. This is how Quill remembers the Obsidian vault folder.

**Carbon hotkeys** — `RegisterEventHotKey` is a C API from the pre-OS-X Carbon era that is still the *only* way to register a global keyboard shortcut without the Accessibility permission. It calls a C function pointer, which cannot capture Swift objects — so we pass `self` through a raw pointer (`Unmanaged`). You'll write that bridge and understand it.

**SF Symbols** — Apple's built-in icon font (`NSImage(systemSymbolName:)`). We use `quote.bubble` (idle) and `record.circle.fill` tinted red (recording) as status indicators.

---

## 2. Architecture — where this fits in Quill

```
┌────────────────────────── Quill.app ──────────────────────────┐
│  Component 1 (THIS MODULE)                                    │
│  QuillApp (@main) ─▶ AppDelegate                              │
│        owns: NSStatusItem ── icon reflects state              │
│              NSPopover ─▶ NSHostingController ─▶ PopoverView  │
│              HotkeyManager (⌥⌘R)                              │
│              AppState (ObservableObject)  ◀── single truth    │
│              PermissionsManager (mic + screen TCC)            │
│                                                               │
│  AppState.startRecording() ──▶ Component 2 AudioRecorderEngine│
│  AppState.micLevel/systemLevel ◀── level taps (Component 2)   │
│  AppState.vaultURL ──▶ Component 4 ObsidianExporter           │
│  history ──▶ Component 5 SQLite                               │
└───────────────────────────────────────────────────────────────┘
```

Ownership is a single chain — AppDelegate owns everything; children point back only via `weak` closures. AppState is the one mutable-state object, `@MainActor`-isolated, injected into SwiftUI and mutated by the engines. Component 1 knows nothing about audio internals: it exposes `startRecording()/stopRecording()` hooks and consumes `Float` levels. That seam is what keeps this module testable without a microphone.

---

## 3. Step-by-step implementation walkthrough

### Step 0 — Create the project
1. Xcode → File → New → Project → **macOS → App**. Product name `Quill`, Interface **SwiftUI**, Language **Swift**. Deployment target **macOS 15.0**.
2. Target → **Info** tab: add `Application is agent (UIElement)` = `YES`, and `Privacy - Microphone Usage Description` = `Quill records meeting audio locally on your Mac. Nothing is uploaded.`
3. Target → **Signing & Capabilities**: under App Sandbox check **Audio Input** and **User Selected File → Read/Write**.
4. Delete the template `ContentView.swift`.

### Step 1 — Entry point and delegate (`QuillApp.swift`)
Type in [`code/QuillApp.swift`](code/QuillApp.swift). Read the annotations as you go; the load-bearing ideas:

- `@NSApplicationDelegateAdaptor(AppDelegate.self)` — SwiftUI creates and retains the delegate; it is your one long-lived AppKit object.
- `Settings { EmptyView() }` — SwiftUI demands *a* scene; an empty Settings scene keeps it happy without creating a window.
- `NSApp.setActivationPolicy(.accessory)` — belt-and-suspenders with `LSUIElement` (the plist key matters for launch; the call matters if the plist is forgotten).
- The status item's `button` is a real `NSButton`: give it target/action like 1998-era AppKit, because that's what it is.
- `popover.behavior = .transient` closes it on most outside clicks; the added **global event monitor** covers clicks that AppKit doesn't route (other apps' menu extras). Note the pairing: every `addGlobalMonitorForEvents` has a matching `removeMonitor` — this is the #1 leak in menu bar apps.
- `appState.onRecordingChanged = { [weak self] ... }` — study this line until the cycle it prevents is obvious: AppDelegate → AppState → closure → AppDelegate.

### Step 2 — State (`AppState.swift`)
Type in [`code/AppState.swift`](code/AppState.swift).

- `@MainActor final class AppState: ObservableObject` — all mutation on the main thread, so `@Published` never fires off-thread (which SwiftUI punishes with runtime warnings and glitches).
- The recording timer is a structured-concurrency loop, not a `Timer`. Cancellation is explicit: `timerTask?.cancel(); timerTask = nil` in `stopRecording()`. Inside the loop, `guard let self else { return }` after a `[weak self]` capture means a dead AppState ends the loop instead of being kept alive by it.
- `setVault(url:)`/`restoreVaultBookmark()` implement security-scoped bookmark persistence via `UserDefaults`. Stale bookmarks (vault moved) are transparently refreshed.

### Step 3 — The popover UI (`PopoverView.swift`)
Type in [`code/PopoverView.swift`](code/PopoverView.swift).

- `@EnvironmentObject` receives the AppState the delegate injected — the view owns *no* state of its own except what `@StateObject`/`@ObservedObject` observation requires.
- `LevelMeter` is a 25-line pure-SwiftUI meter: a `GeometryReader`, two `Capsule`s, a 0.1 s linear animation, green→yellow→red thresholds, and accessibility labels. No timers; it redraws only when `level` changes — that's the "tiny & performant" principle in miniature.
- The vault selector uses `NSOpenPanel` directly from SwiftUI (fine on macOS) and hands the URL to `appState.setVault(url:)`.
- `.task { await permissions.refreshStatuses() }` re-checks permissions every time the popover opens, so the banner disappears the moment the user grants access in System Settings.

### Step 4 — Global hotkey (`HotkeyManager.swift`)
Type in [`code/HotkeyManager.swift`](code/HotkeyManager.swift). This is the hardest file; take it slowly.

- Registration is two calls: `InstallEventHandler` (route hot-key events to our C callback) then `RegisterEventHotKey` (claim ⌥⌘R system-wide).
- The C callback can't capture Swift state, so `self` travels through `userData` as `Unmanaged.passUnretained(self).toOpaque()` and comes back with `takeUnretainedValue()`. *Unretained* is correct because `deinit` removes the handler before `self` dies — the callback can never fire on a freed object.
- `deinit` unregisters both. Forgetting this is not a soft leak — the OS keeps delivering the hotkey to a dangling pointer and you crash.
- The callback hops to the main thread (`DispatchQueue.main.async`) before touching AppState, respecting its `@MainActor` isolation.

### Step 5 — Permissions onboarding (`PermissionsManager.swift`)
Type in [`code/PermissionsManager.swift`](code/PermissionsManager.swift).

- A `@MainActor` singleton `ObservableObject` with `micStatus` / `screenStatus`.
- Microphone: `authorizationStatus` → prompt only when `.notDetermined`; once denied, deep-link to System Settings (`x-apple.systempreferences:` URL) because macOS will never re-prompt.
- Screen recording: preflight silently, prompt once, deep-link otherwise. Warn learners: after granting Screen Recording, macOS requires an app relaunch before capture works.
- The record button is `.disabled(!permissions.allGranted)` — onboarding is enforced by construction, not by hoping.

### Step 6 — Run and verify
- ⌘R. A speech-bubble icon appears top-right; no Dock icon. Click → popover. Grant mic (system dialog) and screen recording (Settings toggle + relaunch).
- Press ⌥⌘R with another app focused: icon turns into a red `record.circle.fill`, timer counts.
- Pick a vault folder, quit, relaunch: the folder name persists (bookmark worked).
- Product → Profile → **Leaks**: open/close the popover 20 times, toggle recording 20 times, take a snapshot — zero leaks expected. Then Debug Memory Graph: exactly one `AppState`, one `HotkeyManager`, zero `NSEvent` monitor blocks when the popover is closed.
- `tccutil reset Microphone <bundle-id>` to replay onboarding from scratch.

---

## 4. Common pitfalls & memory-leak traps

1. **Leaked event monitors.** `NSEvent.addGlobalMonitorForEvents` returns an opaque token; failing to pass it to `removeMonitor` leaks the closure *and* everything it captures, forever, once per popover open. Symptom: memory climbs a few KB per click; Instruments shows accumulating `__NSGlobalEventMonitor` blocks.
2. **Retain cycles through stored closures.** Any `var onSomething: (() -> Void)?` on an object your class owns must be assigned with `[weak self]`. The cycle AppDelegate→AppState→closure→AppDelegate keeps *the entire app graph* alive in tests.
3. **Tasks that outlive their owner.** A `while true { await ... }` Task retains captured objects until cancelled. Always: store the Task, check `Task.isCancelled`, cancel in `stop()` and (for non-MainActor types) `deinit`, and capture `[weak self]` so a forgotten cancel degrades to a no-op loop instead of a leak.
4. **Local `NSStatusItem`.** If the status item is a local variable it deallocates at end of scope and your icon silently never appears. It must be a stored property. Conversely, removing it at runtime requires `NSStatusBar.system.removeStatusItem(_:)`.
5. **Missing `NSMicrophoneUsageDescription`** → instant crash (`TCC` abort) the moment you request mic access. No compiler warning.
6. **Screen Recording confusion.** No plist key exists; the checkbox appears in System Settings only after the first `CGRequestScreenCaptureAccess()`/SCKit use; changes take effect after relaunch. Budget UI copy for this ("Grant, then reopen Quill").
7. **Prompting for mic on a background thread / before app finishes launching** — the dialog may appear behind other windows or not at all for `.accessory` apps. Request from a user action inside the popover (as we do), and consider `NSApp.activate()` first.
8. **Security-scoped bookmark imbalance.** Every `startAccessingSecurityScopedResource()` needs a matching stop (or a deliberate app-lifetime hold, documented, as here). Kernel resources leak otherwise, and after ~thousands of unbalanced starts, file access fails process-wide.
9. **Mutating `@Published` off the main actor.** Purple runtime warnings, torn UI. `@MainActor` on the whole class kills the category of bug.
10. **`.transient` popover + status-item click double-toggle.** The outside-click that closes the popover can be the *same* click on the status button, reopening it. If you observe flicker, check `popover.isShown` in the action (we do) rather than tracking your own flag.
11. **Carbon handler teardown order.** Unregister the hotkey *and* remove the event handler; do it in `deinit`. Test by creating/destroying HotkeyManager in a loop under Instruments.

---

## 5. Exercises

**Exercise 1 (easy) — Status-icon vocabulary.** Add a third visual state: while Component 3 would be transcribing (simulate with a `isProcessing` flag on AppState toggled by a debug button), show `waveform.circle` with a purple tint in the menu bar. Requirements: single source of truth in AppState, no new stored closures without `[weak self]`.

**Exercise 2 (medium) — Right-click menu.** Make right-clicking the status item show an `NSMenu` (Start/Stop Recording, Open Vault in Finder, Quit) while left-click keeps toggling the popover. Hint: inspect `NSApp.currentEvent?.type` inside the action.

**Exercise 3 (hard) — Leak hunt.** The snippet below (a "live waveform preview" someone contributed) contains **three** distinct leak/lifetime bugs. Find and fix all three, then prove the fix in the Debug Memory Graph.

```swift
final class WaveformPreviewController {
    var onLevel: ((Float) -> Void)?
    private var monitor: Any?
    private var pollTask: Task<Void, Never>?

    func start(appState: AppState) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKey(event); return event
        }
        pollTask = Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                self.onLevel?(appState.micLevel)
            }
        }
        onLevel = { level in self.render(level) }
    }
    func stop() { pollTask = nil }
    private func handleKey(_ e: NSEvent) {}
    private func render(_ level: Float) {}
}
```

**Exercise 4 (hard, stretch) — User-configurable hotkey.** Extend `HotkeyManager` to support re-registration at runtime: add `func rebind(keyCode: UInt32, modifiers: HotkeyModifiers)` and a tiny "recording…" capture field in the popover that grabs the next keystroke via a *local* event monitor (removed immediately after capture). Persist the choice in `UserDefaults`.

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1.** Add to AppState: `@Published var isProcessing = false`. Generalize the callback into `var onStateChanged: (() -> Void)?` invoked from `didSet` of both flags. In AppDelegate:

```swift
private func updateStatusIcon() {
    guard let button = statusItem?.button else { return }
    let (symbol, tint): (String, NSColor?) =
        appState.isRecording ? ("record.circle.fill", .systemRed)
        : appState.isProcessing ? ("waveform.circle", .systemPurple)
        : ("quote.bubble", nil)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Quill")
    button.contentTintColor = tint
}
// wiring: appState.onStateChanged = { [weak self] in self?.updateStatusIcon() }
```

**Exercise 2.** In `togglePopover`:

```swift
@objc private func togglePopover(_ sender: Any?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
        showContextMenu(); return
    }
    popover.isShown ? closePopover() : showPopover()
}

private func showContextMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: appState.isRecording ? "Stop Recording" : "Start Recording",
                 action: #selector(menuToggleRecording), keyEquivalent: "")
    if let vault = appState.vaultURL {
        let item = menu.addItem(withTitle: "Open Vault in Finder",
                                action: #selector(openVault), keyEquivalent: "")
        item.representedObject = vault
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Quill",
                 action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    // Assign, pop, then detach so left-click behavior returns to the action:
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil          // critical: while .menu is set, action never fires
}

@objc private func menuToggleRecording() { appState.toggleRecording() }
@objc private func openVault(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL {
        NSWorkspace.shared.open(url)
    }
}
```
The `statusItem?.menu = nil` line is the classic gotcha: a permanently-assigned menu hijacks *all* clicks.

**Exercise 3 — the three bugs:**
1. *Local event monitor never removed and captures `self` strongly.* `start` installs it, nothing calls `removeMonitor`. Fix: in `stop()` (and `deinit`), `if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }`, and capture `[weak self]` in the monitor closure.
2. *Uncancellable infinite Task retaining `self` and `appState`.* `stop()` only nils the reference — `pollTask = nil` does **not** cancel; the loop (`while true`, no `Task.isCancelled` check) runs forever. Fix: `pollTask?.cancel()` before nil-ing, loop on `while !Task.isCancelled`, capture `[weak self]` + `guard let self else { return }`.
3. *Self-retain-cycle through the stored closure.* `onLevel = { level in self.render(level) }` makes the object own a closure that owns the object — it can never deinit even after fixes 1–2. Fix: `onLevel = { [weak self] level in self?.render(level) }`.

Proof: instantiate, `start`, `stop`, nil the last reference; Debug Memory Graph should show zero `WaveformPreviewController` instances.

**Exercise 4 (sketch).** Move registration into a private `register(keyCode:modifiers:)`, a private `unregister()` mirroring `deinit`, then:

```swift
func rebind(keyCode: UInt32, modifiers: HotkeyModifiers) {
    unregister()
    register(keyCode: keyCode, modifiers: modifiers)
    UserDefaults.standard.set(keyCode, forKey: "quill.hotkey.key")
    UserDefaults.standard.set(modifiers.rawValue, forKey: "quill.hotkey.mods")
}
```
Capture UI: on "Record shortcut" click, `captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.finishCapture(event); return nil }` (returning `nil` swallows the keystroke); `finishCapture` translates `event.keyCode`/`event.modifierFlags` (map `.command → cmdKey` etc.), calls `rebind`, and **removes the monitor immediately** — the same leak rule as always. Note only the *local* monitor (needing no permission) is required because the popover is focused during capture.

</details>

---

## 6. Checkpoint checklist

Before moving to Component 2 (AudioRecorderEngine), verify every box:

- [ ] App launches with no Dock icon, no window; speech-bubble icon appears in the menu bar.
- [ ] Left-click toggles the popover; clicking anywhere else closes it; no flicker on the status button itself.
- [ ] Record button disabled until *both* permissions granted; banner rows disappear as each is granted; mic prompt shows your usage string.
- [ ] After denying mic then tapping Grant, System Settings opens at the right pane (no dead re-prompt).
- [ ] ⌥⌘R toggles recording while another app is frontmost; the keystroke does not reach that app.
- [ ] Recording state shows red `record.circle.fill` in the menu bar and a running mm:ss timer in the popover.
- [ ] Level meters render, animate smoothly with simulated values, and report accessibility values in VoiceOver.
- [ ] Vault selection survives quit + relaunch (security-scoped bookmark restored).
- [ ] Instruments → Leaks: zero leaks after 20× popover open/close and 20× record toggle.
- [ ] Debug Memory Graph: one `AppState`, one `HotkeyManager`, zero live event-monitor blocks with the popover closed.
- [ ] `applicationWillTerminate` removes the status item, monitor, and hotkey; recording timer Task provably stops (add a print in the loop and watch it cease).
- [ ] You can explain, out loud, why each `[weak self]` in the codebase is there — and what would leak without it.
