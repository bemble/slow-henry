---
module: "(tooling)"
date: "2026-10-23"
problem_type: tooling_issue
component: dev_environment
symptoms:
  - "`pkill -f \"phx.server\"; …` exits 144 before running the rest of the command"
  - "The server keeps running (and an Oban job keeps working) after the 'stop' command"
root_cause: "pkill -f matches the full command line of every process, including the shell running the command, whose own command line contains the pattern — so it killed itself; the server's BEAM command line didn't contain 'phx.server' anyway"
severity: medium
tags: [pkill, shell, process-management, emergency-stop]
elixir_version: "1.20.2"
---

# `pkill -f <pattern>` kills the shell that runs it

## Symptoms

Stopping the dev server in an emergency (a job indexing data that had to
stop now) with `pkill -f "phx.server"; <cleanup SQL>` exited with code 144:
the shell was killed before the cleanup ran, and the server's BEAM was still
alive and still running the job.

## Root Cause

`-f` matches against full command lines, and the invoking shell's command
line contains the pattern. The BEAM itself shows up as
`beam.smp -- -root …`, without `phx.server`.

## Solution

Kill by the exact PID of what owns the port:

```bash
B=$(ss -ltnp | grep ":4000 " | grep -o "pid=[0-9]*" | cut -d= -f2)
kill $B   # kill -9 if it must stop mid-job
```

and confirm with `ps -eo pid,args | grep beam.smp`.

## Prevention

- Never `pkill -f` with a pattern that appears in your own command.
- For an emergency stop, check that it actually stopped before relying on it.
