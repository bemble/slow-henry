defmodule RetrievalNode.SourcesFile.Watcher do
  @moduledoc """
  Applies `sources.toml` (`SourcesFile.default_path/0`) when the server
  starts, then re-applies it whenever its content changes — checked every
  `:interval_ms` (30 s by default; `SOURCES_WATCH_INTERVAL` in seconds).

  Changes are detected by a SHA-256 of the file's bytes, so an editor
  touching the file without changing it does nothing.

  A missing or invalid file changes **nothing**: the sources stay as they
  are (a half-saved or deleted file must not deactivate everything). The
  error is logged and exposed through `status/0` for the UI, and the next
  valid version is applied as usual. A missing file is not an error (a fresh
  install has none until the Sources editor writes it): `status/0` reports
  `missing: true`.

  Disabled in tests and in the mix tasks that boot the app (`rn.seed`,
  `rn.sources`): `config :retrieval_node, :sources_watch, false`.
  """
  use GenServer

  require Logger

  alias RetrievalNode.SourcesFile

  @default_interval_ms 30_000
  @status_keys [:path, :applied_at, :hash, :changes, :error, :missing]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `%{path:, applied_at:, hash:, changes:, error:, missing:}` — `changes` is the number
  of sources changed by the last apply; `nil` when the watcher isn't running.
  """
  def status do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :status), else: nil
  end

  @doc "Checks the file now (used by tests and the UI)."
  def check_now, do: GenServer.call(__MODULE__, :check, :timer.minutes(1))

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.get(opts, :path) || SourcesFile.default_path(),
      interval: Keyword.get(opts, :interval_ms, interval_ms()),
      hash: nil,
      applied_at: nil,
      changes: nil,
      error: nil,
      missing: false
    }

    # First apply right after boot, outside init so the supervisor isn't held.
    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = check(state)
    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, @status_keys), state}

  def handle_call(:check, _from, state) do
    state = check(state)
    {:reply, Map.take(state, @status_keys), state}
  end

  defp check(state) do
    case File.read(state.path) do
      {:ok, body} ->
        hash = SourcesFile.hash(body)
        state = %{state | missing: false}
        if hash == state.hash, do: state, else: apply_file(state, hash)

      {:error, :enoent} when state.missing ->
        state

      {:error, :enoent} ->
        Logger.info("no #{state.path} yet, sources left unchanged")
        %{state | missing: true, hash: nil, error: nil}

      {:error, reason} ->
        report_error(state, "cannot read #{state.path}: #{:file.format_error(reason)}")
    end
  end

  defp apply_file(state, hash) do
    with {:ok, entries} <- SourcesFile.load(state.path),
         {:ok, changes} <- SourcesFile.apply(entries) do
      changed = Enum.reject(changes, &match?({:unchanged, _}, &1))

      if changed != [],
        do:
          Logger.info(
            "sources.toml applied: #{length(changed)} source(s) changed (#{state.path})"
          )

      %{state | hash: hash, applied_at: DateTime.utc_now(), changes: length(changed), error: nil}
    else
      {:error, reason} ->
        # Keep the old hash: once fixed, the file is applied again.
        report_error(state, if(is_binary(reason), do: reason, else: inspect(reason)))
    end
  end

  # Log once per distinct error, not on every tick.
  defp report_error(%{error: error} = state, error), do: state

  defp report_error(state, error) do
    Logger.error("sources.toml not applied, sources left unchanged: #{error}")
    %{state | error: error}
  end

  defp interval_ms,
    do: Application.get_env(:retrieval_node, :sources_watch_interval_ms, @default_interval_ms)
end
