defmodule RetrievalNode.Ingest.Workers.PullRequestSync do
  @moduledoc """
  Indexes the merged pull requests of a git source that has
  `pull_requests = true` in sources.toml (off by default), through the
  GitHub App token connected on the Settings page (`GitHub.OAuth`).

  Each merged PR becomes one document of the git source — title, author,
  merge date, URL, description, then the human comments and reviews — under
  the virtual path `pulls/<number>`, so it shows up next to the repo's files
  in the UI and in search results. Bot and AI comments are left out. The
  author and the human reviewers also go in the metadata (`author`,
  `reviewers`), which `semantic_search` filters on.

  The watermark is the last `updatedAt` seen (`cursor["prs_updated_since"]`):
  the GitHub search is sorted by update, oldest first, so a PR edited or
  commented after merge is picked up again and re-staged (unchanged content
  is skipped by the owner). At most `@max_per_run` PRs are staged per run; a
  larger backlog snoozes and continues, so a big repo never holds the job.
  Like the other sync workers it only stages rows; `SourceOwner` applies them.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  import Ecto.Query

  alias RetrievalNode.Ingest.{GitHub, PendingChunks, SourceOwner}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

  @max_per_run 300
  @continue_in_s 5
  @epoch "1970-01-01T00:00:00Z"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)

    with :ok <- syncable(source),
         {:ok, repo} <- github_repo(source) do
      state = get_or_create_sync_state(source_id)
      since = Map.get(state.cursor || %{}, "prs_updated_since", @epoch)
      sync(source, repo, state, since, nil, 0)
    end
  end

  # Like the other sync workers: a job queued before the source was
  # deactivated or denied (or a retry) is a no-op.
  defp syncable(source),
    do: if(Source.syncable?(source), do: :ok, else: {:cancel, :ineligible})

  defp github_repo(source) do
    case GitHub.repo_from_url(source.identifier) do
      {:ok, repo} -> {:ok, repo}
      # Not on GitHub: nothing to do, and retrying wouldn't change that.
      :error -> {:cancel, :not_a_github_repo}
    end
  end

  defp sync(source, repo, state, since, cursor, done) do
    case GitHub.merged_prs_page(repo, since, cursor) do
      {:ok, prs, next} ->
        state = stage!(source, state, prs)
        done = done + length(prs)

        cond do
          next == nil ->
            mark_synced!(state)
            :ok

          done >= @max_per_run ->
            {:snooze, @continue_in_s}

          true ->
            sync(source, repo, state, since, next, done)
        end

      # Not connected: nothing a retry fixes; the next hourly run tries again.
      {:error, :github_not_authorized} ->
        {:cancel, :github_not_authorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stage one page and move the watermark to its newest update, in one
  # transaction, so a crash never skips PRs.
  defp stage!(_source, state, []), do: state

  defp stage!(source, state, prs) do
    rows = Enum.map(prs, &row(source, &1))
    newest = prs |> Enum.map(& &1.updated_at) |> Enum.max()

    {:ok, state} =
      Repo.transaction(
        fn ->
          {:ok, _ids} = PendingChunks.insert_raw_all(rows)

          # RepoSync shares this sync_states row (last_sha) and can run at the
          # same time: touch only our key instead of rewriting the cursor.
          {1, [state]} =
            Repo.update_all(
              from(s in SyncState,
                where: s.id == ^state.id,
                select: s,
                update: [
                  set: [
                    cursor:
                      fragment(
                        "jsonb_set(coalesce(?, '{}'::jsonb), '{prs_updated_since}', to_jsonb(?::text))",
                        s.cursor,
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

  defp row(source, pr) do
    path = "pulls/#{pr.number}"
    people = %{"author" => pr.author, "reviewers" => pr.reviewers}

    %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: Source.mirror_slug(source),
      lang: "markdown",
      natural_key: "repo:#{source.id}:#{path}",
      # Covers the people too: an approval with no comment changes `reviewers`
      # but not the text, and the owner skips a row whose hash is unchanged.
      content_hash:
        :crypto.hash(:sha256, [pr.text, Jason.encode!(people)]) |> Base.encode16(case: :lower),
      raw_content: pr.text,
      metadata:
        Map.merge(people, %{
          "path" => path,
          "name" => "PR ##{pr.number}: #{pr.title}",
          "pr" => pr.number,
          "url" => pr.url,
          "merged_at" => pr.merged_at
        })
    }
  end

  defp mark_synced!(state) do
    state |> SyncState.changeset(%{last_synced_at: DateTime.utc_now()}) |> Repo.update!()
  end

  defp get_or_create_sync_state(source_id) do
    case Repo.get_by(SyncState, source_id: source_id) do
      nil -> Repo.insert!(%SyncState{source_id: source_id, cursor: %{}, status: :idle})
      state -> state
    end
  end
end
