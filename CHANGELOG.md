# Changelog

Versions follow the npm package (`@pepperchan/quill`) and the Homebrew cask
(`bunnycompany/tap/quill`). Both ship the `Quill.app.zip` attached to the
GitHub release of the same version.

## 0.1.0-alpha.1 — 2026-08-29

First public alpha.

- Transcripts no longer stop at the first long pause: every pause-delimited
  recognizer result is kept
- Learning lexicon: built from the vault (note titles, tags, wikilinks) and
  editable via `Quill/lexicon.md`
- Voice profiles: rename a speaker in a note and Quill learns the name
- Crash recovery: audio streams to disk; orphaned recordings finish
  processing on next launch
- Cleaned-notes folder: with cleanup on, the AI-cleaned transcript is filed
  under `Meetings/cleaned/` and cross-linked to the raw note
- Processing queue
- Menubar level meter

Requires macOS 15+ on Apple Silicon. Ad-hoc signed: if macOS blocks the
first launch, open System Settings → Privacy & Security and click Open Anyway
(macOS 15 no longer offers right-click → Open for unsigned apps).

Known issues in this build:

- The app bundle reports version 1.0 (build 1) in Finder and About. Builds
  from `app/build.sh` now carry the real version.
- `Quill.app.zip` contains stray `._` AppleDouble entries. They are harmless
  when installed with npm or Homebrew, and visible if you unzip it by hand.
