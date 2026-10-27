defmodule RetrievalNode.Ingest.GitHubDocs do
  @moduledoc """
  What `PullRequestSync` and `IssueSync` share: the documents they add to a
  git source under virtual paths (`pulls/<n>`, `issues/<n>`), each marked
  by a metadata key holding its number (`kind`: "pr", "issue").

  Both walk a GitHub search sorted by update, oldest first, and keep the
  last `updatedAt` seen as a watermark under their own key of the source's
  `sync_states` cursor (`watermark`: "prs_updated_since",
  "issues_updated_since"), which `RepoSync` shares (`last_sha`) — so each
  only ever touches its own key. A run stages at most `@max_per_run` items,
  then snoozes and resumes from the watermark. They only stage rows;
  `SourceOwner` applies them.
  """

  import Ecto.Query

  alias RetrievalNode.Ingest.{GitHub, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @max_per_run 300
  @continue_in_s 5
  @epoch "1970-01-01T00:00:00Z"

  @doc """
  The job's source, unless it was deactivated or denied since it was queued
  (a no-op, like the other sync workers), and its `owner/name` on GitHub.
  """
  def repo(source) do
    if Source.syncable?(source) do
      case GitHub.repo_from_url(source.identifier) do
        {:ok, repo} -> {:ok, repo}
        # Not on GitHub: nothing to do, and retrying wouldn't change that.
        :error -> {:cancel, :not_a_github_repo}
      end
    else
      {:cancel, :ineligible}
    end
  end

  @doc "The source's sync state, created when missing."
  def sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end

  @doc """
  Where the search starts: the `watermark` of `state`, or the `max_age`
  cutoff when that is later (whatever is in the window was updated after
  it).
  """
  def since(state, watermark, cutoff) do
    [Map.get(state.cursor || %{}, watermark, @epoch), cutoff]
    |> Enum.reject(&is_nil/1)
    |> Enum.max()
  end

  @doc """
  Walks the search: `fetch.(cursor)` returns `{:ok, items, next_cursor |
  nil}`, `stage.(state, items)` stages a page and returns the new state.
  Snoozes once `@max_per_run` items are staged and more remain.
  """
  def walk(fetch, stage, state, cursor \\ nil, done \\ 0) do
    case fetch.(cursor) do
      {:ok, items, next} ->
        state = stage.(state, items)
        done = done + length(items)

        cond do
          next == nil ->
            state |> SyncState.changeset(%{last_synced_at: DateTime.utc_now()}) |> Repo.update!()
            :ok

          done >= @max_per_run ->
            {:snooze, @continue_in_s}

          true ->
            walk(fetch, stage, state, next, done)
        end

      # Not connected: nothing a retry fixes; the next hourly run tries again.
      {:error, :github_not_authorized} ->
        {:cancel, :github_not_authorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stages `rows` and moves `watermark` to `newest`, in one transaction, so a
  crash never skips items.
  """
  def stage!(source, state, rows, watermark, newest) do
    {:ok, state} =
      Repo.transaction(
        fn ->
          if rows != [], do: {:ok, _ids} = PendingChunks.insert_raw_all(rows)

          {1, [state]} =
            Repo.update_all(
              from(s in SyncState,
                where: s.id == ^state.id,
                select: s,
                update: [
                  set: [
                    cursor:
                      fragment(
                        "jsonb_set(coalesce(?, '{}'::jsonb), ARRAY[?::text], to_jsonb(?::text))",
                        s.cursor,
                        ^watermark,
                        ^newest
                      )
                  ]
                ]
              ),
              []
            )

          state
        end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
    state
  end

  @doc """
  A content row for the document at `path`. `hash_parts` cover everything
  the owner should re-apply the document for (an unchanged hash is
  skipped); nil metadata values are dropped.
  """
  def row(source, path, text, hash_parts, metadata) do
    %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: Source.mirror_slug(source),
      lang: "markdown",
      natural_key: "repo:#{source.id}:#{path}",
      content_hash: :crypto.hash(:sha256, hash_parts) |> Base.encode16(case: :lower),
      raw_content: text,
      metadata:
        metadata
        |> Map.put("path", path)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  @doc "A deletion row for the document at `path`."
  def deletion_row(source, path) do
    %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: Source.mirror_slug(source),
      natural_key: "repo:#{source.id}:#{path}",
      metadata: %{"path" => path},
      status: "deleted"
    }
  end

  @doc """
  The option is off: every `kind` document of the source goes, and the
  watermark with it (turning it back on re-reads everything). No GitHub
  call.
  """
  def purge_all(source, kind, watermark) do
    {:ok, _} =
      Repo.transaction(fn ->
        stage_deletions!(source, paths(source, kind, []))

        from(s in SyncState,
          where: s.source_id == ^source.id,
          update: [set: [cursor: fragment("? - ?::text", s.cursor, ^watermark)]]
        )
        |> Repo.update_all([])
      end)

    SourceOwner.notify(source.id)
    :ok
  end

  @doc "Stages the deletion of the `kind` documents matching `filters` (see `paths/3`)."
  def purge(source, kind, filters) do
    case paths(source, kind, filters) do
      [] ->
        :ok

      paths ->
        {:ok, _} = Repo.transaction(fn -> stage_deletions!(source, paths) end)
        SourceOwner.notify(source.id)
    end
  end

  defp stage_deletions!(_source, []), do: :ok

  defp stage_deletions!(source, paths) do
    {:ok, _ids} = PendingChunks.insert_raw_all(Enum.map(paths, &deletion_row(source, &1)))
  end

  @doc """
  The paths of the source's `kind` documents that are indexed or staged —
  only those in `state:` when given (merged PRs indexed before states
  existed have none), marked `bot` with `bot: true`, and out of the
  `max_age` window with `older_than: {cutoff, done_field}`: open and not
  updated since the cutoff, or else done (`done_field`: "merged_at",
  "closed_at") before it. An open one indexed before it carried
  `updated_at` counts as out: setting `max_age` re-reads the history, so
  one still active is staged again, with its date, after this deletion
  (rows apply in arrival order).
  """
  def paths(source, kind, filters) do
    paths_query(Chunk, source, kind, filters)
    |> union(^paths_query(PendingChunk, source, kind, [{:raw, true} | filters]))
    |> Repo.all()
  end

  defp paths_query(schema, source, kind, filters) do
    query =
      from r in schema,
        where: r.source_id == ^source.id and fragment("? \\? ?::text", r.metadata, ^kind),
        select: fragment("?->>'path'", r.metadata)

    Enum.reduce(filters, query, fn
      {:raw, true}, query -> where(query, [r], r.status == "raw")
      {:state, state}, query -> where(query, [r], fragment("?->>'state'", r.metadata) == ^state)
      {:bot, true}, query -> where(query, [r], fragment("(?->>'bot')::boolean", r.metadata))
      {:older_than, window}, query -> where(query, [r], ^older_than(window))
    end)
  end

  defp older_than({cutoff, done_field}) do
    dynamic(
      [r],
      fragment(
        "CASE WHEN ?->>'state' = 'open' THEN coalesce(?->>'updated_at', '') < ? ELSE ?->>?::text < ? END",
        r.metadata,
        r.metadata,
        ^cutoff,
        r.metadata,
        ^done_field,
        ^cutoff
      )
    )
  end

  @doc "Stages `rows` (no watermark: for a sync that lists everything each run)."
  def stage_rows!(_source, []), do: :ok

  def stage_rows!(source, rows) do
    {:ok, _} =
      Repo.transaction(fn -> {:ok, _ids} = PendingChunks.insert_raw_all(rows) end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
  end

  @doc """
  The source's documents under `prefix` (`"releases/"`), as `%{path =>
  metadata[field]}`: the indexed ones, then the rows staged since applied in
  order (a staged deletion removes its path). A chunk whose `file_hash` was
  cleared (`Rechunk`) counts with a nil value, so it is staged again.
  """
  def indexed_values(source, prefix, field) do
    pattern = prefix <> "%"

    chunks =
      from c in Chunk,
        where: c.source_id == ^source.id and fragment("?->>'path' LIKE ?", c.metadata, ^pattern),
        distinct: fragment("?->>'path'", c.metadata),
        select:
          {fragment("?->>'path'", c.metadata),
           fragment(
             "CASE WHEN ? IS NOT NULL THEN ?->>?::text END",
             c.file_hash,
             c.metadata,
             ^field
           )}

    staged =
      from p in PendingChunk,
        where:
          p.source_id == ^source.id and p.status in ["raw", "deleted"] and
            fragment("?->>'path' LIKE ?", p.metadata, ^pattern),
        order_by: p.id,
        select:
          {p.status, fragment("?->>'path'", p.metadata),
           fragment("?->>?::text", p.metadata, ^field)}

    Enum.reduce(Repo.all(staged), Map.new(Repo.all(chunks)), fn
      {"raw", path, value}, acc -> Map.put(acc, path, value)
      {"deleted", path, _value}, acc -> Map.delete(acc, path)
    end)
  end

  @doc "Which of `paths` are indexed or staged for the source."
  def indexed_paths(_source, []), do: []

  def indexed_paths(source, paths) do
    chunks =
      from c in Chunk,
        where: c.source_id == ^source.id and fragment("?->>'path'", c.metadata) in ^paths,
        select: fragment("?->>'path'", c.metadata)

    staged =
      from p in PendingChunk,
        where:
          p.source_id == ^source.id and p.status == "raw" and
            fragment("?->>'path'", p.metadata) in ^paths,
        select: fragment("?->>'path'", p.metadata)

    chunks |> union(^staged) |> Repo.all()
  end
end
