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

1. **Microphone** — "Start Recording" stays disabled until it is granted;
   click **Grant** in the popover's permission banner to trigger the prompt.
   Required for the primary mic-capture path.
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

## Version

`build.sh` reads the version from `../npm/package.json` — that file is the
single source of truth. `CFBundleShortVersionString` gets the semver without
its prerelease tag (`0.1.0-alpha.1` → `0.1.0`, because macOS wants dotted
integers there) and `CFBundleVersion` gets the commit count, so it rises with
every commit. That needs a full clone: a shallow clone or a source tarball
falls back to build 1 with a warning, which is fine for a personal build but
not for a release. Bump `npm/package.json` first, then build. (The shipped
0.1.0-alpha.1 predates this and reports 1.0, build 1.)

## Cutting a release

Three channels ship the same `Quill.app.zip`: the GitHub release asset, the
npm package (which bundles it), and the Homebrew cask (which downloads the
release asset and checks its SHA-256). Keep them in lockstep:

1. Bump `"version"` in `npm/package.json` (e.g. `0.1.0-alpha.3`; alpha.2 was
   published and then unpublished, and npm never lets a version number be
   reused), add a `CHANGELOG.md` entry, and commit.
2. `./build.sh --zip` — builds, signs, and writes `app/Quill.app.zip`
   (git-ignored); it prints the SHA-256 you will need for the cask.
3. Tag and publish the GitHub release **from that commit** with
   `Quill.app.zip` attached: tag `v<version>`, marked as a pre-release while
   in alpha. The cask downloads
   `https://github.com/bunnycompany/quill/releases/download/v<version>/Quill.app.zip`.
4. `cp Quill.app.zip ../npm/ && (cd ../npm && npm publish --tag alpha)`.
   `npm/Quill.app.zip` is git-ignored but listed in the package's `files`, so
   it ships inside the tarball. Then
   `npm dist-tag add @pepperchan/quill@<version> latest`: there is no stable
   release yet, so `latest` tracks the newest alpha (it already points at
   0.1.0-alpha.1). Once a stable version ships, leave `latest` on it and keep
   publishing alphas with `--tag alpha` only.
5. In `bunnycompany/homebrew-tap`, set `version` and `sha256` in
   `Casks/quill.rb` to the new values and push.
6. If `site/index.html` changed, redeploy quill.systems.

Sanity check afterwards: `npm view @pepperchan/quill dist-tags`,
`brew fetch --cask bunnycompany/tap/quill`, and the release page should all
agree on the version and the zip's checksum.
