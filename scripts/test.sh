#!/bin/sh
# Local test runner for HomeReel. Runs on your Mac (the project has no hosted CI).
# Usage: scripts/test.sh          unit tests plus simulator UI tests against the pretend server
#        scripts/test.sh unit     unit tests only (about 1 minute)
# Exits with xcodebuild's own status, so a failed test fails this script. On failure the full log is kept.
# Builds are SIGNED on purpose: unsigned simulator builds cannot use the Keychain.
set -eu
cd "$(dirname "$0")/.."
# An Apple TV 4K simulator at 1080p. Set SIM=<simulator id> to pick a specific one (see: xcrun simctl list devices).
if [ -n "${SIM:-}" ]; then DEST="platform=tvOS Simulator,id=$SIM"; else DEST="platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)"; fi
xcodegen generate >/dev/null
ONLY=""
[ "${1:-}" = "unit" ] && ONLY="-only-testing:HomeReelTests"
LOG=$(mktemp "${TMPDIR:-/tmp}/homereel-test.XXXXXX")
STATUS=0
xcodebuild -project HomeReel.xcodeproj -scheme HomeReel -sdk appletvsimulator \
  -destination "$DEST" -derivedDataPath build -allowProvisioningUpdates \
  -parallel-testing-enabled NO -disable-concurrent-destination-testing $ONLY test >"$LOG" 2>&1 || STATUS=$?
# A pipeline reports the status of its last command, so the status above is saved before this filter runs.
grep -E "error:|failed|Executed [0-9]+ tests, with [0-9]+ failures .* seconds$|TEST (SUCCEEDED|FAILED)" "$LOG" | tail -8 || true
if [ "$STATUS" -eq 0 ]; then rm -f "$LOG"; else echo "xcodebuild failed with status $STATUS. Full log: $LOG"; fi
exit "$STATUS"
