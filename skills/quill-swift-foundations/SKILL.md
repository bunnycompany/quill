---
name: quill-swift-foundations
description: Module 0 for the Quill project — Swift and Xcode from absolute zero, scoped to exactly what Quill needs. Covers Swift syntax essentials, optionals, structs/classes/actors, Swift Concurrency (async/await, Task, cancellation), SwiftUI basics, creating the Xcode project, and entitlements/Info.plist for a menubar app. Use before any other Quill module when the learner has no prior macOS or Swift experience.
---

# Quill Module 0 — Swift & Xcode Foundations (Zero to Ready)

This module takes you from *never having opened Xcode* to having a running,
correctly-configured menubar app skeleton called **HelloQuill**, plus the Swift
knowledge every later Quill module assumes. Nothing here requires prior
programming-language-specific knowledge; basic ideas like "a variable holds a
value" are explained as we go.

**Target environment:** Xcode 16+, Swift 5.10+, macOS 15 (Sequoia), Apple Silicon.

**Companion files in this folder:**

| File | What it is |
|---|---|
| `code/HelloQuillApp.swift` | Complete, typed-in-by-you app entry point (menubar skeleton) |
| `code/LevelMeterModel.swift` | Complete observable model demonstrating actors, Task, cancellation |
| `code/HelloQuill.entitlements` | Entitlements file you will add to the project |
| `code/Info-plist-additions.md` | Exact Info.plist keys Quill needs and why |
| `cheatsheets/swift-syntax.md` | One-page Swift syntax reference |
| `cheatsheets/concurrency.md` | One-page Swift Concurrency reference |

---

## 1. Concepts — every term from zero

### 1.1 What is Swift?

**Swift** is Apple's programming language. It is *compiled*: a program called
the compiler translates your source text into machine code before it runs, and
refuses to build if it finds type errors. This matters for Quill: many bugs
(passing text where a number belongs, forgetting a value might be missing) are
caught *before* the app ever runs.

### 1.2 What is Xcode?

**Xcode** is Apple's IDE (Integrated Development Environment) — a single app
containing the code editor, the Swift compiler, the build system, the debugger,
and **Instruments** (the profiler Quill uses to verify zero memory leaks).
You get it free from the Mac App Store. After installing, open Terminal and run
`xcode-select --install` if prompted for command-line tools.

### 1.3 Values, variables, and types

```swift
let appName = "Quill"      // let = constant, can never change. Prefer let.
var sampleCount = 0        // var = variable, can be reassigned.
sampleCount = 4800         // fine
// appName = "Other"       // compile error — appName is a let
```

Every value has a **type**. Swift usually *infers* it (`"Quill"` is a `String`,
`0` is an `Int`), but you can write it explicitly: `let rate: Double = 48_000`.
Core types you'll meet constantly in Quill:

- `Int` — whole numbers (buffer sizes, sample counts)
- `Double` / `Float` — decimals (`Float` is what audio samples use)
- `String` — text (transcripts, markdown)
- `Bool` — `true`/`false` (isRecording)
- `[Float]` — an *array* of floats (a chunk of audio)
- `[String: String]` — a *dictionary* mapping keys to values (YAML frontmatter)

### 1.4 Functions and control flow

```swift
/// Converts a linear audio level (0...1) to decibels.
func decibels(fromLevel level: Float) -> Float {
    if level <= 0 { return -80 }        // silence floor
    return 20 * log10(level)
}

let db = decibels(fromLevel: 0.5)       // argument label reads like English
```

`fromLevel` is an **argument label** — Swift call sites read like sentences.
`-> Float` declares the return type. Loops: `for sample in samples { ... }`,
`while isRecording { ... }`. `guard` is an early-exit `if` you will see
everywhere in Quill:

```swift
func process(buffer: [Float]) {
    guard !buffer.isEmpty else { return }   // bail out early; rest of the
    // ... buffer is guaranteed non-empty here
}
```

### 1.5 Optionals — "this value might not exist"

The single most important Swift concept. A `String?` ("optional String") is
either a `String` or `nil` (nothing). Swift *forces* you to handle the nil case
— this is why Swift apps rarely crash on missing values.

```swift
var vaultPath: String? = nil            // user hasn't picked a vault yet

// Unwrapping — the safe ways:
if let path = vaultPath {               // 1. if-let: runs only when non-nil
    print("Vault at \(path)")
}

guard let path = vaultPath else {       // 2. guard-let: early exit, then
    print("No vault selected")          //    `path` usable for the rest
    return                              //    of the function
}

let display = vaultPath ?? "No vault"   // 3. ?? — default if nil

let count = vaultPath?.count            // 4. optional chaining: count is Int?,
                                        //    nil if vaultPath was nil
```

`vaultPath!` (**force unwrap**) crashes if nil. In Quill code it is banned
except in tests. If you're tempted to write `!`, use `guard let` instead.

### 1.6 Structs, classes, enums — modeling data

**Struct** — a *value type*. Assigning copies it. No shared mutable state, so
no surprises. Default choice in Swift.

```swift
struct MeetingNote {
    let date: Date
    let durationSeconds: Int
    var attendees: [String]

    var titleLine: String {                    // computed property
        "Meeting — \(attendees.count) attendees"
    }
}
```

**Class** — a *reference type*. Assigning shares the same object. Needed when
identity matters or when interfacing with Apple frameworks (AppKit classes like
`NSStatusItem` are classes). Classes are where **memory leaks** live — see §4.

**Enum** — a fixed set of cases, often with attached data. Quill uses enums for
state machines:

```swift
enum RecorderState {
    case idle
    case recording(startedAt: Date)     // case with associated value
    case failed(message: String)
}

switch state {                          // switch must cover every case —
case .idle:                             // the compiler checks this for you
    print("Ready")
case .recording(let startedAt):
    print("Recording since \(startedAt)")
case .failed(let message):
    print("Error: \(message)")
}
```

**Protocol** — a contract of capabilities a type promises to provide
(like an interface). SwiftUI's `View` is a protocol; so is `Codable`
(convert to/from stored data).

### 1.7 Closures

A **closure** is a function value you can store and pass around. Apple APIs use
them heavily as callbacks:

```swift
let doubled = samples.map { $0 * 2 }    // $0 = first argument, shorthand
button.onTap = { print("tapped") }      // stored for later — this is where
                                        // retain cycles hide (see §4)
```

### 1.8 Swift Concurrency — async/await, Task, actors

Quill records audio, transcribes, and updates UI *simultaneously*. Swift
Concurrency is the modern, compiler-checked way to do that.

- **`async` function** — a function that can pause without blocking a thread:

  ```swift
  func transcribe(_ audio: [Float]) async throws -> String { ... }
  ```

- **`await`** — marks the pause point when calling an async function:

  ```swift
  let text = try await transcribe(chunk)
  ```

- **`Task { ... }`** — starts async work from synchronous code (e.g., a button
  tap). A Task can be stored and **cancelled**:

  ```swift
  let job = Task { try await transcribe(chunk) }
  job.cancel()                          // cooperative — the task must check
  ```

  Cancellation is *cooperative*: inside long loops you write
  `try Task.checkCancellation()` or `if Task.isCancelled { break }`. Quill's
  "zero leaks on stop" guarantee depends on every long-running task honoring
  cancellation and cleaning up in `defer` blocks.

- **`actor`** — like a class, but the compiler guarantees only one piece of
  code touches its state at a time. Perfect for Quill's circular audio buffer,
  which is written by the audio thread and read by the transcriber:

  ```swift
  actor SampleStore {
      private var samples: [Float] = []
      func append(_ chunk: [Float]) { samples.append(contentsOf: chunk) }
      func drain() -> [Float] { defer { samples.removeAll() }; return samples }
  }
  // from outside: await store.append(chunk)   — await required
  ```

- **`@MainActor`** — a special global actor for the UI. AppKit and SwiftUI
  state must only be touched on the main actor. Mark UI-facing classes
  `@MainActor` and the compiler enforces it.

- **`AsyncStream`** — an async sequence you can `for await` over; Quill uses it
  to pipe audio levels from the engine to the UI.

### 1.9 SwiftUI in three sentences

**SwiftUI** is Apple's declarative UI framework: you describe *what the UI
looks like for a given state*, and the framework re-renders when state changes.
State lives in `@State` (view-local) or in an `@Observable` model object the
view reads. You never manually "update a label" — you change the data, the UI
follows.

```swift
struct RecordButton: View {
    @State private var isRecording = false
    var body: some View {
        Button(isRecording ? "Stop" : "Record") {
            isRecording.toggle()
        }
    }
}
```

### 1.10 AppKit terms Quill needs

SwiftUI can't yet do everything a menubar app needs, so Quill uses a little
**AppKit** (the older macOS UI framework):

- **`NSStatusItem`** — the icon in the menubar (top-right of the screen).
- **`NSPopover`** — the small floating panel that opens under it.
- **`NSApplicationDelegateAdaptor` / `AppDelegate`** — a class that receives
  app lifecycle events (launched, quitting) where we create the status item.
- **`LSUIElement`** — an Info.plist flag meaning "menubar-only app: no Dock
  icon, no main window."

### 1.11 Sandbox, entitlements, Info.plist, TCC

- **App Sandbox** — macOS confines your app to its own container; you must
  *declare* every capability. Declarations live in the **entitlements** file
  (`.entitlements`, an XML plist). Quill needs: microphone
  (`com.apple.security.device.audio-input`) and user-selected file access
  (`com.apple.security.files.user-selected.read-write`) so the user can pick
  their Obsidian vault. **No network entitlement — that is the privacy-first
  guarantee, enforced by the OS.**
- **Info.plist** — the app's metadata dictionary. Quill needs
  `NSMicrophoneUsageDescription` (the sentence shown in the permission dialog)
  and `LSUIElement = YES`.
- **TCC** — the macOS consent system ("Transparency, Consent, Control") that
  shows "Quill would like to access the microphone" the first time you use it.
  ScreenCaptureKit (system audio) triggers Screen Recording consent similarly.

---

## 2. Architecture — where Module 0 fits in Quill

```
QuillApp (SwiftUI @main) ── AppDelegate (NSStatusItem + NSPopover)
        │                              │
        ▼                              ▼
  PopoverView (SwiftUI)  ←— @Observable models —→  AudioRecorderEngine (actor)
        │                                                   │
        ▼                                                   ▼
  DiarizationEngine / LocalAIParsingEngine  →  ObsidianExporter  →  vault .md
                          │
                          ▼
                    SQLite history
```

Everything in this diagram is built in later modules — but **every arrow uses a
concept from this module**: models are structs/actors, arrows between
concurrent parts are async/await + AsyncStream, the UI is SwiftUI reading
`@Observable` state on `@MainActor`, and the whole app boots through the
`@main` + AppDelegate pattern you build below. Module 0's deliverable,
**HelloQuill**, *is* component 1 (QuillApp/AppDelegate/PopoverView) in
embryonic form, with a fake level meter standing in for the real audio engine.

---

## 3. Step-by-step implementation walkthrough

### Step 1 — Create the project

1. Open Xcode → **File ▸ New ▸ Project…**
2. Choose **macOS ▸ App**. Next.
3. Product Name: `HelloQuill`. Interface: **SwiftUI**. Language: **Swift**.
   Testing System: None (for now). Storage: None.
4. Save it anywhere (e.g. `~/Desktop/quill/HelloQuill`).
5. Press **⌘R** (Run). A blank window appears — you've built a Mac app.
   Quit it (⌘Q in the running app).

### Step 2 — Project settings for a menubar app

1. Click the blue project icon at the top of the left sidebar → target
   **HelloQuill** → **Info** tab.
2. Hover a row, press **+**, add key `Application is agent (UIElement)`
   (raw key: `LSUIElement`), type Boolean, value **YES**. This removes the
   Dock icon and menu bar takeover.
3. **Signing & Capabilities** tab → **+ Capability** → add **App Sandbox** if
   not present. Under App Sandbox tick **Audio Input** and, under File Access,
   set **User Selected File** to **Read/Write**. (This edits the
   `.entitlements` file — compare yours against `code/HelloQuill.entitlements`.)
4. Still in **Info**, add key `Privacy - Microphone Usage Description`
   (`NSMicrophoneUsageDescription`) with value:
   `Quill records meeting audio locally. Nothing leaves your Mac.`
   Full list of keys the real Quill needs is in `code/Info-plist-additions.md`.

### Step 3 — The app entry point and AppDelegate

Delete the template's `ContentView.swift` content mentally — we replace
everything. Open `HelloQuillApp.swift` and type in the complete file from
**`code/HelloQuillApp.swift`** (reproduced here with annotations):

```swift
import SwiftUI   // SwiftUI views + the App protocol
import AppKit    // NSStatusItem, NSPopover — menubar machinery

// MARK: - App entry point
// `@main` tells Swift "start the program here". The App protocol's `body`
// describes the app's scenes. A menubar app has no windows, so we use
// Settings (an empty, never-shown scene) purely to satisfy the protocol.
@main
struct HelloQuillApp: App {
    // Bridges SwiftUI's lifecycle to an AppKit delegate object. SwiftUI
    // creates one AppDelegate and keeps it alive for the app's lifetime.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }   // no real windows; the popover is our UI
    }
}

// MARK: - AppDelegate
// @MainActor: everything here touches UI, so the compiler pins it to the
// main actor. NSObject + NSApplicationDelegate are AppKit requirements.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Strong references — if we didn't store these, ARC (automatic reference
    // counting) would deallocate the status item immediately and the icon
    // would vanish. "My menubar icon disappears" is almost always this bug.
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = LevelMeterModel()   // shared app state (Step 4)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Claim a slot in the system menubar.
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)

        // 2. Give it an icon (SF Symbols ship with macOS — no asset needed).
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Quill")
            button.action = #selector(togglePopover(_:)) // click handler
            button.target = self                          // ...on this object
        }
        statusItem = item   // keep it alive (see comment above)

        // 3. Configure the popover to host our SwiftUI view.
        popover.behavior = .transient      // clicking elsewhere closes it
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model))  // AppKit<->SwiftUI bridge
    }

    // @objc + #selector is the (old) Objective-C callback mechanism AppKit
    // still uses for button actions.
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button,
                         preferredEdge: .minY)   // open below the icon
            // Bring the popover key so buttons inside respond immediately.
            popover.contentViewController?.view.window?
                .makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()   // cancel any running tasks — cleanup discipline
    }
}

// MARK: - PopoverView (SwiftUI)
struct PopoverView: View {
    // The model is a class annotated @Observable; SwiftUI re-renders this
    // view automatically whenever a property the body reads changes.
    var model: LevelMeterModel

    var body: some View {
        VStack(spacing: 12) {
            Text("HelloQuill")
                .font(.headline)

            // Live level meter: a bar whose width follows model.level (0...1).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.isRunning ? .green : .gray)
                        .frame(width: geo.size.width
                                        * CGFloat(model.level))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.05), value: model.level)

            Button(model.isRunning ? "Stop" : "Record") {
                model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut("r")   // ⌘R while popover is open

            Button("Quit HelloQuill") {
                NSApp.terminate(nil)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 260)
    }
}
```

### Step 4 — The model: Task, actor, cancellation, @Observable

Create a new file (**File ▸ New ▸ File… ▸ Swift File**) named
`LevelMeterModel.swift` and type in **`code/LevelMeterModel.swift`**. This file
is a miniature of Quill's real AudioRecorderEngine pattern: an actor holding
bounded data, a Task producing values, `@MainActor` state for the UI, and
clean cancellation. Read every comment — this is the heart of the module.

### Step 5 — Run and verify

1. **⌘R.** No window appears — correct! Look at the menubar for the waveform
   icon. Click it → popover opens.
2. Click **Record** → the meter animates with a fake signal. Click **Stop** →
   it freezes then resets. Reopen the popover — state persists (the model
   lives in the AppDelegate, not the view).
3. **Leak check (the Quill discipline, from day one):**
   Product ▸ Profile (⌘I) → choose the **Leaks** template → record → start and
   stop the meter ten times → the Leaks track must stay clear, and the
   allocation graph must plateau, not climb. If memory climbs each start/stop
   cycle, a Task is not being cancelled — recheck `stop()`.

---

## 4. Common pitfalls & memory-leak traps

1. **The vanishing status item.** `NSStatusBar.system.statusItem(...)` returns
   an object *you* must keep a strong reference to (a stored property). A local
   variable inside `applicationDidFinishLaunching` deallocates at the end of
   the function and the icon disappears.

2. **Retain cycles via closures.** A class whose stored closure captures
   `self` strongly, while `self` stores the closure, leaks both — forever.
   Fix with a capture list:

   ```swift
   timerHandler = { [weak self] in
       guard let self else { return }   // upgrade weak to strong, or bail
       self.tick()
   }
   ```

   Rule of thumb: any closure *stored* by an object owned by `self`, that
   mentions `self`, needs `[weak self]`. Closures that run once and are
   discarded (e.g. the body of a `Task` that finishes) hold `self` only until
   completion — that's a temporary extension of lifetime, not a leak, **unless
   the task never finishes** (see next).

3. **Immortal Tasks.** `Task { for await x in stream { ... } }` over a stream
   that never ends will never finish, so it retains everything it captured
   until app quit. Always (a) store the `Task` handle, (b) `cancel()` it in
   `stop()`/`deinit`, and (c) make the loop cancellation-aware
   (`Task.isCancelled` / `try Task.checkCancellation()`), with cleanup in
   `defer`. This is Quill's number-one rule.

4. **Touching UI off the main actor.** Mutating `@Observable` UI state from a
   background task gives runtime warnings (or crashes in AppKit). Mark UI
   models `@MainActor`. If you see
   "Publishing changes from background threads", this is why.

5. **Unbounded buffers.** `samples.append(contentsOf:)` forever = memory climbs
   forever. Quill mandates *bounded* circular buffers: fixed capacity, old data
   overwritten. `LevelMeterModel.swift` shows the bounded pattern.

6. **Force unwraps (`!`) and force try (`try!`).** Each is a crash waiting for
   a nil/error. Use `guard let` / `do-catch`. Exception: none, in Quill app code.

7. **Forgetting usage-description keys.** Accessing the mic without
   `NSMicrophoneUsageDescription` doesn't show a dialog — the app is killed by
   the OS instantly. Same for Screen Recording consent with ScreenCaptureKit.

8. **Actor deadlock-ish surprises.** Never do heavy blocking work (file I/O,
   `sleep`) inside `@MainActor` code — the UI freezes. Hop to a plain `Task` or
   a non-main actor for work, and come back only to publish results.

9. **Testing sandbox file access wrong.** The sandbox lets you write only
   where the user *picked* via NSOpenPanel (security-scoped). Hard-coding
   `~/Obsidian/...` fails silently in a sandboxed build. Later modules cover
   security-scoped bookmarks; for now, know why the entitlement is
   "user-selected", not "any file".

---

## 5. Exercises (easy → hard)

**Exercise 1 (easy) — Optionals warm-up.** Write a function
`func vaultName(from path: String?) -> String` that returns the last path
component (the folder name) of the vault path, or `"No vault"` if the path is
nil or empty. Use `guard let`, no `!`. Test it with `nil`, `""`, and
`"/Users/me/Obsidian"`.

**Exercise 2 (medium) — Enum state machine.** Replace `isRunning: Bool` in
`LevelMeterModel` with `enum MeterState { case idle, running(startedAt: Date) }`.
Update `start()`, `stop()`, and `PopoverView` (button title should become
"Stop (Ns)" showing elapsed whole seconds — computed at render time is fine).
The switch in the view must be exhaustive with no `default`.

**Exercise 3 (hard) — Bounded circular buffer actor.** Write
`actor CircularBuffer` storing at most `capacity` `Float` values:
`append(_ chunk: [Float])` keeps only the newest `capacity` samples;
`snapshot() -> [Float]` returns them oldest-first; memory must never exceed
capacity regardless of input size. Then write a test harness `Task` that
appends 1_000 random chunks and asserts the count never exceeds capacity.

**Exercise 4 (stretch) — Cancellation cleanup proof.** Add a
`print("meter task exiting cleanly")` inside a `defer` in the model's meter
task. Verify it prints on Stop *and* on Quit. Then run Instruments ▸ Leaks
during 20 start/stop cycles and screenshot the flat allocation graph.

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1:**

```swift
func vaultName(from path: String?) -> String {
    guard let path, !path.isEmpty else { return "No vault" }
    // URL handles trailing slashes and edge cases for us.
    return URL(filePath: path).lastPathComponent
}
```

**Exercise 2 (key parts):**

```swift
enum MeterState: Equatable {
    case idle
    case running(startedAt: Date)
}

// In LevelMeterModel (replace isRunning):
private(set) var state: MeterState = .idle

func start() {
    guard state == .idle else { return }
    state = .running(startedAt: .now)
    // ... launch task as before
}

func stop() {
    meterTask?.cancel()
    meterTask = nil
    level = 0
    state = .idle
}

// In PopoverView:
var buttonTitle: String {
    switch model.state {
    case .idle:
        return "Record"
    case .running(let startedAt):
        let secs = Int(Date.now.timeIntervalSince(startedAt))
        return "Stop (\(secs)s)"
    }
}
```

**Exercise 3:**

```swift
actor CircularBuffer {
    private var storage: [Float]
    private var writeIndex = 0        // next slot to write
    private var count = 0             // how many valid samples (≤ capacity)
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        // Pre-allocate once — no growth ever, the bounded guarantee.
        self.storage = [Float](repeating: 0, count: capacity)
    }

    func append(_ chunk: [Float]) {
        for sample in chunk {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            count = min(count + 1, capacity)
        }
    }

    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity {                       // hasn't wrapped yet
            return Array(storage[0..<count])
        }
        // Wrapped: oldest sample is at writeIndex.
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }
}

// Harness:
let buffer = CircularBuffer(capacity: 4_800)
Task {
    for _ in 0..<1_000 {
        let chunk = (0..<Int.random(in: 1...10_000)).map { _ in
            Float.random(in: -1...1)
        }
        await buffer.append(chunk)
        let n = await buffer.snapshot().count
        assert(n <= 4_800, "buffer exceeded capacity")
    }
    print("bounded buffer verified")
}
```

**Exercise 4:** put `defer { print("meter task exiting cleanly") }` as the
first line inside the `Task { ... }` body in `start()`. It prints on Stop
because `cancel()` makes the loop exit and the task body return; on Quit
because `applicationWillTerminate` calls `model.stop()`. If it does not print
on Quit, you forgot the `applicationWillTerminate` hook.

</details>

---

## 6. Checkpoint checklist

Before moving to Module 1 (AudioRecorderEngine), confirm every box:

- [ ] I can explain `let` vs `var`, and why `String?` differs from `String`.
- [ ] I can unwrap an optional three ways (`if let`, `guard let`, `??`) and I
      know why `!` is banned in Quill.
- [ ] I can say when to choose a struct vs a class vs an actor, and what
      `@MainActor` guarantees.
- [ ] I can start async work with `Task`, store its handle, cancel it, and
      make a loop cancellation-aware with cleanup in `defer`.
- [ ] HelloQuill builds and runs with **no Dock icon** and a working menubar
      popover (icon click toggles it; transient dismissal works).
- [ ] The level meter animates on Record and resets on Stop; state survives
      closing/reopening the popover.
- [ ] The project has App Sandbox enabled with **only** audio-input and
      user-selected read/write entitlements — no network.
- [ ] `Info.plist` has `LSUIElement = YES` and
      `NSMicrophoneUsageDescription` set.
- [ ] Instruments ▸ Leaks shows zero leaks and flat memory across 10+
      start/stop cycles.
- [ ] Exercise 3's bounded buffer passes its harness (count never exceeds
      capacity).
