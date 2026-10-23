# Plan: Embeddings on Ollama — speed, outages, profiles, Connections page

**Status**: DONE (retroactive write-up, 2026-10-23) · **PRs**: bemble/slow-henry #9–#12
(split from the closed #8)

## Problem

Embedding with Bumblebee + EXLA on the devcontainer's CPU was the bottleneck:
~2.7 chunks/s at 500–900 % CPU, hours to index the corpus (100k+ chunks after
the git PRs and Drive), the owner's Mac unusable meanwhile, and repeated OOM
kills of the server in the container. EXLA has no Metal backend, so running
the same binary natively on macOS would not use the GPU either.

## Decisions

1. **Ollama on the Mac's GPU**, called over its OpenAI-compatible
   `/v1/embeddings` (so `llama-server` / LM Studio work too), selected by
   `OLLAMA_ENDPOINT` (the owner preferred a self-explanatory name to
   `EMBEDDING_URL`), model `OLLAMA_EMBEDDING_MODEL` (default
   `nomic-embed-text`). The in-process serving is then not started at all.
2. **Same model, same post-processing**: `nomic-embed-text` v1.5 (137M, F16),
   Matryoshka 384 dims + L2 renormalisation, so `vector(384)` doesn't change.
   MLX was considered and dropped: Ollama uses Metal via ggml, and for a 137M
   BERT-style model the gain is CPU→GPU, not Metal→MLX.
3. **Use nomic's task prefixes** (`search_document: ` / `search_query: `),
   which the original pipeline never applied. `embed/1` is queries,
   `embed_batch/1` is indexed chunks — the split the prefixes rely on.
4. **Re-embed without re-chunking** (`mix rn.reembed`): the embedded text is
   rebuilt from the stored `context_breadcrumb` + `content` (verified: stored
   vs reconstructed, median cosine 1.0 on 200 chunks).
5. **An outage is not a file failure.** A new `Embedding.Unavailable`
   (connection refused, timeout, 502/503/504): `SourceOwner` gives the
   attempt back and defers the whole source for a minute; search falls back
   to BM25-only ranking and says so (`mode: :text_only`). See the outage
   solution doc.
6. **Record which setup produced each vector** (`chunks.embedding_profile`,
   `Embedding.profile/0`), so a switch can't silently mix vector spaces:
   reuse only same-profile vectors, re-embed only stale chunks, show coverage
   in the UI. See the mixed-vector-spaces solution doc.
7. **A Connections page** replaces the Google page: Ollama status (version,
   model pulled, round trip, "Check again") and index coverage per profile,
   plus Google Drive authorization.
8. **Four PRs instead of one** (client → outages → profiles → UI), built by
   deriving each intermediate state from the final tree, each one green on
   its own; the last one's tree is identical to the original PR.

## Benchmark (256 real chunks, avg 236 chars)

| Backend | Throughput | Time |
|---|---|---|
| Ollama on a Mac Studio GPU (no prefix) | ~50 chunks/s | 5.1 s |
| Ollama with prefixes | ~45 chunks/s | 5.6 s |
| EXLA, devcontainer CPU (14 arm64 cores) | 2.7 chunks/s | 94 s (+10 s warm-up) |

Speed-up ×18.5. Cosine(EXLA, Ollama no-prefix): mean 0.9999, min 0.988.

## Phases

- [x] #9 `Embedding.OllamaImpl`, runtime selection, prefixes, basic
      `rn.reembed`, README "Embeddings" section; llama.cpp stub removed
- [x] #10 `Embedding.Unavailable`, `PendingChunks.defer_unavailable/3`,
      `SourceOwner` halts the pass, `Search.search/2` text-only fallback, UI
      notice, MCP `mode`
- [x] #11 migration `embedding_profile`, `profile/0` on every impl,
      profile-aware reuse in `FileIngest`, stale-only `rn.reembed` (`--all`),
      content-hash guard on re-embed writes
- [x] #12 Connections page (`/connections`; `/google` and the OAuth callback
      path kept)

## Migration of the live index

The index was switched while partly built: 21,842 chunks embedded on the CPU
without prefixes, the rest via Ollama with prefixes. Profiles were backfilled
from the write timestamps (a 13-minute gap with no writes separated the CPU
server's stop from the first Ollama write), then only the CPU-era chunks were
re-embedded. Result: 103,192 chunks on `ollama:nomic-embed-text:nomic-prefixes:384`.

## Follow-ups

- Retrieval quality of the prefixes was not measured on this corpus
  (`mix rn.bench` exists but wasn't run)
- `qwen3-embedding:0.6b` (multilingual, better on code) is a candidate model;
  switching is now `OLLAMA_EMBEDDING_MODEL=… mix rn.reembed`
- The app's future home is the LAN box: Ollama must then be reachable on the
  LAN (`OLLAMA_HOST=0.0.0.0` on the Mac, no auth — LAN only)
