# Changelog

Versions follow the npm package (`@pepperchan/quill`) and the Homebrew cask
(`bunnycompany/tap/quill`). Both ship the `Quill.app.zip` attached to the
GitHub release of the same version.

## 0.1.0-alpha.1 — 2026-08-29

First public alpha.

- Complete-transcript fix
- Learning lexicon: built from the vault (note titles, tags, wikilinks) and
  editable via `Quill/lexicon.md`
- Voice profiles: rename a speaker in a note and Quill learns the name
- Crash recovery: audio streams to disk; orphaned recordings finish
  processing on next launch
- Cleaned-notes folder
- Processing queue
- Menubar level meter

Requires macOS 15+ on Apple Silicon. Ad-hoc signed: first launch is
right-click → Open.
