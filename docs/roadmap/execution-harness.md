# Execution harness — delegated work

**Status:** active for the 2026-11-07 progression session.
**Authority:** Buffy is the main administrator. Delegated models execute assigned
packets; they do not own scope, safety, credentials, merges, or release state.

## 1. Worktree protocol

One packet, one worktree, one writer. The main tree is never the agent's working
tree.

```bash
mkdir -p ../asterisma-worktrees
git worktree add ../asterisma-worktrees/<wp>-<slug> \
  -b agent/<wp>-<slug> main
git worktree list
```

- **Path:** `../asterisma-worktrees/<wp>-<slug>`.
- **Branch:** `agent/<wp>-<slug>`.
- **Start point:** the commit named in the packet; default `main`.
- **Writers:** one agent per worktree. Shared files (`project.pbxproj`,
  `Book2.swift`, `LibraryDatabase.swift`, `docs/INDEX.md`) have one writer per
  phase and are serialized by Buffy.
- **Agent commits:** forbidden. The agent leaves changes in the worktree with a
  handoff. Buffy reviews, runs checks, and creates the commit if accepted.
- **Cleanup:** after the gate, remove the worktree with
  `git worktree remove <path>`; keep the branch until the gate passes.

Read-only audits use a worktree too. The agent must not write files or run
`git commit`, `git push`, `git checkout`, `git reset`, `git clean`, or any
state-changing command.

## 2. Packet protocol

Every delegation names a packet in `docs/roadmap/packets/WP-<id>.md` using the
fields in the master roadmap: objective, why, baseline, inputs, allowed paths,
forbidden paths, acceptance, verification, output, model, session budget, stop
authority, and handoff.

A packet is not ready if it has no allowed-path list, no acceptance check, or no
stop condition. Buffy may deny, narrow, reassign, or terminate it at any time.

## 3. Handoff protocol

The agent writes `.agent-handoff/WP-<id>.md` in its worktree, or returns the
same fields in a read-only session. The file is gitignored. It records:

- exact model handle and session ID;
- worktree path and starting commit;
- files changed;
- commands run and exit statuses;
- tests passed, failed, and skipped;
- unresolved questions;
- the agent's summary, labelled as model output.

The handoff is not evidence. Buffy reruns the relevant checks and records the
receipt.

## 4. Merge checklist

Buffy, not the agent, performs every item:

1. `git -C <worktree> status --short` shows only allowed paths.
2. `git -C <worktree> diff --check` exits 0.
3. No `.env`, secret, credential, generated build output, source map, or
   unrelated file is in the diff.
4. The focused build and tests named in the packet pass.
5. The full census passes when the packet changes app code or a gate requires
   it.
6. Documentation edits pass `python3 scripts/audit-markdown.py <file>` and the
   index validation.
7. The diff is reviewed as code, not accepted from the agent's summary.
8. Buffy stages only the reviewed files, commits on the agent branch, and merges
   by fast-forward if `main` has not moved; otherwise Buffy rebases or
   cherry-picks and reruns the affected checks.
9. The phase gate receipt is written before cleanup.
10. The worktree is removed and the resource ledger is updated.

## 5. Concurrency and stop authority

- At most three agent sessions are active at once.
- No agent starts a second packet before its first handoff is written.
- Buffy may interrupt, inspect, or terminate any session; deny any request;
  revert any change; and discard any unmerged worktree.
- A regression, broken build, bad merge, or data-loss risk introduced by an
  agent remains Buffy's responsibility.

## 6. Minimum checks by packet type

| Packet type | Minimum checks |
|---|---|
| Read-only audit | cited paths resolve; command claims reproduced where cheap |
| Documentation | `audit-markdown.py`, `--validate-only`, `git diff --check` |
| App code | Debug build, focused tests, full census before merge |
| Schema/persistence | Build, focused migration tests, 50-cycle create/delete, full census |
| Release/packaging | Build, signed artifact check, clean-machine script |
