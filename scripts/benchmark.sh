#!/bin/bash
# benchmark.sh — opt-in baseline benchmark against a COPY of the real store.
# Never points the app at the live store; never writes to it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIVE="$HOME/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rt-bench.XXXXXX")"
cp -R "$LIVE/." "$WORK/"
OUT="${RT_BENCH_OUT:-$WORK/baseline.json}"

echo "benchmark copy: $WORK"
TEST_RUNNER_RT_BENCH_LIBRARY="$WORK/library.json" \
xcodebuild test \
  -project "AsterismaV2.5.xcodeproj" \
  -scheme "AsterismaV2.5" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:"AsterismaV2.5Tests/BedrockBaselineTests" 2>&1 | tee "$WORK/bench.log" | tail -20

LINE="$(grep -E 'BEDROCK_BASELINE_JSON ' "$WORK/bench.log" | tail -1 | sed 's/^.*BEDROCK_BASELINE_JSON //')"
if [[ -n "$LINE" ]]; then
  printf '%s\n' "$LINE" > "$OUT"
  echo "---- benchmark receipt: $OUT"
  cat "$OUT"
else
  echo "benchmark receipt not found in log; inspect $WORK/bench.log" >&2
  exit 1
fi
