---
name: quill-audio-capture
description: Zero-to-undergrad teaching module for building Quill's AudioRecorderEngine — AVAudioEngine mic capture, ScreenCaptureKit system-audio loopback, PCM formats, sample-rate conversion, a bounded circular buffer with backpressure, CAF/WAV writing, and a zero-leak Swift Concurrency lifecycle.
---

# Quill Module 2: AudioRecorderEngine

**Goal:** by the end of this module you can build, from an empty file, the component of Quill that captures microphone audio *and* system ("what the Mac is playing") audio, converts both into one canonical PCM format, pushes samples through a bounded circular buffer, and writes them to disk — with zero memory leaks and clean cancellation.

**Prerequisites:** none beyond basic programming (variables, functions, loops). Every macOS/Swift term is explained below. Assumes Xcode 16+, Swift 5.10+, macOS 15.

**Privacy constraint (non-negotiable in Quill):** all audio stays on the machine. No network calls, no cloud APIs, no analytics. Files land only in locations the user chose.

---

## 1. Concepts — every term from zero

### 1.1 What is digital audio? (PCM)
A microphone produces a continuously varying voltage. A computer samples that voltage many thousands of times per second and stores each measurement as a number. That list of numbers is **PCM** — Pulse-Code Modulation. Three parameters describe any PCM stream:

- **Sample rate** — measurements per second. 44,100 Hz (CD), 48,000 Hz (default on modern Macs), 16,000 Hz (what most speech-recognition models want). Higher = more fidelity, more data.
- **Bit depth / sample format** — how each number is stored. macOS audio APIs overwhelmingly use **Float32** (a 32-bit floating-point number between −1.0 and +1.0). WAV files traditionally use **Int16**.
- **Channel count** — 1 = mono, 2 = stereo. Speech pipelines want mono.

One second of Float32 mono at 48 kHz = 48,000 × 4 bytes = 192 KB. A one-hour meeting ≈ 675 MB at 48 kHz, or 225 MB at 16 kHz. This is why we downsample early.

**Interleaved vs. non-interleaved:** stereo can be stored as `LRLRLR…` (interleaved, one buffer) or as two separate buffers `LLL…` + `RRR…` (non-interleaved). Apple's engine APIs default to non-interleaved Float32; file formats are usually interleaved. Converters handle this — you just need to know the distinction exists so mismatched formats don't surprise you.

### 1.2 The frameworks you will touch

| Framework | What it is | What Quill uses it for |
|---|---|---|
| **AVFoundation** | Apple's high-level media framework | `AVAudioEngine` (mic capture), `AVAudioConverter` (resampling), `AVAudioFile` (writing CAF/WAV) |
| **Core Audio** | The low-level C audio layer under AVFoundation | `AudioStreamBasicDescription` (format struct), understanding what AVFoundation wraps |
| **ScreenCaptureKit** | macOS 12.3+ framework for capturing screen *and, since macOS 13, system audio* — no kernel extensions, no third-party drivers like BlackHole | System-audio loopback (`SCStream` with `capturesAudio = true`) |
| **CoreMedia** | Timing + sample-buffer plumbing shared by AV frameworks | `CMSampleBuffer`, the container ScreenCaptureKit hands you audio in |
| **Swift Concurrency** | Language-level `async/await`, `Task`, `actor` | Structured lifecycle: start/stop, draining, cancellation cleanup |

### 1.3 AVAudioEngine in one paragraph
`AVAudioEngine` is a graph of audio nodes. For capture you only need one node it gives you for free: `engine.inputNode`, which represents the current input device (mic). You *install a tap* on it — a closure the engine calls repeatedly, from a **real-time audio thread**, handing you an `AVAudioPCMBuffer` of freshly captured samples (typically 10–100 ms worth). Rules of the tap closure:

- It runs on a high-priority audio thread. **Never block it**: no locks that can wait long, no allocation-heavy work, no `await`, no file I/O, no `print` in production.
- Do the minimum — convert format, copy into a preallocated ring buffer — and get out.

### 1.4 ScreenCaptureKit audio in one paragraph
`SCStream` is normally used to record the screen. Set `configuration.capturesAudio = true` and add an output for `.audio`, and macOS gives you the *mixed system output* (everything the speakers would play — Zoom's remote participants, a YouTube video, etc.) as `CMSampleBuffer`s. Set `excludesCurrentProcessAudio = true` so Quill never records itself. Requires the **Screen & System Audio Recording** permission (System Settings → Privacy & Security); the mic separately requires **Microphone** permission via `AVCaptureDevice.requestAccess(for: .audio)`.

### 1.5 AVAudioConverter (sample-rate conversion)
Mic gives you e.g. 48 kHz non-interleaved Float32; SCStream gives you whatever you configured (we ask for 48 kHz stereo). Your diarization/transcription engines want **16 kHz mono Float32**. `AVAudioConverter(from:to:)` performs resampling, channel mixing, and interleave changes in one object. Important: a converter has internal filter state — create **one per stream and reuse it**; creating one per buffer produces clicks at buffer boundaries and wastes CPU.

### 1.6 Circular (ring) buffer and backpressure
A **circular buffer** is a fixed-size array with a write index and a read index that wrap around. Producer (audio tap) writes; consumer (a Swift `Task`) reads. Because the size is fixed, memory is **bounded** — a stalled consumer can never balloon RAM, which is a Quill core principle.

**Backpressure** = what happens when the producer outruns the consumer. Two sane policies:
- **Drop-oldest** (overwrite): live meters, monitoring. Latest data matters most.
- **Drop-newest** (reject the write, count it): recording to disk. You must *know* you lost data, so we increment an `overrunCount` the UI can surface.

Quill uses drop-newest for the record path and exposes the overrun counter.

### 1.7 CAF vs WAV
- **WAV**: universal, header states a fixed size, classically limited to 4 GB, Int16 or Float32 PCM.
- **CAF** (Core Audio Format): Apple's container, streams indefinitely (no 4 GB limit, header doesn't need a final size), holds any Core Audio format. `AVAudioFile` writes both. Quill records to CAF (safe for long meetings) and can export WAV for interoperability.

### 1.8 Swift Concurrency vocabulary used here
- `async/await` — a function can suspend without blocking a thread.
- `Task { }` — a unit of async work you can **cancel**. Cancellation is *cooperative*: the task must check `Task.isCancelled` or call `try Task.checkCancellation()`.
- `actor` — a class-like type where all mutable state is accessed serially; the compiler prevents data races. Our engine is an actor.
- `AsyncStream` — a bridge that lets callback-style APIs (like an audio tap) feed an `for await` loop.
- **Structured cleanup** — every `start()` must have a `stop()` that tears down *everything it created*, and cancellation must run the same teardown (`defer` / `withTaskCancellationHandler`).

### 1.9 Memory-management vocabulary
- **ARC** — Automatic Reference Counting. Objects are freed when the last strong reference disappears.
- **Retain cycle** — A strongly holds B, B strongly holds A → neither is ever freed. The classic audio bug: the engine retains a tap closure, the closure captures `self` strongly, `self` retains the engine. Break it with `[weak self]`.
- **Unowned vs weak** — `weak` becomes `nil` when the object dies (safe); `unowned` crashes if used after death. In audio callbacks, prefer `weak` + early-return.

---

## 2. Architecture — where this sits in Quill

```
 ┌────────────────────────── QuillApp (menubar) ─────────────────────────┐
 │  PopoverView ──(start/stop, levels)──► AudioRecorderEngine (actor)    │
 └───────────────────────────────────────────────────────────────────────┘
        Mic ──► AVAudioEngine.inputNode tap ──┐
                                              ├─► AVAudioConverter ─► 16 kHz mono Float32
 System audio ─► SCStream(.audio) CMSampleBuf ┘            │
                                                           ▼
                                              BoundedRingBuffer (fixed 10 s)
                                                           │  (drain Task, for await)
                                        ┌──────────────────┼──────────────────┐
                                        ▼                  ▼                  ▼
                                  AVAudioFile (CAF)   live RMS level    DiarizationEngine
                                  on disk             → PopoverView     (Module 3 consumes
                                                                        the same samples)
```

Contract with neighbors:
- **Upstream (UI, Module 1):** calls `await engine.start(configuration:)`, `await engine.stop()`; observes `levelStream` for meters and `overrunCount` for a "dropped audio" warning badge.
- **Downstream (Module 3):** reads the finished CAF path from `stop()`'s return value, or subscribes to `sampleStream` for live processing. Everything is 16 kHz mono Float32 — the *canonical format* the rest of Quill assumes.
- **SQLite (Module 5):** stores the recording path + duration that `stop()` returns.

---

## 3. Step-by-step implementation walkthrough

Create a new file group `AudioCapture/` in the Quill Xcode project. You will write three files (full versions also ship alongside this skill as `BoundedRingBuffer.swift`, `AudioRecorderEngine.swift`):

### Step 0 — Project settings (one-time)
1. Target → *Signing & Capabilities* → **App Sandbox** → check **Audio Input**. If sandboxed, also enable a user-selected file access entitlement for the vault.
2. `Info.plist`: add `NSMicrophoneUsageDescription` — e.g. "Quill records meeting audio locally to transcribe it. Nothing leaves your Mac."
3. First run of system-audio capture will prompt for **Screen & System Audio Recording**; nothing to add in plist for SCK on macOS 15, but the user must approve it in System Settings.

### Step 1 — The canonical format
Everything downstream speaks one format. Define it once:

```swift
import AVFoundation

enum QuillAudio {
    /// 16 kHz, mono, Float32, non-interleaved — what diarization/ASR want.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!  // Force-unwrap is safe: these parameters are always representable.
}
```

`AVAudioFormat` is a wrapper around the Core Audio struct `AudioStreamBasicDescription`. The initializer returns an optional because absurd parameters (0 channels) would fail; ours cannot.

### Step 2 — The bounded ring buffer
Read `BoundedRingBuffer.swift` in this folder. Key decisions, annotated:

- **Fixed capacity chosen at init** (`10 s × 16 000 = 160 000` floats = 640 KB). Bounded memory, Quill principle #1.
- **`OSAllocatedUnfairLock`** guards indices. An unfair lock is a *non-blocking-in-practice* spinny lock: the critical sections here are a few dozen nanoseconds (index math + `memcpy`), so it is safe to take on the real-time audio thread. An `actor` would *not* be safe there — actors require `await`, and you cannot await on the audio thread.
- **Drop-newest on overflow** + `overrunCount`. The write returns how many samples it actually accepted.
- **Single-producer/single-consumer assumption documented.** Two taps (mic + system) do NOT write to one ring directly — each source gets its own ring; mixing happens in the drain task. (Simpler variant used in the walkthrough: mix in the tap via a preallocated scratch buffer. Both shown.)

### Step 3 — Mic capture with AVAudioEngine
Read `AudioRecorderEngine.swift`, section *MARK: Mic*. The flow:

```swift
let input = avEngine.inputNode
let hwFormat = input.outputFormat(forBus: 0)          // e.g. 48 kHz, 1–2 ch, Float32
micConverter = AVAudioConverter(from: hwFormat, to: QuillAudio.canonicalFormat)

input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
    self?.ingest(buffer, via: self?.micConverter, into: self?.micRing)
}
try avEngine.start()
```

Annotations:
- `bufferSize: 4096` is a *request*; the OS may deliver other sizes. Never hard-code assumptions about `buffer.frameLength`.
- `format: hwFormat` — you must tap in the node's *native* format; asking the tap itself to resample is unreliable. Convert yourself.
- `[weak self]` — the engine strongly retains the tap closure until `removeTap(onBus:)`. Capturing `self` strongly here is *the* Quill-class retain cycle.
- The tap body only converts + ring-writes. No allocation beyond the converter's preallocated output buffer (see Step 5).

### Step 4 — System audio with ScreenCaptureKit
Read section *MARK: System audio*. Flow:

```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
let filter = SCContentFilter(display: display, excludingWindows: [])   // audio needs *a* filter

let cfg = SCStreamConfiguration()
cfg.capturesAudio = true
cfg.excludesCurrentProcessAudio = true       // never record Quill itself
cfg.sampleRate = 48_000
cfg.channelCount = 2
cfg.width = 2; cfg.height = 2                // minimize the (unused) video path
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 video fps, we ignore frames

let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
try await stream.startCapture()
```

The delegate callback hands you a `CMSampleBuffer`. Convert it to `AVAudioPCMBuffer` with `withAudioBufferList` (zero-copy view into the CMSampleBuffer), then run it through the *system* converter into the *system* ring. Same ingest path as the mic — this symmetry is deliberate.

- Why a content filter with no excluded windows? SCK's API is screen-centric; audio capture still requires a filter object. Excluding nothing = capture all system audio.
- The `SCStreamDelegate` `stream(_:didStopWithError:)` fires if the user revokes permission mid-recording — forward it so `stop()` runs and the file is finalized rather than corrupted.

### Step 5 — Ingest: convert without allocating per callback
The one clever bit. `AVAudioConverter.convert(to:error:withInputFrom:)` uses a *pull* model: you give it an output buffer and a closure that supplies input when asked.

```swift
private nonisolated func ingest(_ src: AVAudioPCMBuffer,
                                converter: AVAudioConverter,
                                scratch: AVAudioPCMBuffer,   // preallocated once
                                ring: BoundedRingBuffer) {
    var fed = false
    var err: NSError?
    let status = converter.convert(to: scratch, error: &err) { _, outStatus in
        if fed { outStatus.pointee = .noDataNow; return nil }  // exactly one buffer per call
        fed = true
        outStatus.pointee = .haveData
        return src
    }
    guard status != .error, scratch.frameLength > 0,
          let ch = scratch.floatChannelData else { return }
    ring.write(ch[0], count: Int(scratch.frameLength))         // mono ⇒ channel 0
}
```

- `scratch` is allocated once in `start()` sized for the worst case (`4096 × 16000/48000` rounded up, ×2 margin). **Zero allocations on the hot path.**
- Returning `.noDataNow` after one buffer makes the converter process exactly what we have and return — the streaming idiom.
- `nonisolated` — this runs on the audio thread, outside the actor. It touches only lock-protected (`ring`) or single-thread-confined (`converter`, `scratch`) state. This is the *documented escape hatch* and the part you must reason about most carefully.

### Step 6 — Drain task: mix, meter, write to disk
An async task owned by the actor:

```swift
drainTask = Task { [micRing, sysRing, levelContinuation] in
    var mix = [Float](repeating: 0, count: 3200)   // 200 ms scratch, allocated once
    var mic = [Float](repeating: 0, count: 3200)
    var sys = [Float](repeating: 0, count: 3200)
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))     // pacing; wakes 10×/s
        let n = min(micRing.read(into: &mic), sysRing.read(into: &sys))
        guard n > 0 else { continue }
        for i in 0..<n { mix[i] = max(-1, min(1, mic[i] + sys[i])) }  // sum + clip
        await self?.append(samples: mix, count: n)          // actor hop: AVAudioFile write
        levelContinuation.yield(Self.rms(mix, n))           // live meter
    }
}
```

- Reading both rings and taking `min` keeps the two sources loosely aligned; a production diarizer would timestamp instead (Exercise 3).
- `AVAudioFile` writing happens **inside the actor** (`append`), never on the audio thread. Disk latency spikes are absorbed by the ring — that is what it is for.
- The `while !Task.isCancelled` loop is the cooperative-cancellation checkpoint. `stop()` cancels this task and `await drainTask?.value` before closing the file, guaranteeing no write-after-close.

### Step 7 — Lifecycle: start / stop / deinit
```swift
func stop() async throws -> RecordingResult {
    guard state == .recording else { throw AudioCaptureError.notRecording }
    state = .stopping
    avEngine.inputNode.removeTap(onBus: 0)   // 1. stop producers first
    avEngine.stop()
    try? await scStream?.stopCapture()
    drainTask?.cancel()                      // 2. then drain
    _ = await drainTask?.result             // wait for the loop to exit cleanly
    await flushRemaining()                   // 3. empty the rings into the file
    levelContinuation.finish()               // 4. end streams so `for await` loops exit
    let result = RecordingResult(url: fileURL, duration: duration,
                                 droppedSamples: micRing.overrunCount + sysRing.overrunCount)
    audioFile = nil                          // 5. AVAudioFile finalizes header on release
    reset()
    state = .idle
    return result
}
```
Order matters: producers off → consumer drained → file closed → streams finished. Reversing 1 and 2 loses tail audio; skipping 4 leaks any UI task `for await`-ing the level stream.

`AVAudioFile` has no `close()` — releasing the last reference finalizes it. Setting `audioFile = nil` *is* the close.

### Step 8 — Verify (Quill's standard bar)
1. **Build** clean, no warnings.
2. **Leaks:** Xcode → Product → Profile → *Leaks* instrument; record/stop 10 times; zero leaks, memory graph flat.
3. **CPU:** *Time Profiler* while recording: engine should sit under ~3% on Apple Silicon.
4. **Cancellation:** start recording, immediately `stop()`; start, then cancel the enclosing task — assert file is valid (open the CAF in QuickTime) and `state == .idle`.
5. **Backpressure:** temporarily add `Task.sleep(for: .seconds(1))` in the drain loop, confirm `overrunCount` climbs and memory does *not*.

---

## 4. Common pitfalls & memory-leak traps

1. **Strong `self` in `installTap`** — the #1 leak. Engine → closure → self → engine cycle. Always `[weak self]`; always `removeTap` in `stop()` *and* in `deinit`-adjacent cleanup.
2. **Blocking the audio tap** — a mutex held across file I/O, an `os_log` with string interpolation, a Swift dictionary allocation — each can cause audible glitches. Tap = convert + ring write, nothing else.
3. **`await`/actor calls from the tap** — impossible to do safely; the compiler will fight you and any workaround (semaphores!) deadlocks or glitches. The ring buffer *is* the bridge between the real-time world and async world.
4. **New `AVAudioConverter` per buffer** — clicks at boundaries (lost filter state) + allocation churn. One converter per source, created in `start()`.
5. **Assuming the hardware format** — AirPods report 24 kHz mic; external interfaces report 96 kHz; channel counts vary. Always read `inputNode.outputFormat(forBus: 0)` at start; also handle the format *changing* (device switch) → `AVAudioEngineConfigurationChange` notification → restart taps.
6. **Unbounded queues as "buffers"** — `DispatchQueue.async { array.append(...) }` grows without limit when the consumer stalls. Quill forbids it; the ring's fixed capacity is the whole point.
7. **Forgetting `continuation.finish()`** — an `AsyncStream` that never finishes keeps every `for await` consumer task alive forever: a *task leak*, invisible to the Leaks instrument but visible in the memory graph as lingering Tasks.
8. **Zombie drain task** — cancelling without awaiting `drainTask?.result` lets the last loop iteration race the file close → crash or truncated file. Cancel *then await*.
9. **Recording Quill's own output** — forgetting `excludesCurrentProcessAudio = true` produces feedback once Quill ever plays audio (e.g., a stop chime).
10. **Sandbox/entitlement surprises** — missing *Audio Input* entitlement makes `installTap` deliver silence (not an error!). Missing screen-recording permission makes `startCapture()` throw. Test both denial paths.
11. **CMSampleBuffer lifetime** — pointers from `withAudioBufferList` are valid only inside the closure. Copy into the ring *inside* it; never stash the pointer.
12. **4 GB WAV ceiling** — a 6-hour 48 kHz stereo Float32 recording exceeds it. Record CAF; export WAV only on request.

---

## 5. Exercises

### Exercise 1 (easy) — Meter math
Write `static func rms(_ samples: [Float], _ count: Int) -> Float` returning the root-mean-square of the first `count` samples, and `static func decibels(fromRMS rms: Float) -> Float` returning `20·log10(rms)` clamped to −80 dB floor. Explain in one sentence why the UI wants dB rather than raw RMS.

### Exercise 2 (medium) — Drop-oldest mode
Extend `BoundedRingBuffer` with a `policy` enum (`.dropNewest`, `.dropOldest`). In `.dropOldest`, a write that would overflow advances the read index (discarding the oldest samples) so the newest always fit. Keep `overrunCount` accurate in both modes. Write a small test: capacity 8, write 6, write 6 — assert contents under each policy.

### Exercise 3 (hard) — Timestamped alignment
The `min(micRead, sysRead)` mixing trick drifts if one source stalls. Redesign: give each ring a companion "frames-written-since-start" counter; in the drain task, compute each source's stream position, and when one source is ahead by > 100 ms, insert silence into the other (zero-fill) instead of stalling. Sketch the data structures and write the drain-loop diff. (This mirrors what the DiarizationEngine needs for speaker timestamps.)

### Exercise 4 (stretch) — WAV export
Using `AVAudioFile(forWriting:settings:)` with `[AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]`, write `exportWAV(from caf: URL, to wav: URL) async throws` that streams the CAF through in 32k-frame chunks (bounded memory!) and converts Float32→Int16 via the file's processing format. Verify with `afinfo` in Terminal.

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
```swift
static func rms(_ samples: [Float], _ count: Int) -> Float {
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<count { sum += samples[i] * samples[i] }
    return (sum / Float(count)).squareRoot()
}
static func decibels(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return -80 }
    return max(-80, 20 * log10(rms))
}
```
Why dB: human loudness perception is logarithmic, so a linear RMS meter would slam between "barely moving" and "pegged"; dB spreads the useful range evenly.

**Exercise 2** — core of the changed `write`:
```swift
if free < count {
    switch policy {
    case .dropNewest:
        overrun += count - free
        countToWrite = free
    case .dropOldest:
        let need = count - free
        readIndex = (readIndex + need) % capacity   // discard oldest
        stored -= need
        overrun += need
        countToWrite = count
    }
}
```
Test expectation, capacity 8, writes of [0…5] then [6…11]: `.dropNewest` retains `0,1,2,3,4,5,6,7`(indices 6,7 from second write) — i.e. first 6 plus first 2 of the second, overrun 4. `.dropOldest` retains the *last* 8 values `4,5,6,7,8,9,10,11`, overrun 4.

**Exercise 3** — sketch:
```swift
struct TimedRing { let ring: BoundedRingBuffer; private(set) var framesIngested: Int64 }
// tap: ring.write(...); framesIngested += accepted  (atomic Int64)
// drain:
let micPos = micTimed.framesIngested - Int64(micRing.available)   // frames already consumed... 
let lead = micPos - sysPos
if lead > 1600 {                        // mic ahead > 100 ms @16k
    sysRead = zeroFill(&sys, count: n)  // treat missing system audio as silence
} else if lead < -1600 {
    micRead = zeroFill(&mic, count: n)
}
```
The key insight: *time keeps flowing even when a source doesn't* — silence is the truthful representation of a stalled source, and it keeps downstream speaker timestamps monotonic.

**Exercise 4** — skeleton:
```swift
func exportWAV(from caf: URL, to wav: URL) async throws {
    let inFile = try AVAudioFile(forReading: caf)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
    ]
    let outFile = try AVAudioFile(forWriting: wav, settings: settings)
    let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: 32_768)!
    while inFile.framePosition < inFile.length {
        try Task.checkCancellation()
        try inFile.read(into: buf)
        guard buf.frameLength > 0 else { break }
        try outFile.write(from: buf)   // AVAudioFile converts Float32→Int16 internally
    }
}
```
`afinfo out.wav` should report "LEI16, 16000 Hz, 1 ch". Bounded memory because only one 32k-frame buffer ever exists.

</details>

---

## 6. Checkpoint checklist

Before moving to Module 3 (DiarizationEngine), confirm:

- [ ] I can explain sample rate, bit depth, channels, and interleaving without notes.
- [ ] I can say why the audio tap must never block, allocate, or `await` — and what the ring buffer's job is.
- [ ] Mic recording works: start → speak → stop → CAF plays back in QuickTime.
- [ ] System-audio recording works: play a video, record, hear it in the CAF; Quill's own audio is excluded.
- [ ] Both permissions' *denial* paths are handled with a user-visible error, not silence or a crash.
- [ ] `overrunCount` is observable and memory stays flat when I artificially stall the drain task.
- [ ] Leaks instrument shows zero leaks over 10 record/stop cycles; no lingering `Task`s in the memory graph.
- [ ] `stop()` after cancellation mid-recording still produces a valid, playable file.
- [ ] Time Profiler shows < ~3% CPU while recording on Apple Silicon.
- [ ] No network entitlement, no outbound calls anywhere in this component (grep for `URLSession`).
- [ ] Exercises 1–3 completed (4 optional).

**Reference files in this folder:** `BoundedRingBuffer.swift` (complete buffer), `AudioRecorderEngine.swift` (complete engine), `pcm-cheatsheet.md` (formats, sizes, API crib notes).
