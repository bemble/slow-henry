---
module: "Search.HybridQuery"
date: "2026-10-22"
problem_type: database_issue
component: ecto_query
symptoms:
  - "DBConnection.EncodeError: Postgrex expected a binary of 16 bytes, got \"3262ad70-75c9-41ea-afe6-d34f1e508545\""
  - "Filtering a search by source always crashes; unfiltered search works"
root_cause: "HybridQuery runs raw SQL through Repo.query!, which binds $5::uuid with Postgrex's uuid extension: it expects the 16-byte binary, while callers hold the 36-char string Ecto uses for :binary_id"
severity: medium
tags: [uuid, postgrex, raw-sql, repo-query, binary-id]
elixir_version: "1.20.2"
---

# Raw `Repo.query!` needs dumped UUIDs

## Symptoms

The new search page's per-source filter crashed with
`Postgrex expected a binary of 16 bytes`. Nothing had used the `:source_id`
option of `HybridQuery.search/1` before, and no test covered it.

## Root Cause

Ecto casts `:binary_id` fields for you in Ecto queries. `Repo.query!/2` with
raw SQL bypasses Ecto types: a `$n::uuid` parameter goes straight to
Postgrex, whose uuid extension only accepts the raw 16-byte binary.

## Solution

```elixir
# RetrievalNode.Search.HybridQuery
params = [..., dump_uuid(opts[:source_id]), ...]

defp dump_uuid(nil), do: nil
defp dump_uuid(id), do: Ecto.UUID.dump!(id)
```

A regression test filters by a string UUID; it fails before the fix.

## Prevention

- Every `uuid` parameter of a raw query needs `Ecto.UUID.dump!/1`.
- Give each optional filter of a raw query its own test — untested options
  hide binding bugs until a caller appears.
