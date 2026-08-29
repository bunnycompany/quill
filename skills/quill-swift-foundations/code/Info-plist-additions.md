# Info.plist keys for a Quill-style menubar app

Set these in Xcode: project ▸ target ▸ **Info** tab (they are written into the
target's Info.plist / build settings). Raw keys shown; Xcode displays the
human-readable names in parentheses.

## Required for Module 0 (HelloQuill)

| Raw key | Type | Value | Why |
|---|---|---|---|
| `LSUIElement` (Application is agent) | Boolean | `YES` | Menubar-only app: no Dock icon, no app menu takeover. The status item is the whole UI. |
| `NSMicrophoneUsageDescription` (Privacy - Microphone Usage Description) | String | `Quill records meeting audio locally. Nothing leaves your Mac.` | Shown in the TCC consent dialog. **Missing key = instant kill by the OS** the moment mic capture starts, with no dialog. |

## Needed by later Quill modules (add when you get there)

| Raw key | Type | Value | Why |
|---|---|---|---|
| `NSAudioCaptureUsageDescription` | String | `Quill captures system audio locally to transcribe the other side of your calls.` | macOS 15 system-audio capture via ScreenCaptureKit / Core Audio taps. First use also triggers the System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording consent flow. |
| `LSMinimumSystemVersion` | String | `15.0` | Quill uses macOS 15 APIs (ScreenCaptureKit audio-only capture, @Observable, etc.). |
| `LSApplicationCategoryType` | String | `public.app-category.productivity` | App Store / Finder categorization. |

## Notes

- Consent state is per-app-bundle-ID and cached by TCC. While testing, reset
  it with: `tccutil reset Microphone com.yourteam.HelloQuill`
  (and `tccutil reset ScreenCapture ...` for system audio).
- Usage-description strings are user-facing marketing for your privacy story —
  say "locally" and mean it; the missing network entitlement backs it up.
- `LSUIElement` apps can still show windows (e.g. a Settings window via the
  SwiftUI `Settings` scene) — they just have no Dock presence.
