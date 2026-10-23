---
module: "RetrievalNode.Embedding.ReembedTest"
date: "2026-10-23"
problem_type: test_failure
component: testing
symptoms:
  - "assert {:ok, 1} = Reembed.run(after: first) fails with {:ok, 0} on one branch, passes on another"
root_cause: "The test resumed after the smaller of two random UUIDs and expected one chunk left. Once re-embed became stale-only, the remaining chunk was sometimes the one already re-embedded (count 0) — which one depended on the random UUID order"
severity: low
tags: [flaky-test, uuid, ordering, exunit]
elixir_version: "1.20.2"
---

# An assertion that depended on random UUID order

## Symptoms

A re-embed test passed in one checkout and failed in another, with no code
difference in the module under test.

## Root Cause

Chunk ids are random UUIDs and the test walked them in id order. After the
stale-only behaviour landed, the expected count depended on whether the chunk
re-embedded in the previous step sorted before or after the other.

## Solution

Make the step independent of profile state (`Reembed.run(after: first,
all: true)`), then run the module with several random seeds to confirm.

## Prevention

- Assertions over rows ordered by random keys must not depend on which row
  comes first; derive expectations from the sorted ids, or remove the
  dependency.
- When a behaviour change touches a function, re-read its existing tests'
  assumptions, not just their pass/fail.
