defmodule RetrievalNode.Ingest.Workers.PullRequestSync do
  @moduledoc """
  Indexes the merged pull requests of a git source that has
  `pull_requests = true` in sources.toml (off by default) — and its open ones
  too with `open_pull_requests = true` — through the GitHub App token
  connected on the Settings page (`GitHub.OAuth`).

  Each PR becomes one document of the git source — title, author, state,
  URL, description, then the human comments and reviews — under the virtual
  path `pulls/<number>`, so it shows up next to the repo's files in the UI
  and in search results. Bot and AI comments are left out. The author, the
  human reviewers and the state also go in the metadata (`author`,
  `reviewers`, `state`, `draft`), which `semantic_search` filters on.

  With open PRs on, the search covers every state and each PR is handled by
  its own:

    * merged → indexed;
    * open (drafts included) → indexed, named `PR #<n> [open]: <title>`;
      left out when a bot opened it (dependabot, renovate…: long-lived,
      constantly updated) — its merge is indexed as usual;
    * closed without merge → a deletion entry when it is indexed (an
      abandoned PR indexed while open).

  An open PR that gets merged keeps its path, so its document is replaced.

  The watermark is the last `updatedAt` seen (`cursor["prs_updated_since"]`):
  the GitHub search is sorted by update, oldest first, so a PR edited or
  commented later is picked up again and re-staged (unchanged content is
  skipped by the owner); `SourcesFile` clears it when open PRs are turned
  on, since those not updated since it would be missed. At most
  `@max_per_run` PRs are staged per run; a larger backlog snoozes and
  continues from the watermark, so a big repo never holds the job. Like the other
  sync workers it only stages rows; `SourceOwner` applies them.

  Turning the options off is handled here too, from the source's config when
  the job runs: with `pull_requests` off, every PR document of the source is
  staged for deletion and the watermark cleared (so turning it back on
  re-reads everything), without calling GitHub; with `open_pull_requests`
  off, each run stages the deletion of the open PRs still indexed.
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
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @max_per_run 300
  @continue_in_s 5
  @epoch "1970-01-01T00:00:00Z"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    config = source.config || %{}

    with :ok <- syncable(source) do
      if config["pull_requests"] == true,
        do: sync(source, config["open_pull_requests"] == true),
        else: purge_all(source)
    end
  end

  defp sync(source, open?) do
    with {:ok, repo} <- github_repo(source) do
      state = get_or_create_sync_state(source.id)
      unless open?, do: purge_open(source)
      since = Map.get(state.cursor || %{}, "prs_updated_since", @epoch)
      sync(source, repo, open?, state, since, nil, 0)
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

  defp sync(source, repo, open?, state, since, cursor, done) do
    case GitHub.prs_page(repo, since, cursor, open: open?) do
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
            sync(source, repo, open?, state, since, next, done)
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
    newest = prs |> Enum.map(& &1.updated_at) |> Enum.max()

    {:ok, state} =
      Repo.transaction(
        fn ->
          rows = rows(source, prs)
          if rows != [], do: {:ok, _ids} = PendingChunks.insert_raw_all(rows)

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

  # Closed-without-merge PRs are only deleted when they are indexed (or
  # staged): most were never open while the option was on.
  defp rows(source, prs) do
    {closed, kept} = Enum.split_with(prs, &(&1.state == :closed))
    indexed = indexed_paths(source, Enum.map(closed, &path/1))

    deletions =
      for pr <- closed, path(pr) in indexed, do: deletion_row(source, path(pr))

    contents = for pr <- kept, not (pr.state == :open and pr.bot_author), do: row(source, pr)
    deletions ++ contents
  end

  defp path(pr), do: "pulls/#{pr.number}"

  defp row(source, pr) do
    path = path(pr)
    people = %{"author" => pr.author, "reviewers" => pr.reviewers}
    open = if pr.state == :open, do: " [open]", else: ""

    %{
      source: "git",
      source_id: source.id,
      source_type: "git_repo",
      repo: Source.mirror_slug(source),
      lang: "markdown",
      natural_key: "repo:#{source.id}:#{path}",
      # Covers the people and the state too: an approval with no comment
      # changes `reviewers` but not the text, and PRs indexed before states
      # existed get theirs; the owner skips a row whose hash is unchanged.
      content_hash:
        :crypto.hash(:sha256, [pr.text, Jason.encode!(people), Atom.to_string(pr.state)])
        |> Base.encode16(case: :lower),
      raw_content: pr.text,
      metadata:
        people
        |> Map.merge(%{
          "path" => path,
          "name" => "PR ##{pr.number}#{open}: #{pr.title}",
          "pr" => pr.number,
          "url" => pr.url,
          "state" => Atom.to_string(pr.state),
          "merged_at" => pr.merged_at,
          "draft" => if(pr.draft, do: true)
        })
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp deletion_row(source, path) do
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

  # --- turning the options off ---

  # `pull_requests` off: every PR document goes, and the watermark with it.
  defp purge_all(source) do
    {:ok, _} =
      Repo.transaction(fn ->
        stage_deletions!(source, pr_paths(source, nil))

        from(s in SyncState,
          where: s.source_id == ^source.id,
          update: [set: [cursor: fragment("? - 'prs_updated_since'", s.cursor)]]
        )
        |> Repo.update_all([])
      end)

    SourceOwner.notify(source.id)
    :ok
  end

  # `open_pull_requests` off: the open PRs still indexed go.
  defp purge_open(source) do
    case pr_paths(source, "open") do
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

  # The PR paths of `source` that are indexed or staged — only those in
  # `state` when given ("open"; merged PRs indexed before states existed
  # have none).
  defp pr_paths(source, state) do
    pr_paths_query(Chunk, source, state)
    |> union(^pr_paths_query(PendingChunk, source, state, raw: true))
    |> Repo.all()
  end

  defp pr_paths_query(schema, source, state, opts \\ []) do
    query =
      from r in schema,
        where: r.source_id == ^source.id and fragment("? \\? 'pr'", r.metadata),
        select: fragment("?->>'path'", r.metadata)

    query = if opts[:raw], do: where(query, [r], r.status == "raw"), else: query

    if state,
      do: where(query, [r], fragment("?->>'state'", r.metadata) == ^state),
      else: query
  end

  defp indexed_paths(_source, []), do: []

  defp indexed_paths(source, paths) do
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
