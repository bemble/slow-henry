---
module: "Embedding.NxServingImpl"
date: "2026-10-23"
problem_type: performance_issue
component: dev_environment
symptoms:
  - "The dev server, the test suite and ad-hoc mix runs are killed with exit code 137"
  - "/sys/fs/cgroup/memory.events oom_kill keeps increasing (up to 15); container peak ~13 GB, swap ~16 GB"
  - "Indexing at 500–900% CPU makes the host Mac unusable"
root_cause: "Not fully pinned down. The kills happened when several BEAMs ran at once in the devcontainer (dev server with the Bumblebee/EXLA serving, mix test, compiles in a second worktree). Each process alone stayed well under the limit (server ~1–2 GB idle). CPU embedding was the common heavy load."
severity: high
tags: [oom, devcontainer, orbstack, exla, cpu, ollama]
elixir_version: "1.20.2"
---

# OOM kills and a saturated host while embedding on the CPU

## Symptoms

During heavy indexing, the dev server died repeatedly (exit 137) together
with test runs; the OOM counter of the container's cgroup rose to 15. The
owner's Mac was saturated by indexing.

## Investigation

1. Sampled per-process RSS every second during server start: steady at
   ~0.8–1 GB, container ~2.5 GB — no runaway on its own.
2. Ruled out: the OAuth listener (stable 105 MB), VS Code port relays
   (stable), ElixirLS (no `.elixir_ls` build).
3. Kills coincided with concurrent BEAMs (server + `mix test` + a worktree
   compiling EXLA/tree-sitter) on top of CPU embedding.

## Root Cause

Unconfirmed. The mitigation removed the heavy part rather than explaining
the peak.

## Solution

Embeddings moved to Ollama on the Mac's GPU (`OLLAMA_ENDPOINT`): the
in-process serving isn't started, the server runs at ~330 MB and ~17 % CPU,
and no OOM kill has happened since. A monitor that logs the top processes
when the container exceeds 8 GB was used to catch a culprit; it never fired
after the switch.

## Prevention

- Don't run the test suite or a second worktree's compile while the dev
  server embeds on the CPU.
- If CPU embedding is needed again, watch `memory.events` and sample top RSS
  when memory crosses a threshold, to finally identify the peak.
