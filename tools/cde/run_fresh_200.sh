#!/bin/bash
# run_fresh_200.sh — 200 fresh synthetic rounds through the Swift estimator.
#
# Every batch writes its own prepare, Xcode, export and grade log. Nothing is
# overwritten: a re-run needs a new directory. The demo-profile run exercises
# all 16 catalog personas in each of the 200 rounds with a fresh simulation
# seed.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=tools/cde/fresh-200-20261030
mkdir -p "$OUT"
export FRESH_OUT="$OUT"
ROUNDS=200
# Five rounds per batch: the 10-round batch that reached rounds 151-160 was
# killed by the test host (unexpected exit, no assertion). The smaller batch
# keeps the same case mix while staying well inside the host's memory envelope.
BATCH=5

for ((first=1; first<=ROUNDS; first+=BATCH)); do
  last=$((first+BATCH-1))
  printf -v a '%03d' "$first"
  printf -v b '%03d' "$last"
  stem="rounds-$a-$b"
  if [[ -f "$OUT/$stem-graded.json" ]]; then
    echo "SKIP $stem (already graded)"
    continue
  fi
  echo "START $stem $(date -u +%FT%TZ)"
  if [[ -f "$OUT/$stem-input.json" ]]; then
    # A killed batch leaves a prepared input but no result bundle. Reuse the
    # input and discard only that batch's incomplete Xcode artifacts.
    echo "REUSE $stem prepared input"
    rm -rf "$OUT/$stem.xcresult" "$OUT/$stem-attachments" "$OUT/$stem-predictions.json"
  else
    python3 tools/cde/fresh_100.py prepare --first "$first" --last "$last" \
      > "$OUT/$stem-prepare.log" 2>&1
  fi
  xcodebuild test -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 \
    -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO \
    "-only-testing:AsterismaV2.0Tests/FreshStressBundleTests/testBundledBatch" \
    -resultBundlePath "$OUT/$stem.xcresult" > "$OUT/$stem-xcode.log" 2>&1
  xcrun xcresulttool export attachments --path "$OUT/$stem.xcresult" \
    --output-path "$OUT/$stem-attachments" > "$OUT/$stem-export.log" 2>&1
  python3 - "$OUT" "$stem" <<'PY'
import json, pathlib, shutil, sys
root, stem = pathlib.Path(sys.argv[1]), sys.argv[2]
d = root / (stem + '-attachments')
m = json.loads((d / 'manifest.json').read_text())
names = [a['exportedFileName'] for test in m for a in test['attachments']
         if 'fresh-stress-predictions' in a['suggestedHumanReadableName']]
if len(names) != 1:
    raise ValueError(f'expected one prediction attachment: {names}')
dest = root / (stem + '-predictions.json')
if dest.exists():
    raise FileExistsError(dest)
shutil.copyfile(d / names[0], dest)
PY
  python3 tools/cde/fresh_100.py grade --first "$first" --last "$last" \
    --predictions "$OUT/$stem-predictions.json" --weight 0.5 \
    > "$OUT/$stem-grade.log" 2>&1
  echo "DONE $stem $(date -u +%FT%TZ)"
done

# Demo profiles: every catalog persona, 200 freshly seeded rounds.
if [[ ! -f "$OUT/demo-200-predictions.json" ]]; then
python3 - "AsterismaV2.0Tests/Engines/FreshDemoRounds.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'w') as handle:
    json.dump(list(range(1, 201)), handle, separators=(',', ':'))
    handle.write('\n')
PY
echo "START demo-200 $(date -u +%FT%TZ)"
xcodebuild test -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO \
  "-only-testing:AsterismaV2.0Tests/FreshStressBundleTests/testFreshDemoRounds" \
  -resultBundlePath "$OUT/demo-200.xcresult" > "$OUT/demo-200-xcode.log" 2>&1
xcrun xcresulttool export attachments --path "$OUT/demo-200.xcresult" \
  --output-path "$OUT/demo-200-attachments" > "$OUT/demo-200-export.log" 2>&1
python3 - "$OUT" <<'PY'
import json, pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
d = root / 'demo-200-attachments'
m = json.loads((d / 'manifest.json').read_text())
names = [a['exportedFileName'] for test in m for a in test['attachments']
         if 'fresh-demo-predictions' in a['suggestedHumanReadableName']]
if len(names) != 1:
    raise ValueError(f'expected one demo attachment: {names}')
dest = root / 'demo-200-predictions.json'
if dest.exists():
    raise FileExistsError(dest)
shutil.copyfile(d / names[0], dest)
PY
echo "DONE demo-200 $(date -u +%FT%TZ)"
else
  echo "SKIP demo-200 (already exported)"
fi
echo "ALL DONE $(date -u +%FT%TZ)"
