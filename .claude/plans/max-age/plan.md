# Plan: a maximum age for a repo's non-code data

**Status**: IMPLEMENTED (2026-10-27) · **Branch**: `feat/max-age`

## Problem

A repo with `pull_requests = true` indexes its whole PR history: thousands
of documents for a big repo, most of them years old, which cost embedding
time and crowd out recent work in search results. The same will hold for
issues and releases (planned next).

## Decisions

1. **Config: `max_age = "2y"` on a `[[git]]` entry**, a number followed by
   `d`, `w`, `m` or `y` (days, weeks, months, years). Unset keeps
   everything, as today. It covers every kind of non-code data of the repo
   (PRs now; issues and releases when they come), never the code itself.
2. **The age of a PR** is that of its merge for a merged PR, and that of its
   last activity (`updatedAt`) for an open one: an open PR untouched for
   that long is abandoned.
3. **A rolling window.** The cutoff is computed at each run (today minus
   `max_age`, at midnight UTC):
   - the GitHub search starts at the later of the watermark and the cutoff
     (a PR merged after the cutoff was updated after it too);
   - a merged PR found by the search but merged before the cutoff (an old
     PR commented recently) is skipped;
   - every PR sync stages the deletion of the indexed PRs that left the
     window, so they age out without any other job.
4. **Open PRs carry `updated_at`** in their metadata and their hash, so the
   indexed value follows their activity (a label or a reaction re-stages
   the document; its embeddings are reused). Merged PRs are unchanged, so
   nothing is re-staged for them. An open PR indexed before it carried
   `updated_at` counts as out of the window: setting `max_age` re-reads the
   PR history, so one still active is staged again, with its date, after
   its deletion (the owner applies rows in arrival order).
5. **Changing `max_age`** (set, changed or removed) clears the PR watermark
   and queues a PR sync, as turning open PRs on does: a wider window must
   re-read the older PRs; a narrower one purges at that run. It never
   queues a repo pass (`scope` leaves it out).
6. **UI**: a "Max age" field per repo in the sources editor; the source
   page's PR badge says the window. `mix rn.sources` describes the change.

## Steps

- [x] `Ingest.MaxAge`: parse/validate `"<n><d|w|m|y>"`, cutoff for a date
- [x] `SourcesFile`: `max_age` key (validation, write-back, out of `scope`),
      watermark reset + PR sync on change; `mix rn.sources`
- [x] `PullRequestSync`: search from the cutoff, skip old merged PRs, purge
      what left the window; `updated_at` on open PRs
- [x] Sources editor field; source page badge; README and example
- [x] Tests for each of the above
- [x] `mix precommit`, `mix credo --strict`, `mix dialyzer`
- [x] Checked on the dev DB (snitun, 90d then 91d): the 413 merged PRs
      (none in the window) dropped, open ones kept with `updated_at`, the 3
      stale open ones indexed before it dropped on the re-read
