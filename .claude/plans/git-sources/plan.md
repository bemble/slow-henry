# Plan: Git sources — path exclusion and merged pull requests

**Status**: DONE (retroactive write-up, 2026-10-23) · **PR**: bemble/slow-henry #7
**Depends on**: `../fork-foundations/plan.md` (sources.toml, UI)

## Requirements (from the owner)

1. Index the messages of **merged** pull requests, only for repos where it is
   enabled (off by default).
2. Index `home-assistant/core` but leave out `homeassistant/components/*`,
   except `homeassistant/components/cloud` (later also `tests/components/*`
   except `tests/components/cloud`).
3. Show in the UI which repos have PRs enabled (`PR` chip) and which are
   partial (`partial` chip).

## Decisions

1. **`exclude` uses `.gitignore`-style patterns** (`Ingest.PathFilter`),
   anchored at the repo root: `*` within a segment, `**` across segments, a
   directory covers its tree, `!` re-includes — unlike git, even below an
   excluded directory, which is what makes the `cloud` exception work — and
   the last matching pattern wins. Patterns compile to escaped regexes.
2. **Excluded paths are dropped before `git show`**, and only those already
   indexed or staged get a deletion row, so a huge excluded tree costs nothing
   on a first sync.
3. **A `full` RepoSync mode** re-reads the whole tree instead of the diff
   since `last_sha`. Changing `exclude` queues it, because a new pattern
   affects files that didn't change.
4. **Merged PRs through the `gh` CLI** (`gh api graphql`), so auth is
   whatever `gh auth login` set up for the server's user — no new token to
   manage. One document per PR, under the virtual path `pulls/<n>` of the git
   source (it shows next to the repo's files and in search): title, author,
   merge date, URL, description, then human comments and reviews (bots
   dropped).
5. **Watermark = last `updatedAt` seen**, on a search sorted by update
   ascending, so PRs edited or commented after merge are re-staged (unchanged
   content is skipped by the owner). At most 300 PRs per run, then snooze —
   which also keeps each search window under GitHub's 1,000-result cap.
6. **`RepoSync` and `PullRequestSync` share a `sync_states` row** and may run
   at the same time: each updates only its own cursor key with `jsonb_set`
   (see the shared-cursor solution doc).
7. **Options are stored only when set** (`exclude` non-empty,
   `pull_requests = true`), so existing sources don't read as changed and
   don't trigger a full pass.

## Phases

- [x] `Ingest.PathFilter` + tests (including the home-assistant/core case)
- [x] `RepoSync`: exclusion, `full` mode, atomic `last_sha` update
- [x] `Ingest.GitHub` (`gh` runner, GraphQL search, rendering, bot filter)
- [x] `Workers.PullRequestSync` + hourly `git_prs` kind in `SyncScheduler`
      (only opted-in sources)
- [x] `[[git]]` `exclude` / `pull_requests` in `SourcesFile`; `sync_jobs/1`
      decides full pass vs PR sync; `rn.sources --dry-run` says which
- [x] UI chips (`PR`, `partial` with the patterns as tooltip)

## Results (owner's setup)

- 5,460 merged PRs fetched across 7 repos (57 to 2,410 per repo), 22 MB of
  text, largest 59 KB.
- home-assistant/core (897 MB, 95,859 merged PRs — PRs deliberately not
  enabled) reduced to 1,363 files, none from integrations other than `cloud`.

## Follow-ups

- A `pull_requests_since` option would make PRs viable on huge repos like core
- MCP `get_file` / `grep` work on the mirror, so they still see excluded files
  and don't know the virtual `pulls/<n>` paths
