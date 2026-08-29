---
name: quill-diarization-transcription
description: Zero-to-undergrad teaching module for building Quill's DiarizationEngine — voice activity detection (VAD), acoustic speaker embeddings, online clustering into Speaker 1/2/N, on-device transcription with SFSpeechRecognizer, and merging diarization with transcript timestamps. Swift 5.10+, macOS 15, local/privacy-first, zero third-party dependencies.
---

# Quill Module 3a — DiarizationEngine: "Who said what, and when?"

You are building the part of Quill that takes raw recorded audio and answers two questions:

1. **Transcription** — *what* was said (words + timestamps).
2. **Diarization** — *who* said it (Speaker 1, Speaker 2, … + timestamps).

Everything runs **on-device**. No audio ever leaves the Mac. No third-party
frameworks — only Apple's `AVFoundation`, `Accelerate`, and `Speech`.

This document assumes **zero** prior macOS/Swift experience. Every term is
explained the first time it appears. The complete, compiling source lives in
[`code/`](code/) and is walked through piece by piece below. A one-page
reference is in [`CHEATSHEET.md`](CHEATSHEET.md).

---

## 1. Concepts (from zero)

### 1.1 Digital audio in 60 seconds

Sound is a pressure wave. A microphone turns it into a voltage; the computer
**samples** that voltage thousands of times per second. Each sample is one
number (we use `Float`, −1.0…+1.0). Key vocabulary:

| Term | Meaning | Quill's value |
|---|---|---|
| **Sample** | One amplitude measurement | a `Float` |
| **Sample rate** | Samples per second (Hz) | 16 000 Hz for analysis |
| **PCM** | "Pulse-Code Modulation" — the plain array-of-samples format | `AVAudioPCMBuffer` |
| **Frame** | One sample per channel at one instant | mono ⇒ frame == sample |
| **Window / frame (DSP sense)** | A short slice of samples analyzed together | 25 ms = 400 samples |
| **Hop** | How far the window slides each step | 10 ms = 160 samples |

Why 16 kHz? Human speech content lives below ~8 kHz; by the
**Nyquist theorem** a 16 kHz sample rate captures everything up to 8 kHz.
Speech models (including Apple's) are trained at 16 kHz, and it's 3× less
data to process than the 48 kHz the mic delivers. Quill's
`AudioRecorderEngine` (Module 2) hands us 16 kHz mono `Float` PCM.

### 1.2 The frameworks you'll touch

- **AVFoundation** — Apple's audio/video framework. We use `AVAudioPCMBuffer`
  (a container of PCM samples + format metadata) and `AVAudioFormat`.
- **Accelerate / vDSP** — Apple's SIMD-optimized math library. Gives us FFT,
  vector multiply/add, mean, etc., running on the CPU's vector units. We use
  it for feature extraction so diarization costs almost no CPU.
- **Speech** — the framework containing `SFSpeechRecognizer`.
  Setting `requiresOnDeviceRecognition = true` forces Apple's local model:
  nothing is sent to Apple's servers. This is Quill's privacy contract.
- **Swift Concurrency** — `async/await`, `actor`, `Task`, `AsyncStream`.
  An **actor** is a class whose state can only be touched by one task at a
  time — the compiler enforces it, eliminating data races. `Task` cancellation
  is *cooperative*: you must check `Task.isCancelled` / call
  `Task.checkCancellation()` yourself and clean up.

### 1.3 The DSP pipeline vocabulary

- **RMS energy** — root-mean-square of a window: "how loud is it".
- **Zero-crossing rate (ZCR)** — how often the waveform crosses zero.
  Fricatives ("s", "f") have high ZCR; silence and hum have low.
- **VAD (Voice Activity Detection)** — classifying each window as
  *speech* or *non-speech*. Ours: adaptive energy threshold + ZCR gate +
  hangover smoothing (explained in §3.2).
- **FFT (Fast Fourier Transform)** — converts a window of samples
  (time domain) into magnitudes per frequency (frequency domain).
- **Mel scale** — a warped frequency axis matching human hearing
  (finer resolution at low frequencies). A **mel filterbank** pools FFT bins
  into ~40 perceptual bands.
- **Log-mel features / embedding** — `log(mel energies)`. Averaged over a
  segment and normalized, this vector is a cheap **speaker embedding**: a
  fixed-length fingerprint of a voice's timbre. Two windows of the *same*
  speaker produce nearby vectors; different speakers, distant ones.
  (Production systems use neural embeddings — x-vectors/ECAPA — but the
  clustering machinery is identical, and our engine hides the embedder
  behind a protocol so you can swap in a Core ML model later.)
- **Cosine similarity** — `dot(a,b) / (‖a‖·‖b‖)`, ranges −1…1.
  Measures the *angle* between embeddings, ignoring loudness. ≥ ~0.85 for
  our features ⇒ "same speaker".
- **Online clustering** — assigning each new segment to a speaker *as it
  arrives*, without seeing the future: compare to each known speaker's
  **centroid** (running mean embedding); if best similarity ≥ threshold,
  assign & update centroid; else mint "Speaker N+1".

### 1.4 Transcription vocabulary

- **`SFSpeechRecognizer`** — the recognizer object, tied to a locale.
- **`SFSpeechURLRecognitionRequest`** — "transcribe this audio file".
  We write the session to a temporary WAV and use this (simplest reliable
  path for finished recordings; buffer-based streaming requests exist too).
- **Segment** — the API returns per-word `SFTranscriptionSegment`s with
  `timestamp` and `duration` — exactly what we need to merge with diarization.
- **Merging** — each word's midpoint time is looked up against the
  diarization timeline to label it `Speaker N`.

---

## 2. Architecture — where this fits in Quill

```
AudioRecorderEngine (Module 2)                DiarizationEngine (THIS MODULE)
┌───────────────────────────┐   16 kHz mono   ┌─────────────────────────────────────┐
│ mic + ScreenCaptureKit    │  Float frames   │  VAD ──► segmenter ──► embedder     │
│ loopback → circular buffer│ ───────────────►│                 │                   │
└───────────────────────────┘  AsyncStream    │                 ▼                   │
                                              │        online clusterer             │
                                              │        (Speaker 1..N timeline)      │
                                              │                 │                   │
                               session WAV    │  Transcriber (SFSpeechRecognizer,   │
                              ───────────────►│  on-device) → timestamped words     │
                                              │                 │                   │
                                              │                 ▼                   │
                                              │  TranscriptMerger → [Utterance]     │
                                              └───────────────┬─────────────────────┘
                                                              ▼
                                    LocalAIParsingEngine (3b) → ObsidianExporter (4)
```

- **Input**: an `AsyncStream<AudioChunk>` of 16 kHz mono Float PCM from the
  recorder, plus (after stop) the session's WAV file URL.
- **Output**: `DiarizedTranscript` — an array of `Utterance`
  (`speaker`, `start`, `end`, `text`) plus per-speaker stats. Module 3b
  turns this into Attendees / Action Items / Key Takeaways markdown.
- **Threading**: the engine is an `actor`; heavy DSP runs inside it off the
  main thread. The UI observes progress via an `AsyncStream<Progress>`.
- **Memory rules** (project-wide): bounded buffers only (we never hold more
  than one analysis window + running sums), every `Task` cancellable, no
  retain cycles (`[weak self]` in escaping closures — see §4).

---

## 3. Step-by-step implementation

Create a group `DiarizationEngine` in the Quill Xcode target and add each
file below. Full files (with more comments) are in [`code/`](code/) —
you can type them in from here or copy from there; they are identical.

### 3.0 Shared types — `DiarizationTypes.swift`

Start with the vocabulary of the whole module as plain value types.
`struct`s are **value types** (copied on assignment, no shared mutable
state — free thread-safety), which is why we prefer them for data.

See [`code/DiarizationTypes.swift`](code/DiarizationTypes.swift). Key types:

```swift
/// One chunk of mono 16 kHz Float32 audio handed to us by the recorder.
public struct AudioChunk: Sendable {
    public let samples: [Float]        // −1.0 … +1.0
    public let startTime: TimeInterval // seconds since session start
    public static let sampleRate: Double = 16_000
}

/// A contiguous stretch of one speaker talking.
public struct SpeakerSegment: Sendable, Equatable {
    public let speakerID: Int          // 1-based: "Speaker 1"
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerLabel: String { "Speaker \(speakerID)" }
}

/// One merged, speaker-attributed piece of transcript.
public struct Utterance: Sendable {
    public let speakerLabel: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
}

/// Final product handed to LocalAIParsingEngine.
public struct DiarizedTranscript: Sendable {
    public let utterances: [Utterance]
    public let speakerCount: Int
    public let duration: TimeInterval
}
```

`Sendable` tells the compiler "safe to pass between concurrency domains" —
required because these cross actor boundaries.

### 3.1 Feature extraction — `AudioFeatureExtractor.swift`

The one DSP-heavy file. It converts a 400-sample window into
(a) RMS + ZCR for VAD and (b) a 40-dim log-mel vector for embeddings.
Full annotated source: [`code/AudioFeatureExtractor.swift`](code/AudioFeatureExtractor.swift).

The interesting parts:

```swift
import Accelerate

final class AudioFeatureExtractor {
    static let windowSize = 400          // 25 ms @ 16 kHz
    static let hopSize    = 160          // 10 ms
    static let melBands   = 40
    private let fftSize   = 512          // next power of two ≥ 400
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private let hannWindow: [Float]
    private let melFilterbank: [[(bin: Int, weight: Float)]] // sparse rows
    ...
}
```

- **Hann window**: multiplying the slice by a raised-cosine taper before the
  FFT prevents spectral "leakage" from the hard edges of the slice.
  `vDSP.window(ofType:usingSequence:count:isHalfWindow:)` builds it.
- **FFT via vDSP**: `vDSP.FFT` wants "split complex" (separate real/imag
  arrays). We zero-pad 400 → 512, forward-transform, then compute
  magnitude² per bin with `vDSP.squareMagnitudes`.
- **Mel filterbank**: built once in `init` — 40 triangular filters spanning
  0–8000 Hz on the mel scale (`mel = 2595·log10(1 + f/700)`). Each output
  band is a weighted sum of FFT-bin powers; we store only nonzero weights
  (sparse) so applying it is ~1500 multiply-adds.
- **Log + floor**: `log(max(e, 1e-10))` — the floor avoids `log(0) = -inf`.

RMS and ZCR are two lines each with vDSP:

```swift
func rms(_ x: ArraySlice<Float>) -> Float {
    vDSP.rootMeanSquare(Array(x))
}
func zeroCrossingRate(_ x: [Float]) -> Float {
    var crossings = 0
    for i in 1..<x.count where (x[i-1] < 0) != (x[i] < 0) { crossings += 1 }
    return Float(crossings) / Float(x.count)
}
```

### 3.2 Voice Activity Detection — `VoiceActivityDetector.swift`

Full source: [`code/VoiceActivityDetector.swift`](code/VoiceActivityDetector.swift).

The algorithm, window by window:

1. **Noise floor tracking.** Keep an exponential moving average of the RMS
   of *non-speech* windows: `noiseFloor = 0.95·noiseFloor + 0.05·rms`.
   The threshold is `max(noiseFloor × 3, absoluteMin)` — adapts to fan hum,
   AC, quiet rooms.
2. **Decision.** speech iff `rms > threshold && zcr < 0.35`
   (very high ZCR with low structure is usually broadband noise).
3. **Hangover smoothing.** Raw decisions flicker. A tiny state machine
   requires `minSpeechWindows` (3 ≈ 30 ms) consecutive speech windows to
   *enter* speech, and `hangoverWindows` (25 ≈ 250 ms) of silence to
   *leave* it — so short pauses between words don't split segments.
4. **Segment emission.** On the speech→silence transition, emit a
   `(start, end)` time range. Ranges shorter than 300 ms are dropped
   (coughs, clicks).

```swift
struct VADSegment: Sendable { let start, end: TimeInterval }

final class VoiceActivityDetector {
    private enum State { case silence, maybeSpeech(run: Int), speech(silentRun: Int) }
    private var state: State = .silence
    ...
    /// Feed one window; returns a finished segment when one closes.
    func process(rms: Float, zcr: Float, windowStart: TimeInterval) -> VADSegment?
}
```

This is a plain `final class` (not an actor) because it is *owned by* the
engine actor and only ever called from inside it — a common pattern:
one actor guarding several single-threaded helpers.

### 3.3 Speaker embeddings — `SpeakerEmbedder.swift`

Full source: [`code/SpeakerEmbedder.swift`](code/SpeakerEmbedder.swift).

```swift
/// Anything that can turn a speech segment's audio into a fingerprint.
/// Swap in a Core ML x-vector model later without touching the clusterer.
protocol SpeakerEmbedding {
    var dimension: Int { get }
    func embed(melFrames: [[Float]]) -> [Float]   // L2-normalized
}
```

`LogMelStatsEmbedder` implements it: mean + standard deviation of every
mel band across the segment's frames (40 means ⊕ 40 std-devs = 80 dims),
then **L2-normalize** (divide by vector length) so cosine similarity is
just a dot product. Mean captures average timbre; std-dev captures how the
voice *moves* — together they separate speakers surprisingly well for
meeting audio on distinct mics/voices.

### 3.4 Online clustering — `OnlineSpeakerClusterer.swift`

Full source: [`code/OnlineSpeakerClusterer.swift`](code/OnlineSpeakerClusterer.swift).

```swift
final class OnlineSpeakerClusterer {
    struct Cluster { var centroid: [Float]; var count: Int }
    private(set) var clusters: [Cluster] = []
    let similarityThreshold: Float   // 0.85 default
    let maxSpeakers: Int             // 8 — bounded memory, per project rules

    /// Returns 1-based speaker ID for this embedding.
    func assign(_ embedding: [Float]) -> Int {
        var best = (id: -1, sim: -Float.infinity)
        for (i, c) in clusters.enumerated() {
            let sim = dot(embedding, c.centroid) // both L2-normed ⇒ cosine
            if sim > best.sim { best = (i, sim) }
        }
        if best.id >= 0, best.sim >= similarityThreshold || clusters.count >= maxSpeakers {
            update(cluster: best.id, with: embedding)   // running-mean centroid
            return best.id + 1
        }
        clusters.append(Cluster(centroid: embedding, count: 1))
        return clusters.count
    }
}
```

The centroid update is an **incremental mean** followed by re-normalization:
`centroid = normalize((centroid·n + e) / (n+1))`. Note the two exits of the
threshold test: if we're already at `maxSpeakers`, force-assign to the
nearest cluster rather than growing without bound.

**Relabeling pass:** because clustering is online, "Speaker 1" is just
"first voice heard". After the session, `relabelBySpeakingTime()` renumbers
speakers by total talk time (most talkative = Speaker 1) so labels are
stable and meaningful in the exported markdown.

### 3.5 On-device transcription — `Transcriber.swift`

Full source: [`code/Transcriber.swift`](code/Transcriber.swift).

```swift
import Speech

actor Transcriber {
    struct Word: Sendable { let text: String; let start: TimeInterval; let duration: TimeInterval }

    func transcribe(fileURL: URL, locale: Locale = .init(identifier: "en_US"))
        async throws -> [Word] {

        // 1. Ask the user for permission (macOS shows a system dialog once).
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriberError.notAuthorized }

        // 2. Recognizer that supports local-only recognition.
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition
        else { throw TranscriberError.onDeviceUnavailable }

        // 3. File request, pinned on-device. PRIVACY: never flip this flag.
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        // 4. Bridge the callback API into async/await, with cancellation.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                var task: SFSpeechRecognitionTask?
                task = recognizer.recognitionTask(with: request) { result, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let result, result.isFinal else { return }
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    cont.resume(returning: words)
                }
                self.activeTask = task
            }
        } onCancel: {
            Task { await self.cancelActive() }   // stops the recognizer promptly
        }
    }
}
```

Three techniques worth naming:

- **`withCheckedContinuation`** wraps a completion-handler API so you can
  `await` it. Rule: resume **exactly once** (the `guard result.isFinal`
  early-returns on intermediate callbacks; the real code also guards
  against double-resume after an error).
- **`withTaskCancellationHandler`** runs its `onCancel` closure the moment
  the surrounding `Task` is cancelled, letting us call
  `SFSpeechRecognitionTask.cancel()` so the recognizer doesn't keep burning
  CPU after the user hits Stop — the project's "cancellation cleans up"
  rule in action.
- **`requiresOnDeviceRecognition = true`** may throw on locales without a
  downloaded local model; we surface `onDeviceUnavailable` to the UI rather
  than silently falling back to the network. *Never* fall back silently —
  that would violate Quill's privacy contract.

### 3.6 Merging — `TranscriptMerger.swift`

Full source: [`code/TranscriptMerger.swift`](code/TranscriptMerger.swift).

Both streams are timelines; merging is interval lookup:

1. For each transcribed `Word`, compute midpoint `t = start + duration/2`.
2. Binary-search the (sorted, non-overlapping) `SpeakerSegment` list for the
   segment containing `t`. If none (word in a VAD gap), inherit the previous
   word's speaker — recognizers timestamp slightly loosely.
3. Fold consecutive same-speaker words into one `Utterance`; also split when
   the inter-word gap exceeds 1.5 s (paragraph break).

The whole file is ~70 lines of pure functions — trivially unit-testable,
which is exactly why it's kept separate from the actor.

### 3.7 The engine — `DiarizationEngine.swift`

Full source: [`code/DiarizationEngine.swift`](code/DiarizationEngine.swift).
This actor owns everything and exposes two calls:

```swift
actor DiarizationEngine {
    enum Progress: Sendable { case listening(speakers: Int), transcribing, merging, done }

    private let extractor = AudioFeatureExtractor()
    private let vad = VoiceActivityDetector()
    private let embedder: any SpeakerEmbedding = LogMelStatsEmbedder()
    private let clusterer = OnlineSpeakerClusterer(similarityThreshold: 0.85, maxSpeakers: 8)
    private var pending: [Float] = []          // BOUNDED: < 1 window + hop
    private var segments: [SpeakerSegment] = []
    private var melAccumulator: [[Float]] = [] // frames of the open segment only

    /// Phase 1 — consume the live stream; run VAD/embed/cluster per chunk.
    func run(stream: AsyncStream<AudioChunk>) async throws {
        for await chunk in stream {
            try Task.checkCancellation()       // cooperative cancellation point
            ingest(chunk)                      // windows → VAD → segments
        }
        flushOpenSegment()
    }

    /// Phase 2 — after recording stops: transcribe file, merge, relabel.
    func finish(audioFileURL: URL) async throws -> DiarizedTranscript {
        let words = try await Transcriber().transcribe(fileURL: audioFileURL)
        let relabeled = clusterer.relabelBySpeakingTime(segments: segments)
        let utterances = TranscriptMerger.merge(words: words, segments: relabeled)
        return DiarizedTranscript(utterances: utterances,
                                  speakerCount: clusterer.clusters.count,
                                  duration: segments.last?.end ?? 0)
    }
}
```

`ingest` is the bounded-buffer heart: append the chunk to `pending`, peel
off complete 400-sample windows advancing by 160, and **drop consumed
samples immediately** (`pending.removeFirst(hop)` amortized via an index —
see the full file for the O(1) version). `pending` can never exceed
`windowSize + chunkSize` samples: memory is bounded no matter how long the
meeting runs. Mel frames are accumulated **only while a VAD segment is
open**, and cleared the moment the segment closes and is embedded.

### 3.8 Wiring it into Quill

In the record/stop flow (Module 1's popover view model):

```swift
recordTask = Task {                            // stored so Stop can cancel
    let engine = DiarizationEngine()
    async let diarization: Void = engine.run(stream: recorder.chunkStream)
    try await diarization                      // ends when stream finishes
    let transcript = try await engine.finish(audioFileURL: recorder.sessionWAV)
    await parsingEngine.summarize(transcript)  // → Module 3b → Obsidian
}
```

Stop = `recorder.stop()` (finishes the stream) — or Cancel =
`recordTask?.cancel()`, which propagates into `run`'s
`Task.checkCancellation()` and the transcriber's cancellation handler.

### 3.9 Build & verify

- Add to the target's **entitlements/Info.plist**:
  `NSSpeechRecognitionUsageDescription` ("Quill transcribes meetings
  locally on your Mac.") and `NSMicrophoneUsageDescription`.
  Sandbox: `com.apple.security.device.audio-input`.
- Build: `xcodebuild -scheme Quill build` (or ⌘B).
- Unit-test the pure parts (see Exercises): VAD state machine, clusterer,
  merger — none need real audio.
- **Profile**: Instruments → Leaks + Allocations while recording 10 min of
  looped speech. Flat allocation graph expected (bounded buffers). Then hit
  Cancel mid-transcription and confirm the `SFSpeechRecognitionTask` and
  engine actor deallocate (no abandoned tasks in the Time Profiler).

---

## 4. Common pitfalls & memory-leak traps

1. **Unbounded `pending` buffer.** Forgetting to drop consumed samples turns
   the engine into "store the whole meeting in RAM". Symptom: Allocations
   graph climbs linearly. Fix: consume-and-drop per window (§3.7).
2. **`Array.removeFirst(_:)` in a hot loop is O(n).** It shifts every
   remaining element. Use a read index and compact occasionally
   (the provided code does), or a ring buffer.
3. **Continuation resumed twice / never.** `recognitionTask` calls its
   handler many times (partials, then final, or error). Resuming a
   `CheckedContinuation` twice crashes; never resuming leaks the awaiting
   task *forever* (a classic invisible leak). Guard with an `isResumed`
   flag or early-return on non-final results, and make sure the error path
   also resumes.
4. **Retain cycles in callbacks.** `recognizer.recognitionTask { ... }`
   escapes. If that closure captures `self` strongly *and* `self` stores
   the returned task, you have `self → task → closure → self`. Use
   `[weak self]` in any escaping closure stored (directly or transitively)
   by `self`.
5. **Ignoring cancellation.** `for await chunk in stream` does *not* stop
   on cancel by itself if the producer keeps producing. Check
   `Task.checkCancellation()` inside the loop, and give the transcriber a
   `withTaskCancellationHandler`. Verify in Instruments: after Cancel, CPU
   must drop to idle.
6. **Silent cloud fallback.** Creating a plain request without
   `requiresOnDeviceRecognition = true` "works" and quietly ships audio to
   Apple. Pin it, and assert `supportsOnDeviceRecognition` first.
7. **Actor re-entrancy.** Every `await` inside an actor is a suspension
   point where other calls can interleave; don't assume `segments` is
   unchanged across an `await`. The provided engine only mutates state in
   synchronous sections.
8. **FFT setup per window.** Building `vDSP.FFT`/filterbank per call is
   ~100× the cost of the transform. Build once in `init`, reuse forever.
9. **Threshold worship.** 0.85 similarity / 3× noise floor are starting
   points, not truth. Same-speaker-twice or two-speakers-merged? Tune the
   threshold, or lengthen `minSegment` so embeddings average over more audio.
10. **Testing only with your own voice.** One speaker never exercises the
    clusterer's "new speaker" branch. Test with a podcast (2+ voices)
    played through the loopback path.

---

## 5. Exercises

### Exercise 1 (easy) — Read the timeline
Given windows of RMS `[0.001, 0.002, 0.09, 0.11, 0.10, 0.002, 0.001, 0.12, …]`
with threshold 0.01, `minSpeechWindows = 2`, `hangoverWindows = 2`: trace the
VAD state machine (§3.2) window by window and say where the first segment
starts and whether the dip at windows 6–7 splits it.

### Exercise 2 (easy–medium) — Cosine by hand, then in code
(a) Compute cosine similarity of `[1,0,1]` and `[1,1,0]` by hand.
(b) Write `func cosine(_ a: [Float], _ b: [Float]) -> Float` using
`vDSP.dot` / `vDSP.sumOfSquares` and a unit test asserting your hand answer
to 4 decimal places.

### Exercise 3 (medium) — Unit-test the clusterer
Write an XCTest that builds three synthetic unit embeddings — `e1 = [1,0,0]`,
`e2 = [0,1,0]`, `e1' = normalize([0.95, 0.05, 0])` — feeds them to
`OnlineSpeakerClusterer(similarityThreshold: 0.85, maxSpeakers: 8)` in the
order `e1, e2, e1'`, and asserts the returned IDs are `1, 2, 1` and that
cluster 1's count is 2.

### Exercise 4 (hard) — Overlap-tolerant merger
`TranscriptMerger` assigns a word falling in a VAD gap to the *previous*
speaker. Improve it: if the word's midpoint is in a gap, assign it to
whichever neighboring segment's *edge* is closer in time (previous segment's
end vs next segment's start). Add a test with segments
`[S1: 0–2.0]`, `[S2: 3.0–5.0]` and words at t = 2.1 and t = 2.9.

### Exercise 5 (hard, stretch) — Swap the embedder
Sketch (code compiles, model optional) a `CoreMLEmbedder: SpeakerEmbedding`
that loads a bundled `.mlmodelc`, feeds it the mel frames as an
`MLMultiArray`, and L2-normalizes the output. Nothing else in the engine may
change — that's the point of the protocol.

<details>
<summary><strong>Answers</strong></summary>

**1.** Windows 1–2 silence. W3 speech-candidate → `maybeSpeech(1)`; W4 second
consecutive → enters `speech`; segment start is backdated to W3's start
(3 × 10 ms = 20 ms into the audio). W6–7 silent = `silentRun` 1, 2 — reaches
`hangoverWindows` only *at* 2, so the segment would close at W7's end; but W8
is speech again. With hangover = 2 the close fires and a new segment opens at
W8 — i.e. the dip *does* split it. (With the production value 25, it would
not — which is why hangover exists.)

**2.** (a) dot = 1; ‖a‖ = ‖b‖ = √2; cos = 1/2 = **0.5**.
(b)
```swift
import Accelerate
func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let d = vDSP.dot(a, b)
    let na = vDSP.sumOfSquares(a).squareRoot()
    let nb = vDSP.sumOfSquares(b).squareRoot()
    return d / max(na * nb, .leastNormalMagnitude)
}
func testCosine() { XCTAssertEqual(cosine([1,0,1],[1,1,0]), 0.5, accuracy: 0.0001) }
```

**3.**
```swift
func testClusterAssignments() {
    let c = OnlineSpeakerClusterer(similarityThreshold: 0.85, maxSpeakers: 8)
    let e1: [Float] = [1, 0, 0]
    let e2: [Float] = [0, 1, 0]
    let n = (0.95*0.95 + 0.05*0.05).squareRoot()
    let e1p: [Float] = [Float(0.95/n), Float(0.05/n), 0]
    XCTAssertEqual(c.assign(e1), 1)
    XCTAssertEqual(c.assign(e2), 2)   // cos(e1,e2)=0 < 0.85 → new cluster
    XCTAssertEqual(c.assign(e1p), 1)  // cos ≈ 0.9986 ≥ 0.85
    XCTAssertEqual(c.clusters[0].count, 2)
}
```

**4.** Core of the change in `speaker(for:)`: when binary search misses,
you have the insertion index `i`; compare `t - segments[i-1].end` against
`segments[i].start - t` and take the smaller (guarding array edges).
Word at 2.1: distances 0.1 vs 0.9 → **S1**. Word at 2.9: 0.9 vs 0.1 → **S2**.
The old behavior gave S1 for both.

**5.** Skeleton:
```swift
import CoreML
final class CoreMLEmbedder: SpeakerEmbedding {
    let dimension = 192
    private let model: MLModel
    init(modelURL: URL) throws { model = try MLModel(contentsOf: modelURL) }
    func embed(melFrames: [[Float]]) -> [Float] {
        let t = melFrames.count, m = melFrames.first?.count ?? 40
        let arr = try! MLMultiArray(shape: [1, NSNumber(value: t), NSNumber(value: m)],
                                    dataType: .float32)
        for (i, f) in melFrames.enumerated() {
            for (j, v) in f.enumerated() { arr[i*m + j] = NSNumber(value: v) }
        }
        let out = try! model.prediction(from:
            MLDictionaryFeatureProvider(dictionary: ["mel": arr]))
        let e = out.featureValue(for: "embedding")!.multiArrayValue!
        var v = (0..<dimension).map { Float(truncating: e[$0]) }
        let norm = vDSP.sumOfSquares(v).squareRoot()
        vDSP.divide(v, norm, result: &v)
        return v
    }
}
```
Engine change required: one line — the `embedder` property's initializer.
</details>

---

## 6. Checkpoint checklist

Before moving to Module 3b, confirm every box:

- [ ] I can explain sample rate, PCM, window vs hop, and why Quill uses 16 kHz mono.
- [ ] I can state what VAD, an embedding, cosine similarity, and online clustering each do — in one sentence each.
- [ ] All seven Swift files added; project builds clean under Swift 5.10 strict concurrency (no `Sendable` warnings).
- [ ] `NSSpeechRecognitionUsageDescription` present; first transcription shows the system permission dialog exactly once.
- [ ] `requiresOnDeviceRecognition = true` is set, and `supportsOnDeviceRecognition` is checked — verified no network traffic during transcription (Little Snitch or `nettop`).
- [ ] Playing a 2-speaker podcast through the loopback path yields ≥ 2 speakers, and utterances alternate plausibly.
- [ ] Instruments Allocations: flat memory over a 10-minute recording (bounded buffers proven).
- [ ] Instruments Leaks: zero leaks; cancelling mid-transcription drops CPU to idle and deallocates the engine.
- [ ] Unit tests for cosine, clusterer, and merger pass (Exercises 2–4).
- [ ] I can trace one word from PCM samples to its `Utterance` — through window → VAD segment → embedding → cluster ID → merge — from memory.
