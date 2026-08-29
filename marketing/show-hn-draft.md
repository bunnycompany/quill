# Show HN draft

**Title:** Show HN: Quill – on-device meeting notes for Mac that save into Obsidian (MIT)

**Body:**

I kept getting on calls where people asked me to do things, and a week later I couldn't remember any of it. Every meeting-notes tool wanted to put a bot in my calls and my audio in their cloud. So I built Quill: a macOS menubar app where everything — recording, speaker diarization, transcription, summarization — runs on-device.

How it works, technically:

- Audio: AVAudioEngine mic tap (plus optional ScreenCaptureKit system-audio loopback for remote calls), downsampled to 16 kHz mono through a bounded SPSC ring buffer.
- Diarization: hand-rolled and honest about it — energy/ZCR VAD, log-mel statistics embeddings, online centroid clustering. It splits distinct voices fine; a proper ECAPA-class Core ML embedder is the roadmap.
- Transcription: Apple's SFSpeechRecognizer pinned to on-device recognition, biased with a custom vocabulary Quill learns from your vault (note titles, tags, wikilinks — so your project names stop being mangled).
- Summaries: Apple's Foundation Models framework when available; otherwise it gives you the transcript and says so — it never fabricates takeaways it can't support.
- Output: markdown with YAML frontmatter straight into your Obsidian vault, Dataview-ready, with the audio embedded as m4a. Rename "Speaker 1" to a real name in the note and Quill learns it for next time.

It's an alpha (ad-hoc signed, right-click-to-open), MIT, no account, no telemetry, install is `npm i -g @pepperchan/quill@alpha`. A 72-minute meeting transcribes in ~9 minutes on an A18 Pro MacBook while Quill itself stays under 3% CPU — the heavy lifting is macOS's own speech engine.

Site: https://quill.systems

Things I'd love scrutiny on: the diarization approach, the crash-recovery design (audio streams to disk; orphaned recordings finish processing on next launch), and whether anyone else wants the multi-device idea — per-person iPhone mics as ground-truth diarization.
