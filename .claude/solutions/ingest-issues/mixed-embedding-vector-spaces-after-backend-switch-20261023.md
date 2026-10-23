---
module: "Embedding"
date: "2026-10-23"
problem_type: design_issue
component: embeddings
symptoms:
  - "After switching from the in-process CPU model to Ollama with task prefixes, old and new vectors coexist in one index with nothing showing it"
  - "A re-embed run interrupted midway can't tell which chunks are done"
root_cause: "Nothing recorded which backend/model/prefixes produced a vector, and FileIngest reused any stored vector whose chunk text was unchanged — so a switch silently mixed vector spaces until a full re-embed, and partial re-embeds weren't resumable"
severity: medium
tags: [embeddings, vector-space, re-embed, migration, ollama, profiles]
elixir_version: "1.20.2"
---

# Switching embedding setups silently mixes vector spaces

## Symptoms

The index was switched to Ollama (with nomic's `search_document:` /
`search_query:` prefixes) while partly built. New chunks got prefixed
vectors, old ones kept CPU-era unprefixed vectors, and `FileIngest`'s reuse
kept old vectors for unchanged chunks forever. A first re-embed run was
interrupted and had to be restarted from zero.

## Root Cause

A vector is only comparable to vectors from the same backend, model, prefixes
and dimensions — but that identity wasn't stored anywhere.

## Solution

- `profile/0` on the `Embedding` behaviour (e.g.
  `ollama:nomic-embed-text:nomic-prefixes:384`), stored on every chunk in
  `chunks.embedding_profile` (nullable migration; NULL = before profiles).
- `FileIngest` reuses a stored vector only if its profile equals the current
  one.
- `mix rn.reembed` redoes only chunks not on the current profile (resumable
  by re-running; `--all` forces), rebuilding the embedded text from the
  stored breadcrumb + content (no re-chunking), and writes only if the chunk's
  `content_hash` is unchanged (the server may rewrite it meanwhile).
- The Connections page shows coverage per profile.

For the live index, profiles were backfilled from write timestamps: a
13-minute window with no writes separated the CPU server's stop from the
first Ollama write, so `updated_at` before/after it identified each
population; only the 21,842 CPU-era chunks were re-embedded.

## Prevention

- Store the provenance of derived data that depends on a swappable
  component, from day one.
- Before trusting a reconstruction (re-embedding from stored text), sample
  it: stored vs reconstructed vectors had median cosine 1.0 on 200 chunks.
