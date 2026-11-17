#!/bin/bash
# Runs the app's in-process smoke test against local fixture pages.
# Usage: Scripts/selftest.sh [output-dir]   (PNG snapshots, fixtures and result.txt land there)
# By default the app runs in the background: no Dock icon, no visible window, never takes focus,
# its own preferences (app.arcx.ArcX.tests) and in-memory web data. Checks that need keyboard focus
# are then skipped and listed as "skip". ARCX_FOREGROUND=1 shows the window and asks for focus so
# those checks run too.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/selftest}
rm -rf "$OUT"; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
APP=.build/xcode/Build/Products/Debug/ArcX.app/Contents/MacOS/ArcX
[[ -x "$APP" ]] || { echo "build the app first (Scripts/verify.sh)"; exit 2; }
# A test is the real app. Without this, macOS can store its window and the next normal launch opens there.
ARGS=(-ApplePersistenceIgnoreState YES)
env -u ARCX_START_URL ARCX_SELFTEST="$OUT" "$APP" "${ARGS[@]}" >"$OUT/app.log" 2>&1 &
PID=$!
for _ in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
if kill -0 $PID 2>/dev/null; then
  kill $PID
  echo "self-test timed out after 30 s"
  cat "$OUT/result.txt" 2>/dev/null
  exit 1
fi
wait $PID; STATUS=$?
cat "$OUT/result.txt" 2>/dev/null || echo "no result written (exit $STATUS); see $OUT/app.log"
if [[ $STATUS -ne 0 ]]; then
  grep -i "warning\|error\|exception\|fault" "$OUT/app.log" || true
fi
exit $STATUS
