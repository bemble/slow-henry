# Plan: index open pull requests

**Status**: IMPLEMENTED (2026-10-27) · **Branch**: `feat/open-pull-requests`

## Problem

`PullRequestSync` only indexes merged PRs (`pull_requests = true`): the
GitHub search is `is:pr is:merged updated:>=<watermark> sort:updated-asc`.
Work in flight — what is being changed right now, by whom, what reviewers
are pushing back on — is invisible to search.

Also, turning `pull_requests` off leaves the indexed PR chunks in place.

## Decisions

1. **Config: a separate boolean, `open_pull_requests = true`**, that only
   has an effect alongside `pull_requests = true`. Existing `sources.toml`
   files are untouched, the validator keeps accepting booleans only, and the
   sources editor gets a second checkbox (disabled while PRs are off).
2. **One search, every state.** With the option on, the search drops
   `is:merged` (`is:pr updated:>=<watermark>`); the same watermark covers
   it. The GraphQL query also asks for `state` and `isDraft`. Per PR:
   - `MERGED` → indexed, as today;
   - `OPEN` → indexed, marked open — except when its author is a bot
     (dependabot, renovate…: long-lived, constantly updated, noise). Their
     merged PRs stay indexed as today;
   - `CLOSED` (not merged) → a deletion entry when it is indexed (an open PR
     that was abandoned); nothing otherwise.

   Transitions need nothing else: open → merged keeps the natural key
   (`pulls/<n>`) and replaces the document; a new comment bumps
   `updatedAt`, so the next run re-reads it; unchanged content is skipped
   on its hash.
3. **Drafts are indexed**, marked `draft` — the thinking is often there.
4. **Document and metadata.**
   - Header: `Pull request #12 in acme/app by @x, open (draft)` instead of
     `merged 2026-…`.
   - Metadata `state: "open" | "merged"`, `draft: true` when it is; an open
     PR has no `merged_at`.
   - Name `PR #12 [open]: <title>`, so the state shows in search results
     and in the breadcrumb (the breadcrumb de-duplication still matches the
     `": <title>"` suffix).
5. **Turning options on or off** (`SourcesFile`):
   - `open_pull_requests` newly on → `SourcesFile` clears
     `prs_updated_since` (in its transaction) and enqueues PR sync: open PRs
     not updated since the watermark would be missed. Not a `"full"` job
     arg: a sync that snoozes through a backlog re-runs with the same args,
     and restarted from scratch forever (caught on the dev DB). Merged PRs
     already indexed are re-staged once, since the state is part of the PR
     hash (embeddings are reused); the cost is GitHub API pages (~50 for
     naboo).
   - `open_pull_requests` off → deletion entries for the source's open PR
     chunks, staged by every PR sync run while the option is off (so a job
     swallowed by uniqueness doesn't leave them behind).
   - `pull_requests` off → deletion entries for all its PR chunks (the
     existing gap), and the PR watermark is cleared so turning it back on
     re-reads everything. The PR sync job does it, from the source's config
     when it runs, without calling GitHub.
   - Any PR option change queues a PR sync; a sync job still waiting takes
     the new args when they ask for more (`replace`, as upstream's resync).
6. **Search filter `pr_state`** (`"open"` / `"merged"`) on `semantic_search`
   and `Search`/`HybridQuery`: a new SQL parameter `$16`, so the graph leg
   moves to `$17` (weight) and `$18+` (terms). A PR without a `state`
   (indexed before it existed) counts as merged. `author`/`reviewer`
   descriptions stop saying "merged PRs".

## Follow-up: open PRs opened by bots, as an option

Bot-opened open PRs (dependabot, renovate…) carry useful context (what is
being bumped, the changelog excerpts), so they can be indexed too with a
third boolean, `bot_pull_requests = true`, effective only alongside
`open_pull_requests`:

- such PRs are indexed with `bot: true` in their metadata;
- turning it on clears the PR watermark and queues a PR sync, like
  `open_pull_requests`; turning it off makes each PR sync stage the deletion
  of the open PRs marked `bot` (merged bot PRs stay, as before);
- the sources editor gets an "Open bot PRs" checkbox, disabled while open
  PRs are off; the source badge reads "PR + open + bots".

## Steps

- [x] `Ingest.GitHub`: `prs_page/4` with an `open:` option (query with or
      without `is:merged`), `state`/`isDraft` in the GraphQL query, open
      header, `state`/`draft`/`bot_author` on the PR map
- [x] `PullRequestSync`: per-state rows (index / skip bot-authored open /
      delete closed when indexed), `state`/`draft` metadata, name with
      `[open]`, state in the hash; purges from the config when options are off
- [x] `SourcesFile`: `open_pull_requests` key (validation, write-back),
      watermark reset and PR sync on toggles, `replace` for waiting jobs;
      `mix rn.sources` describes the changes
- [x] Sources editor checkbox; source page badge; README and example
- [x] `pr_state` filter: `HybridQuery`, `Search`, `semantic_search`
- [x] Tests for each of the above
- [x] `mix precommit`, `mix credo --strict`, `mix dialyzer`
- [x] Checked on the dev DB (snitun): 4 human open PRs indexed, 6
      dependabot ones skipped, `pr_state` filters both ways
- [x] PR on the fork (`feat:` commit) — #43
- [x] `bot_pull_requests` option (same PR)
