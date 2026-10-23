defmodule Mix.Tasks.Rn.Reembed do
  @shortdoc "Recomputes every chunk's embedding with the configured backend"

  @moduledoc """
  Re-embeds the stored chunks (see `RetrievalNode.Embedding.Reembed`) — run it
  after switching the embedding backend, model or prefixes, e.g. after
  setting `OLLAMA_ENDPOINT`. It can run while the server is up: a chunk the
  server rewrites meanwhile keeps the server's (current) vector.

      mix rn.reembed                    # chunks not on the current setup yet
      mix rn.reembed --all              # every chunk
      mix rn.reembed --source naboo     # one source

  Only stale chunks are redone by default, so re-running it resumes an
  interrupted run.
  """

  use Mix.Task

  alias RetrievalNode.Embedding
  alias RetrievalNode.Embedding.{NxServingImpl, Reembed}

  @switches [source: :string, after: :string, batch: :integer, all: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.config")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = RetrievalNode.Repo.start_link()
    {:ok, _} = Finch.start_link(name: RetrievalNode.Finch)
    start_in_process_serving_if_needed()

    started = System.monotonic_time(:millisecond)

    Mix.shell().info(
      "Re-embedding with #{inspect(Embedding.impl())} (profile #{Embedding.profile()})…"
    )

    {:ok, count} =
      Reembed.run(
        source: opts[:source],
        all: opts[:all],
        after: opts[:after],
        batch: opts[:batch] || 256,
        progress: &report(&1, started)
      )

    Mix.shell().info("Done: #{count} chunk(s) re-embedded.")
  end

  defp report(%{done: done, total: total, last_id: last}, started) do
    secs = max(System.monotonic_time(:millisecond) - started, 1) / 1000
    rate = done / secs
    eta = if rate > 0, do: round((total - done) / rate), else: 0

    Mix.shell().info(
      "#{done}/#{total} (#{Float.round(rate, 1)}/s, ~#{eta}s left) last id #{last}"
    )
  end

  # The CPU model only exists when its supervisor runs.
  defp start_in_process_serving_if_needed do
    if Embedding.impl() == NxServingImpl do
      {:ok, _} = Application.ensure_all_started(:bumblebee)
      {:ok, _} = Application.ensure_all_started(:exla)
      {:ok, _} = Supervisor.start_link([Embedding.Supervisor], strategy: :one_for_one)
    end
  end
end
