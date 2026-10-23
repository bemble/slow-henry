---
module: "GitHub.OAuth"
date: "2026-10-23"
problem_type: integration_issue
component: github_oauth
symptoms:
  - "Risk: two concurrent token refreshes lose GitHub access until the user reconnects"
  - "In a test, Disconnect left the refresh token in secrets.toml"
root_cause: "GitHub App refresh tokens rotate on every refresh and are single-use. Two processes refreshing with the same token: the second gets bad_refresh_token, and whichever stores last may store a dead token. A refresh in flight during Disconnect re-stores its rotated token after the delete."
severity: medium
tags: [github, oauth, device-flow, refresh-token, global, race]
elixir_version: "1.20.2"
---

# GitHub App refresh tokens rotate: serialize refreshes and Disconnect

## Symptoms

Found while writing tests rather than in production. The Connections page
looks up the account (`/user`) on mount, which refreshes the access token in
a `start_async` task. Clicking Disconnect right after left
`github_refresh_token` in `secrets.toml`: the refresh finished after the
delete and stored the rotated token.

## Root Cause

GitHub returns a **new refresh token on every refresh** and the old one stops
working. Any two refreshes racing (PR sync job, git fetch, the Connections
page) would burn the token; any refresh racing a delete resurrects it.

## Solution

- `access_token/0` checks the cache, then refreshes inside
  `:global.trans({GitHub.OAuth, self()}, ...)`, re-checking the cache once the
  lock is held (another caller may have refreshed meanwhile).
- The rotated refresh token is written to `Secrets` before the access token
  is cached or returned.
- `forget/0` deletes under the same lock.

Test: five concurrent `access_token/0` calls against a slow `Req.Test` stub
hit the token endpoint once.

## Also seen: a refresh from another process

A one-off `mix run` script that called `access_token/0` refreshed from its own
BEAM. GitHub revoked the server's cached access token, and the server kept
using it: git fetches failed (`could not read Username`), PR syncs got 401s
until one of them dropped the cache. Since then, a git refusal also calls
`invalidate/0`, so the job's retry refreshes. Don't refresh from a second
node or a script while the server runs — the `:global` lock only covers one node.

## A token without access looks like success or like a write error

- GraphQL `search` on a repo the token can't see returns zero results, not an
  error. The PR query now also asks for `repository(owner:, name:) { id }`;
  null means `{:github_repo_not_visible, repo}`, and the job fails.
- git gets `remote: Write access to repository not granted` / 403 even for a
  read-only fetch. The error now says to check that the App is installed on
  the repo with Contents read access.

## Prevention

For any OAuth provider with rotating refresh tokens, treat the refresh as a
critical section across the whole node and persist the new token first.
