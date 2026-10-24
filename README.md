<p align="center">
  <img src="assets/imgs/icon-text.png" alt="Slow Henry" width="240" />
</p>

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
- **MCP tools:** `semantic_search`, `grep`, `get_file` (git),
  `get_document` (Drive doc / Jira issue text), `list_repos`, at `/mcp`.
- **Web UI** (LAN-only, no auth, like `/mcp`):
  - `/` — sources with file/chunk/pending counts, sync status and a Sync button,
    Oban job errors, and database size per table;
  - `/sources/edit` — pick the GitHub repos and the Google Drive scope to
    index (writes `sources.toml`);
  - `/sources/:id` — the indexed files of a source and the chunks of each file;
  - `/search` — the same hybrid search as `semantic_search`, with scores;
  - `/connections` — the app version, how to add the MCP server to a client
    (Claude Code, `.mcp.json`, VS Code…), embedding backend status (Ollama
    reachability, model, share of the index on the current embedding setup),
    and GitHub / Google Drive authorization.

## Stack

Elixir/Phoenix + LiveView · Postgres + pgvector · Oban · Bumblebee/Nx/EXLA ·
tree-sitter (code chunking) · Anubis MCP · Tailwind/daisyUI.

Production is self-hosted ARM (glibc), either as a release tarball
(`deploy/README.md`) or as the Docker image (see
[Running with Docker](#running-with-docker)); development runs in the
devcontainer.

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

### Prebuilt native artifacts

Some deps ship native code that their maintainers publish prebuilt on GitHub
releases, rather than in the Hex package (which holds source only):

| Dep | Downloads | Building it instead |
|---|---|---|
| `tree_sitter_language_pack`, `tokenizers` | Rust NIF (`.so`) for the OS/CPU, checked against the package's checksum file | Rust toolchain, 5–15 min |
| `xla` (for EXLA) | Google's XLA compiler, ~126 MB | Bazel, hours |
| `tailwind` | Tailwind CSS CLI binary | none: only distributed this way |

These deps download with Erlang's `:httpc`, which since **OTP 29.1** rejects
responses with over 10 KB of headers (`{:header_too_long, {:max, 10240}}`).
GitHub's release download redirect sends ~11 KB, so a build with an empty cache
fails. `scripts/prefetch_github_artifacts.sh` downloads the same files with
curl, verifies their checksums, and puts them where each dep looks before
downloading. CI, the Dockerfile and `scripts/build_arm64.sh` run it after
`mix deps.get`. Locally, if `mix setup` or `mix compile` fails with
`header_too_long`:

```sh
export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$HOME/.cache/github-artifacts/rustler_precompiled"
export XLA_CACHE_DIR="$HOME/.cache/github-artifacts/xla"
scripts/prefetch_github_artifacts.sh --tailwind
mix setup
```

The script can go once those deps raise the limit themselves, or GitHub's
headers shrink.

## Configuration

Configuration comes from environment variables. They can be set in the
environment, or in an optional, git-ignored `.env` that mise loads into every
command run in the repo (`.env.example` is the template). When `.env` exists,
its values win over the shell environment. The app never writes `.env`:
credentials it obtains itself (OAuth tokens) go to `DATA_DIR/secrets.toml`.

| Variable | Used for |
|---|---|
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | Database, in dev and prod (defaults: the devcontainer's local Postgres). |
| `DATABASE_URL` | Prod only: takes precedence over the `PG*` variables. |
| `OLLAMA_ENDPOINT` | Ollama server for embeddings, e.g. `http://localhost:11434` (see [Embeddings](#embeddings)). Unset: in-process CPU model. |
| `OLLAMA_EMBEDDING_MODEL` | Ollama embedding model (default `nomic-embed-text`). |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google Drive OAuth client (see below). |
| `GOOGLE_REFRESH_TOKEN` | Optional: overrides the Google token stored by the `/connections` page. |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub App, for merged PRs and private clones (see below). |
| `GITHUB_TOKEN` | Optional: a token (e.g. a fine-grained PAT) that overrides the one stored by `/connections`. |
| `DATA_DIR` | The app's data dir: `sources.toml` and `secrets.toml` (default `./data` in dev, `/var/lib/retrieval_node` in a release). |
| `SOURCES_FILE` | Path of the sources file (default `DATA_DIR/sources.toml`). |
| `SOURCES_WATCH_INTERVAL` | Seconds between checks of the sources file for changes (default 30). |
| `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_PROJECT_KEY` | Jira source, registered with `mix rn.seed`. |
| `GIT_MIRROR_ROOT` | Prod: where the bare git mirrors live. |
| `PORT` | HTTP port (default 4000). |
| `SECRET_KEY_BASE` | Prod only, required: signs cookies (`mix phx.gen.secret`). |
| `PHX_HOST` | Prod: the host name in generated URLs (default `example.com`; `localhost` in `docker-compose.yml`). |

`mix test` always uses the local Postgres on `localhost`, whatever `PGHOST`
says, so a `.env` pointing at a real database can't be wiped by the suite.

## Running with Docker

The image `ghcr.io/bemble/slow-henry` is published for `linux/amd64` and
`linux/arm64`. `docker-compose.yml` runs it next to Postgres 18 + pgvector
(`pgvector/pgvector:pg18`):

```sh
cp .env.example .env                    # then fill it in, see below
docker compose up -d
```

In `.env`, set at least `SECRET_KEY_BASE` (`openssl rand -base64 48`, or
`mix phx.gen.secret`). The `PG*` values are used both to create the database
and to connect to it, and `PGHOST` is always `db` inside compose. Everything
else in [Configuration](#configuration) applies as is.

- The UI and `/mcp` are on port 4000 (`PORT` in `.env` changes the host port).
  Pending migrations run at each start; set `RUN_MIGRATIONS=false` to skip them.
- Pick the sources to index on the **Edit sources** page (`/sources/edit`,
  see [Sources](#sources)). They are saved in `sources.toml` in the
  `app-data` volume. Earlier compose files mounted `./sources.toml` from the host
  instead; to keep that file, copy it into the volume once:
  `docker compose cp sources.toml app:/var/lib/retrieval_node/sources.toml`.
- The `app-data` volume holds `sources.toml`, `secrets.toml` (OAuth tokens
  from `/connections`), the git mirrors, and the embedding model (~1 GB). The model
  is downloaded at first boot, so the container reports healthy (`/healthz`)
  only after a few minutes. With `OLLAMA_ENDPOINT` set, nothing is downloaded.
  The compose file has a commented-out `ollama` service.
- The `db-data` volume holds the database.

**Versions.** `latest` is the latest release. Pin `SLOW_HENRY_VERSION` in
`.env` instead (`0.2.0`, or `0.2` to follow patch releases), then upgrade with
`docker compose pull && docker compose up -d`. `edge` follows `main`, and every
build is also tagged `sha-<commit>`.

To build the image yourself: `docker build -t slow-henry .`

### Releases

Versions follow [semver](https://semver.org/) and are managed by
[release-please](https://github.com/googleapis/release-please) from
[Conventional Commits](https://www.conventionalcommits.org/) (`fix:` → patch,
`feat:` → minor, `feat!:` or `BREAKING CHANGE:` → minor until 1.0). On each
push to `main` (`.github/workflows/release.yml`):

1. release-please opens or updates a release PR that bumps `version` in
   `mix.exs` and adds the changes to `CHANGELOG.md`;
2. merging that PR tags `vX.Y.Z` and creates the GitHub Release;
3. the image is built on native amd64 and arm64 runners and pushed as `edge`,
   plus `X.Y.Z`, `X.Y`, `X` and `latest` for a release
   (`.github/workflows/docker.yml`, which also test-builds pull requests that
   touch the image).

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
don't mix well in one index. Every chunk records the setup that embedded it
(`chunks.embedding_profile`, e.g. `ollama:nomic-embed-text:nomic-prefixes:384`);
the Connections page shows how much of the index is on the current one, and
new or changed files are always embedded with it. To redo the rest:

```sh
mix rn.reembed     # only chunks not on the current setup; re-run to resume
                   # --all redoes everything, --source NAME one source
```

It re-embeds the stored chunk text without re-chunking, and can run while
the server is up (a chunk the server rewrites meanwhile keeps its new vector).

**When Ollama is unreachable** (connection refused, timeout, 502/503/504),
nothing is lost or given up: ingestion defers the source's staged files and
retries every minute without spending their attempts, and search falls back
to full-text ranking — the search page shows a notice, and the
`semantic_search` MCP tool returns `"mode": "text_only"` instead of
`"hybrid"`.

## Sources

Git repos and the Google Drive scope are declared in `DATA_DIR/sources.toml`
(`data/sources.toml` in dev, git-ignored since it names private repos; start
by copying `sources.example.toml` there):

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

The **Edit sources** page (`/sources/edit`, from the Sources page) writes
this file for you: GitHub repos are picked from the ones your GitHub
connection can read (any other git URL, or a public repo, can be added by its
URL), `exclude` patterns and Drive ids are plain text fields (a pasted Drive
folder URL is turned into its id), and a review step shows what will change
before saving. Saving rewrites the file without its comments, and is refused
if the file changed on disk since the page was opened.

The server applies the file when it starts and again whenever its content
changes (checked every 30 seconds, `SOURCES_WATCH_INTERVAL` to change it); the
Sources page says when it was last applied. A missing or invalid file changes
nothing — the sources stay as they are and the page shows the error. To apply
or preview by hand:

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

`pull_requests = true` indexes the repo's **merged** pull requests through
GitHub's GraphQL API, with the GitHub App token (see below): one document per
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
4. Open `/connections` in the UI and click **Connect Google Drive**. Google redirects
   back to `/google/callback`, and the refresh token is stored in
   `DATA_DIR/secrets.toml` (mode 0600, never displayed) and used from then on,
   across restarts. **Disconnect** on the same page forgets it.
   `GOOGLE_REFRESH_TOKEN`, if set, overrides the stored token.

When the server runs on another machine than the browser, Google's redirect to
`localhost` fails to load: paste that page's URL into the form on `/connections`.

### GitHub

Merged pull requests, and clones of private `https://github.com/` repos, use
the token of a **GitHub App**, obtained through the device flow — no `gh` CLI,
no redirect, so it works on a headless server. The token can only do what the
App's permissions allow, on the repos where the App is installed and you have
access.

One-time setup:

1. GitHub → Settings → Developer settings → **GitHub Apps** → New GitHub App.
   Any homepage URL; **uncheck Webhook**; check **Enable Device Flow**.
2. Repository permissions, all **read-only**: Contents, Pull requests (Metadata
   is added automatically). Nothing else.
3. Create it, note the **Client ID**, generate a **client secret**, and set
   `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`. If the App must be installed on
   an organization you don't own, make it installable by **Any account**.
4. Install the App on the organization(s) or account holding the repos, for
   all repos or a selection.
5. Open `/connections` and click **Connect GitHub**: enter the code shown at
   github.com/login/device. The refresh token goes to `DATA_DIR/secrets.toml`;
   GitHub rotates it at each refresh (access tokens last 8 hours, refresh
   tokens 6 months when unused). **Disconnect** forgets it.

`GITHUB_TOKEN`, if set, is used instead and never refreshed. Without any token,
PR syncs are cancelled and git falls back to its own credential helper.

## Project plan

The build is sequenced in `.claude/plans/retrieval-node/plan.md` (10 phases,
Phase 0 scaffold → Phase 9 validation). Design rationale lives under
`.claude/plans/retrieval-node/research/`.
