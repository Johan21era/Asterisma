#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=tools/cde/fresh-100-20261030
for first in 2 12 22 32 42 52 62 72 82 92; do
  last=$((first+9)); if (( last > 100 )); then last=100; fi
  printf -v a '%03d' "$first"; printf -v b '%03d' "$last"
  stem="rounds-$a-$b"
  echo "START $stem $(date -u +%FT%TZ)"
  python3 tools/cde/fresh_100.py prepare --first "$first" --last "$last" > "$OUT/$stem-prepare.log" 2>&1
  xcodebuild test -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO "-only-testing:AsterismaV2.5Tests/FreshStressBundleTests/testBundledBatch" -resultBundlePath "$OUT/$stem.xcresult" > "$OUT/$stem-xcode.log" 2>&1
  xcrun xcresulttool export attachments --path "$OUT/$stem.xcresult" --output-path "$OUT/$stem-attachments" > "$OUT/$stem-export.log" 2>&1
  python3 - "$OUT" "$stem" <<'PY'
import json, pathlib, shutil, sys
root,stem=pathlib.Path(sys.argv[1]),sys.argv[2]
d=root/(stem+'-attachments'); m=json.loads((d/'manifest.json').read_text())
names=[a['exportedFileName'] for test in m for a in test['attachments'] if 'fresh-stress-predictions' in a['suggestedHumanReadableName']]
if len(names)!=1: raise ValueError(f'expected one prediction attachment: {names}')
dest=root/(stem+'-predictions.json')
if dest.exists(): raise FileExistsError(dest)
shutil.copyfile(d/names[0],dest)
PY
  python3 tools/cde/fresh_100.py grade --first "$first" --last "$last" --predictions "$OUT/$stem-predictions.json" > "$OUT/$stem-grade.log" 2>&1
  echo "DONE $stem $(date -u +%FT%TZ)"
done
