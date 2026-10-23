---
module: "RetrievalNodeWeb.ConnectionsLive"
date: "2026-10-23"
problem_type: integration_issue
component: oauth
symptoms:
  - "After clicking Allow on Google's consent screen the page spins forever; the browser never shows http://127.0.0.1:8765/"
  - "Opening http://127.0.0.1:8765/test on the Mac also spins, while curl to the same port from inside the devcontainer answers"
root_cause: "The OAuth redirect target was a dedicated listener on 127.0.0.1:8765 inside the devcontainer. The Mac's 127.0.0.1:8765 was accepted by the OrbStack / VS Code port relay but never forwarded to a process bound to the container's loopback, so the navigation hung; Chrome keeps showing the previous page (Google) during a pending navigation"
severity: medium
tags: [oauth, loopback-redirect, devcontainer, orbstack, port-forwarding, google]
elixir_version: "1.20.2"
---

# OAuth loopback redirect hangs behind a devcontainer port relay

## Symptoms

The Desktop-app OAuth flow redirects to a loopback URL after consent. With a
mix task listening on `127.0.0.1:8765` in the devcontainer, Google's page
"spun" after *Allow*. The user saw no redirect to localhost at all.

## Investigation

1. The task was listening and healthy: `curl` from inside the container got
   a 404 for `/favicon.ico` (the listener skips non-redirect requests).
2. The Google side was valid: the same authorize URL with a wrong
   `redirect_uri` produced `redirect_uri_mismatch`, the real one a normal
   sign-in redirect.
3. On the Mac, `http://127.0.0.1:8765/test` also hung: the connection was
   accepted by a relay (OrbStack / VS Code) but never reached the listener.
   Earlier, before any listener existed, the port already "accepted"
   connections — the tell-tale sign of a relay.
4. Chrome keeps the previous page and URL during a pending navigation, so a
   hung redirect looks like Google itself spinning.

## Root Cause

Loopback redirects target the browser's machine. In a devcontainer, that is
only the app's machine through a port relay, and relays differ per port and
bind address. The app's own HTTP port (4000, bound to `0.0.0.0`) was relayed
correctly; an ad-hoc port bound to the container's loopback was not.

## Solution

Make the consent flow part of the UI and redirect to the app itself: a
Desktop client accepts any loopback port and path, so
`http://localhost:<endpoint port>/google/callback` works through the relay
that already serves the UI. The callback LiveView exchanges the code on the
connected mount only (a code can be redeemed once), `state` is a signed
`Phoenix.Token` (no session needed across `localhost` vs `127.0.0.1`), and a
paste-the-URL form covers a browser that can't reach the server at all (the
server on another machine). The standalone listener and its mix task were
removed.

### Files Changed

- `lib/retrieval_node_web/live/connections_live.ex` (was `google_live.ex`)
- `lib/retrieval_node/google/oauth.ex` — `redirect_uri` is a parameter
- `lib/retrieval_node_web/router.ex` — `/google/callback`

## Prevention

- In a devcontainer, reuse a port that is already reachable from the host
  browser rather than opening a new one.
- To debug "nothing happens after consent", open the redirect URL directly
  in the browser and check DevTools → Network for a pending request.
