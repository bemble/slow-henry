# Slow Henry

A self-hosted **MCP knowledge server** (the Elixir app is `RetrievalNode`) that
makes git repos, Google Drive docs and resolved Jira issues searchable by an AI
assistant, plus a small web UI to see what is indexed.

It performs **hybrid semantic search** — dense vector similarity fused with
BM25/full-text ranking via Reciprocal Rank Fusion (RRF) — over content that is
incrementally ingested, chunked, and embedded. Results and file access are
exposed to clients as **MCP tools** over HTTP.

## What it does

- **Three sources, one index:** git repos (bare mirrors), Google Docs and
  resolved Jira issues are chunked and embedded into a single store, so one
  query ranks across all of them.
- **Hybrid retrieval:** pgvector cosine similarity (HNSW) + Postgres full-text
  search (GIN), fused with RRF (k=60). Optional `source`/`repo`/`lang` filters
  are applied *before* ranking so filtered searches stay accurate.
- **Incremental ingestion:** per-source Oban sync jobs stage changed content in
  `pending_chunks` and advance a watermark; one `SourceOwner` process per source
  chunks, embeds and upserts it. Re-runs are no-ops. Lockfiles, minified
  bundles, source maps, snapshots, SVGs and text files over 256 KB are skipped.
- **Local embeddings:** `nomic-embed-text-v1.5`, Matryoshka-truncated to 384
  dimensions — in-process via Bumblebee/Nx.Serving (CPU), or on an Ollama
  server (e.g. a Mac's GPU, see [Embeddings](#embeddings)).
- **Secrets-aware:** git and Drive content goes through gitleaks (regex
  fallback), Jira through the regex scanner; secrets are redacted in place
  before anything is embedded, and an append-only audit log records what was
  found (hash only).
- **MCP tools:** `semantic_search`, `grep`, `get_file`, `list_repos`, at `/mcp`.
- **Web UI** (LAN-only, no auth, like `/mcp`):
  - `/` — sources with file/chunk/pending counts, sync status and a Sync button,
    Oban job errors, and database size per table;
  - `/sources/:id` — the indexed files of a source and the chunks of each file;
  - `/search` — the same hybrid search as `semantic_search`, with scores;
  - `/google` — Google Drive authorization.

## Stack

Elixir/Phoenix + LiveView · Postgres + pgvector · Oban · Bumblebee/Nx/EXLA ·
tree-sitter (code chunking) · Anubis MCP · Tailwind/daisyUI.

Production is self-hosted ARM (glibc); development runs in the devcontainer.

## Development

Requires the tools in `.mise.toml` (Erlang, Elixir, gitleaks) and Postgres with
the `vector` extension (**≥ 0.5.0**, for HNSW). Then:

```sh
mix setup          # deps, database, and the UI assets (Tailwind + esbuild)
mix phx.server     # server on :4000 — UI at /, MCP endpoint at /mcp
mix test           # run the suite
mix precommit      # warnings-as-errors compile, format, tests
```

> **Dev DB:** the devcontainer installs **PostgreSQL 18 + pgvector** and runs it
> on the standard port **5432** (`.devcontainer/Dockerfile` + `setup.sh`;
> `postStartCommand` restarts it on later boots). If the DB is ever unreachable:
> `sudo pg_ctlcluster 18 main start`.

## Configuration

Everything comes from environment variables. They can be set in the
environment, or in an optional, git-ignored `.env` that mise loads into every
command run in the repo (`.env.example` is the template). When `.env` exists,
its values win over the shell environment.

| Variable | Used for |
|---|---|
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | Database, in dev and prod (defaults: the devcontainer's local Postgres). |
| `DATABASE_URL` | Prod only: takes precedence over the `PG*` variables. |
| `OLLAMA_ENDPOINT` | Ollama server for embeddings, e.g. `http://localhost:11434` (see [Embeddings](#embeddings)). Unset: in-process CPU model. |
| `OLLAMA_EMBEDDING_MODEL` | Ollama embedding model (default `nomic-embed-text`). |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google Drive OAuth client (see below). |
| `GOOGLE_REFRESH_TOKEN` | Google Drive access, obtained from the `/google` page. |
| `SOURCES_FILE` | Path of the sources file (default `sources.toml`). |
| `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_PROJECT_KEY` | Jira source, registered with `mix rn.seed`. |
| `GIT_MIRROR_ROOT` | Prod: where the bare git mirrors live. |
| `PORT` | HTTP port (default 4000). |

`mix test` always uses the local Postgres on `localhost`, whatever `PGHOST`
says, so a `.env` pointing at a real database can't be wiped by the suite.

## Embeddings

By default chunks are embedded in-process on the CPU (Bumblebee + EXLA, about
3 chunks/s on 14 arm64 cores). For anything beyond a few repos, run
[Ollama](https://ollama.com) where there is a GPU — on an Apple Silicon Mac it
uses Metal, about 18x faster (about 50 chunks/s on a Mac Studio):

```sh
ollama pull nomic-embed-text           # the same model: nomic-embed-text v1.5
```

then set `OLLAMA_ENDPOINT` (e.g. `http://localhost:11434`; from a devcontainer
on the same Mac, `localhost` or `host.docker.internal`; for another machine,
start Ollama with `OLLAMA_HOST=0.0.0.0` — it has no authentication, keep it on
the LAN). The in-process model is then not loaded at all.

Through Ollama, chunks are embedded with nomic's `search_document: ` prefix and
queries with `search_query: `, as the model was trained.

**Switching setups.** Vectors from different backends, models or prefixes
don't mix well in one index, so after switching re-embed what is stored:

```sh
mix rn.reembed     # stop the server first; --source NAME, --after ID to resume
```

It re-embeds the stored chunk text without re-chunking.

## Sources

Git repos and the Google Drive scope are declared in `sources.toml`
(git-ignored, since it names private repos; start from `sources.example.toml`):

```toml
[[git]]
name = "my-repo"                               # mirror slug + MCP `repo` filter
url = "https://github.com/my-org/my-repo.git"  # clone URL (the source identity)
# active = false                               # keep the chunks, stop syncing
# exclude = ["docs/*", "!docs/adr"]            # paths to leave out (see below)
# pull_requests = true                         # also index merged PRs (default false)

[drive]
my_drive = true                  # Docs you own (default true)
shared_with_me = false           # Docs shared directly with you (default false)
include = ["0AbCdEfGhIjKlMnOpQ"] # shared drive or folder ids (folders: whole tree)
```

```sh
mix rn.sources --dry-run   # print what would change
mix rn.sources             # apply: add, update, deactivate
```

`exclude` uses `.gitignore`-style patterns, anchored at the repo root: `*`
stays within one path segment, `**` crosses segments, a pattern matching a
directory covers everything below it, `!` re-includes (even below an excluded
directory), and the last matching pattern wins. For example
`["homeassistant/components/*", "!homeassistant/components/cloud"]` keeps
only the `cloud` integration. Changing `exclude` triggers a full pass that
indexes newly included files and removes newly excluded ones.

`pull_requests = true` indexes the repo's **merged** pull requests through the
`gh` CLI (`gh auth login` for the user running the server): one document per
PR, under the virtual path `pulls/<number>`, with its title, author, merge
date, URL, description, and the human comments and reviews (bots left out).
They are synced hourly, picking up PRs edited or commented after merge.

New sources get their first sync right away, then git syncs every 15 minutes
and Drive every 30 minutes (plus a full Drive pass daily at 04:15). A source
removed from the file is **deactivated, never deleted**: its chunks stay
searchable and putting it back resumes where it stopped. Jira is still
registered with `mix rn.seed` from its environment variables.

### Google Drive

Only Google Docs are indexed (exported as markdown, images stripped), and only
those with **no Classification label, or classified Public / Internal**. If the
label can't be read, nothing is indexed.

One-time setup:

1. In the Google Cloud console, create a project and enable the **Google Drive
   API** and the **Drive Labels API**.
2. OAuth consent screen: type **Internal**, scopes `drive.readonly` and
   `drive.labels.readonly`.
3. Create an OAuth client ID of type **Desktop app**, and set
   `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.
4. Open `/google` in the UI and click **Connect Google Drive**. Google redirects
   back to `/google/callback`; the refresh token is then used until the server
   restarts and **shown once**. Nothing is written to disk: set
   `GOOGLE_REFRESH_TOKEN` to keep it.

When the server runs on another machine than the browser, Google's redirect to
`localhost` fails to load: paste that page's URL into the form on `/google`.

## Project plan

The build is sequenced in `.claude/plans/retrieval-node/plan.md` (10 phases,
Phase 0 scaffold → Phase 9 validation). Design rationale lives under
`.claude/plans/retrieval-node/research/`.
