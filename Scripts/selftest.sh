#!/bin/bash
# Runs the app's in-process smoke test against local fixture pages.
# Usage: Scripts/selftest.sh [output-dir]   (PNG snapshots, fixtures and result.txt land there)
# By default the app runs in the background: no Dock icon, no visible window, never takes focus,
# its own preferences (app.arcx.ArcX.tests), in-memory web data and a session folder inside the
# output dir. Checks that need keyboard focus are then skipped and listed as "skip".
# ARCX_FOREGROUND=1 shows the window and asks for focus so those checks run too.
#
# The app is launched once per phase, all on the same data folder (<output-dir>/data):
#   main     first launch: tabs, sidebar, address field, saving, empty state, snapshots
#   restore  relaunch: the saved session comes back, only the selected tab gets a web view
#   corrupt  relaunch on a corrupt session.json, with ARCX_START_URL set
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/selftest}
rm -rf "$OUT"; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
APP=.build/xcode/Build/Products/Debug/ArcX.app/Contents/MacOS/ArcX
[[ -x "$APP" ]] || { echo "build the app first (Scripts/verify.sh)"; exit 2; }
# A test is the real app. Without this, macOS can store its window and the next normal launch opens there.
ARGS=(-ApplePersistenceIgnoreState YES)
FAILED=0

# run_phase <name> <timeout seconds> [VAR=value ...]
run_phase() {
  local phase=$1 timeout=$2; shift 2
  env -u ARCX_START_URL -u ARCX_DATA_DIR ARCX_SELFTEST="$OUT" ARCX_SELFTEST_PHASE="$phase" "$@" \
    "$APP" "${ARGS[@]}" >"$OUT/app-$phase.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 $((timeout * 2))); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  if kill -0 $pid 2>/dev/null; then
    kill $pid; wait $pid 2>/dev/null
    echo "FAIL phase $phase timed out after $timeout s" >>"$OUT/result-$phase.txt"
    FAILED=1
    return
  fi
  wait $pid; local status=$?
  [[ -f "$OUT/result-$phase.txt" ]] || echo "FAIL phase $phase wrote no result (exit $status); see app-$phase.log" >"$OUT/result-$phase.txt"
  if [[ $status -ne 0 ]]; then
    FAILED=1
    grep -i "warning\|error\|exception\|fault" "$OUT/app-$phase.log" >>"$OUT/result-$phase.txt" || true
  fi
}

run_phase main 90
run_phase restore 30
# A file that is not a session at all; the app must move it aside unchanged.
printf '{ "version": 1, "tabs": [ this is not a session' >"$OUT/corrupt-session.txt"
mkdir -p "$OUT/data"; cp "$OUT/corrupt-session.txt" "$OUT/data/session.json"
run_phase corrupt 30 ARCX_START_URL="file://$OUT/fixtures/a.html"

# One result.txt: each phase's lines under a heading, then the totals.
{
  for phase in main restore corrupt; do
    echo "== $phase"
    grep -v '^RESULT' "$OUT/result-$phase.txt"
  done
  cat "$OUT"/result-*.txt | awk '
    /^RESULT/ { for (i = 2; i <= NF; i++) { split($i, kv, "="); sum[kv[1]] += kv[2] } }
    /^FAIL phase/ { sum["fail"] += 1 }
    END { printf "RESULT pass=%d fail=%d skip=%d\n", sum["pass"], sum["fail"], sum["skip"] }'
} >"$OUT/result.txt"
cat "$OUT/result.txt"
grep -q '^RESULT pass=[0-9]* fail=0 ' "$OUT/result.txt" || FAILED=1
exit $FAILED
