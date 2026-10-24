defmodule Mix.Tasks.Rn.Seed do
  @shortdoc "Seeds a git source (this repo by default) and enqueues its first sync"

  @moduledoc """
  Registers the thin-corpus ingest sources (design-mcp.md Phase 9 Task 1) so the
  four MCP tools have data to answer over, then enqueues each source's first
  `*Sync` job the same way `Ingest.Workers.SyncScheduler`'s cron fan-out does.

  ## Git (always seedable, zero credentials)

  Registers this repository itself via a `file://` mirror of its own `.git` dir
  — no external service required. Override with:

      mix rn.seed --git-url file:///path/to/some/repo.git --repo some-repo

  Git repos, Jira projects and Google Drive are normally declared in
  `sources.toml` and applied with `mix rn.sources`; this task remains for
  ad-hoc git seeding.

  ## Idempotency

  Rerunning is safe: each source is upserted on its `[:source_type, :identifier]`
  unique key (never duplicated), and every `*Sync` worker declares a `unique`
  window keyed on `source_id`, so a re-enqueue inside that window collapses onto
  the existing job instead of piling up.

  ## Status only

      mix rn.seed --status

  Prints registered sources with their chunk/pending-chunk counts and the
  `oban_jobs` state breakdown. Read-only — no sources are created or enqueued.
  """

  use Mix.Task

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @default_repo_name "slow-henry"
  @default_git_url "file:///workspaces/slow-henry/.git"

  @switches [git_url: :string, repo: :string, status: :boolean]

  # run/1 ends in System.halt/1 (boot/0's ensure_all_started boots the full
  # supervision tree, which would otherwise keep the VM alive after seeding
  # finishes), so it genuinely never returns — the spec tells dialyzer that's
  # intentional.
  @spec run([binary()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} = OptionParser.parse(args, strict: @switches)

    boot()

    if opts[:status] do
      print_status()
    else
      seed(opts)
    end

    # boot/0 brings up the *entire* supervision tree (Endpoint, Oban, the
    # embedding Serving/Warmer sub-tree, ...) since Oban.insert/1 needs a
    # running Oban instance to resolve its config — none of which has a
    # reason to keep running once sources are seeded/status is printed.
    # Without an explicit halt, `mix rn.seed` would hang after printing (a
    # script/CI invocation would need to be killed rather than exiting on
    # its own).
    System.halt(0)
  end

  # --- boot ---

  # This task only needs Repo + Oban's insert path — `Oban.insert/1` requires a
  # running Oban instance to resolve its config, but NOT running queues. It
  # deliberately disables local queue/plugin execution and the ~1.2 GB embedding
  # model load: actual ingestion runs on the already-supervised Oban instance
  # (dev server / systemd), never inside this short-lived task process. If this
  # process's own queues raced to claim a job and then the task exited mid
  # `git clone --mirror`, it would leave a corrupt bare mirror behind.
  # Shared with `mix rn.sources`.
  @doc false
  def boot do
    Mix.Task.run("app.config")

    Application.put_env(:retrieval_node, :embedding_serving_start, false)
    # These tasks apply (or deliberately don't apply) sources themselves.
    Application.put_env(:retrieval_node, :sources_watch, false)

    oban_config = Application.get_env(:retrieval_node, Oban, [])

    Application.put_env(
      :retrieval_node,
      Oban,
      Keyword.merge(oban_config, queues: [], plugins: [])
    )

    {:ok, _} = Application.ensure_all_started(:retrieval_node)
  end

  # --- seed ---

  defp seed(opts) do
    seed_git(opts)

    Mix.shell().info("""

    Watch progress:
      PGPORT=5433 psql -h localhost -U postgres -d retrieval_node_dev -c \
    "select state, count(*) from oban_jobs group by state;"
      PGPORT=5433 psql -h localhost -U postgres -d retrieval_node_dev -c \
    "select count(*) from pending_chunks; select count(*) from chunks;"
    or: mix rn.seed --status
    """)
  end

  defp seed_git(opts) do
    name = opts[:repo] || @default_repo_name
    url = opts[:git_url] || @default_git_url

    {:ok, source} = upsert_source(%{source_type: :git_repo, name: name, identifier: url})

    enqueue!(RepoSync, source, "git repo #{inspect(name)} (#{url})")
  end

  # --- Source upsert (idempotent on the [:source_type, :identifier] unique key) ---

  @doc false
  @spec upsert_source(map()) :: {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def upsert_source(attrs) do
    %Source{}
    |> Source.create_changeset(attrs)
    |> Repo.insert(
      conflict_target: [:source_type, :identifier],
      on_conflict: {:replace, [:name, :updated_at]},
      returning: true
    )
  end

  defp enqueue!(worker, source, label) do
    case Oban.insert(worker.new(%{"source_id" => source.id})) do
      {:ok, %{conflict?: true}} ->
        Mix.shell().info(
          "~ #{label}: already registered, sync already queued/running (source_id=#{source.id})"
        )

      {:ok, _job} ->
        Mix.shell().info(
          "+ #{label}: registered, #{inspect(worker)} enqueued (source_id=#{source.id})"
        )

      {:error, reason} ->
        Mix.raise("failed to enqueue #{inspect(worker)} for #{label}: #{inspect(reason)}")
    end
  end

  # --- status (read-only) ---

  defp print_status do
    case Repo.all(from(s in Source, order_by: [asc: s.source_type, asc: s.name])) do
      [] -> Mix.shell().info("No sources registered yet. Run `mix rn.seed` first.")
      sources -> Enum.each(sources, &print_source_status/1)
    end

    print_job_status()
  end

  defp print_source_status(source) do
    chunk_count = Repo.aggregate(from(c in Chunk, where: c.source_id == ^source.id), :count, :id)

    pending_count =
      Repo.aggregate(from(p in PendingChunk, where: p.source_id == ^source.id), :count, :id)

    Mix.shell().info(
      "#{source.source_type} #{source.name} (#{source.identifier}) — " <>
        "active=#{source.active} chunks=#{chunk_count} pending=#{pending_count} " <>
        "last_synced=#{last_synced_at(source)}"
    )
  end

  defp last_synced_at(source) do
    case Repo.get_by(SyncState, source_id: source.id) do
      %{last_synced_at: %DateTime{} = ts} -> DateTime.to_iso8601(ts)
      _ -> "never"
    end
  end

  defp print_job_status do
    counts =
      Oban.Job
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> Repo.all()
      |> Map.new()

    Mix.shell().info("oban_jobs by state: #{inspect(counts)}")
  end
end
