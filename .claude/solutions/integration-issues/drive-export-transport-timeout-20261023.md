---
module: "Ingest.Drive"
date: "2026-10-23"
problem_type: integration_issue
component: google_drive
symptoms:
  - "DriveSync fails with {:error, :export_incomplete} on every attempt"
  - "Log: Drive export failed (will retry): ... reason=%Req.TransportError{reason: :timeout}"
root_cause: "Drive renders the markdown export on the fly; a long doc took longer than Req's default 15 s receive_timeout, and one failed export made the whole page fail (cursor kept, job retried) — deterministically, on every attempt"
severity: medium
tags: [google-drive, req, timeout, export, retries]
elixir_version: "1.20.2"
---

# Drive exports hit Req's default receive timeout

## Symptoms

The Drive full pass kept failing with `:export_incomplete`; the job was
burning its attempts. The export failure itself carried no detail.

## Investigation

1. Added a log line on each failed export (doc id, title, reason — never
   content). It showed a single `Req.TransportError{reason: :timeout}`.
2. The same doc timed out on every attempt: a deterministic failure dressed
   up as a transient one.

## Root Cause

Req's default `receive_timeout` is 15 s. Exporting a long Google Doc to
markdown is rendered server-side and can take longer.

## Solution

- Exports get `receive_timeout: :timer.minutes(2)` (other Drive calls keep
  the default).
- Separately, a 4xx on one doc's export (e.g. `exportSizeLimitExceeded`) is
  logged and **skipped** instead of failing the run; only non-4xx errors keep
  the "don't advance the cursor, retry" behaviour.

## Prevention

- Long server-side renders need their own timeout, not the client default.
- Log the identity of the failing item (not its content) on every per-item
  failure; an aggregate `:export_incomplete` hides which item and why.
