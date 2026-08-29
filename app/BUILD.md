# Building Quill

## Rebuild

```sh
./build.sh
```

That's the whole build: it compiles everything in `Sources/` with `swiftc`
(`-target arm64-apple-macos15.0`, no Xcode project, no SwiftPM), assembles
`Quill.app` (Contents/MacOS/Quill + Info.plist with `LSUIElement=true`),
and ad-hoc codesigns it (`codesign --force --sign -`). Output:
`Quill.app` next to this file. Launch with `open Quill.app` — the app lives
in the menu bar (quote-bubble icon), there is no Dock icon.

## First-run permissions

macOS will prompt for these the first time the corresponding feature runs:

1. **Microphone** — on your first "Start Recording". Required for the
   primary mic-capture path.
2. **Speech Recognition** — when the first recording finishes and
   transcription starts. Transcription is pinned on-device
   (`requiresOnDeviceRecognition = true`); audio never leaves the Mac.
3. **Screen Recording** — only if you enable the "Capture system audio"
   toggle (off by default). macOS gates ScreenCaptureKit audio loopback
   behind this permission; you may need to relaunch Quill after granting it.

If a prompt was previously denied, use the "Grant" buttons in the popover's
permission banner — they deep-link to the right System Settings pane.

## Usage flow

Menubar icon → popover → pick your Obsidian vault ("Choose…") → Start
Recording → talk → Stop. Quill then diarizes, transcribes on-device,
builds a structured note (rule-based; no Apple Intelligence required), and
writes `Meetings/<date>-<title>.md` with YAML frontmatter into the vault.
History (recordings, segments, notes) is stored in
`~/Library/Application Support/Quill/quill.sqlite`; raw audio CAFs in
`~/Library/Application Support/Quill/Audio/`.
