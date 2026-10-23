---
module: "Ingest.Workers.RepoSync"
date: "2026-10-22"
problem_type: performance_issue
component: ingest_pipeline
symptoms:
  - "First sync of 8 repos: 0 chunks/min for minutes while beam.smp sits at ~900% CPU"
  - "Every source shows one staged row at attempts=1; one source is stuck on a 554 KB yarn.lock"
root_cause: "RepoSync staged every text file, including lockfiles and other generated text; one yarn.lock became ~1,600 chunks and the shared embedding serving processed them while every other source's owner waited"
severity: high
tags: [lockfile, generated-files, embedding, throughput, staging, repo-sync]
elixir_version: "1.20.2"
---

# A lockfile monopolizes the shared embedding serving

## Symptoms

After registering 8 repos, staging finished quickly (1,743 files) but the
chunk count stayed flat for minutes while the BEAM used ~900 % CPU. Each
source's `SourceOwner` had claimed one row; one of them was `yarn.lock`
(554 KB), claimed 7 minutes earlier.

## Investigation

1. Rows were advancing (`updated_at` moving) but nothing committed, so the
   owners were waiting, not crashing.
2. The embedding `Nx.Serving` is shared by every owner. The lockfile alone
   chunked into ~1,600 chunks, all queued in front of the other sources'.
3. After it finished, 1,611 of the source's chunks came from that one file —
   pure noise for retrieval.

## Root Cause

`RepoSync` filtered binaries only. Lockfiles, minified bundles, source maps,
snapshots, SVGs and very large text files are text, so they were staged,
chunked and embedded like source code, and their sheer size starved the
shared serving.

## Solution

Decide indexability where bytes are staged, and stage the rest as deletions
(so chunks from an earlier, smaller version of the file are reconciled away):

```elixir
# RetrievalNode.Ingest.Workers.RepoSync
@skip_basenames ~w(yarn.lock package-lock.json pnpm-lock.yaml mix.lock poetry.lock
                   uv.lock Pipfile.lock Cargo.lock go.sum Gemfile.lock composer.lock
                   flake.lock .terraform.lock.hcl)
@skip_suffixes ~w(.min.js .min.css .map .snap .svg)
@max_indexed_bytes 256 * 1024

def indexable?(path, content) do
  base = Path.basename(path)

  byte_size(content) <= @max_indexed_bytes and base not in @skip_basenames and
    not String.ends_with?(base, @skip_suffixes)
end
```

Already-staged and already-indexed offenders were cleaned with a one-off
script using the same predicate.

### Files Changed

- `lib/retrieval_node/ingest/workers/repo_sync.ex` — `indexable?/2`, used next
  to `Chunking.binary_content?/1`
- `test/retrieval_node/ingest/workers/repo_sync_test.exs`

## Prevention

- A shared, CPU-bound stage needs an input-size budget: one pathological
  input stalls every producer behind it.
- Look at the top files by chunk count after a first real ingest.

## Related

- `.claude/solutions/ecto-issues/binary-file-invalid-utf8-staging-insert-20260715.md`
  — the same "guard at the staging seam" principle, for binaries
