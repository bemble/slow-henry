defmodule RetrievalNode.Ingest.Rechunk do
  @moduledoc """
  Re-chunks everything that isn't tree-sitter code — PRs, GitHub issues and
  releases, Drive docs, Jira issues, and the repo files without a
  tree-sitter grammar — after a chunker change, by re-staging it from its
  origin.

  The raw files are unchanged, so `FileIngest` would skip them on their
  `file_hash`; `run/0` clears it on those chunks first, then:

    * drops `modified_time` from Drive chunks, so a full pass re-exports
      every doc instead of only the newer ones;
    * drops the PR and issue watermarks (`prs_updated_since`,
      `issues_updated_since`), so their syncs re-read everything;
    * enqueues a full `RepoSync` (`"full" => true`: every file re-staged with
      `force`), `DriveSync` and `JiraSync` (`"mode" => "full"`) per syncable
      source, and a `PullRequestSync` (`IssueSync`, `ReleaseSync`) per git
      source with `pull_requests = true` (`issues = true`, `releases =
      true`) — releases have no watermark: their cleared `file_hash` is
      what makes `ReleaseSync` stage them again.

  Code files re-staged by the full repo pass still skip on their hash, and an
  unchanged chunk keeps its embedding (`FileIngest`'s reuse), so the cost is
  re-embedding the chunks that actually changed.

  Each sync worker is unique per source, so like
  `Ingest.force_full_resync_git_sources/0` a job still waiting
  (`available`/`scheduled`/`retryable`) has its args replaced with the full
  ones (`:upgraded`), while one already executing can't be: its source comes
  back in `:busy` — run it again once that job is done.
  """

  import Ecto.Query

  alias RetrievalNode.Chunking.TreeSitterImpl

  alias RetrievalNode.Ingest.Workers.{
    DriveSync,
    IssueSync,
    JiraSync,
    PullRequestSync,
    ReleaseSync,
    RepoSync
  }

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source, SyncState}

  @type summary :: %{
          chunks_reset: non_neg_integer(),
          enqueued: non_neg_integer(),
          upgraded: non_neg_integer(),
          busy: [String.t()]
        }

  @waiting_states ~w(available scheduled retryable)
  @waiting_state_atoms [:available, :scheduled, :retryable]

  @spec run() :: {:ok, summary()} | {:error, term()}
  def run do
    with {:ok, chunks_reset} <- reset_index_state(),
         {:ok, jobs} <- enqueue_syncs() do
      {:ok, Map.put(jobs, :chunks_reset, chunks_reset)}
    end
  end

  # Rewrites every non-code chunk row (and so its embedding index entries):
  # tens of seconds on a large corpus, so no statement timeout.
  defp reset_index_state do
    Repo.transaction(
      fn ->
        code = TreeSitterImpl.allowed_languages()

        {chunks_reset, _} =
          from(c in Chunk, where: is_nil(c.lang) or c.lang not in ^code)
          |> Repo.update_all([set: [file_hash: nil]], timeout: :infinity)

        from(c in Chunk,
          where: c.source_type == :drive_folder,
          update: [set: [metadata: fragment("? - 'modified_time'", c.metadata)]]
        )
        |> Repo.update_all([], timeout: :infinity)

        from(s in SyncState,
          where: fragment("? \\?| array['prs_updated_since', 'issues_updated_since']", s.cursor),
          update: [
            set: [
              cursor: fragment("? - array['prs_updated_since', 'issues_updated_since']", s.cursor)
            ]
          ]
        )
        |> Repo.update_all([])

        chunks_reset
      end,
      timeout: :infinity
    )
  end

  defp enqueue_syncs do
    jobs =
      for source <- syncable_sources(),
          {worker, args} <- workers(source) do
        job =
          worker.new(Map.put(args, "source_id", source.id),
            replace: Enum.map(@waiting_state_atoms, &{&1, [:args]})
          )

        {source, job}
      end

    jobs
    |> Enum.reduce_while({:ok, %{enqueued: 0, upgraded: 0, busy: []}}, fn {source, job},
                                                                          {:ok, acc} ->
      case Oban.insert(job) do
        {:ok, %Oban.Job{conflict?: false}} ->
          {:cont, {:ok, Map.update!(acc, :enqueued, &(&1 + 1))}}

        {:ok, %Oban.Job{state: state}} when state in @waiting_states ->
          {:cont, {:ok, Map.update!(acc, :upgraded, &(&1 + 1))}}

        {:ok, %Oban.Job{}} ->
          {:cont, {:ok, Map.update!(acc, :busy, &(&1 ++ [source.name]))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp syncable_sources do
    Repo.all(from s in Source, where: s.active == true and s.policy == :allow, order_by: s.name)
  end

  @full %{"mode" => "full"}

  defp workers(%Source{source_type: :git_repo, config: config}) do
    config = config || %{}

    [
      {RepoSync, %{"full" => true}},
      config["pull_requests"] == true && {PullRequestSync, %{}},
      config["issues"] == true && {IssueSync, %{}},
      config["releases"] == true && {ReleaseSync, %{}}
    ]
    |> Enum.filter(& &1)
  end

  defp workers(%Source{source_type: :drive_folder}), do: [{DriveSync, @full}]
  defp workers(%Source{source_type: :jira_project}), do: [{JiraSync, @full}]
end
