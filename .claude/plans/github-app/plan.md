# Plan: GitHub App token instead of the gh CLI

**Status**: DONE (2026-10-23) · **Branch**: `feat/github-app`

## Problem

Merged-PR indexing shelled out to `gh api graphql`, so the server needed the
`gh` CLI installed and logged in (`gh auth login`) as the user running it —
awkward in a container or on the LAN box, and the login was an all-scopes
personal token. Private clones relied on whatever git credential helper the
host had. Google Drive already authenticates from the UI and keeps its token
in `DATA_DIR/secrets.toml`; GitHub should work the same way.

## Decisions

1. **A GitHub App, not an OAuth App.** Its user-to-server token is bounded by
   the App's permissions (read-only Contents + Pull requests, Metadata) and
   only reaches repos where the App is installed *and* the user has access.
   An OAuth App's `repo` scope would grant write access to every repo.
2. **Device flow** (Connections page shows a code, the user enters it at
   github.com/login/device, the LiveView polls). No redirect URI, so it works
   from a headless server — the loopback-redirect trouble seen with Google
   does not apply.
3. **Direct API calls with Req**, no `gh`: `Ingest.GitHub.graphql/2` POSTs to
   `api.github.com/graphql` with the bearer token. A 401 drops the cached
   access token; no token at all cancels the PR sync job (no retries).
4. **Token storage**: refresh token in `Secrets` (`github_refresh_token`),
   access token (8 h) cached in `:persistent_term` with a 60 s margin.
   `GITHUB_TOKEN` (e.g. a fine-grained PAT) overrides and is never refreshed.
5. **Refresh tokens rotate and work once**, so refreshes are serialized with
   `:global.trans/2`, the new refresh token is stored before the access token
   is used, and `forget/0` (Disconnect) takes the same lock.
6. **git clone/fetch of `https://github.com/` URLs** sends the token as an
   `http.extraHeader` (`basic x-access-token:<token>`), passed through git's
   `GIT_CONFIG_COUNT/KEY_n/VALUE_n` environment so it never appears on a
   command line. Without a token, git falls back to its credential helper.

## Steps

- [x] `RetrievalNode.GitHub.OAuth` (device flow, refresh, env override, login)
- [x] `Ingest.GitHub` transport on Req; `PullRequestSync` cancels when unauthorized
- [x] `GitMirror` token via `GIT_CONFIG_*` env
- [x] Connections page GitHub section (connect, code, account, disconnect)
- [x] `config/runtime.exs`, `.env.example`, README setup
- [x] Tests: device flow, rotation, single concurrent refresh, PR sync via `Req.Test`, LiveView
