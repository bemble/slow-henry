# Plan: Jira from the UI, with optional fields

**Status**: IMPLEMENTED, in review (2026-10-24) · **Branch**: `feat/jira-api-token-people`

## Problem

Jira was the one source still outside `sources.toml` and the UI:

- a project was registered only by `mix rn.seed`, from `JIRA_*` env vars;
- those vars were mapped to `config :retrieval_node, :jira` **only inside the
  seed task**: nothing in `config/runtime.exs` read them, so the hourly
  `JiraSync` in the server ran against `https://example.atlassian.net` with
  empty credentials;
- the client called `GET /rest/api/3/search`, which Atlassian has removed
  (replaced by `/rest/api/3/search/jql`, paged by `nextPageToken`), with
  `maxResults: 50` and no pagination;
- the watermark (`2026-03-01T10:30:00.000+0000`) went into the JQL as is,
  a format JQL doesn't accept;
- only `summary`, `description` and `resolutiondate` were indexed: no type
  (to ask for bugs), no people, no epic.

## Decisions

1. **Credentials on the Connections page** (`Jira.Credentials`): site, email
   and API token, checked against `/rest/api/3/myself` before being stored in
   `secrets.toml` (`jira_base_url`, `jira_email`, `jira_api_token`); the token
   is never displayed. **Disconnect** forgets them. `JIRA_BASE_URL` /
   `JIRA_EMAIL` / `JIRA_API_TOKEN`, now read by `runtime.exs`, override them
   when all three are set (the form is then hidden). The site is normalized
   (`acme.atlassian.net`, a pasted board URL, the gateway URL).
2. **Tokens with scopes.** Atlassian only accepts them through
   `https://api.atlassian.com/ex/jira/<cloudId>`; the site answers 401.
   `Jira.connect/1` retries there when an `*.atlassian.net` site refuses the
   token (cloud id from the public `/_edge/tenant_info`), stores the gateway
   as `base_url` and the site as `jira_site_url`, for links to issues. A
   refusal shows what Jira said (`HTTP 401: Unauthorized; scope does not
   match`).
3. **Projects in `sources.toml`**: `[[jira]] project = "CLOUD"` (upper-case
   key, the source identity; name `Jira: CLOUD`), `active` like the others.
   `:jira_project` becomes a managed type: added → first sync, removed →
   deactivated. `/sources/edit` adds projects by key. `mix rn.seed` no longer
   handles Jira.
4. **Always indexed**: summary, description, type, status, resolution,
   resolution date, as a header on the text and as metadata (`issue_type`,
   `status`, `resolution`, plus `name` and `url` for `get_document`).
5. **Optional fields, per project, off by default** like `pull_requests`:
   `assignee`, `reporter`, `parent` (key, type and summary: the epic, for a
   story). Stored in the source config only when on; a field turned off is
   neither requested nor in the text nor in the metadata. Changing them
   queues a full pass (`"mode" => "full"`, the watermark ignored). Checkboxes
   per project on `/sources/edit`.
6. **`semantic_search` filters**: `issue_type` (case-insensitive), `assignee`
   / `reporter` (case-insensitive substring of the display name: "pierre"
   finds "Pierre Clément"), `parent` (key). Applied inside both RRF legs like
   the PR filters, factored into one `filters` fragment.
7. **Enhanced search API**: `/rest/api/3/search/jql`, 100 per page, following
   `nextPageToken`. Since `isLast` is reported unreliable, it also stops on a
   missing or repeated token, and at 50 pages per run (the next run resumes
   from the watermark). Each page is staged with the watermark in one
   transaction.
8. **Selection and watermark**: `statusCategory = Done` instead of the status
   names `Resolved/Closed/Done` (so custom done statuses such as "Won't Do"
   are included). The JQL clause is the watermark's **date minus one day**
   (JQL dates are minute-precise in the account's time zone); the overlap is
   re-staged and skipped by the owner when unchanged. The watermark never
   moves backwards.
9. **No credentials** → `JiraSync` is cancelled (`:jira_not_configured`);
   the next hourly run tries again.
10. **Backfill**: a migration drops `resolutiondate_watermark`, so existing
    Jira sources re-stage every issue with the new header and metadata.

## Not done

- Comments, labels, components, attachments, custom fields.
- Open issues.
- OAuth 2.0 (3LO) for Jira: an API token is enough for read access.
- Jira filters on the `/search` page (MCP only, like the PR filters).
