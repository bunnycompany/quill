# Quill

Local-first macOS menubar meeting recorder. Records the room (mic; optional
system audio), then — entirely on-device — separates speakers, transcribes,
and writes a structured markdown note with a playable audio embed into your
Obsidian vault. No cloud, no account.

## Install

```
npm install -g @pepperchan/quill@alpha
```

Installs `Quill.app` to `/Applications` (or `~/Applications`). Requires
macOS 15+ on Apple Silicon. The alpha is ad-hoc signed: first launch is
right-click → Open.

## Use

Click the menubar feather (or press ⌥⌘R). Pick your Obsidian vault once.
Record. Stop. A note lands in `<vault>/Meetings/` with YAML frontmatter,
speaker-labeled transcript, action items, and an `![[audio]]` embed
(m4a in `Meetings/attachments/`). Speaker names are plain text — rename
"Speaker 1" in the note like any edit.

## Status: alpha

Recording, on-device transcription, note structuring, audio embed, and
Obsidian export are tested end-to-end. System-audio capture is experimental.
Speaker separation quality depends on voices being acoustically distinct.

MIT. Site: quill.systems
