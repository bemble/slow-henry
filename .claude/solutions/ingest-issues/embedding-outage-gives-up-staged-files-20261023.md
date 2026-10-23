---
module: "Ingest.SourceOwner"
date: "2026-10-23"
problem_type: design_issue
component: ingest_pipeline
symptoms:
  - "(anticipated) With the embedding server down for more than ~30 minutes, every staged file reaches attempts=5 and is never retried"
  - "(anticipated) Search crashes because the query can't be embedded"
root_cause: "SourceOwner counts an attempt when it claims a row (mark_attempt before apply) and gives up after 5 attempts with 1/2/4/8/16-minute backoff. With an external embedding server, an outage is not a property of the file, yet it was treated as a per-file failure; search had no path without a query vector"
severity: high
tags: [ollama, outage, retries, backoff, search-fallback, bm25]
elixir_version: "1.20.2"
---

# An embedding outage would give up every staged file

## Symptoms

Found by review when moving embeddings to an Ollama server on another
machine (a Mac that can sleep): if it is unreachable for about half an hour,
every staged file exhausts its 5 attempts and stays parked until manual
intervention; the search page and the `semantic_search` MCP tool crash.

## Root Cause

The retry policy was designed for per-file failures (parse crashes, bad
content). An external dependency being down is a different failure class:
retrying faster or giving up is wrong, waiting is right.

## Solution

- `Embedding.Unavailable` (connection refused, timeout, 502/503/504), raised
  by `OllamaImpl`; other errors still fail the file.
- `SourceOwner` rescues it separately: the attempt is given back, the whole
  source is deferred by a minute (`PendingChunks.defer_unavailable/3`, one
  UPDATE), and the pass halts — so the owner idles instead of hammering a
  server that is down, and nothing is given up.
- `Search.search/2` falls back to BM25 when the query can't be embedded:
  `HybridQuery` accepts a nil embedding (`AND $1::vector IS NOT NULL` empties
  the vector CTE, RRF ranks on full-text alone) and returns
  `mode: :text_only`, shown by the search page and returned by the MCP tool.

### Files Changed

- `lib/retrieval_node/embedding/unavailable.ex`, `ollama_impl.ex`
- `lib/retrieval_node/ingest/source_owner.ex`, `pending_chunks.ex`
- `lib/retrieval_node/search.ex`, `search/hybrid_query.ex`
- `lib/retrieval_node/mcp/tools/semantic_search.ex`, `live/search_live.ex`

## Prevention

- When a stage starts depending on an external service, revisit the retry
  policy: separate "this input is bad" from "the dependency is down".
- Degrade read paths (search) instead of failing them.
