defmodule RetrievalNode.Ingest.Workers.DriveSync do
  @moduledoc """
  Discovery job for the Google Drive source. Same shape as `RepoSync`: it only
  stages `pending_chunks` rows (content or deletion, `natural_key:
  "drive:<doc_id>"`) and advances its cursor; `Ingest.SourceOwner` applies them.

  What is indexed is decided by `Ingest.DrivePolicy` from the source config
  (written by `RetrievalNode.SourcesFile` from `[drive]` in sources.toml):

      %{"my_drive" => true, "shared_with_me" => true, "include" => ["<drive or folder id>", ...]}

  Two modes:

    * **full** — lists every in-scope Google Doc, exports the ones not indexed
      yet or modified since, and stages deletions for indexed docs that are no
      longer in scope or allowed (moved out, deleted, re-classified). Runs
      until the first backfill is complete, then daily (`"mode" => "full"`
      from the cron) to catch what the changes feed cannot express, like a
      folder moved out of scope. At most `@max_exports` docs are exported per
      run; when more remain the job snoozes briefly and continues, so a large
      backfill never holds one job for long.
    * **changes** — pages the Drive changes feed since the stored cursor and
      re-evaluates each touched file: export when indexable and newer, delete
      when it was indexed and no longer is.

  Fail closed: if the Classification label can't be read, nothing is staged.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      # Sole active sync per source for its whole lifetime (see RepoSync).
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  require Logger

  alias RetrievalNode.Chunking
  alias RetrievalNode.Ingest.{Drive, DrivePolicy, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @max_exports 200
  @stage_batch 50
  @continue_in_s 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id} = args}) do
    source = Repo.get!(Source, source_id)
    state = get_or_create_sync_state(source_id)

    with {:ok, classification} <- Drive.classification_label(),
         {:ok, scope} <- resolve_scope(source.config || %{}) do
      if full?(args, state),
        do: full(source, state, classification, scope),
        else: changes(source, state, classification, scope)
    end
  catch
    # Raised from the memoized parent lookup: abort rather than guess scope.
    {:drive_lookup, {:snooze, seconds}} -> {:snooze, seconds}
    {:drive_lookup, {:error, reason}} -> {:error, {:parent_lookup, reason}}
  end

  defp full?(args, state) do
    args["mode"] == "full" or state.cursor["start_page_token"] == nil or
      state.cursor["backfill_done"] != true
  end

  # --- full ---

  defp full(source, state, classification, scope) do
    with {:ok, state} <- ensure_cursor(state),
         {:ok, files} <- scope_docs(scope, classification.label_id) do
      allowed =
        files
        |> Enum.filter(
          &(DrivePolicy.doc?(&1) and DrivePolicy.classification_allowed?(&1, classification))
        )
        |> Enum.uniq_by(& &1["id"])

      indexed = indexed_docs(source.id)
      allowed_ids = MapSet.new(allowed, & &1["id"])
      stale = Enum.filter(allowed, &stale?(&1, indexed))
      gone = indexed |> Map.keys() |> Enum.reject(&MapSet.member?(allowed_ids, &1))
      {now, later} = Enum.split(stale, @max_exports)

      case stage(source, now, gone) do
        :ok when later == [] ->
          finish!(state, %{"backfill_done" => true})
          :ok

        :ok ->
          SourceOwner.notify(source.id)
          {:snooze, @continue_in_s}

        other ->
          other
      end
    end
  end

  # Take the changes cursor *before* listing, so anything edited during a long
  # backfill is picked up by the next changes run.
  defp ensure_cursor(%{cursor: %{"start_page_token" => token}} = state) when is_binary(token),
    do: {:ok, state}

  defp ensure_cursor(state) do
    with {:ok, token} <- Drive.start_page_token() do
      {:ok, update_cursor!(state, %{"start_page_token" => token}, false)}
    end
  end

  defp scope_docs(scope, label_id) do
    listings =
      [
        if(scope.my_drive, do: fn -> Drive.my_drive_docs(label_id) end),
        if(scope.shared_with_me, do: fn -> Drive.shared_with_me_docs(label_id) end)
      ] ++
        Enum.map(scope.drives, fn id -> fn -> Drive.shared_drive_docs(id, label_id) end end) ++
        Enum.map(scope.folders, fn id ->
          fn -> folder_docs([id], label_id, %{}, []) end
        end)

    listings
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, []}, fn list, {:ok, acc} ->
      case list.() do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        other -> {:halt, other}
      end
    end)
  end

  # Breadth-first walk of a folder tree; `seen` guards against shortcut loops.
  # `seen` is a plain map (id => true): a MapSet seeded with MapSet.new() trips
  # Dialyzer's opaque-type checks on OTP 29.
  defp folder_docs([], _label_id, _seen, acc), do: {:ok, acc}

  defp folder_docs([id | rest], label_id, seen, acc) do
    if Map.has_key?(seen, id) do
      folder_docs(rest, label_id, seen, acc)
    else
      with {:ok, children} <- Drive.folder_children(id, label_id) do
        {folders, docs} = Enum.split_with(children, &(&1["mimeType"] == Drive.folder_mime()))

        folder_docs(
          rest ++ Enum.map(folders, & &1["id"]),
          label_id,
          Map.put(seen, id, true),
          acc ++ docs
        )
      end
    end
  end

  # --- changes ---

  defp changes(source, state, classification, scope) do
    with {:ok, %{changes: changes, cursor: new_cursor}} <-
           Drive.changes(state.cursor["start_page_token"], classification.label_id) do
      indexed = indexed_docs(source.id)
      parents_of = memoized_parents()

      # The feed can list a file several times; only its latest state matters.
      latest = changes |> Enum.reverse() |> Enum.uniq_by(& &1.file_id)

      decide = &decide(&1, indexed, scope, classification, parents_of)
      decisions = Enum.map(latest, decide)
      export = for {:export, file} <- decisions, do: file
      delete = for {:delete, id} <- decisions, do: id

      case stage(source, export, delete) do
        :ok ->
          finish!(state, %{"start_page_token" => new_cursor})
          :ok

        other ->
          other
      end
    end
  end

  # Export when indexable and newer than what is indexed; delete when it was
  # indexed and no longer is (removed, trashed, moved out, re-classified).
  defp decide(change, indexed, scope, classification, parents_of) do
    cond do
      not change.removed and
          DrivePolicy.indexable?(change.file, scope, classification, parents_of) ->
        if stale?(change.file, indexed), do: {:export, change.file}, else: :skip

      Map.has_key?(indexed, change.file_id) ->
        {:delete, change.file_id}

      true ->
        :skip
    end
  end

  defp memoized_parents do
    fn id ->
      key = {__MODULE__, :parents, id}

      case Process.get(key) do
        nil ->
          parents = fetch_parents(id)
          Process.put(key, parents)
          parents

        parents ->
          parents
      end
    end
  end

  defp fetch_parents(id) do
    case Drive.get_file(id, "id,parents") do
      {:ok, file} -> file["parents"] || []
      # A folder we can't see can't be the in-scope ancestor.
      {:error, :not_found} -> []
      other -> throw({:drive_lookup, other})
    end
  end

  # --- staging ---

  # Deletions first, then exports in batches so a long run commits (and the
  # owner starts indexing) as it goes. Export failures stage the successes but
  # return an error, so the cursor isn't advanced past a doc that failed.
  defp stage(source, files, deleted_ids) do
    if deleted_ids != [], do: insert!(source, Enum.map(deleted_ids, &deletion_row(source, &1)))

    files
    |> Enum.chunk_every(@stage_batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      results = Enum.map(batch, &export_row(source, &1))
      rows = for {:ok, row} <- results, do: row
      if rows != [], do: insert!(source, rows)

      case Enum.find(results, &(not match?({:ok, _}, &1) and &1 != :skip)) do
        nil -> {:cont, :ok}
        {:snooze, seconds} -> {:halt, {:snooze, seconds}}
        {:error, _} -> {:halt, {:error, :export_incomplete}}
      end
    end)
  end

  defp insert!(source, rows) do
    {:ok, _} =
      Repo.transaction(fn -> {:ok, _ids} = PendingChunks.insert_raw_all(rows) end,
        timeout: PendingChunks.insert_timeout()
      )

    SourceOwner.notify(source.id)
  end

  defp export_row(source, file) do
    case Drive.export_doc(file["id"]) do
      {:ok, markdown} ->
        text = Drive.strip_images(markdown)

        if Chunking.binary_content?(text) do
          {:ok, deletion_row(source, file["id"])}
        else
          {:ok,
           %{
             source: "drive",
             source_id: source.id,
             source_type: "drive_folder",
             lang: nil,
             natural_key: "drive:#{file["id"]}",
             content_hash: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
             raw_content: text,
             metadata: %{
               "doc_id" => file["id"],
               "name" => file["name"],
               "modified_time" => file["modifiedTime"],
               "url" => file["webViewLink"]
             }
           }}
        end

      # A doc deleted between listing and export: reconcile it away.
      {:error, :not_found} ->
        {:ok, deletion_row(source, file["id"])}

      # A 4xx on one doc (e.g. 403 exportSizeLimitExceeded) won't fix itself on
      # retry: skip that doc instead of failing — and endlessly retrying — the
      # whole run. The daily full pass tries it again.
      {:error, {:drive_http, status, _body} = reason} when status in 400..499 ->
        log_export_failure(file, reason, "skipped")
        :skip

      {:error, reason} = error ->
        log_export_failure(file, reason, "will retry")
        error

      other ->
        other
    end
  end

  # Doc id and title only, never content.
  defp log_export_failure(file, reason, outcome) do
    Logger.warning(
      "Drive export failed (#{outcome}): doc_id=#{file["id"]} name=#{inspect(file["name"])} " <>
        "reason=#{inspect(reason, limit: 5, printable_limit: 200)}"
    )
  end

  defp deletion_row(source, doc_id) do
    %{
      source: "drive",
      source_id: source.id,
      source_type: "drive_folder",
      natural_key: "drive:#{doc_id}",
      metadata: %{"doc_id" => doc_id},
      status: "deleted"
    }
  end

  # --- index state ---

  # doc_id => latest indexed (or staged) modifiedTime; nil when unknown.
  defp indexed_docs(source_id) do
    chunks =
      from c in Chunk,
        where: c.source_id == ^source_id and not is_nil(fragment("?->>'doc_id'", c.metadata)),
        group_by: fragment("?->>'doc_id'", c.metadata),
        select:
          {fragment("?->>'doc_id'", c.metadata), max(fragment("?->>'modified_time'", c.metadata))}

    staged =
      from p in PendingChunk,
        where: p.source_id == ^source_id and p.status == "raw",
        group_by: fragment("?->>'doc_id'", p.metadata),
        select:
          {fragment("?->>'doc_id'", p.metadata), max(fragment("?->>'modified_time'", p.metadata))}

    Map.merge(Map.new(Repo.all(chunks)), Map.new(Repo.all(staged)), fn _id, a, b ->
      max_time(a, b)
    end)
  end

  defp max_time(nil, b), do: b
  defp max_time(a, nil), do: a
  defp max_time(a, b), do: max(a, b)

  # RFC 3339 UTC timestamps from Drive compare correctly as strings.
  defp stale?(file, indexed) do
    case Map.fetch(indexed, file["id"]) do
      :error -> true
      {:ok, nil} -> true
      {:ok, at} -> is_binary(file["modifiedTime"]) and file["modifiedTime"] > at
    end
  end

  # --- scope ---

  defp resolve_scope(config) do
    config
    |> Map.get("include", [])
    |> Enum.reduce_while(
      {:ok,
       %{
         my_drive: Map.get(config, "my_drive", true),
         shared_with_me: Map.get(config, "shared_with_me", false),
         drives: MapSet.new(),
         folders: MapSet.new()
       }},
      fn id, {:ok, scope} ->
        case include_kind(id) do
          {:ok, :drive} -> {:cont, {:ok, %{scope | drives: MapSet.put(scope.drives, id)}}}
          {:ok, :folder} -> {:cont, {:ok, %{scope | folders: MapSet.put(scope.folders, id)}}}
          other -> {:halt, other}
        end
      end
    )
  end

  defp include_kind(id) do
    case Drive.get_drive(id) do
      {:ok, _drive} ->
        {:ok, :drive}

      {:error, :not_found} ->
        folder_kind(id)

      other ->
        other
    end
  end

  defp folder_kind(id) do
    case Drive.get_file(id, "id,mimeType") do
      {:ok, %{"mimeType" => mime}} ->
        if mime == Drive.folder_mime(),
          do: {:ok, :folder},
          else: {:error, {:include_not_a_folder, id}}

      {:error, :not_found} ->
        {:error, {:include_not_found, id}}

      other ->
        other
    end
  end

  # --- sync state ---

  defp finish!(state, cursor_changes), do: update_cursor!(state, cursor_changes, true)

  defp update_cursor!(state, cursor_changes, synced?) do
    attrs = %{cursor: Map.merge(state.cursor || %{}, cursor_changes), status: :idle}
    attrs = if synced?, do: Map.put(attrs, :last_synced_at, DateTime.utc_now()), else: attrs

    state |> SyncState.changeset(attrs) |> Repo.update!()
  end

  defp get_or_create_sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end
end
