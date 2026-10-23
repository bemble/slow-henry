---
module: "Ingest.DrivePolicy"
date: "2026-10-23"
problem_type: privacy_issue
component: google_drive
symptoms:
  - "During the first Drive sync, documents the owner had planned to keep out of the index (meeting notes) were being staged and indexed"
root_cause: "The Drive filter relies only on the Classification label (none / Public / Internal allowed). The owner's plan was to label those notes Confidential, but they weren't labelled yet when Drive was first enabled, so they passed the filter. Nothing showed what would be indexed before indexing started."
severity: high
tags: [privacy, google-drive, classification, preview, incident]
elixir_version: "1.20.2"
---

# A label-based filter indexed documents that weren't labelled yet

## Symptoms

A title check run during the first Drive sync found documents in the
"should not be indexed" category being staged, and two already indexed.

## Investigation / response

1. Stopped the server by PID — the Drive job runs in-process, so stopping
   it was the only reliable way to stop the job (see the `pkill -f` doc).
2. Deactivated the Drive source, cancelled its job, and pinned
   `active = false` in `sources.toml` so `mix rn.sources` couldn't re-enable
   it.
3. Deleted those documents' chunks (and secret findings), every staged
   Drive row, and the dev server log (debug SQL logs include staged content);
   `VACUUM` both tables.
4. Nothing had left the machine: embeddings are computed locally.

The owner then decided these documents *may* be indexed, and Drive was
re-enabled.

## Root Cause

The safety of the filter depended on a manual labelling step that hadn't
happened yet, and the first run was a real run.

## Solution / prevention

- Before enabling a new scope, show what would be indexed (titles, with the
  reason for each exclusion) and let the owner confirm — proposed, not built.
- When a filter depends on the user doing something first (labelling),
  check it was done before turning ingestion on.
- Keep an emergency-stop path that actually stops in-process jobs, and know
  where staged content can linger (staging rows, debug logs).
