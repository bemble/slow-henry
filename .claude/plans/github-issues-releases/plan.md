# Plan: GitHub issues, releases and their dependencies

**Status**: part 1 (issues) IMPLEMENTED (2026-10-27) · **Branch**: `feat/github-issues`

## Problem

A git source indexes its code and, on request, its pull requests. Its
issues (bug reports, feature discussions, their resolution) and its
releases (what shipped when) are invisible to search. And there is no way
to answer "which of our releases ship `aiohttp` < 3.9.4?" when a CVE comes
out.

## Parts (one PR each)

1. **Issues** — `issues = true` on a `[[git]]` entry (this branch).
2. **Releases** — `releases = true`: one document per GitHub release, with
   its notes and the PRs it contains, computed from git.
3. **Dependency inventory per release** — the packages and versions each
   release ships, read from its lockfiles in the mirror, in a table; an MCP
   tool to query it.
4. **CVE matching** (optional) — OSV.dev lookups of that inventory.

Parts 2–4 are only sketched below; each gets its decisions written here
before it starts.

## Part 1: issues

### Decisions

1. **Config: `issues = true`** (default false), independent of the PR
   options. `max_age` applies: an open issue ages by its last activity, a
   closed one by its closing date.
2. **One document per issue**, under the virtual path `issues/<n>`, as for
   PRs (`pulls/<n>`): title, `Issue #12 in acme/app by @x, open` (or
   `closed 2026-…` / `closed 2026-… as not planned`), URL, labels,
   assignees, the linked PRs (that closed it or will once merged), the
   description, then the human comments (bots and AI left out, as for
   PRs). Name `Issue #12 [open]: <title>` when open, `Issue #12: <title>`
   when closed.
3. **Every state is indexed.** Unlike a PR closed without merge, a closed
   issue keeps its value: the discussion and how it was resolved. Issues a
   bot opened (dependency dashboards…) are indexed too, marked `bot`.
4. **Metadata**: `issue` (number), `state` (`open`/`closed`),
   `state_reason` (`completed`, `not_planned`, `duplicate`…), `labels`,
   `author`, `assignees`, `linked_prs` (the PRs that closed it or will),
   `closed_at`, and
   `updated_at` for open issues (in the hash too, as for open PRs, so
   `max_age` follows their activity).
5. **Sync: a separate `IssueSync` worker**, unique per source, with its own
   watermark (`issues_updated_since`, in the shared `sync_states` cursor)
   and an hourly cron (`git_issues`). Same shape as `PullRequestSync`:
   GraphQL search `repo:X is:issue updated:>=<since> sort:updated-asc`,
   300 issues per run then snooze. The staging, watermark and purge helpers
   both workers need move to a shared module.
6. **Turning it off** stages the deletion of every issue document and
   clears the watermark, from the job, without calling GitHub (as
   `pull_requests = false`). A changed `max_age` clears both watermarks
   and queues both syncs when enabled.
7. **A full repo pass leaves issue documents alone** (`issue` joins `pr`
   in `RepoSync`'s `@virtual_keys`).
8. **Search**: a new `issue_state` filter (`"open"` / `"closed"`, issues
   only, as `pr_state` is PRs only); `author` matches issue authors as it
   does PR authors; `involves` also matches issue assignees.
9. **UI**: an "Issues" checkbox in the sources editor; an `issues` badge on
   the source page; `mix rn.sources` describes the toggle.

### Steps

- [x] Shared GitHub staging helpers out of `PullRequestSync`
- [x] `GitHub.issues_page/3` and the issue document
- [x] `IssueSync` worker, cron, `SyncScheduler` kind, `Rechunk`
- [x] `SourcesFile`: `issues` key, toggles, `max_age`; `mix rn.sources`
- [x] `RepoSync` virtual keys; `FileIngest` breadcrumb prefix
- [x] `issue_state` filter and `involves` on assignees (`HybridQuery`,
      `Search`, `semantic_search`)
- [x] Sources editor checkbox; badge; README and example
- [x] Tests; `mix precommit`, `mix credo --strict`, `mix dialyzer`
- [x] Checked on the dev DB (snitun): with `max_age = "2y"`, 9 closed and
      3 open issues indexed with their linked PRs; `closed_by` renamed
      `linked_prs` (GitHub's field also lists the PRs that will close an
      open issue)

## Part 2: releases (sketch)

- One document per GitHub release, `releases/<tag>`: tag, date, notes,
  and the list of PRs it contains with their titles, computed from the
  mirror (`git log <previous tag>..<tag>`, PR numbers from squash
  `(#123)` and merge `Merge pull request #123` messages: no API cost).
- Metadata `tag`, `published_at`, `prerelease`, `prs`, so "which release
  shipped PR #123" is a filter.
- `ReleaseSync` after `RepoSync`'s fetch (it needs the tags); `max_age` by
  publication date.

## Part 3: dependency inventory (sketch)

- For each release tag, the lockfiles read from the mirror (`git show
  <tag>:uv.lock`): first Python (`uv.lock`, `poetry.lock`,
  `requirements*.txt`), then npm and `mix.lock` — to confirm.
- A `release_dependencies` table (source, tag, ecosystem, package,
  version, direct?), deduplicated by lockfile hash. A library without a
  lockfile only has its declared constraints, stored as such.
- MCP tool `dependency_releases(package, ecosystem?, versions?)`.

## Part 4: CVE matching (sketch, optional)

- OSV.dev `querybatch` on (ecosystem, package, version), refreshed daily;
  vulnerabilities stored per release; MCP tool
  `release_vulnerabilities(repo, tag?)`. Sends public package names and
  versions only.
