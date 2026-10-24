# Plan: PR authors and reviewers

**Status**: IMPLEMENTED, in review (2026-10-24) · **Branch**: `feat/pr-authors-reviewers`

## Problem

Merged PRs are indexed as `pulls/<number>` documents, and their text already
names the people (`… by @alice, merged …`, `**@bob:** …`). But the chunk
metadata only carries `path`, `name`, `pr`, `url` and `merged_at`:

- a `semantic_search` hit doesn't say who wrote or reviewed the PR without
  fetching it with `get_file`;
- "the PRs @alice worked on" can't be asked reliably: matching the login in
  the text also hits PRs that merely mention her, and misses approvals with
  no comment (empty reviews aren't rendered).

## Decisions

1. **People in the metadata.** `GitHub.to_pr/2` returns `author` (the PR
   author's login) and `reviewers` (every login that submitted a review,
   comment-less approvals included), which `PullRequestSync` stores as
   `metadata["author"]` / `metadata["reviewers"]` (jsonb array).
2. **Reviewers are humans only.** Left out: bots (`__typename: "Bot"` or a
   `[bot]` login), a fixed list of AI reviewers that may not come through as
   bots (Copilot, CodeRabbit, Gemini Code Assist, Sourcery, Greptile,
   Ellipsis, Qodo, Devin, Cursor, Claude; compared lowercased), deleted
   accounts (`ghost`), and the author's own replies. Deduplicated, in review
   order. The same bot check now also drops AI comments from the rendered
   text.
3. **The author is kept as is**, even when it is a bot (a Dependabot PR is
   still Dependabot's).
4. **Three `semantic_search` filters**, each a GitHub login matched
   case-insensitively: `author`, `reviewer`, and `involves` (author *or*
   reviewer — "every PR this dev acted on"). They are applied inside both
   RRF legs like the other filters (see `HybridQuery`), so they never starve
   recall; chunks without the metadata (code, Drive, Jira) never match.
   No index: the predicates ride along the HNSW/GIN scans, and PR chunks are
   a small share of the table.
5. **The content hash covers the people.** `content_hash` is the SHA-256 of
   the text plus the JSON of `{author, reviewers}`: an approval with no
   comment changes `reviewers` but not the text, and `FileIngest` skips a
   row whose hash matches the indexed `file_hash`.
6. **Backfill by re-sync.** A data migration drops `prs_updated_since` from
   every `sync_states.cursor`, so the next hourly `PullRequestSync` re-stages
   every merged PR (300 per run, then snooze and continue). Thanks to (5) the
   owner re-applies them; chunk text is unchanged, so embeddings are reused
   (except PRs that lose AI comments). The `down` is a no-op.

## Not done

- Filters on the `/search` page (MCP only for now).
- Review *requests* that were never answered, and PR assignees.
- Reviews past the first 50 / comments past the first 100 per PR (the
  GraphQL query's existing limits).
