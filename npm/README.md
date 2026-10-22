# Quill

Local-first macOS menubar meeting recorder. Records the room (mic; optional
system audio), then — entirely on-device — separates speakers, transcribes,
and writes a structured markdown note with a playable audio embed into your
Obsidian vault. No cloud, no account.

## Install

```
npm install -g @pepperchan/quill@alpha
```

or with Homebrew:

```
brew tap bunnycompany/tap && brew install --cask quill
```

Either installs `Quill.app` to `/Applications` (npm falls back to
`~/Applications`; if the app is missing after an npm install, run
`quill-install`). Requires macOS 15+ on Apple Silicon. The alpha is ad-hoc
signed, so macOS may block the first launch: open System Settings → Privacy &
Security and click **Open Anyway** (macOS 15 no longer offers right-click →
Open for unsigned apps). Homebrew users can skip that prompt with
`brew install --cask --no-quarantine quill`.

## Use

Click the quote-bubble icon in the menubar (or press ⌥⌘R); it becomes a live
waveform while recording. Pick your Obsidian vault once. Record. Stop. A note
lands in `<vault>/Meetings/` with YAML frontmatter, a speaker-labeled
transcript, and an `![[audio]]` embed (m4a in `Meetings/attachments/`). On a
Mac with Apple Intelligence the note also gets a summary, key takeaways, and
action items; without it, Quill writes the transcript and says so in the note
instead of inventing analysis. Speaker names are plain text — rename
"Speaker 1" in the note like any edit, and Quill learns the name.

## Status: alpha

Recording, on-device transcription, note structuring, audio embed, and
Obsidian export are tested end-to-end. System-audio capture is experimental.
Speaker separation quality depends on voices being acoustically distinct.

MIT. Site: quill.systems · Source: github.com/bunnycompany/quill
