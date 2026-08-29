# Quill Curriculum — Zero to Shipped

A learning path through the eight Quill teaching modules. Follow in order; each module's output is the next module's input. Total: roughly 40–55 hours of focused work for a complete beginner, less with prior Swift experience.

**Environment for every module:** Apple Silicon Mac, macOS 15 (Sequoia), Xcode 16+, Swift 5.10+. Module 3b's Foundation Models path additionally needs macOS 26 + Apple Intelligence (a rule-based fallback covers macOS 15).

## The Path

### 0. `quill-swift-foundations` — Swift & Xcode from zero
- **Time:** 6–8 h
- **Prerequisites:** none (Module 0 assumes you have never opened Xcode)
- **Covers:** Swift syntax, optionals, structs/classes/enums/actors, Swift Concurrency (Task, cancellation), SwiftUI basics, project creation, entitlements/Info.plist, sandbox/TCC.
- **Demo after:** a running "HelloQuill" menubar skeleton with a live level meter fed by a cancellable Task and a bounded circular-buffer actor.
- Skip only if you already write idiomatic Swift Concurrency code.

### 1. `quill-menubar-app` — Component 1: MenuBar app core
- **Time:** 5–7 h
- **Prerequisites:** Module 0
- **Covers:** NSStatusItem + NSPopover + NSHostingController, SwiftUI popover UI, Carbon global hotkey (⌥⌘R), mic + Screen Recording TCC onboarding, security-scoped bookmark vault persistence, teardown without leaks.
- **Demo after:** Quill's real UI shell — status-bar icon that changes with recording state, popover with record/stop, level meters, vault picker, global hotkey, permission onboarding.

### 2. `quill-audio-capture` — Component 2: AudioRecorderEngine
- **Time:** 6–8 h
- **Prerequisites:** Modules 0–1 (permissions and UI shell in place)
- **Covers:** PCM fundamentals, AVAudioEngine mic tap, ScreenCaptureKit system-audio loopback, AVAudioConverter to 16 kHz mono Float32, SPSC bounded ring buffer (drop-newest, overrun counting), CAF writing, ordered zero-leak start/stop lifecycle.
- **Demo after:** press Record → mic + system audio mixed, metered live, written to a CAF file; press Stop → everything cancels and deallocates cleanly.

### 3a. `quill-diarization-transcription` — Component 3: DiarizationEngine
- **Time:** 8–10 h (the deepest module)
- **Prerequisites:** Module 2 (16 kHz mono Float32 chunks as input)
- **Covers:** vDSP feature extraction (RMS/ZCR/FFT/log-mel), adaptive VAD, speaker embeddings + online centroid clustering, on-device SFSpeechRecognizer, merging speakers with word timestamps.
- **Demo after:** feed a recorded meeting, get back "Speaker 1: … / Speaker 2: …" with timestamps, fully on-device.

### 3b. `quill-ai-parsing` — Component 3 (cont.): LocalAIParsingEngine
- **Time:** 4–6 h
- **Prerequisites:** Module 3a (`[TranscriptSegment]` input); Foundation Models path needs macOS 26
- **Covers:** on-device LLMs, @Generable guided generation, token-budgeted chunking, map-reduce summarization with cooperative cancellation, deterministic markdown rendering, rule-based fallback.
- **Demo after:** a diarized transcript becomes a structured MeetingNote — summary, attendees, action items, key takeaways — as deterministic YAML-frontmatter markdown.

### 4. `quill-obsidian-export` — Component 4: ObsidianExporter
- **Time:** 3–4 h
- **Prerequisites:** Module 3b (MeetingNote input); bookmark concepts from Module 1
- **Covers:** sandbox-safe vault access with stale-bookmark recovery, Dataview-safe YAML escaping, collision-free naming, atomic writes (sync-tool-safe), clipboard export.
- **Demo after:** a note lands as `Meetings/2026-08-12-Sync.md` in a real Obsidian vault, renders correctly, and is queryable via Dataview.

### 5. `quill-storage-history` — Component 5: SQLite history & cache
- **Time:** 5–7 h
- **Prerequisites:** Module 0 (Swift); conceptually independent of 2–4, so it can be done any time after Module 0 — it's placed here so real data exists to store
- **Covers:** raw SQLite3 C API from Swift, WAL/foreign keys, migrations via PRAGMA user_version, QuillStore actor with prepare/bind/defer-finalize, LRU transcript cache, pruning with window functions.
- **Demo after:** recordings/segments/notes persisted in `quill.sqlite`, surviving relaunch, with cache eviction and prune policies working.

### 6. `quill-testing-performance` — Verification & release gate
- **Time:** 5–7 h
- **Prerequisites:** all previous modules (it verifies them)
- **Covers:** XCTest + Swift Testing, deallocation/leak assertions, cancellation-cleanup tests with fake sources, `leaks`/`heap`/Instruments workflows, performance baselines (<5% CPU, 0 leaked bytes, <250 ms cancel), manual QA checklist including the privacy hard gate (zero network sockets).
- **Demo after:** a green test suite, a passing `leakcheck.sh`, and a signed-off manual QA run — Quill is shippable.

## Milestone summary

| After module | You can demo |
|---|---|
| 0 | Menubar skeleton runs |
| 1 | Full UI shell + hotkey + permissions |
| 2 | Real audio capture to disk |
| 3a | Who-said-what transcript |
| 3b | Structured meeting note |
| 4 | Note in Obsidian |
| 5 | Persistent history |
| 6 | Verified, leak-free, shippable app |
