# Quill Manual QA Checklist

Run top-to-bottom before every release, on a clean login session.
Mark each item pass/fail; any fail blocks release.

## 0. Environment
- [ ] Fresh build (Release), Apple Silicon Mac, macOS 15.
- [ ] Reset permissions to test first-run flows:
      `tccutil reset Microphone <bundle-id>` and
      `tccutil reset ScreenCapture <bundle-id>`.

## 1. Menubar / UI
- [ ] App launches with NO Dock icon, only the menubar (NSStatusItem) icon.
- [ ] Icon states: idle, recording (distinct, visible in light AND dark menu bar).
- [ ] Click opens the popover; click-outside and Esc dismiss it.
- [ ] Record/Stop button toggles state; status icon matches within 1 s.
- [ ] Live level meters move with speech, sit at floor in silence.
- [ ] Vault selector opens a folder picker; chosen vault persists across relaunch.
- [ ] Global hotkey starts/stops recording with the popover closed.
- [ ] Quit from the menu actually terminates the process (`pgrep -x Quill` empty).

## 2. Permissions
- [ ] First recording prompts for Microphone; denial shows a helpful in-app
      message (no crash, no silent 0-level recording).
- [ ] System loopback prompts for Screen Recording (ScreenCaptureKit);
      denial degrades to mic-only with a visible notice.
- [ ] After granting in System Settings, capture works without relaunch
      (or the app clearly asks to relaunch).

## 3. Recording pipeline
- [ ] 2-minute recording: play a video (system audio) while speaking; both
      sources present in the transcript.
- [ ] Memory in Activity Monitor is flat during recording (bounded buffer).
- [ ] CPU < 5 % steady state while recording.
- [ ] Stop mid-sentence: no crash, partial audio processed, cleanup < 250 ms
      (icon returns to idle promptly).
- [ ] Start/stop 10× rapidly: no crash, no stuck "recording" state, memory
      returns to baseline.
- [ ] Sleep the Mac mid-recording, wake: app recovers to a defined state.

## 4. Diarization & summarization sanity
- [ ] Two people talking → transcript shows Speaker 1 / Speaker 2 segments
      with plausible boundaries and timestamps.
- [ ] Explicit spoken action item ("Alice will send the deck by Friday")
      appears under Action Items.
- [ ] Duration in frontmatter matches wall clock ±5 s.

## 5. Obsidian rendering
- [ ] Note appears at `<vault>/Meetings/YYYY-MM-DD-<Title>.md`.
- [ ] Open in Obsidian: frontmatter renders as Properties (no raw `---` text
      visible → YAML is valid).
- [ ] Dataview query `TABLE duration, attendees FROM "Meetings"` lists the note.
- [ ] Attendees render as a list; timestamps section, Action Items and Key
      Takeaways sections render as proper headings/checkboxes.
- [ ] Filename with spaces/emoji in title is sanitized, not crashing export.
- [ ] Same title twice in one day: second file does not overwrite the first.
- [ ] Clipboard-copy button puts identical markdown on the pasteboard.

## 6. History / SQLite
- [ ] Past recordings list survives relaunch.
- [ ] Deleting a history entry removes it from the DB (relaunch to confirm)
      but never deletes the note in the vault.

## 7. Privacy (hard gate)
- [ ] While idle AND while recording: `lsof -a -i -p $(pgrep -x Quill)`
      prints nothing (zero network sockets).
- [ ] No audio files or transcripts written outside the vault, app support
      dir, and SQLite DB (`fs_usage -w -f filesys pgrep -x Quill` spot-check).
- [ ] All processing works with Wi-Fi off (airplane-mode test).

## 8. Leak/perf sign-off
- [ ] `leakcheck.sh` passes.
- [ ] Instruments Leaks: zero leaks over 5 record/stop cycles.
- [ ] Allocations generation marking: flat per cycle after warm-up.

Sign-off: name ______  date ______  build ______
