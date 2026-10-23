---
module: "Ingest.Workers.DriveSync"
date: "2026-10-23"
problem_type: otp_issue
component: code_reloading
symptoms:
  - "UndefinedFunctionError: function RetrievalNode.Ingest.Workers.DriveSync.backoff/1 is undefined (module ... is not available)"
  - "Oban job error (EXIT ...) :undef, consuming an attempt, right after editing the worker in dev"
root_cause: "In dev, Phoenix's code reloader recompiles on the next HTTP request (and `mix compile` in another shell notifies the running node through Mix listeners). Reloading the worker module while one of its jobs was finishing left Oban's executor calling backoff/1 on a module that was briefly unavailable"
severity: low
tags: [code-reloader, oban, dev-only, hot-reload, mix-listeners]
elixir_version: "1.20.2"
---

# Reloading a worker while its Oban job runs → `:undef`

## Symptoms

Right after changing `DriveSync` and hitting the UI to trigger a reload, the
running Drive job failed with `:undef` on `DriveSync.backoff/1`, burning one
of its attempts.

## Root Cause

The dev code reloader purges and reloads changed modules. Oban's executor
calls back into the worker module (`backoff/1`) when a job finishes; if the
module is being swapped at that instant, the call fails. A `mix compile` /
`mix run` in another shell can trigger the same reload through Mix
listeners (`listeners: [Phoenix.CodeReloader]` in `mix.exs`).

## Solution

Operational, dev only:

- Before reloading code that a running job uses, check that no job of that
  worker is executing (`select … from oban_jobs where state = 'executing'`).
- Raising the job's `max_attempts` in the DB kept it alive after the lost
  attempts.

## Prevention

- Don't hit the dev UI (or compile in the same project) while a long job of
  a module you just edited is running.
- Edits to `config/*.exs` can't be reloaded at all: the reloader refuses and
  the server must be restarted.
