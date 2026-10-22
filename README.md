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
`~/Applications`). Requires macOS 15+ on Apple Silicon. The alpha is ad-hoc
signed: first launch is right-click → Open.

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

## Repository layout

- `app/` — Swift sources and `build.sh`. See [`app/BUILD.md`](app/BUILD.md) to build from source or cut a release.
- `npm/` — the `@pepperchan/quill` installer package; it bundles the built `Quill.app.zip`.
- `site/` — the single-page site served at quill.systems.
- `skills/` — eight teaching modules that rebuild Quill from zero; start at [`skills/CURRICULUM.md`](skills/CURRICULUM.md).
- `marketing/` — launch post drafts.

Each [GitHub release](https://github.com/bunnycompany/quill/releases) carries
the signed `Quill.app.zip` that the npm package bundles and the Homebrew cask
downloads. Changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

MIT. Site: quill.systems
