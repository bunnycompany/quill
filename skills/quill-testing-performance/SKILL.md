---
name: quill-testing-performance
description: >
  Zero-to-undergrad teaching module for verifying the Quill macOS menubar app:
  XCTest + Swift Testing setup, memory-leak detection with Instruments and the
  `leaks` tool, CPU profiling, testing Swift Concurrency cancellation cleanup,
  audio-pipeline test fixtures, and a manual QA checklist for menubar /
  recording / Obsidian rendering. Assumes Xcode 16+, Swift 5.10+, macOS 15.
---

# Quill Module: Testing, Memory-Leak Detection & Performance Verification

You are learning how to *prove* that Quill — a privacy-first, local-only macOS
menubar app that records meetings and exports markdown to Obsidian — is
correct, leak-free, and fast. This module assumes **zero prior macOS or Swift
experience**. Every term is explained the first time it appears.

---

## 1. Concepts (from zero)

### 1.1 What is a "test" and why Quill cares so much

A test is a small program that runs part of your app with known inputs and
checks the output. Quill's principles — *tiny & performant*, *zero memory
leaks*, *local privacy first* — are all claims. Tests turn claims into checks
that run on every build.

### 1.2 XCTest

**XCTest** is Apple's original testing framework, shipped with **Xcode**
(Apple's IDE — the app you write and build Swift code in). You write a class
that subclasses `XCTestCase`; every method whose name starts with `test` is
run automatically. Assertions look like `XCTAssertEqual(a, b)`. XCTest also
provides *performance* tests (`measure { }`) and UI tests. It is Objective-C
flavored: class-based, camelCase `testFooDoesBar` names.

### 1.3 Swift Testing (the new framework)

**Swift Testing** is Apple's modern framework (Xcode 16+, `import Testing`).
Instead of subclasses you write free functions or struct methods annotated
with `@Test`, and one macro `#expect(...)` replaces the dozens of
`XCTAssert*` variants. It supports *parameterized* tests (run one test body
over many inputs) and runs tests in parallel by default. **Both frameworks can
coexist in one test target** — we use Swift Testing for logic tests and keep
XCTest for performance measurement (`measure`) and UI tests, which Swift
Testing does not yet cover.

### 1.4 Test target, test bundle, host app

An Xcode project is organized into **targets** (things that get built: the
app, a framework, a test bundle). A **unit-test target** builds your tests
into a bundle that Xcode injects into a running copy of the app (the *host
application*) or runs standalone. For Quill, logic like the circular buffer or
the markdown formatter should live in code that can run *without* the menubar
UI so tests are fast and don't need Screen Recording permission.

### 1.5 Memory: ARC, retain cycles, and leaks

Swift manages memory with **ARC** (Automatic Reference Counting): every class
instance carries a count of how many references point at it; at zero it is
freed (`deinit` runs). A **retain cycle** is A→B→A: counts never reach zero,
memory is never freed — a **leak**. Classic Quill traps:

- A closure stored by an object that captures `self` strongly
  (`audioEngine.installTap { self.process($0) }` — the tap holds `self`,
  `self` holds the engine).
- A long-lived `Task { self.doWork() }` that never finishes and captures
  `self`.
- Delegate properties declared `var delegate: Foo` instead of
  `weak var delegate: Foo?`.

`weak` references don't increment the count and become `nil` when the target
dies; `unowned` is like weak but crashes if used after death (use only when
lifetime is guaranteed).

**Abandoned memory** is subtler: still referenced, never used again — e.g. an
audio buffer array that only grows. Quill's bounded circular buffer exists
precisely to prevent this.

### 1.6 Instruments

**Instruments** is Apple's profiler, bundled with Xcode (Xcode ▸ Open
Developer Tool ▸ Instruments, or Product ▸ Profile, ⌘I). Key templates:

- **Leaks** — snapshots the heap periodically and flags unreachable-but-
  allocated blocks; shows retain cycles as a graph.
- **Allocations** — every allocation over time. Use **generation marking**
  ("Mark Generation" button): mark, do an action (record + stop), mark again;
  growth between generations that shouldn't persist = abandoned memory.
- **Time Profiler** — samples all thread stacks ~1000×/sec; the heaviest
  stacks tell you where CPU goes. Quill targets low single-digit % CPU while
  recording.

### 1.7 The `leaks` and `heap` command-line tools

`leaks <pid|process-name>` inspects a *running* process for leaked blocks —
scriptable, perfect for CI-ish checks. Set the environment variable
`MallocStackLogging=1` when launching the app to get allocation backtraces in
the report. `heap <pid>` lists live objects by class — great for asserting
"exactly zero `AudioRecorderEngine` instances alive after stop".

### 1.8 Swift Concurrency & cancellation (what we must test)

Swift Concurrency gives you `async`/`await` functions and `Task` — a unit of
async work. Cancellation is **cooperative**: `task.cancel()` only sets a
flag; the task must notice via `Task.isCancelled` / `try Task.checkCancellation()`
and clean up. An **actor** is a class-like type that serializes access to its
state, eliminating data races. **`AsyncStream`** adapts callback-style APIs
(like audio taps) into `for await` sequences; its `onTermination` handler is
where cleanup belongs.

For Quill, "cancellation cleanup" means: cancel a recording mid-flight and
verify the tap is removed, the engine stops, buffers are released, and no
task lingers. Untested cancellation paths are the #1 source of leaks in
concurrency code.

### 1.9 Test doubles and fixtures

A **fixture** is known input data — for audio, a deterministic
`AVAudioPCMBuffer` (a chunk of PCM samples: raw amplitude values at a sample
rate like 48 kHz). We *generate* fixtures in code (sine tones, silence,
alternating "speakers") rather than shipping .wav files: deterministic, tiny,
privacy-clean. A **fake/mock** replaces a real dependency (the microphone,
the filesystem) with a controllable stand-in — tests must never require a
real mic or Screen Recording permission.

---

## 2. Architecture: where verification fits in Quill

```
QuillApp (menubar UI) ──▶ AudioRecorderEngine ──▶ CircularBuffer ──▶ DiarizationEngine
                                                                      │
        SQLite history ◀── ObsidianExporter ◀── LocalAIParsingEngine ◀┘

Verification layer (this module):
  QuillTests/            Swift Testing + XCTest bundle
    Fixtures/            AudioFixtures.swift  (generated PCM buffers)
    Helpers/             LeakCheckHelpers.swift (deinit-tracking)
    CircularBufferTests, CancellationTests, ExporterTests, PerformanceTests
  Scripts/               leakcheck.sh (leaks/heap CLI harness)
  QA/                    manual-qa-checklist.md
```

Design rule that makes all of this possible: **engines are plain Swift types
with injected dependencies** (protocols for audio source, clock, filesystem),
so unit tests exercise them headlessly; only the manual QA checklist touches
the real mic, ScreenCaptureKit, and Obsidian.

---

## 3. Step-by-step implementation walkthrough

### Step 0 — Add a test target

In Xcode: File ▸ New ▸ Target… ▸ **Unit Testing Bundle**, name it
`QuillTests`, Testing System: **Swift Testing (with XCTest support)**. Run
tests with **⌘U**.

### Step 1 — A deinit-tracking leak helper

The cheapest leak detector needs no Instruments: hold the object `weak`, drop
the strong reference, assert it became `nil`.

```swift
// QuillTests/Helpers/LeakCheckHelpers.swift
import Testing
import XCTest

/// Swift Testing flavor: run `body` with a fresh instance, then verify the
/// instance deallocates once the strong reference is gone.
/// `T: AnyObject` restricts this to classes — structs can't leak by cycle.
func expectDeallocation<T: AnyObject>(
    of makeInstance: () -> T,
    after body: (T) async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async rethrows {
    weak var weakRef: T?          // does NOT keep the object alive
    do {
        let instance = makeInstance()
        weakRef = instance
        try await body(instance)  // use it; strong ref dies at scope end
    }
    // Give any pending Tasks / autorelease pools one hop to unwind.
    await Task.yield()
    #expect(weakRef == nil,
            "Instance leaked — a retain cycle is keeping it alive",
            sourceLocation: sourceLocation)
}

/// XCTest flavor: registers a teardown block, so it checks at test end.
extension XCTestCase {
    func assertNoLeak(_ instance: AnyObject,
                      file: StaticString = #filePath, line: UInt = #line) {
        addTeardownBlock { [weak instance] in
            XCTAssertNil(instance, "Instance leaked", file: file, line: line)
        }
    }
}
```

Annotations: `weak var` is the whole trick — if a cycle exists, the object
survives the scope and `weakRef` stays non-nil. `#_sourceLocation` makes the
failure point at the *caller's* line, not the helper's.

### Step 2 — Audio fixtures (deterministic PCM)

See `AudioFixtures.swift` in this folder for the full annotated file. Core
idea:

```swift
let tone   = AudioFixtures.sineBuffer(frequency: 440, duration: 1.0)  // "speech"
let quiet  = AudioFixtures.silenceBuffer(duration: 0.5)               // VAD off
let meeting = AudioFixtures.twoSpeakerSequence()  // 440 Hz vs 220 Hz turns
```

Sine tones at distinct frequencies are enough to test VAD thresholds, level
meters (RMS of a sine of amplitude a is a/√2 ≈ 0.707a — an *exact* expected
value!), and speaker-change segmentation, with zero real audio.

### Step 3 — Test the circular buffer (correctness + boundedness)

```swift
// QuillTests/CircularBufferTests.swift
import Testing
@testable import Quill   // @testable: access internal (non-public) symbols

@Suite("CircularBuffer")
struct CircularBufferTests {

    @Test("stores and reads back in FIFO order")
    func fifo() {
        var buf = CircularBuffer<Int>(capacity: 4)
        buf.write([1, 2, 3])
        #expect(buf.read(3) == [1, 2, 3])
    }

    @Test("never exceeds capacity — overwrites oldest",
          arguments: [4, 16, 1024])          // parameterized: 3 runs
    func bounded(capacity: Int) {
        var buf = CircularBuffer<Int>(capacity: capacity)
        buf.write(Array(0..<(capacity * 3))) // write 3× capacity
        #expect(buf.count == capacity)       // memory stayed bounded
        // Oldest survivor is exactly (2×capacity): earlier items overwritten.
        #expect(buf.read(1) == [capacity * 2])
    }

    @Test("empty read returns empty, not crash")
    func emptyRead() {
        var buf = CircularBuffer<Int>(capacity: 8)
        #expect(buf.read(5).isEmpty)
    }
}
```

`@Suite` groups tests; `arguments:` turns one body into three named test
cases. Boundedness *is* Quill's abandoned-memory guarantee — test it directly.

### Step 4 — Test Swift Concurrency cancellation cleanup

This is the heart of the module. We model the recorder's contract with a
protocol so tests inject a fake source (no mic, no permissions):

```swift
// Quill (app target): the seam
protocol AudioSource: Sendable {
    /// Stream of PCM buffers; MUST honor termination by tearing down capture.
    func buffers() -> AsyncStream<AVAudioPCMBuffer>
    func stop() async
}
```

```swift
// QuillTests/CancellationTests.swift
import Testing
import AVFoundation
@testable import Quill

/// Fake source: emits fixture buffers on a timer, records teardown.
final class FakeAudioSource: AudioSource, @unchecked Sendable {
    // @unchecked Sendable: we guarantee thread-safety ourselves via the lock.
    private let lock = NSLock()
    private var _stopped = false
    var stopped: Bool { lock.withLock { _stopped } }

    func buffers() -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(AudioFixtures.sineBuffer(
                        frequency: 440, duration: 0.02))
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
            // onTermination fires when the consumer's task is cancelled
            // or the stream is dropped — THE cleanup hook.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async { lock.withLock { _stopped = true } }
}

@Suite("Recorder cancellation cleanup")
struct CancellationTests {

    @Test("cancelling mid-recording stops the source and frees the engine")
    func cancelCleansUp() async throws {
        let source = FakeAudioSource()

        await expectDeallocation(of: { AudioRecorderEngine(source: source) },
                                 after: { engine in
            let recording = Task { await engine.record() }  // start
            try await Task.sleep(for: .milliseconds(100))   // let it run
            recording.cancel()                              // user hits Stop
            _ = await recording.value                       // wait for unwind
            #expect(source.stopped, "cancel must call source.stop()")
        })
        // expectDeallocation additionally proves the engine deinit'd:
        // no Task or tap is still retaining it.
    }

    @Test("cancellation within 250 ms (no stuck await)")
    func cancelIsPrompt() async throws {
        let engine = AudioRecorderEngine(source: FakeAudioSource())
        let recording = Task { await engine.record() }
        try await Task.sleep(for: .milliseconds(50))

        let t0 = ContinuousClock.now
        recording.cancel()
        _ = await recording.value
        #expect(ContinuousClock.now - t0 < .milliseconds(250))
    }
}
```

And the engine pattern being verified — cleanup lives in `defer`, so it runs
on *every* exit path including cancellation:

```swift
// Quill (app target)
actor AudioRecorderEngine {
    private let source: AudioSource
    private var buffer = CircularBuffer<AVAudioPCMBuffer>(capacity: 512)
    init(source: AudioSource) { self.source = source }

    func record() async {
        defer {                       // runs even when the Task is cancelled
            Task { await source.stop() }
        }
        for await pcm in source.buffers() {   // loop ends on cancellation:
            if Task.isCancelled { break }     // the stream finishes because
            buffer.write([pcm])               // onTermination cancelled the
        }                                     // producer task
    }
}
```

### Step 5 — Exporter tests without touching a real vault

Inject the directory; use a per-test temp dir; assert the exact markdown.

```swift
// QuillTests/ExporterTests.swift
import Testing
import Foundation
@testable import Quill

@Suite("ObsidianExporter")
struct ExporterTests {
    /// Fresh temp dir per test — Swift Testing runs in parallel, so tests
    /// must never share a path.
    func makeVault() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillTestVault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("writes Dataview-compatible YAML frontmatter")
    func frontmatter() throws {
        let vault = makeVaultOrFail()
        defer { try? FileManager.default.removeItem(at: vault) }

        let note = MeetingNote(
            title: "Sync",
            date: ISO8601DateFormatter().date(from: "2026-08-12T10:00:00Z")!,
            duration: 1800,
            attendees: ["Speaker 1", "Speaker 2"],
            actionItems: ["Ship the exporter tests"],
            takeaways: ["Fixtures beat real audio"],
            segments: [])

        let exporter = ObsidianExporter(vaultRoot: vault)
        let fileURL = try exporter.export(note)

        #expect(fileURL.lastPathComponent == "2026-08-12-Sync.md")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.hasPrefix("---\n"))               // frontmatter fence
        #expect(text.contains("date: 2026-08-12"))
        #expect(text.contains("duration: 30m"))
        #expect(text.contains("- \"Speaker 1\""))      // YAML list item
        #expect(text.contains("## Action Items"))
    }

    func makeVaultOrFail() -> URL { try! makeVault() }
}
```

### Step 6 — CPU performance tests (XCTest side)

```swift
// QuillTests/PerformanceTests.swift
import XCTest
@testable import Quill

final class PerformanceTests: XCTestCase {
    /// Budget: processing 1 s of 48 kHz audio must take a small fraction of
    /// 1 s of CPU, or Quill can't keep up in real time.
    func testBufferThroughput() {
        let buffers = (0..<50).map { _ in
            AudioFixtures.sineBuffer(frequency: 440, duration: 1.0)
        }
        measure(metrics: [XCTCPUMetric(), XCTMemoryMetric(), XCTClockMetric()]) {
            var ring = CircularBuffer<AVAudioPCMBuffer>(capacity: 128)
            for b in buffers { ring.write([b]) }
        }
        // First run: Xcode shows the result — click it and "Set Baseline".
        // Future runs FAIL if they regress past the baseline. That is your
        // CPU-regression gate, checked into source control.
    }
}
```

### Step 7 — CLI leak harness (`leaks` / `heap`)

`Scripts/leakcheck.sh` in this folder builds Quill, launches it with
`MallocStackLogging=1`, and runs `leaks`/`heap` against the live process.
Run it after any change to the audio pipeline:

```bash
./skills/quill-testing-performance/leakcheck.sh   # exits non-zero on leaks
```

### Step 8 — Instruments sessions (manual, but scripted procedure)

1. Product ▸ Profile (⌘I) ▸ **Leaks** template. Record ▸ start/stop a Quill
   recording 5×. Any red ✕ in the Leaks track = fail; open the cycle graph.
2. Switch to **Allocations**. Mark Generation → record 30 s → stop → Mark
   Generation. Persistent growth in generation B that isn't the saved note ≈
   abandoned memory (suspect: unbounded arrays, un-finished streams).
3. **Time Profiler** while recording 60 s: sort by weight, "Invert Call
   Tree" off, look at heaviest self-weight symbols. Budget: < 5 % CPU steady
   state on Apple Silicon.

Full click-by-click procedure with what-good-looks-like screenshots described
in `instruments-cheatsheet.md`.

### Step 9 — Manual QA

Run `manual-qa-checklist.md` (in this folder) before every release: menubar
behavior, permissions flows, recording, diarization sanity, Obsidian
rendering (frontmatter renders as Properties, Dataview query finds the note),
and privacy checks (no network connections: verify with
`lsof -i -p <pid>` returning nothing).

---

## 4. Common pitfalls & memory-leak traps

1. **`self` captured in audio tap / stream closures.** `installTap` and
   `AsyncStream` closures outlive the call. Use `[weak self]` and bail on
   `nil`. Symptom: engine never deinits → `expectDeallocation` fails.
2. **Cleanup after `await` instead of in `defer`.** Code after a cancelled
   `await` may never run (e.g. `Task.sleep` throws on cancel). Put teardown
   in `defer` — it runs on every path.
3. **Forgetting `continuation.onTermination`.** The consumer cancels, but the
   producer task keeps yielding forever: a task leak *and* CPU burn.
4. **Testing with real devices/permissions.** Tests that need mic/Screen
   Recording hang in CI and prompt dialogs. Inject `AudioSource` fakes.
5. **Shared temp paths under parallel Swift Testing.** Two tests writing
   `…/TestVault` corrupt each other. Always UUID the path.
6. **`Task { … }` fire-and-forget in `deinit`/teardown** capturing `self`
   strongly — resurrects the object mid-deinit or delays dealloc so the weak
   check flakes. `await Task.yield()` in the helper mitigates; structure code
   so `deinit` needs no async work.
7. **Trusting "no leaks" from the Leaks instrument alone.** Leaks only finds
   *unreachable* memory. Abandoned-but-reachable growth (the growing array)
   needs Allocations generation marking. Use both.
8. **Performance tests without baselines.** `measure {}` that never fails is
   decoration. Set baselines and commit them.
9. **`unowned` in audio callbacks.** Audio threads can fire after teardown →
   crash. Prefer `weak` + guard.
10. **Asserting exact floating-point audio values.** Compare RMS/levels with
    a tolerance: `#expect(abs(rms - 0.707) < 0.01)`.

---

## 5. Exercises (easy → hard)

**Exercise 1 (easy).** Write a Swift Testing test that verifies
`AudioFixtures.silenceBuffer(duration: 0.5)` at 48 kHz contains exactly
24 000 frames and that every sample is `0`.

**Exercise 2 (medium).** The level meter shows RMS. Write a parameterized
test over amplitudes `[0.1, 0.5, 1.0]` asserting the RMS of a fixture sine
equals `amplitude / sqrt(2)` within `0.005`. (Write the `rms(of:)` helper
too.)

**Exercise 3 (medium-hard).** Introduce a deliberate retain cycle: give
`FakeAudioSource` a `var onBuffer: (() -> Void)?` and set
`source.onBuffer = { engine.tick() }` while the engine holds the source.
Show `expectDeallocation` failing, then fix it with `[weak engine]` and show
it passing.

**Exercise 4 (hard).** Write a cancellation *stress* test: start and cancel
`AudioRecorderEngine.record()` 100 times in a loop; assert every iteration's
engine deallocates and `FakeAudioSource.stopped` is true each time, and the
whole loop finishes in < 10 s. Then run it under the Thread Sanitizer
(scheme ▸ Diagnostics ▸ Thread Sanitizer) and confirm zero race reports.

<details>
<summary><strong>Answers</strong></summary>

**Answer 1**

```swift
@Test func silenceIsAllZeros() {
    let buf = AudioFixtures.silenceBuffer(duration: 0.5) // 48 kHz default
    #expect(buf.frameLength == 24_000)
    let samples = UnsafeBufferPointer(start: buf.floatChannelData![0],
                                      count: Int(buf.frameLength))
    #expect(samples.allSatisfy { $0 == 0 })
}
```

**Answer 2**

```swift
func rms(of buf: AVAudioPCMBuffer) -> Float {
    let n = Int(buf.frameLength)
    let p = UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)
    let sumSq = p.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumSq / Float(n)).squareRoot()
}

@Test(arguments: [Float(0.1), 0.5, 1.0])
func rmsOfSine(amplitude: Float) {
    let buf = AudioFixtures.sineBuffer(frequency: 440, duration: 1.0,
                                       amplitude: amplitude)
    #expect(abs(rms(of: buf) - amplitude / Float(2).squareRoot()) < 0.005)
}
```

**Answer 3** — the broken version leaks because the source (owned by the
engine) stores a closure strongly capturing the engine:

```swift
// LEAKS: engine → source → onBuffer closure → engine
source.onBuffer = { engine.tick() }
// FIX: break the cycle with weak capture
source.onBuffer = { [weak engine] in engine?.tick() }
```

The test is exactly `cancelCleansUp` from Step 4 with the closure wired up;
before the fix `#expect(weakRef == nil)` fails, after the fix it passes.

**Answer 4**

```swift
@Test func cancellationStress() async throws {
    let t0 = ContinuousClock.now
    for _ in 0..<100 {
        let source = FakeAudioSource()
        await expectDeallocation(of: { AudioRecorderEngine(source: source) },
                                 after: { engine in
            let t = Task { await engine.record() }
            try await Task.sleep(for: .milliseconds(10))
            t.cancel()
            _ = await t.value
            #expect(source.stopped)
        })
    }
    #expect(ContinuousClock.now - t0 < .seconds(10))
}
```

Enable Thread Sanitizer: Product ▸ Scheme ▸ Edit Scheme… ▸ Test ▸
Diagnostics ▸ check "Thread Sanitizer", re-run ⌘U. Races appear as runtime
issues in the Issue navigator; the target is zero.

</details>

---

## 6. Checkpoint checklist

- [ ] `QuillTests` target exists; ⌘U runs Swift Testing *and* XCTest tests.
- [ ] I can explain ARC, a retain cycle, and the difference between a leak
      and abandoned memory.
- [ ] `expectDeallocation` helper compiles and catches a deliberate cycle
      (Exercise 3 done both broken and fixed).
- [ ] Circular buffer tests pass, including the 3× overwrite boundedness test.
- [ ] Cancellation tests pass: prompt (<250 ms), `stop()` called, engine
      deallocates; stress test (Exercise 4) passes under Thread Sanitizer.
- [ ] Exporter tests pass in parallel (UUID temp vaults), frontmatter exact.
- [ ] Performance baseline set and committed; a deliberate 2× slowdown makes
      ⌘U fail.
- [ ] `leakcheck.sh` runs clean against a live Quill process.
- [ ] One Instruments session each of Leaks, Allocations (generation
      marking), and Time Profiler completed; steady-state CPU < 5 %.
- [ ] Full `manual-qa-checklist.md` pass, including `lsof -i` showing no
      network sockets (privacy check).
