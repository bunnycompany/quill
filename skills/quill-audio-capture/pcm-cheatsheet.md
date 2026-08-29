# PCM & Capture Cheatsheet (Quill Module 2)

## Data-rate math
bytes/sec = sampleRate x channels x bytesPerSample

| Stream | Rate | Ch | Format | Per second | Per hour |
|---|---|---|---|---|---|
| Mac mic default | 48 kHz | 1 | Float32 | 192 KB | 675 MB |
| SCK loopback (as configured) | 48 kHz | 2 | Float32 | 384 KB | 1.35 GB |
| Quill canonical | 16 kHz | 1 | Float32 | 64 KB | 225 MB |
| WAV export | 16 kHz | 1 | Int16 | 32 KB | 112 MB |

Ring buffer: 10 s @ canonical = 160,000 floats = 640 KB per source. Bounded forever.

## API crib notes

**Mic (AVAudioEngine)**
```swift
let fmt = engine.inputNode.outputFormat(forBus: 0)     // NEVER assume; read it
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, when in ... }
try engine.start()
engine.inputNode.removeTap(onBus: 0); engine.stop()    // teardown pair
```
Tap thread rules: no await, no allocation, no long locks, no file I/O.

**System audio (ScreenCaptureKit, macOS 13+)**
```swift
cfg.capturesAudio = true
cfg.excludesCurrentProcessAudio = true
try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
try await stream.startCapture() / stopCapture()
```
Needs Screen & System Audio Recording permission. CMSampleBuffer pointers from
`withAudioBufferList` die at closure end — copy inside it.

**Converter**
- One `AVAudioConverter` per source, created at start, reused (filter state).
- Pull model: supply input closure; return `.haveData` once, then `.noDataNow`.

**Files**
- CAF = unlimited length, any Core Audio format. WAV = 4 GB cap, universal.
- `AVAudioFile` has no `close()` — release the reference to finalize.
- `afinfo file.caf` in Terminal verifies format; QuickTime verifies playback.

## Permission checklist
- [ ] Entitlement: App Sandbox -> Audio Input (missing = silent buffers, no error!)
- [ ] Info.plist: NSMicrophoneUsageDescription
- [ ] `AVCaptureDevice.requestAccess(for: .audio)` before start
- [ ] Screen & System Audio Recording approved (SCK throws if not)
- [ ] Both DENIAL paths tested

## Teardown order (memorize)
1. removeTap / engine.stop / stream.stopCapture   (producers)
2. drainTask.cancel() then `await drainTask.result` (consumer — cancel THEN wait)
3. flush rings to file
4. continuation.finish()                            (frees for-await consumers)
5. audioFile = nil                                  (finalizes header)

## Leak-hunt quick list
retain cycle in tap closure - unfinished AsyncStream - un-awaited cancelled task -
per-buffer converter allocation - unbounded dispatch-queue "buffers" - stashed
CMSampleBuffer pointers.
