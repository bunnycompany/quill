# Quill DiarizationEngine — one-page cheatsheet

## Pipeline
```
16 kHz mono Float PCM ─► 25 ms windows (10 ms hop)
   ├─ RMS + ZCR ──► VAD (adaptive threshold + hangover) ──► speech segments
   └─ FFT → mel filterbank → log-mel (40 dims per window)
segment mel frames ─► mean⊕std embed (80-d, L2-normed)
   ─► online clusterer (cosine ≥ 0.85 → join, else new; cap 8) ─► Speaker N timeline
session WAV ─► SFSpeechRecognizer (on-device) ─► words + timestamps
merge: word midpoint → binary-search segment → fold into Utterances
```

## Magic numbers (and why)
| Value | Meaning |
|---|---|
| 16 000 Hz | speech bandwidth ≤ 8 kHz (Nyquist); matches speech models |
| 400 / 160 samples | 25 ms window / 10 ms hop — standard speech framing |
| 512 | FFT size: next power of 2 ≥ 400 |
| 40 | mel bands |
| 3× noise floor | VAD energy threshold multiplier |
| 3 / 25 windows | VAD onset / hangover (30 ms / 250 ms) |
| 0.3 s | minimum segment (drops coughs/clicks) |
| 0.85 | cosine threshold "same speaker" (tune!) |
| 8 | max speakers — bounded memory |
| 1.5 s | word gap that splits an utterance |

## Key APIs
```swift
vDSP.rootMeanSquare(x)                      // RMS
vDSP.FFT(log2n:radix:ofType:)               // build ONCE in init
vDSP.window(ofType:usingSequence:.hanningDenormalized:...)
vDSP.dot(a, b)                              // cosine, if both L2-normed
SFSpeechRecognizer(locale:)?.supportsOnDeviceRecognition  // check FIRST
SFSpeechURLRecognitionRequest(url:).requiresOnDeviceRecognition = true  // ALWAYS
result.bestTranscription.segments           // per-word timestamp + duration
withCheckedThrowingContinuation { ... }     // resume EXACTLY once
withTaskCancellationHandler { } onCancel: { task.cancel() }
Task.checkCancellation()                    // inside every for-await loop
```

## Concurrency rules
- Engine = `actor`; helpers = plain `final class` owned by it.
- Every `await` inside an actor is a re-entrancy point — mutate state only in synchronous stretches.
- Escaping closure stored by `self` ⇒ `[weak self]`.
- Cancel path: `recordTask?.cancel()` → `checkCancellation()` in `run` + recognizer `onCancel`.

## Memory contract
- `pending` buffer: read-index + bulk compaction — never > ~window + chunk.
- Mel frames kept only while a VAD segment is open; freed on close.
- Verify: Instruments Allocations flat over 10 min; Leaks = 0; CPU idle after cancel.

## Setup checklist
- Info.plist: `NSSpeechRecognitionUsageDescription`, `NSMicrophoneUsageDescription`
- Entitlement: `com.apple.security.device.audio-input`
- Frameworks: AVFoundation, Accelerate, Speech (all system; zero third-party)
