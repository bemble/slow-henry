---
module: "Ingest.Workers.PullRequestSync"
date: "2026-10-23"
problem_type: database_issue
component: ecto_query
symptoms:
  - "(prevented) Two sync workers of the same source rewriting each other's watermark in sync_states.cursor"
root_cause: "RepoSync (last_sha) and the new PullRequestSync (prs_updated_since) share one sync_states row per source and can run concurrently (each is only unique per worker). Writing the cursor as Map.put(loaded_cursor, key, value) rewrites the whole jsonb with a stale copy of the other worker's key"
severity: medium
tags: [jsonb, lost-update, concurrency, oban, watermark]
elixir_version: "1.20.2"
---

# Two workers, one jsonb cursor: lost updates

## Symptoms

None in production — caught while adding `PullRequestSync`. Both workers'
`unique` constraints are per worker, so a `RepoSync` and a `PullRequestSync`
of the same source may run at the same time, both holding a copy of the
cursor loaded at their start.

## Root Cause

Read-modify-write of a whole jsonb document: the last writer wins for *every*
key, not just its own.

## Solution

Each worker updates only its own key, atomically, in SQL:

```elixir
Repo.update_all(
  from(s in SyncState,
    where: s.id == ^state.id,
    update: [set: [cursor: fragment(
      "jsonb_set(coalesce(?, '{}'::jsonb), '{last_sha}', to_jsonb(?::text))",
      s.cursor, ^new_sha)]]
  ),
  []
)
```

(`prs_updated_since` likewise in `PullRequestSync`.) A test checks that a PR
sync keeps the repo's `last_sha`.

## Prevention

- When a second writer starts sharing a jsonb column, switch every writer
  to key-level `jsonb_set` (or split the row).
