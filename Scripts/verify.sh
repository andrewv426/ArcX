#!/bin/bash
# The single gate. Default: package build + headless tests + app build into .build/xcode.
#   --no-app    skip the Xcode app build
# Quiet on success; prints the full log of any step that fails.
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=Packages/ArcXKit
APP=1
for arg in "$@"; do
  case "$arg" in
    --no-app) APP=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

# Runs a command quietly: prints only lines matching the pattern on success,
# the whole log on failure.
filtered() {
  local pattern=$1; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    grep -E "$pattern" "$log" || true
    rm -f "$log"
  else
    cat "$log"; rm -f "$log"; exit 1
  fi
}

step "Package build (warnings are errors)"
filtered "Build complete" swift build --package-path "$PKG"

step "Headless tests"
filtered "✘|Test run" swift test --package-path "$PKG"

if [[ $APP -eq 1 ]]; then
  step "App build"
  filtered "BUILD SUCCEEDED" xcodegen generate --quiet
  filtered "BUILD SUCCEEDED" xcodebuild -project ArcX.xcodeproj -scheme ArcX -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode build -quiet
  echo "built .build/xcode/Build/Products/Debug/ArcX.app"
fi

printf '\nverify: all green\n'
