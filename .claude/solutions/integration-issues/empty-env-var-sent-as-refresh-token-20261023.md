---
module: "Google.OAuth"
date: "2026-10-23"
problem_type: integration_issue
component: configuration
symptoms:
  - "DriveSync fails with {:error, {:google_oauth, 400, \"invalid_request\"}}"
  - "The same refresh token works with curl against oauth2.googleapis.com/token"
root_cause: "`.env` contained `GOOGLE_REFRESH_TOKEN=` (empty, from the template). System.get_env returns \"\", which passed the is_binary/1 check, so the server sent an empty refresh_token; Google answers invalid_request (missing parameter), not invalid_grant"
severity: medium
tags: [env-vars, oauth, google, configuration, empty-string]
elixir_version: "1.20.2"
---

# An empty env var is a value, not "unset"

## Symptoms

The first Drive sync after authorizing failed with `400 invalid_request`
while the refresh token, tested with `curl` and with the app's code path in a
separate process, worked.

## Investigation

1. `curl` with the token from `.env`: 200, both scopes granted.
2. `OAuth.access_token/0` in a fresh `mix run`: OK.
3. `invalid_request` is what Google returns for a *missing* parameter. The
   server had booted while `.env` still had `GOOGLE_REFRESH_TOKEN=` from
   `.env.example`.

## Root Cause

`System.get_env("X")` returns `""` for `X=`. The guard
`not is_binary(cfg[:refresh_token])` treats `""` as a token.

## Solution

```elixir
# RetrievalNode.Google.OAuth
not present?(cfg[:refresh_token]) -> {:error, :google_not_authorized}

defp present?(value), do: is_binary(value) and value != ""
```

with a test for `refresh_token: ""`.

## Prevention

- Treat `""` as unset for every optional env-derived setting; templates
  (`.env.example`) ship empty assignments.
- When an API rejects a credential that works elsewhere, compare what the
  failing process actually sent (its config at boot), not the file.
