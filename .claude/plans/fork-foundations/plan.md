# Plan: Fork foundations — config, inspection UI, sources.toml

**Status**: DONE (retroactive write-up, 2026-10-23) · **PRs**: bemble/slow-henry #1–#5
**Context**: `bemble/slow-henry` is a hard fork of `bbangert/slow-henry`
(RetrievalNode), tailored to one engineering manager's needs: a local
knowledge base for morning briefs, meeting prep and investigations. No
obligation to stay compatible with upstream; changes are cherry-picked from
upstream only when useful. The app runs from the repo's devcontainer
(OrbStack, `--network=host`) against a Postgres 18 + pgvector server on the
LAN, and will later run on that LAN box.

This plan covers the first five PRs: what had to exist before any new source
or backend could be added.

---

## Decisions

1. **Configuration comes from environment variables only.** Standard libpq
   `PG*` variables in dev *and* prod (prod still prefers `DATABASE_URL`), so
   one set of variables works everywhere. An optional, git-ignored `.env` is
   loaded by mise (`[env] _.file = ".env"`); when it exists, its values win
   over the shell. The app never writes `.env`.
2. **Tests never touch a real database.** `config/test.exs` pins
   `hostname: "localhost"`, whatever `PGHOST` says, so a `.env` pointing at the
   LAN box can't be wiped by `mix test`.
3. **gitleaks is a mise tool.** Without the binary the scrubber silently
   degrades to the regex scanner; installing it through `.mise.toml` makes the
   devcontainer and the LAN box behave the same.
4. **Skip what isn't worth indexing at the staging seam.** Lockfiles, minified
   bundles, source maps, snapshots, SVGs and any text file over 256 KB are
   staged as deletions by `RepoSync` (see the yarn.lock solution doc).
5. **An inspection UI, in-repo.** A LiveView UI (stock `phx.new` 1.8 front-end
   base: Tailwind, daisyUI, esbuild, heroicons) rather than a separate tool or a
   SQL client: sources with counts and sync status, files of a source with their
   chunks, and the same hybrid search as the MCP tool with scores. LAN-only and
   unauthenticated like `/mcp`. Read queries live in `RetrievalNode.Inventory`.
6. **The source list is a file.** Git repos were registered one
   `mix rn.seed --git-url` at a time and only lived in the DB. `sources.toml`
   (git-ignored, it names private repos; `sources.example.toml` is the template)
   is now the source of truth, applied with `mix rn.sources [--dry-run]` in one
   transaction. Removing an entry **deactivates** the source — chunks stay
   searchable and re-adding it resumes from its cursor.

## Phases

### Phase 1 — Environment-driven config (PR #1)
- [x] `config/dev.exs` reads `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE` with
      the devcontainer's local Postgres as defaults
- [x] `config/runtime.exs` (prod): `DATABASE_URL`, else `PGHOST` + `PGDATABASE`
      (+ user/password/port), else a clear error naming both options
- [x] `.mise.toml`: `[env] _.file = ".env"`, `gitleaks` in `[tools]`
- [x] `.env.example`, `/.env` git-ignored; `config/test.exs` pinned to localhost
- [x] Verified: prod runtime config evaluated with `PG*` only, `DATABASE_URL`
      only, and neither

### Phase 2 — Skip generated and oversized files (PR #2)
- [x] `RepoSync.indexable?/2` (basename list + suffix list + 256 KB cap)
- [x] Non-indexable files become deletion rows, so earlier chunks reconcile away
- [x] Cleaned the live index (1,611 `yarn.lock` chunks, 14 staged rows)

### Phase 3 — Search `source_id` filter fix (PR #3)
- [x] `HybridQuery` dumps the string UUID before binding `$5::uuid`
      (see the Postgrex UUID solution doc); regression test

### Phase 4 — LiveView inspection UI (PR #4)
- [x] Front-end base copied from a reference `phx.new` 1.8.15 project; deps,
      compilers, `assets.*` aliases, watchers, `ErrorHTML`, CSP in the browser
      pipeline, `scripts/build_arm64.sh` runs `assets.deploy`
- [x] `/` Sources (counts, pending/failing, redactions, last sync, status,
      Sync button, Oban errors, auto-refresh 5 s), `/sources/:id` Files,
      `/search` Search
- [x] "Sources indexing" status: a source with staged files shows as
      *indexing*, because chunking/embedding runs in `SourceOwner`, outside
      Oban (a "jobs running" counter always read 0)

### Phase 5 — `sources.toml` + `mix rn.sources` (PR #5)
- [x] `RetrievalNode.SourcesFile`: parse + validate (safe mirror slug names,
      `GitMirror`'s URL schemes, no duplicates/unknown keys), plan, apply
- [x] `--dry-run`; `SOURCES_FILE` override; example file checked by a test

## Verification

```
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix sobelow --private --skip --exit --threshold medium --ignore Config.HTTPS
```

## Follow-ups (handled in later plans)

- Google Drive that actually works → `../google-drive/plan.md`
- Path exclusion and merged PRs for git sources → `../git-sources/plan.md`
- CPU embeddings far too slow for the corpus → `../ollama-embeddings/plan.md`
- Markdown chunks are very small (heuristic fallback: tens of characters,
  ~50 chunks per Drive doc on average) — not addressed yet
