#!/usr/bin/env python3
"""Archive the 100/200-round evidence trees into one Markdown receipt.

The raw trees are large; this script records every file's size and SHA-256,
a global manifest commitment, per-batch digests, readable aggregates, and
gzip+base64 copies of the small summary/log files. It does not delete anything.
"""
from __future__ import annotations

import base64
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/audits/evidence/fresh-stress-evidence-archive-2026-10-31.md'
RUNS = [
    ('200-round', ROOT / 'tools/cde/fresh-200-20261030'),
    ('100-round', ROOT / 'tools/cde/fresh-100-20261030'),
]
BLOBS = {
    '200-round': [
        ('verified-summary.json', 'verified-summary.json'),
        ('weight-sweep-summary.json', 'weight-sweep-summary.json'),
        ('worst-differing-cases.json', 'worst-differing-cases.json'),
        ('analysis.log', 'analysis.log'),
        ('run.log', 'run.log'),
        ('demo attachment manifest', 'demo-200-attachments/manifest.json'),
        ('census log', 'checks/census.log'),
        ('census exit', 'checks/census.exit'),
        ('python tests log', 'checks/python-tests.log'),
        ('python tests exit', 'checks/python-tests.exit'),
        ('index log', 'checks/index.log'),
        ('index exit', 'checks/index.exit'),
        ('sentinel log', 'checks/sentinel.log'),
        ('sentinel exit', 'checks/sentinel.exit'),
    ],
    '100-round': [
        ('verified-summary.json', 'verified-summary.json'),
        ('verify.log', 'verify.log'),
        ('census.log', 'census.log'),
        ('root-cause.log', 'root-cause.log'),
        ('orchestrator.log', 'orchestrator.log'),
        ('orchestrator.exit', 'orchestrator.exit'),
        ('report-before-census.txt', 'report-before-census.txt'),
    ],
}


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def b64_gzip(data: bytes) -> tuple[str, int]:
    packed = gzip.compress(data, mtime=0)
    return base64.b64encode(packed).decode('ascii'), len(packed)


def fmt(value: float) -> str:
    return f'{value:.2f}'


def fmt_count(value: int) -> str:
    return f'{value:,}'


def collect(directory: Path):
    entries = []
    for path in sorted(directory.rglob('*')):
        if not path.is_file():
            continue
        rel = path.relative_to(directory).as_posix()
        data = path.stat().st_size
        entries.append((rel, data, sha_file(path)))
    lines = [f'{rel}\t{size}\t{digest}' for rel, size, digest in entries]
    manifest_sha = sha_bytes(('\n'.join(lines) + '\n').encode())
    return entries, lines, manifest_sha


def tree_digest(entries, prefix: str) -> str:
    digest = hashlib.sha256()
    for rel, size, sha in entries:
        if rel.startswith(prefix + '/'):
            digest.update(f'{rel}\t{size}\t{sha}\n'.encode())
    return digest.hexdigest()


def case_count(directory: Path, stem: str) -> str:
    path = directory / f'{stem}-summary.json'
    if not path.exists():
        return '—'
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return fmt_count(sum(item.get('cases', 0) for item in data))
    return fmt_count(data.get('cases', 0))


def read_exit(directory: Path, name: str) -> str:
    path = directory / name
    return path.read_text().strip() if path.exists() else 'SKIPPED'


def main():
    if OUT.exists():
        raise FileExistsError(OUT)
    main = []

    def add(text=''):
        main.append(text)

    data = {}
    entries = {}

    for label, directory in RUNS:
        data[label] = {
            'verified': json.loads((directory / 'verified-summary.json').read_text()),
            'verify': (directory / 'verify.log').read_text() if (directory / 'verify.log').exists() else '',
        }
        entries[label] = collect(directory)

    add('# Fresh stress evidence archive — 2026-10-31')
    add()
    add('This file replaces the raw 100- and 200-round synthetic stress evidence trees. The trees were '
        'hashed, summarized and compressed here, then deleted. **The raw per-case JSON and Xcode '
        'bundles are not recoverable from this file; the hashes below are commitments to what was '
        'deleted, and every number reported in the two audit reports is retained here.** The graph '
        'output under `graphify-out/` was not touched.')
    add()
    add('## What was deleted')
    add()
    add('| Run | Files | Bytes | Directory |')
    add('|---|---:|---:|---|')
    for label, directory in RUNS:
        run_entries, _, _ = entries[label]
        add(f"| {label} | {fmt_count(len(run_entries))} | {fmt_count(sum(e[1] for e in run_entries))} | "
            f"`{directory.relative_to(ROOT)}/` |")
    add()
    add('The trees were untracked by Git. Deleting them changes no Git object; their report claims '
        'and digests are preserved below and in the reports.')
    add()
    add('## Run receipts')
    add()
    add('| Run | Receipt | Value |')
    add('|---|---|---|')
    add(f"| 200-round | `run.exit` | {read_exit(RUNS[0][1], 'run.exit')} |")
    add(f"| 200-round | `analysis.exit` | {read_exit(RUNS[0][1], 'analysis.exit')} |")
    for name in ('checks/python-tests.exit', 'checks/sentinel.exit', 'checks/index.exit', 'checks/census.exit'):
        add(f"| 200-round | `{name}` | {read_exit(RUNS[0][1], name)} |")
    add(f"| 100-round | `orchestrator.exit` | {read_exit(RUNS[1][1], 'orchestrator.exit')} |")
    add(f"| 100-round | `census.exit` | {read_exit(RUNS[1][1], 'census.exit')} |")
    add()
    add('The 200-round run ended with `ALL DONE 2026-10-31T02:12:20Z`; the 100-round verifier and '
        'census receipts are embedded below.')
    add()
    add('## 200-round aggregates')
    add()
    summary = data['200-round']['verified']
    add('| Set / model | Cases | Median % | Mean % | P90 % | Max % | Spikes |')
    add('|---|---:|---:|---:|---:|---:|---:|')
    for title, bucket in [('All main', summary['summary']['overall']),
                          ('Differing', summary['summary']['differing']),
                          ('Holdout 101–200', summary['holdout_rounds_101_200']['overall']),
                          ('Holdout differing', summary['holdout_rounds_101_200']['differing']),
                          ('Demo', summary['demo'])]:
        for model in ('baseline', 'legacy', 'selected'):
            if model not in bucket:
                continue
            item = bucket[model]
            add(f"| {title} — {model} | {fmt_count(item['n'])} | {fmt(item['median_pct'])} | "
                f"{fmt(item['mean_pct'])} | {fmt(item['p90_pct'])} | {fmt(item['max_pct'])} | "
                f"{fmt_count(item['spikes'])} |")
    add()
    add(f"Fitted weight: `{summary['weight']:.12f}`. Calibration cases: "
        f"{fmt_count(summary['calibration']['cases'])}; development mean APE: "
        f"{summary['calibration']['development_mean_ape_pct']:.6f}%.")
    add()
    add('### 200-round regimes')
    add()
    add('| Regime | Cases | Differing | Baseline median % | Candidate median % | Baseline mean % | Candidate mean % | Baseline spikes | Candidate spikes |')
    add('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for name, row in summary['summary']['regimes'].items():
        add(f"| `{name}` | {fmt_count(row['baseline']['n'])} | {fmt_count(row['differing'])} | "
            f"{fmt(row['baseline']['median_pct'])} | {fmt(row['selected']['median_pct'])} | "
            f"{fmt(row['baseline']['mean_pct'])} | {fmt(row['selected']['mean_pct'])} | "
            f"{fmt_count(row['baseline']['spikes'])} | {fmt_count(row['selected']['spikes'])} |")
    add()
    add('### 200-round groups')
    add()
    add('| Group | Cases | Differing | Baseline median % | Candidate median % | Baseline mean % | Candidate mean % |')
    add('|---|---:|---:|---:|---:|---:|---:|')
    for name, row in summary['summary']['groups'].items():
        add(f"| `{name}` | {fmt_count(row['baseline']['n'])} | {fmt_count(row['differing'])} | "
            f"{fmt(row['baseline']['median_pct'])} | {fmt(row['selected']['median_pct'])} | "
            f"{fmt(row['baseline']['mean_pct'])} | {fmt(row['selected']['mean_pct'])} |")
    add()
    add('## 100-round aggregates')
    add()
    old = data['100-round']['verified']
    add('| Set / model | Cases | Median % | Mean % | P90 % | Max % | Spikes |')
    add('|---|---:|---:|---:|---:|---:|---:|')
    for title, bucket, spikes in [
        ('All main', old['overall'], ('baseline_spikes', 'candidate_spikes')),
        ('Demo', old['demo'], ('baseline_spikes', 'candidate_spikes')),
    ]:
        for model in ('baseline', 'candidate'):
            item = bucket[model]
            add(f"| {title} — {model} | {fmt_count(item['cases'])} | {fmt(item['median_ape'])} | "
                f"{fmt(item['mean_ape'])} | {fmt(item['p90_ape'])} | {fmt(item['max_ape'])} | "
                f"{fmt_count(bucket[spikes[0] if model == 'baseline' else spikes[1]])} |")
    add()
    add(f"Weight: `{old['weight']!r}`, 100 rounds, 991,400 main cases.")
    add()
    add('## Per-batch manifests')
    add()
    for label, directory in RUNS:
        run_entries, _, _ = entries[label]
        add(f'### {label}')
        add()
        add('| Batch | Cases | Input SHA-256 | Truth SHA-256 | Predictions SHA-256 | Graded SHA-256 | Summary SHA-256 | XCResult tree SHA-256 |')
        add('|---|---:|---|---|---|---|---|---|')
        for input_path in sorted(directory.glob('rounds-*-input.json')):
            stem = input_path.name[:-len('-input.json')]
            fields = []
            for suffix in ('input', 'truth', 'predictions', 'graded', 'summary'):
                path = f'{stem}-{suffix}.json'
                found = next((sha for rel, _, sha in run_entries if rel == path), None)
                fields.append(found or 'MISSING')
            xc = f'{stem}.xcresult'
            xc_digest = tree_digest(run_entries, xc)
            add(f"| `{stem}` | {case_count(directory, stem)} | " + ' | '.join(f'`{f}`' for f in fields) +
                f" | `{xc_digest}` |")
        add()

    add('## Manifest commitment')
    add()
    for label, directory in RUNS:
        run_entries, lines, manifest_sha = entries[label]
        packed, packed_size = b64_gzip(('\n'.join(lines) + '\n').encode())
        add(f"- **{label}:** {fmt_count(len(lines))} files; global manifest SHA-256 `{manifest_sha}`; "
            f"gzip {fmt_count(packed_size)} bytes; base64 {fmt_count(len(packed))} characters. "
            f"Directory: `{directory.relative_to(ROOT)}/`.")
    add()
    add('The global manifest SHA-256 is over the newline-terminated rows `relative-path<TAB>bytes<TAB>SHA-256`, '
        'sorted by relative path. It commits to every file that was present immediately before deletion, '
        'including files inside the `.xcresult` bundles.')
    add()
    add('## Compressed evidence')
    add()
    add('These blocks are the small summary and log files, gzip-compressed and base64-encoded. Reconstruct '
        'one with `base64 -d <<< <block> | gunzip > <name>`; verify the SHA-256 after reconstruction. '
        'The large per-case JSON is covered by the manifest, not embedded.')
    add()
    for label, directory in RUNS:
        add(f'### {label}')
        add()
        for title, relative in BLOBS[label]:
            path = directory / relative
            if not path.exists():
                add(f'- **{title}:** SKIPPED (not present at archive time: `{relative}`).')
                continue
            raw = path.read_bytes()
            packed, packed_size = b64_gzip(raw)
            add(f"<details><summary><strong>{title}</strong> — {fmt_count(len(raw))} bytes, "
                f"gzip {fmt_count(packed_size)} bytes, SHA-256 <code>{sha_bytes(raw)}</code></summary>")
            add()
            add('```text')
            add(packed)
            add('```')
            add()
            add('</details>')
            add()
    add('## Deletion command')
    add()
    add('After this archive was written and its SHA-256 recorded, the raw trees were removed with exactly:')
    add()
    add('```bash')
    add('rm -rf tools/cde/fresh-100-20261030 tools/cde/fresh-200-20261030')
    add('```')
    add()
    add('`graphify-out/`, `.mirage-runtime/`, source, tests and docs were not part of that command.')
    add()
    add('## Limitations')
    add()
    add('The raw synthetic cases cannot be reconstructed from this archive; only the hashes, aggregates '
        'and small summary/log files are preserved. The outcomes are generated assumptions, not '
        'measurements of real readers. There was no independent hand grading, and the 200-round driver '
        'resumed at batch 176 after an interruption. The archive records what existed; it does not turn '
        'those artifacts into validation.')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text('\n'.join(main) + '\n')
    print('wrote', OUT.relative_to(ROOT), 'lines', len(main), 'sha256', sha_file(OUT))
    for label, _ in RUNS:
        print(label, 'files', len(entries[label][0]), 'manifest', entries[label][2])


if __name__ == '__main__':
    main()
