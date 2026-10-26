# Plan: markdown chunking for everything that isn't code

**Status**: IMPLEMENTED, rebased on the upstream sync, not yet deployed (2026-10-26) · **Branch**: `feat/markdown-chunker`

## Problem

Only the tree-sitter languages (python, javascript, typescript, go, rust,
ruby, java, and elixir since upstream's AST chunking) get structural
chunking. Everything else — merged PRs, Google
Docs, Jira issues, repo docs and config files — falls back to
`HeuristicImpl`, which ends a chunk at every blank line (its brace balance is
always 0 in prose). Every paragraph, list item and heading becomes its own
chunk:

| Kind (prod, 2026-10-25) | Chunks | Median length | Under 100 chars |
|---|---|---|---|
| Merged PRs | 65,246 | 107 | 49 % |
| Google Docs | 54,621 | 60 | 59 % |
| Repo `.md` | 8,693 | 175 | 39 % |
| Repo config (yml, yaml, tf, json, toml, ini, Dockerfile…) | ~5,300 | ~150 | — |
| Repo plain text (txt, LICENSE…) | ~1,800 | ~60 | — |
| Jira issues | 856 | 209 | 7 % |
| Code (tree-sitter), for reference | 24,536 | 357 | 8 % |

PR #2612 in naboo, for instance, is 8 chunks: the title alone (62 chars),
`## Proposed change` alone (18), `## Additional` alone (13), then the
paragraphs. The breadcrumb is only the file prefix — `pulls/2612` for a PR,
the doc name for Drive — so a description chunk carries neither the PR title
nor its section. Searches mostly land on the short title chunk, which is why
callers report that "PR text isn't indexed": the description is stored, but
in fragments that rank poorly and can't be attributed.

Jira issues suffer less (breadcrumb `KEY: summary`, most issues 1–2 chunks),
but the header (status, assignee) is split from the description, long issues
fragment (CLOUD-312: 5 chunks of 126–319 chars), and the ADF description is
flattened to plain text, losing its headings, lists and code blocks.

## Principle

Everything that isn't code is turned into markdown and chunked by one
markdown chunker. Two modes:

- **Prose** (`lang: "markdown"`): PRs, Drive docs, Jira issues, repo docs.
  Headings drive the split and the breadcrumb.
- **Verbatim** (`yaml`, `json`, `toml`, `ini`, `properties`, `terraform`,
  `dockerfile`, `ignore`, `text`): config files and plain text. Chunked as
  if the whole file were one fenced code block: `#` is a comment, not a
  heading, and lines are packed up to the target size. The stored content
  stays the raw file — only the chunker treats it as a fence. Each keeps
  its real language name rather than a generic `"config"`, because `lang`
  is a `semantic_search` filter.

Code that tree-sitter doesn't cover yet (C/C++, shell, HTML, CSS…) is
**not** markdown and stays on `HeuristicImpl` (see Out of scope).

## Decisions

1. **A dedicated `Chunking.MarkdownImpl`**, pure Elixir (no NIF), implementing
   the `Chunking` behaviour:
   - Splits into blank-line-separated blocks, tracking fenced code blocks
     (```` ``` ```` / `~~~`): never splits inside one, and a `#` line inside
     one is not a heading.
   - Keeps a stack of ATX headings (`#` to `######`); the chunk's breadcrumb
     is the heading trail (`Incident log > Timeline`).
   - A heading starts a new chunk only once the current one has ~400 chars;
     smaller sections merge, and the breadcrumb is the trail they share. A
     heading is never emitted alone — it stays with the content after it.
   - Packs a section's blocks up to ~1,500 chars (`HeuristicImpl`'s target).
     A block over the target — a long code block or a config file — is split
     on line boundaries, preferring blank lines, then any line.
   - Verbatim languages run the same code path on the source as a single
     fence: no heading detection, line packing only, empty symbol trail.
   - Same pre-flight guards as `TreeSitterImpl` (2 MB cap, binary content).
     Chunks are `kind: "markdown_section"` / `"config_block"`,
     `parse_status: :ok`.
2. **Routing in `Chunking`**: `"markdown"` and the verbatim languages go to
   `MarkdownImpl` whatever `:chunking_impl` is, so prod and test behave the
   same and `FileIngest` doesn't change. Both entry points route through
   `impl_for/1` — `chunk/2` and upstream's `chunk_with_graph/2`, which
   `FileIngest` calls and which wraps `MarkdownImpl`'s chunks with empty
   graph lists.
3. **Jira: ADF → markdown.** `Ingest.Jira`'s `extract_text/1` flattens the
   description to plain text. Replace it with a small ADF-to-markdown
   renderer (`Ingest.Jira.Adf`): headings, paragraphs (blank-line
   separated), bullet/ordered lists (nested), code blocks (fenced, with
   language), blockquotes, links, mentions, inline cards (URL), simple
   tables; unknown nodes fall back to their text. The issue header becomes a
   `# KEY: summary` heading followed by the metadata lines, and `JiraSync`
   stages `lang: "markdown"`.
4. **Languages for the other sources**:
   - `PullRequestSync` already stages `"markdown"`.
   - `DriveSync` stages `lang: "markdown"` (the export is already markdown).
   - `RepoSync` maps by extension or file name:
     - `"markdown"`: `md`, `markdown`, `mdx`, `rst`, `adoc`, and
       extension-less `README`, `CHANGELOG`, `CONTRIBUTING`, `AUTHORS`,
       `NOTICE`, `LICENSE`, `COPYING`;
     - verbatim: `yml`/`yaml` → `yaml`, `json`, `toml`, `ini`/`cfg`/`conf`
       → `ini`, `properties`, `tf`/`tfvars`/`hcl` → `terraform`,
       `Dockerfile`, `Dockerfile.*` → `dockerfile`, `.gitignore`-style
       dotfiles → `ignore`, `txt` and `CODEOWNERS` → `text`;
     - `CMakeLists.txt` is code (CMake) and keeps `nil`;
     - extensions are matched case-insensitively; anything else keeps its
       current behaviour (`nil` → `HeuristicImpl`).
5. **Breadcrumb prefix**: a PR row uses its `name` (`PR #2612: <title>`)
   instead of `path` in `FileIngest.file_prefix/1`. `Breadcrumb.build/2` drops
   a leading heading equal to the prefix, so a Drive doc or a Jira issue
   whose first `#` is its title doesn't read `Title > Title > …`.
6. **Re-chunking existing content** needs a nudge: the raw files are
   unchanged, so `FileIngest.unchanged?/1` would skip them.
   `RetrievalNode.Ingest.Rechunk.run/0`, run in the live node after deploy
   (it enqueues Oban jobs) with
   `bin/retrieval_node rpc "RetrievalNode.Release.rechunk()"`:
   - sets `file_hash = NULL` on every chunk whose `lang` isn't a tree-sitter
     language (PRs, Drive, Jira, and all repo files without a grammar —
     those still on `HeuristicImpl` re-chunk identically and keep their
     embeddings);
   - removes `modified_time` from Drive chunk metadata, so the next full pass
     re-exports every doc;
   - deletes `prs_updated_since` from `sync_states` and enqueues `git_prs`;
   - enqueues `RepoSync` with `"full" => true` per git source (upstream's
     full resync: every file re-staged with `force`, embeddings reused by
     content), `DriveSync` and `JiraSync` with `"mode" => "full"`, and
     `PullRequestSync` per source with `pull_requests = true`. Like
     `Ingest.force_full_resync_git_sources/0`, a sync still waiting has its
     args replaced (`:upgraded`); one already executing comes back in
     `:busy`, to run it again once done.

   Jira's text changes anyway (ADF → markdown), so its content hash differs
   and it would re-chunk on its own; nulling `file_hash` is harmless there.

   Simulated on the prod corpus (each document rebuilt from its current
   chunks, 2026-10-26):

   | Kind | Chunks before | After | Median | p90 | Under 100 chars |
   |---|---|---|---|---|---|
   | Google Docs | 54,621 | 9,960 | 1,086 | 1,455 | 0 % |
   | Merged PRs | 65,246 | 23,522 | 1,269 | 1,673 | 5 % |
   | Repo `.md` | 8,693 | 2,823 | 1,139 | 1,554 | 1 % |
   | Jira | 856 | 541 | 277 | 1,105 | 0 % |

   ~129k chunks become ~37k (plus the config files), all re-embedded on
   Ollama (tens of minutes to an hour). Search keeps working throughout.

## Out of scope

- Code without a tree-sitter grammar here: C/C++ (~22k chunks, esphome),
  HTML/CSS/templates, shell, proto. They are code, not markdown; the fix is
  adding their grammars to `TreeSitterImpl` (tree-sitter has C and C++).
  Separate change. (Elixir got AST chunking upstream.)
- PR metadata added after a PR was indexed isn't backfilled because the
  watermark has moved past it (seen with `author`/`reviewers`, fixed by hand
  on 2026-10-25). Separate change.

## Steps

- [x] `Chunking.MarkdownImpl` (markdown + verbatim) + routing in `Chunking.chunk/2`
- [x] `Ingest.Jira.Adf` (ADF → markdown), issue header as `# KEY: summary`,
      description headings one level down, `lang: "markdown"` in `JiraSync`
- [x] `lang: "markdown"` in `DriveSync`; extension/file-name mapping in `RepoSync`
- [x] PR breadcrumb prefix (`file_prefix/1`); de-duplicated title in `Breadcrumb.build/2`
- [x] Tests:
  - `markdown_impl_test.exs`: one-chunk doc, heading split, heading never
    last, small-section merge, packing to target, small tail merge, `#`
    inside a fence, `~~~` fences, oversize split at blank lines, long line,
    heading trail, heading edge cases, a synthetic merged PR → 1–2 chunks,
    empty doc, CRLF; verbatim: YAML `#` comments, large JSON, every
    language; guards
  - `adf_test.exs`: headings + offset, nested lists, task lists, code
    blocks, quotes/panels/expands/rules, tables, marks, inline nodes,
    media/unknown nodes, nil/strings
  - routing in `chunking_test`; breadcrumb de-duplication; `RepoSync`
    mapping; `DriveSync` lang; Jira text in `sources_test`; PR breadcrumb
    in `FileIngest`; `rechunk_test.exs`
- [x] `Ingest.Rechunk.run/0` + `Release.rechunk/0` + test
- [x] `mix precommit`, `mix credo --strict`, `mix dialyzer`
- [ ] PR on the fork (`feat:` commit)
- [ ] After deploy: run `Release.rechunk/0` on prod, check chunk counts and
      sizes per kind, and that a search on a PR description returns the
      description with its PR title
