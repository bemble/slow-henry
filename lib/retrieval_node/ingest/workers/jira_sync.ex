defmodule RetrievalNode.Ingest.Workers.JiraSync do
  @moduledoc """
  Watermark-driven "discover work" job for a Jira project. Append-only, same
  shape as `Ingest.Workers.RepoSync`/`DriveSync`: pages through the issues
  resolved since the stored `resolutiondate_watermark` (`Ingest.Jira`) and
  stages one raw `pending_chunks` row per issue, its metadata carrying the
  type and status, plus the assignee, reporter and parent when the project
  turns them on — never touches `chunks` directly. `"mode" => "full"` (queued
  when those options change) ignores the watermark and re-stages every issue.
  `Ingest.SourceOwner` is the only process that does. No removal path today
  (Jira issues aren't removed the way a git path or Drive doc is) — but an
  issue whose text comes back binary (`Chunking.binary_content?/1`, a
  defensive check; Jira's own ADF text extraction shouldn't produce this)
  still stages a deletion entry rather than being silently dropped by
  `PendingChunks.insert_raw_all/1`'s own binary guard, so any previously
  indexed chunks for it get reconciled away.

  Staging a page's rows and advancing the watermark happen in ONE
  `Repo.transaction` (a plain write — this job's `unique` window on
  `source_id` makes it the sole writer of its cursor). After commit,
  `Ingest.SourceOwner.notify/1` wakes (or starts) the owner that applies the
  batch.

  A 429 returns `{:snooze, seconds}` (parsed from `Retry-After`) so rate
  limits don't burn attempts. Without credentials (Connections page) the job
  is cancelled; the next hourly run tries again.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      # `period: :infinity` with active-only `states` (no :completed) makes an
      # ACTIVE sync the sole one for its source for its whole lifetime — however
      # long it runs — closing the window where a finite period expired while a
      # slow sync was still executing and a second concurrent sync could then
      # regress the cursor / mailbox order. A fresh sync still enqueues once the
      # prior one leaves the active states (completed/discarded/cancelled).
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Chunking
  alias RetrievalNode.Ingest.{Jira, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}
  alias RetrievalNode.SourcesFile

  @max_pages 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id} = args}) do
    source = Repo.get!(Source, source_id)
    state = get_or_create_sync_state(source_id)

    # A full pass (options changed in sources.toml) re-stages every issue.
    watermark =
      if args["mode"] == "full",
        do: nil,
        else: Map.get(state.cursor || %{}, "resolutiondate_watermark")

    sync(source, state, watermark, nil, 0)
  end

  # The optional fields turned on for this project in sources.toml.
  defp options(source) do
    for o <- SourcesFile.jira_options(), (source.config || %{})[o] == true, do: o
  end

  # Page through everything resolved since the watermark, staging page by page
  # so a failure mid-way keeps what was staged. `@max_pages` bounds a run (and a
  # search that would keep handing out tokens); the next run resumes from the
  # watermark.
  defp sync(source, state, watermark, page_token, pages) do
    case Jira.fetch_resolved_page(source.identifier, watermark, page_token, options(source)) do
      {:ok, issues, next} ->
        state = stage!(source, state, issues)

        if next in [nil, page_token] or pages + 1 >= @max_pages do
          mark_synced!(state)
          SourceOwner.notify(source.id)
          :ok
        else
          sync(source, state, watermark, next, pages + 1)
        end

      # No credentials: nothing a retry fixes; the next hourly run tries again.
      {:error, :jira_not_configured} ->
        {:cancel, :jira_not_configured}

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stage!(_source, state, []), do: state

  defp stage!(source, state, issues) do
    rows = Enum.map(issues, &raw_row(source, &1))

    # Never backwards: the search overlaps the previous run by a day.
    new_watermark =
      [
        Map.get(state.cursor || %{}, "resolutiondate_watermark")
        | Enum.map(issues, & &1.resolutiondate)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    {:ok, state} =
      Repo.transaction(
        fn ->
          {:ok, _ids} = PendingChunks.insert_raw_all(rows)
          advance_watermark!(state, new_watermark)
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
    state
  end

  defp raw_row(source, issue) do
    if Chunking.binary_content?(issue.text) do
      deletion_row(source, issue)
    else
      %{
        source: "jira",
        source_id: source.id,
        source_type: "jira_project",
        lang: nil,
        natural_key: "jira:#{issue.key}",
        content_hash: :crypto.hash(:sha256, issue.text) |> Base.encode16(case: :lower),
        raw_content: issue.text,
        metadata: issue.metadata
      }
    end
  end

  defp deletion_row(source, issue) do
    %{
      source: "jira",
      source_id: source.id,
      source_type: "jira_project",
      natural_key: "jira:#{issue.key}",
      metadata: %{"issue_key" => issue.key},
      status: "deleted"
    }
  end

  defp mark_synced!(state) do
    state
    |> SyncState.changeset(%{status: :idle, last_synced_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  # No new watermark (Jira returned only issues without a resolutiondate) — still
  # refresh last_synced_at so a sync that staged work doesn't read stale.
  defp advance_watermark!(state, nil), do: mark_synced!(state)

  defp advance_watermark!(state, watermark) do
    state
    |> SyncState.changeset(%{
      cursor: Map.put(state.cursor || %{}, "resolutiondate_watermark", watermark),
      status: :idle,
      last_synced_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp get_or_create_sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end
end
