#!/bin/sh
# Proves scripts/test.sh can fail. It runs that script with stand-in tools, so it takes a second and needs no simulator.
# A test script that always exits 0 looks fine right up until it hides a real failure.
set -eu
cd "$(dirname "$0")/.."
TOOLS=$(mktemp -d "${TMPDIR:-/tmp}/homereel-gate.XXXXXX")
trap 'rm -rf "$TOOLS"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$TOOLS/xcodegen"
chmod +x "$TOOLS/xcodegen"

run() {   # run <exit code from the stand-in xcodebuild>
  printf '#!/bin/sh\nexit %s\n' "$1" > "$TOOLS/xcodebuild"
  chmod +x "$TOOLS/xcodebuild"
  STATUS=0
  PATH="$TOOLS:$PATH" sh scripts/test.sh >/dev/null 2>&1 || STATUS=$?
  echo "$STATUS"
}

[ "$(run 0)" = 0 ] || { echo "FAILED: a passing run did not exit 0"; exit 1; }
[ "$(run 65)" = 65 ] || { echo "FAILED: a failing run did not report its failure"; exit 1; }
echo "test.sh gate OK: passes on success, fails on failure"
