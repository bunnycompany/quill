# Instruments & CLI Profiling Cheatsheet (Quill)

Quick reference for the three Instruments templates plus the CLI tools.
Xcode 16+, macOS 15, Apple Silicon.

## Launching

| How | Steps |
|---|---|
| From Xcode | Product ▸ Profile (⌘I) → template picker |
| Standalone | Xcode ▸ Open Developer Tool ▸ Instruments, then choose a running process (Quill) as target |
| CLI trace | `xctrace record --template 'Time Profiler' --attach Quill --time-limit 60s --output quill.trace` |

Profile **Release** builds for CPU numbers (Debug is unoptimized and lies);
**Debug** builds are fine for Leaks/Allocations.

## Leaks template

- Red ✕ marks on the Leaks track = leaked blocks found at that snapshot.
- Select a leak → Detail pane → **Cycles & Roots** shows the retain-cycle
  graph. The arrows tell you which reference to make `weak`.
- Quill ritual: start trace → record/stop a Quill recording 5× → wait for two
  more snapshots → expect zero ✕.

## Allocations template (abandoned memory)

1. Start trace, let Quill idle 10 s.
2. Click **Mark Generation** (flag button, bottom bar) → "Generation A".
3. Do one full record→stop→export cycle (30 s).
4. **Mark Generation** again → "Generation B". Repeat the cycle → "C".
5. Inspect Generation B's *persistent* bytes: memory allocated during B still
   alive at the end. Legit: the saved note, SQLite row. Suspicious: growing
   `AVAudioPCMBuffer` counts, `AsyncStream` continuations, `Task` allocs.
6. Steady state per extra cycle should be ~flat. Linear growth per cycle =
   abandoned memory even if Leaks says clean.

## Time Profiler

- Record 60 s while Quill is actively recording audio.
- Call tree settings (bottom): check **Separate by Thread**, **Hide System
  Libraries** initially; sort by Weight.
- What good looks like: audio tap + buffer copy dominates but total process
  CPU < 5 %; UI thread near-idle while popover closed.
- Red flags: `objc_retain`/`release` storms (churny allocations in the audio
  path), polling loops (`Task.sleep`-free while-loops), JSON/regex work on
  the audio thread.

## CLI tools

```bash
leaks Quill                          # leak check a running process by name
leaks --atExit -- ./Quill.app/Contents/MacOS/Quill   # whole-lifetime check
MallocStackLogging=1 ./Quill …       # enables allocation backtraces first
heap Quill | grep AudioRecorderEngine     # live-object census by class
heap Quill -addresses AVAudioPCMBuffer   # addresses for `leaks --trace`
footprint Quill                      # ledger-style memory footprint summary
lsof -a -i -p $(pgrep -x Quill)      # privacy: must print NOTHING
```

`leaks` exit code is non-zero when leaks are found — script-friendly (see
`leakcheck.sh`).

## Sanitizers (scheme ▸ Edit Scheme ▸ Test/Run ▸ Diagnostics)

| Tool | Finds | Cost | Note |
|---|---|---|---|
| Address Sanitizer | buffer overruns, use-after-free | 2–5× slow | can't combine with TSan |
| Thread Sanitizer | data races | 5–15× slow | run the cancellation stress test under it |
| Malloc Scribble/Guard | use of freed memory | low | fills freed mem with 0x55 |
| Zombie Objects | messages to dealloc'd ObjC objects | low | for AVFoundation delegate bugs |

## Budgets (fail the check if exceeded)

- Steady-state CPU while recording: **< 5 %** (Release, M-series).
- Memory: flat per record/stop cycle after cycle 2 (allow warm-up in cycle 1).
- Leaks: **0 bytes**, always.
- Cancellation latency: stop → all cleanup done **< 250 ms**.
