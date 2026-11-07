#!/bin/bash
# verify-clean-machine.sh — PR-8 / ADR-3: the clean-machine gate.
#
#   [1/3] stage the bundled runtime from PINNED inputs (scripts/
#         stage-mirage-runtime.sh: pinned python-build-standalone release +
#         verbatim engine tree at the pinned SHA + RUNTIME-MANIFEST.json);
#   [2/3] spawn smoke FROM the staged bundle, self-hosted: the bundle's own
#         bin/python3.12 drives the probe (no host python, no dev checkout);
#   [3/3] the full default census of the app (TEST SUCCEEDED or refusal).
#
# Refuses on any stage. The real ledger is never touched (disposable stubs
# only). Usage: scripts/verify-clean-machine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIRAGE_HOME="${MIRAGE_HOME:?set MIRAGE_HOME to the pinned MirageV1.0 checkout}"
STAGE="$(mktemp -d /tmp/mirage-clean-machine-XXXXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "== [1/3] staging the bundled runtime =="
"$ROOT/scripts/stage-mirage-runtime.sh" "$STAGE"

echo "== [2/3] staged-bundle spawn smoke (self-hosted) =="
"$STAGE/mirage-runtime/bin/python3.12" "$ROOT/scripts/bundle_smoke.py" "$STAGE/mirage-runtime"

echo "== [3/3] default census =="
cd "$ROOT"
xcodebuild test \
  -project "AsterismaV2.5.xcodeproj" \
  -scheme "AsterismaV2.5" \
  -configuration Debug \
  -destination 'platform=macOS' 2>&1 | tee "$STAGE/census.log" | grep -E "TEST (SUCCEEDED|FAILED)"
grep -q "TEST SUCCEEDED" "$STAGE/census.log"

echo "CLEAN MACHINE OK"
