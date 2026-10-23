# Plan: Google Drive source rewrite

**Status**: DONE (retroactive write-up, 2026-10-23) · **PR**: bemble/slow-henry #6
**Depends on**: `../fork-foundations/plan.md` (env config, UI, sources.toml)

## Problem

The inherited Drive source could not work for real:

- **Auth**: a static `DRIVE_ACCESS_TOKEN` (expires after an hour, no refresh),
  read only by `mix rn.seed` — the server running the sync never received it.
- **No backfill**: the first run only seeded the changes cursor, so existing
  docs were never indexed.
- **No pagination** of the changes feed: a page with more than 100 changes had
  no `newStartPageToken`, the cursor became nil and the next run re-seeded,
  silently losing those changes.
- **No shared drives** (`supportsAllDrives` / `includeItemsFromAllDrives`).
- **No filter**: the whole Drive, while the owner wanted a scope and a
  confidentiality rule.

## Requirements (from the owner)

- My Drive, plus shared drives / folders of his choice, plus (later) docs
  shared directly with him (`shared_with_me`, off by default).
- Only docs with **no `Classification` label, or classified `Public` /
  `Internal`**. Others' misclassification is their responsibility.
- 1:1 notes may be indexed (decided after a pause, see *Incident* below).
- The app must never write `.env`; tokens are shown once and persisted by the
  operator.

## Decisions

1. **OAuth Desktop-app client with a refresh token** (`Google.OAuth`): access
   tokens cached in `:persistent_term` until a minute before expiry,
   invalidated on 401. Scopes `drive.readonly` + `drive.labels.readonly`.
2. **Consent from the UI, redirecting to the app's own port.** A Desktop
   client accepts any loopback redirect, so Google returns to
   `http://localhost:<port>/google/callback`. A separate listener on 8765 was
   tried first and failed behind the devcontainer's port relay (see the
   OAuth loopback solution doc). `state` is a signed `Phoenix.Token`, so the
   callback needs no session. A paste-the-URL form covers a server the
   browser can't reach (the LAN box).
3. **Fail closed on the label.** If the `Classification` label can't be read,
   nothing is indexed. A label applied without a value is not allowed.
4. **Policy as pure functions** (`Ingest.DrivePolicy`): `doc?`,
   `classification_allowed?`, `in_scope?` (owned by me / directly shared with
   me / in a configured shared drive / below a configured folder, walking
   parents with a memoized lookup).
5. **Two sync modes in `DriveSync`**: a *full* pass (first run, then daily at
   04:15, and on scope change) that lists every in-scope doc, exports new or
   newer ones (`modifiedTime` watermark per doc) and stages deletions for
   indexed docs that left the scope or the filter; and an incremental pass
   over the paginated changes feed. The full pass exports at most 200 docs per
   run and snoozes to continue, so a backfill never holds one job.
6. **Scope lives in `[drive]`** of `sources.toml`, managed like git sources;
   a scope change queues a full pass. Drive leaves `rn.seed`.
7. **Drive text goes through gitleaks**, like git content; the doc title is
   the chunk breadcrumb.

## Phases

- [x] `Google.OAuth` (authorize URL, code exchange, refresh, cache)
- [x] `Ingest.Drive` client: changes (paginated), listings (My Drive, shared
      drive, folder children, shared-with-me), export, Labels API parsing,
      429 / rate-limit 403 → snooze
- [x] `Ingest.DrivePolicy` + `DriveSync` full/changes passes, batching and
      continuation, deletions, export failures keep the cursor
- [x] `[drive]` in `SourcesFile` (`my_drive`, `include`, `active`, later
      `shared_with_me`), daily full pass in the cron (`SyncScheduler` forwards
      `mode`)
- [x] UI consent page (later the Connections page) with paste fallback
- [x] Live fixes found while indexing the real Drive:
  - [x] a 4xx on one doc's export is logged and skipped instead of failing
        the run
  - [x] export receive timeout 15 s → 2 min (long docs)
  - [x] inline base64 images stripped from the markdown export (tsvector
        overflow and polluted embeddings)
  - [x] empty `GOOGLE_REFRESH_TOKEN=` treated as "not authorized"
- [x] `shared_with_me` option: docs shared directly with the user (Drive sets
      `sharedWithMeTime` on the shared item only; folders shared with the user
      are crawled only when listed in `include`)

## Incident: 1:1 notes indexed before the owner had labelled them

The owner had said he would label his 1:1 notes `Confidential`; they were not
labelled yet when Drive was first enabled, so they passed the filter. Caught by
a title check during the first sync: the server was stopped (the job ran
in-process), the Drive source deactivated, the staged rows and the 2 indexed
1:1 docs purged, the debug server log deleted. The owner then decided 1:1
notes *may* be indexed, and Drive was re-enabled. Lesson: before enabling a new
scope, show what would be indexed (a preview) instead of relying on a
labelling step the user may not have done yet.

## Results (owner's Drive)

273 docs / 14,099 chunks after the first full pass, then +451 directly shared
docs with `shared_with_me`; 0 failing files.

## Follow-ups

- A preview (titles that would be indexed / excluded and why) before
  enabling a new scope — not built
- Only Google Docs are exported (no Sheets, Slides, PDFs)
- Shared folders' contents are not crawled automatically
