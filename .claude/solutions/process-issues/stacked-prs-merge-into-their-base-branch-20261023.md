---
module: "(GitHub workflow)"
date: "2026-10-23"
problem_type: process_issue
component: git_workflow
symptoms:
  - "Merged two stacked PRs, but main didn't change"
  - "The bottom PR of the stack now contains three PRs' worth of commits"
root_cause: "A stacked PR's base is the previous PR's branch, so merging it merges into that branch, not main. GitHub only retargets a dependent PR to main automatically when its base branch is deleted after a merge into main; merging from the top of the stack (or out of order) just folds changes into the branch below"
severity: low
tags: [github, stacked-prs, merge-order, retarget]
elixir_version: "1.20.2"
---

# Stacked PRs merge into their base branch, not `main`

## Symptoms

Of a 5-PR stack (`main ← #1 ← #2 ← #3 ← #4 ← #5`), #3 and #2 were merged
first. `main` didn't move: #3 went into #2's branch, then #2 into #1's.

## Root Cause

A PR merges into its base. Stacking keeps each PR's diff readable, but the
merge target is the branch below. GitHub retargets the next PR to `main` only
when the merged PR's branch is deleted — and only for merges into `main`.

## Solution

Nothing was lost: #1 (base `main`) then contained #1+#2+#3. Merge #1, then
for each next PR: `gh pr edit <n> --base main` (its diff shrinks to its own
commit, since the rest is already in `main`), then merge it.

## Prevention

- Merge a stack bottom-up, retargeting each next PR to `main` before
  merging it (or let GitHub do it by deleting branches on merge).
- Prefer merge commits over squash in a stack: squashing rewrites the
  commits the next PR still contains.
- Two stacks never interleave well: when one PR depends on another that is
  only on a fork, a PR to the upstream repo can't be stacked on it at all.
