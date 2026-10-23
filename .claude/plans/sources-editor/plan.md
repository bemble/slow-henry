# Plan: edit sources.toml from the UI

**Status**: IMPLEMENTED, in review (2026-10-23) · **Branch**: `feat/sources-editor`

## Problem

The indexed git repos and the Google Drive scope are configured by editing
`DATA_DIR/sources.toml` by hand: the clone URL has to be typed or copied for
each repo, and the `include` ids have to be copied out of Drive URLs. Now that
the app has its own GitHub (GitHub App user token) and Google (Drive read-only)
access, the UI can list what is reachable and write the file itself.

## Decisions

1. **`sources.toml` stays the source of truth; the UI writes it.** The editor
   never touches the `sources` table directly: it encodes the entries, writes
   the file, then calls `SourcesFile.Watcher.check_now/0`. Validation
   (`parse/1`), `plan/1`, deactivation instead of deletion, and the syncs
   queued on change all stay as they are. `mix rn.sources` and hand edits
   keep working.
2. **Comments are not preserved.** The `toml` dep only decodes, so
   `SourcesFile.encode/1` is a small deterministic encoder (fixed header
   comment, `[[git]]` tables in the editor's order, then `[drive]`); string
   escaping is shared with `Secrets` in `RetrievalNode.TomlWriter`. Saving from the UI rewrites the file without the user's own comments.
3. **Optimistic lock on the file hash.** The editor remembers the SHA-256 of
   the file it loaded; `save/3` refuses to write if the file on disk changed
   since (a hand edit in between), and the UI asks to reload.
4. **Atomic write**: temp file + `rename`, after `parse/1` accepted the
   entries, so the watcher never reads a half-written file. A failed write
   (read-only mount, or the docker-compose single-file bind mount, which
   can't be renamed over) is reported in the review panel; nothing changes.
5. **GitHub repos from `GET /user/repos`** (paginated via the `Link` header,
   Req). With the GitHub App token it returns the repos where the App is
   installed and the user has access; it also works with a `GITHUB_TOKEN` PAT.
   Loaded once per page visit (`start_async`), filtered server-side as the
   user types (`phx-change` + `phx-debounce`).
6. **Non-GitHub repos** (`ssh://`, `file://`, other hosts) already in the
   file go in an **"Other"** section with an editable URL field, so they are
   neither lost on save nor forced through the GitHub picker.
7. **A separate page**, `/sources/edit` (`SourcesEditLive`), reached from an
   "Edit sources" button on the Sources page. The Sources table refreshes
   every 5 s, which doesn't suit editing in place.
8. **Preview before save**: the diff from `SourcesFile.plan/1` (added /
   updated / deactivated, and which changes trigger a full re-sync). Removing
   a repo is shown as "deactivate: indexed chunks stay searchable".

## UI

- **GitHub repos**: search box + filtered list of reachable repos; checking a
  repo adds it with `name` = repo name and `url` = `clone_url`. Each selected
  repo shows:
  - `name` (editable, to resolve collisions such as two `core` repos)
  - `active` and `pull_requests` checkboxes
  - `exclude`: one text field per pattern, with add / remove buttons
  Selected repos that the token can no longer see stay listed, flagged.
- **Other repos**: same fields as GitHub repos, plus an editable `url` field and an "Add" button.
- **Google Drive**: `my_drive` and `shared_with_me` checkboxes, `active`
  checkbox, `include` as one text field per id with add / remove. Pasting a
  folder or shared-drive URL extracts the id; each id shows its resolved name
  (`Drive.get_drive/1`, falling back to `files.get` for a folder) or an
  "inaccessible" warning.
- Errors from `parse/1` are shown in the form, not only in the watcher's error banner on the Sources page.
- The Sources page's empty state points to the editor instead of `mix rn.seed`.

## Steps

- [x] `SourcesFile.encode/1`, `SourcesFile.save/3` (validate, hash check,
      atomic write), expose the loaded file's hash
- [x] Tests: encode → decode → parse round-trip equals the input entries,
      hash conflict refused, invalid entries refused without writing
- [x] `Ingest.GitHub.list_repos/0` (pagination, unauthorized handling) +
      `Req.Test` tests
- [x] Drive id resolution helper (shared drive or folder name) + id
      extraction from Drive URLs, with tests
- [x] `SourcesEditLive` at `/sources/edit`: GitHub picker, Other repos,
      Drive section, plan preview, save → `Watcher.check_now/0`
- [x] "Edit sources" button and new empty state on `SourcesLive`
- [x] LiveView tests: add a repo, add/remove an exclude, Drive include,
      save writes the file, hash conflict message
- [x] Update the `SourcesFile` moduledoc and README (`sources.toml` can be
      edited from the UI; comments are not preserved)
- [x] `mix precommit`

## Deployment

- docker-compose no longer bind-mounts `./sources.toml` read-only (the editor
  can't save there): the file lives in the `app-data` volume at
  `DATA_DIR/sources.toml`, the image's default. Existing installs copy theirs
  in once (`docker compose cp`), as the README says.
