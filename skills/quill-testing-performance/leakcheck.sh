#!/bin/zsh
# leakcheck.sh — CLI leak/heap harness for Quill.
# Builds the app, launches it with malloc stack logging, exercises it for a
# fixed window (start/stop recordings manually or via hotkey during the
# window), then runs `leaks` and `heap` and fails on any leaked bytes or any
# surviving engine instances.
#
# Usage: ./leakcheck.sh [seconds-to-exercise]   (default 30)
set -euo pipefail

APP_NAME="Quill"
EXERCISE_SECS="${1:-30}"
SCHEME="Quill"
DERIVED="$(mktemp -d)"

echo "==> Building $SCHEME (Debug)…"
xcodebuild -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED" build -quiet

APP_PATH="$DERIVED/Build/Products/Debug/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "App not found at $APP_PATH"; exit 1; }

echo "==> Launching with MallocStackLogging=1…"
# Launch the binary directly so the env var applies (open(1) drops env).
MallocStackLogging=1 "$APP_PATH/Contents/MacOS/$APP_NAME" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

echo "==> Exercise the app now (record/stop a few times): ${EXERCISE_SECS}s"
sleep "$EXERCISE_SECS"

echo "==> Privacy check: open network sockets (must be empty)…"
if lsof -a -i -p "$PID" 2>/dev/null | grep -q .; then
    echo "FAIL: Quill has open network sockets — violates local-only rule."
    lsof -a -i -p "$PID"
    exit 1
fi

echo "==> Running leaks…"
LEAKS_OUT="$(leaks "$PID" 2>&1 || true)"
echo "$LEAKS_OUT" | tail -n 5

echo "==> Running heap (engine instance census)…"
HEAP_OUT="$(heap "$PID" 2>/dev/null || true)"
# After all recordings are stopped, zero live engine objects is the target.
SURVIVORS="$(echo "$HEAP_OUT" | grep -E 'AudioRecorderEngine' || true)"

FAIL=0
if ! echo "$LEAKS_OUT" | grep -q "0 leaks for 0 total leaked bytes"; then
    echo "FAIL: leaks reported leaked memory."
    FAIL=1
fi
if [[ -n "$SURVIVORS" ]]; then
    echo "FAIL: engine instances still alive after exercise:"
    echo "$SURVIVORS"
    FAIL=1
fi

[[ $FAIL -eq 0 ]] && echo "PASS: no leaks, no surviving engines, no sockets."
exit $FAIL
