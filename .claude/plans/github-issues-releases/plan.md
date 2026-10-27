# Plan: GitHub issues, releases and their dependencies

**Status**: part 1 (issues) IMPLEMENTED (2026-10-27, `feat/github-issues`) ·
part 2 (releases) IMPLEMENTED (2026-10-27, `feat/github-releases`)

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
4. ~~CVE matching~~ — **dropped** (2026-10-27): the inventory and its query
   tool are enough; the prompt asks the model to check osv.dev itself. The
   inventory therefore names ecosystems and versions the way OSV does
   (`npm`, `PyPI`, `Hex`), so a hit can be looked up as is.

Part 3 is only sketched below; it gets its decisions written here before
it starts.

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

## Part 2: releases

### Decisions

1. **Config: `releases = true`** (default false). `max_age` applies by
   publication date.
2. **One document per published GitHub release** (drafts left out,
   pre-releases kept and marked), under `releases/<tag>`: title,
   `Release v1.2.0 of acme/app, published 2026-… by @x` (`, pre-release`),
   URL, `Since: v1.1.0`, the notes, then `## Pull requests`: `#123 <title>`
   per PR the release contains, then `## Other commits` (direct pushes),
   capped (300 lines, then `… and N more`). Name `Release v1.2.0` (`:
   <name>` when the release has its own name).
3. **The PRs come from git, not the API**: `git log <previous>..<tag>` in
   the mirror, PR numbers from squash (`… (#123)`) and merge (`Merge pull
   request #123 from …`, title from the body) messages. Free, and right for
   any merge style.
4. **Previous release** = the newest earlier release whose commit is an
   ancestor of this one (`merge-base --is-ancestor`), skipping pre-releases
   for a stable release — so `1.9.1` on a maintenance branch, published
   after `2.0.0`, is compared to `1.9.0`, and `2.0.0` to `1.9.0` and not to
   `2.0.0b3`. None: the whole history up to the tag (first release).
5. **Metadata**: `release` (the tag), `published_at`, `prerelease`,
   `previous` (tag), `prs` (numbers), `url`, `author`.
6. **Sync: `ReleaseSync`**, hourly cron (`git_releases`), unique per source.
   Releases are few and can't be searched by update date, so each run
   lists them all (GraphQL, 50 a page, newest first) — no watermark — and
   reconciles: stages the releases whose hash changed (compared to the
   indexed `file_hash`), and the deletion of the indexed releases no longer
   listed (deleted on GitHub, or out of the `max_age` window). A release
   whose commit isn't in the mirror yet (published since the last fetch) is
   indexed without its PRs; its hash changes once they are known.
7. **Turning it off** stages the deletion of every release document.
   `RepoSync`'s full pass leaves them alone (`release` joins
   `@virtual_keys`).
8. **Search**: a new MCP tool `list_releases(repo, pr?)`: the indexed
   releases of a repo (tag, date, pre-release, previous, PR count, URL),
   newest first — or, with `pr`, the ones that shipped it; with `tag`, that
   release's whole document (rebuilt from its chunks, as `get_document`:
   `get_file` only reads the mirror). `semantic_search` finds the text.
9. **UI**: "Releases" checkbox, `releases` badge, `mix rn.sources` toggle.

### Steps

- [x] `GitMirror.log/4` (first-parent commits of a range) and `ancestor?/3`
- [x] `GitHub.releases/1` and the release document (`Ingest.Releases`)
- [x] `ReleaseSync`, cron (:50), `SyncScheduler` kind, `Rechunk`,
      `RepoSync`, `FileIngest`
- [x] `SourcesFile` `releases` key (parsed and written back); `mix
      rn.sources`
- [x] `list_releases` MCP tool (`Ingest.releases/2`, `Ingest.release/2`)
- [x] Sources editor checkbox; badge; README (and the missing Issues
      permission of the GitHub App) and example
- [x] Tests; precommit, credo, dialyzer
- [x] Checked on the dev DB (snitun, `max_age = "2y"`): 18 releases, each
      compared to the right previous one (0.40.0 to 0.39.1, out of the
      window; 0.41.6 and 0.41.7 both to 0.41.5, 0.41.6's tag being off
      main); `pr: 492` → 0.46.1. `3y` → 26, back to `2y` → 8 deletions and
      nothing re-staged. Notes come with CRLF line endings: normalized.

## Part 3: dependency inventory (sketch)

- For each release tag, the lockfiles read from the mirror (`git show
  <tag>:<path>`), anywhere in the tree (monorepos), in this order:
  1. npm: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`;
  2. Python: `uv.lock`, `poetry.lock`, `requirements*.txt` (pinned `==`);
  3. Elixir: `mix.lock`;
  4. Docker: `Dockerfile*` `FROM` images and their tags/digests (the
     packages inside an image aren't in the repo; base image versions
     are what a CVE on the image names).
- A `release_dependencies` table (source, tag, ecosystem, package,
  version, manifest path, direct?), deduplicated by lockfile blob sha. A
  library without a lockfile only has its declared constraints, stored as
  such.
- MCP tool `dependency_releases(package, ecosystem?, repo?)`: the releases
  shipping it, with versions; and the inventory of one release.
