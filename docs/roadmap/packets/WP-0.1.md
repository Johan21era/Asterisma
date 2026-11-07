# WP-0.1 — Open-work reconciliation

**Status:** completed
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free`
**Baseline:** `dc4afe4`
**Mode:** read-only audit; no file edits

## Objective

Map every open, pending, next, or known-issue item in `README.md`,
`docs/registers/04-handoff.md`, `docs/roadmap/07-master-progression.md`, and
`docs/roadmap/05-remediation-roadmap.md` to current code or tests. Mark each item
`IMPLEMENTED`, `VERIFY_AND_CLOSE`, `STILL_OPEN`, `BLOCKED`, or `UNVERIFIED`.

## Why

G0 requires the execution baseline to contain no stale open item. NA-3, NA-4,
NA-5, and F-12 are the highest-risk inherited claims because they can make the
roadmap start from a false premise.

## Inputs

- the four source documents above;
- the current source tree and test tree;
- existing gate and audit receipts in `docs/plans/`, `docs/registers/`, and
  `docs/audits/`;
- the repository instructions in `AGENTS.md`.

## Allowed paths

Read every tracked file needed for evidence. Write nothing. Do not run
`git commit`, `git push`, `git checkout`, `git reset`, `git clean`, or any
command that changes the tree. Do not read `.env`, `.env.*`, or secret stores.

## Required output

A Markdown table with these columns:

| Source (path:line) | Claim | Code evidence (path:line or command) | Status | Recommendation |
|---|---|---|---|---|

Then a short **UNVERIFIED** list. Every row must cite a real source line and a
real code path or a command. A documentation claim is not evidence that code
exists. If a path does not resolve, mark the row `UNVERIFIED` and say what would
prove it.

## Acceptance

Buffy re-opens every cited path and re-runs every cited command. The packet is
accepted only when every `IMPLEMENTED` row has a code receipt and every
`VERIFY_AND_CLOSE` row has a focused verification step. Model claims are not
receipts.

## Budget

One session, maximum 40 message turns, stop at 30 minutes or 80 messages,
whichever comes first. Do not start a second packet.

## Stop authority

Buffy may interrupt or terminate this session at any time, deny any request,
and discard the worktree. Stop immediately if asked to exceed the allowed paths,
read a secret, or make a code change.

## Handoff

Return the table and the UNVERIFIED list in the session response. Do not write a
report file; Buffy will verify the findings and decide what enters the repo.

## Result

Audit completed in `ses_e4be99068ffeSUBkfahAgpeIy5` on 2026-11-07. The verified
subset is recorded in `docs/audits/2026-11-07-open-work-reconciliation.md`.
Unverified and still-open rows remain open; the model's table is not a receipt.
