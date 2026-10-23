defmodule RetrievalNode.SourcesFile do
  @moduledoc """
  `sources.toml` is the source of truth for the git repos and the Google Drive
  scope that are indexed. It lives in the data dir (`DATA_DIR/sources.toml`,
  git-ignored: it names private repos and Drive ids; `SOURCES_FILE`
  overrides the path); `sources.example.toml` is the template.

      [[git]]
      name = "adr"                                  # mirror slug + MCP `repo` filter
      url = "https://github.com/my-org/adr.git"     # clone URL (the source identity)
      # active = false                              # keep indexed chunks, stop syncing
      # exclude = ["docs/*", "!docs/adr"]           # .gitignore-style (Ingest.PathFilter)
      # pull_requests = true                        # also index merged PRs (default false)

      [drive]
      my_drive = true                               # Docs you own (default true)
      shared_with_me = true                         # Docs shared directly with you (default false)
      include = ["0AbC...", "1xYz..."]              # shared drive or folder ids
      # active = false

  Drive docs are further filtered by their Classification label (see
  `Ingest.DrivePolicy`).

  `apply/1` aligns the `sources` table with the file — at boot and on every
  change by `SourcesFile.Watcher`, or by hand with `mix rn.sources`:

    * an entry with no matching source is **added** and gets its first sync;
    * a known one whose name, `active` flag or Drive scope differs is
      **updated**; re-activation, or a changed Drive scope, triggers a sync;
    * a git or Drive source in the database but no longer in the file is
      **deactivated** — never deleted, so its chunks stay searchable and
      putting it back resumes from its cursor.

  The Sources editor (`RetrievalNodeWeb.SourcesEditLive`) writes the file
  with `save/3` (`encode/1`, which does not keep comments), then lets the
  watcher apply it.

  Jira is still registered by `mix rn.seed` from its credentials.
  """

  import Ecto.Query

  alias RetrievalNode.Ingest.PathFilter
  alias RetrievalNode.Ingest.Workers.{DriveSync, PullRequestSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source
  alias RetrievalNode.TomlWriter

  @file_name "sources.toml"
  @managed_types [:git_repo, :drive_folder]
  @drive_identifier "drive:me"
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @url_schemes ~w(https:// http:// ssh:// git:// file://)
  @drive_id_format ~r/\A[A-Za-z0-9_-]+\z/
  @header """
  # Sources indexed by Slow Henry (git repos + Google Drive), written by the
  # Sources editor (/sources/edit). Hand edits work too, but the editor does
  # not keep comments. Format and rules: RetrievalNode.SourcesFile.
  """

  @typedoc "A source as the file wants it."
  @type entry :: %{
          source_type: :git_repo | :drive_folder,
          identifier: String.t(),
          name: String.t(),
          active: boolean(),
          config: map()
        }
  @type change ::
          {:add, entry()}
          | {:update, Source.t(), entry()}
          | {:deactivate, Source.t()}
          | {:unchanged, Source.t()}

  @doc "The file to read: `SOURCES_FILE` if set, else `<data dir>/sources.toml`."
  def default_path,
    do: System.get_env("SOURCES_FILE") || Path.join(RetrievalNode.data_dir(), @file_name)

  @doc "Reads and validates the file."
  @spec load(Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def load(path) do
    with {:ok, body} <- read(path),
         {:ok, doc} <- decode(path, body) do
      parse(doc)
    else
      {:error, :enoent} ->
        {:error, "cannot read #{path}: no such file (copy sources.example.toml there)"}

      error ->
        error
    end
  end

  @doc """
  Like `load/1`, plus the SHA-256 of the bytes read, to pass back to
  `save/3`. A missing file reads as no entries with a nil hash.
  """
  @spec load_with_hash(Path.t()) :: {:ok, [entry()], String.t() | nil} | {:error, String.t()}
  def load_with_hash(path) do
    with {:ok, body} <- read(path),
         {:ok, doc} <- decode(path, body),
         {:ok, entries} <- parse(doc) do
      {:ok, entries, hash(body)}
    else
      {:error, :enoent} -> {:ok, [], nil}
      error -> error
    end
  end

  @doc "The hash `load_with_hash/1`, `save/3` and the watcher compare."
  def hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  @doc """
  Writes `entries` to `path` (temp file + rename) if the file still has
  `expected_hash` (nil: still missing), i.e. nobody changed it since it was
  read. Returns the new hash, `{:error, :conflict}`, or the validation or
  write error — the file is left as it was then.
  """
  @spec save(Path.t(), [entry()], String.t() | nil) ::
          {:ok, String.t()} | {:error, :conflict | String.t()}
  def save(path, entries, expected_hash) do
    body = encode(entries)

    with {:ok, doc} <- decode(path, body),
         {:ok, _entries} <- parse(doc),
         :ok <- unchanged(path, expected_hash),
         :ok <- write_file(path, body) do
      {:ok, hash(body)}
    end
  end

  # A read-only mount, or a single-file bind mount (which can't be renamed
  # over), fails here.
  defp write_file(path, body) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp unchanged(path, expected_hash) do
    current =
      case File.read(path) do
        {:ok, body} -> hash(body)
        {:error, _} -> nil
      end

    if current == expected_hash, do: :ok, else: {:error, :conflict}
  end

  @doc """
  The file for `entries`: `[[git]]` tables in order, then `[drive]`. Only
  options that differ from their default are written, except Drive's scope.
  """
  @spec encode([entry()]) :: String.t()
  def encode(entries) do
    {drive, git} = Enum.split_with(entries, &(&1.source_type == :drive_folder))
    tables = Enum.map(git, &git_table/1) ++ Enum.map(drive, &drive_table/1)

    Enum.join([@header | tables], "\n")
  end

  defp git_table(e) do
    table("[[git]]", [
      {"name", e.name},
      {"url", e.identifier},
      {"active", if(e.active, do: nil, else: false)},
      {"exclude", e.config["exclude"]},
      {"pull_requests", e.config["pull_requests"]}
    ])
  end

  defp drive_table(e) do
    table("[drive]", [
      {"my_drive", e.config["my_drive"]},
      {"shared_with_me", e.config["shared_with_me"] == true},
      {"include", e.config["include"]},
      {"active", if(e.active, do: nil, else: false)}
    ])
  end

  defp table(header, pairs) do
    lines = for {k, v} <- pairs, not is_nil(v), do: "#{k} = #{TomlWriter.value(v)}"
    Enum.join([header | lines], "\n") <> "\n"
  end

  @doc "Validates an already-decoded TOML document."
  @spec parse(map()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(doc) do
    with :ok <- known_sections(doc),
         {:ok, raw} <- git_tables(doc),
         {:ok, git} <- collect(raw),
         :ok <- unique(git, :name),
         :ok <- unique(git, :identifier),
         {:ok, drive} <- drive_entry(Map.get(doc, "drive")) do
      {:ok, git ++ List.wrap(drive)}
    end
  end

  @doc "What `apply/1` would do, without writing anything."
  @spec plan([entry()]) :: [change()]
  def plan(entries) do
    existing = Repo.all(from s in Source, where: s.source_type in ^@managed_types)
    by_key = Map.new(existing, &{{&1.source_type, &1.identifier}, &1})
    wanted = MapSet.new(entries, &{&1.source_type, &1.identifier})

    planned = Enum.map(entries, &plan_entry(&1, by_key))

    retired =
      for s <- existing,
          s.active,
          not MapSet.member?(wanted, {s.source_type, s.identifier}),
          do: {:deactivate, s}

    planned ++ retired
  end

  defp plan_entry(entry, by_key) do
    case Map.fetch(by_key, {entry.source_type, entry.identifier}) do
      :error -> {:add, entry}
      {:ok, s} -> if same?(s, entry), do: {:unchanged, s}, else: {:update, s, entry}
    end
  end

  defp same?(s, e),
    do: s.name == e.name and s.active == e.active and (s.config || %{}) == e.config

  @doc """
  Applies `plan/1` in one transaction, then enqueues a sync for every added or
  re-activated source (and a full Drive pass when its scope changed).
  Requires a running Oban instance.
  """
  @spec apply([entry()]) :: {:ok, [change()]} | {:error, term()}
  def apply(entries) do
    changes = plan(entries)

    result = Repo.transaction(fn -> Enum.map(changes, &write!/1) end)

    with {:ok, written} <- result do
      for {change, source} <- written, job <- sync_jobs(change), do: enqueue!(source, job)
      {:ok, changes}
    end
  end

  defp write!(change) do
    case write(change) do
      {:ok, source} -> {change, source}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write({:add, e}) do
    %Source{}
    |> Source.create_changeset(Map.take(e, [:source_type, :identifier, :name, :active, :config]))
    |> Repo.insert()
  end

  defp write({:update, s, e}),
    do: s |> Source.update_changeset(Map.take(e, [:name, :active, :config])) |> Repo.update()

  defp write({:deactivate, s}),
    do: s |> Source.update_changeset(%{active: false}) |> Repo.update()

  defp write({:unchanged, s}), do: {:ok, s}

  # The {worker, extra args} jobs a change calls for.
  defp sync_jobs({:add, %{active: false}}), do: []
  defp sync_jobs({:add, e}), do: [{worker(e), %{}} | pr_job(%{}, e.config)]

  defp sync_jobs({:update, _s, %{active: false}}), do: []

  defp sync_jobs({:update, s, e}) do
    old = s.config || %{}

    main =
      cond do
        # A changed scope (Drive include, git exclude) affects content that
        # didn't change: re-read everything.
        scope(old) != scope(e.config) -> [{worker(e), %{"mode" => "full"}}]
        not s.active -> [{worker(e), %{}}]
        true -> []
      end

    main ++ pr_job(if(s.active, do: old, else: %{}), e.config)
  end

  defp sync_jobs(_change), do: []

  # PR sync when pull_requests is newly on (or the source comes back).
  defp pr_job(old, new) do
    if new["pull_requests"] == true and old["pull_requests"] != true,
      do: [{PullRequestSync, %{}}],
      else: []
  end

  defp scope(config), do: Map.delete(config, "pull_requests")

  defp worker(%{source_type: :drive_folder}), do: DriveSync
  defp worker(_entry), do: RepoSync

  defp enqueue!(source, {worker, args}) do
    {:ok, _job} = Oban.insert(worker.new(Map.put(args, "source_id", source.id)))
  end

  # --- reading / validation ---

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(path, body) do
    case Toml.decode(body) do
      {:ok, doc} -> {:ok, doc}
      {:error, {:invalid_toml, reason}} -> {:error, "#{path}: #{reason}"}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  defp known_sections(doc) do
    case Map.keys(doc) -- ~w(git drive) do
      [] -> :ok
      unknown -> {:error, "unknown section(s) #{Enum.join(unknown, ", ")}"}
    end
  end

  defp git_tables(doc) do
    case Map.get(doc, "git", []) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, "`git` must be an array of tables ([[git]])"}
    end
  end

  defp collect(raw) do
    raw
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
      case git_entry(item) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        {:error, msg} -> {:halt, {:error, "[[git]] ##{i}: #{msg}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp git_entry(%{"name" => name, "url" => url} = item)
       when is_binary(name) and is_binary(url) do
    active = Map.get(item, "active", true)
    exclude = Map.get(item, "exclude", [])
    pull_requests = Map.get(item, "pull_requests", false)
    unknown = Map.keys(item) -- ~w(name url active exclude pull_requests)

    cond do
      unknown != [] ->
        {:error, "unknown key(s) #{Enum.join(unknown, ", ")}"}

      not Regex.match?(@name_format, name) ->
        {:error, "invalid name #{inspect(name)}"}

      not Enum.any?(@url_schemes, &String.starts_with?(url, &1)) ->
        {:error, "invalid url #{inspect(url)}"}

      not is_boolean(active) or not is_boolean(pull_requests) ->
        {:error, "`active` and `pull_requests` must be true or false"}

      not PathFilter.valid?(exclude) ->
        {:error, "`exclude` must be a list of path patterns"}

      true ->
        {:ok,
         %{
           source_type: :git_repo,
           identifier: url,
           name: name,
           active: active,
           config: git_config(exclude, pull_requests)
         }}
    end
  end

  defp git_entry(_), do: {:error, "`name` and `url` are required strings"}

  # Options are stored only when set, so sources configured before they
  # existed don't read as changed.
  defp git_config(exclude, pull_requests) do
    %{}
    |> then(&if(exclude != [], do: Map.put(&1, "exclude", exclude), else: &1))
    |> then(&if(pull_requests, do: Map.put(&1, "pull_requests", true), else: &1))
  end

  defp drive_entry(nil), do: {:ok, nil}

  defp drive_entry(%{} = item) do
    flags = %{
      my_drive: Map.get(item, "my_drive", true),
      shared_with_me: Map.get(item, "shared_with_me", false),
      include: Map.get(item, "include", []),
      active: Map.get(item, "active", true),
      unknown: Map.keys(item) -- ~w(my_drive shared_with_me include active)
    }

    case drive_error(flags) do
      nil ->
        {:ok,
         %{
           source_type: :drive_folder,
           identifier: @drive_identifier,
           name: "Google Drive",
           active: flags.active,
           config: drive_config(flags)
         }}

      msg ->
        {:error, "[drive]: " <> msg}
    end
  end

  defp drive_entry(_), do: {:error, "`drive` must be a table ([drive])"}

  # shared_with_me is only stored when on, so sources configured before the
  # option existed don't read as changed (which would queue a full pass).
  defp drive_config(flags) do
    config = %{"my_drive" => flags.my_drive, "include" => flags.include}
    if flags.shared_with_me == true, do: Map.put(config, "shared_with_me", true), else: config
  end

  defp drive_error(%{unknown: [_ | _] = unknown}),
    do: "unknown key(s) #{Enum.join(unknown, ", ")}"

  defp drive_error(%{my_drive: my, shared_with_me: shared, active: active})
       when not is_boolean(my) or not is_boolean(shared) or not is_boolean(active),
       do: "`my_drive`, `shared_with_me` and `active` must be true or false"

  defp drive_error(%{include: include} = flags) do
    cond do
      not is_list(include) or not Enum.all?(include, &drive_id?/1) ->
        "`include` must be a list of Drive ids"

      length(Enum.uniq(include)) != length(include) ->
        "duplicate id in `include`"

      not flags.my_drive and not flags.shared_with_me and include == [] ->
        "nothing to index (my_drive and shared_with_me are false and no include)"

      true ->
        nil
    end
  end

  defp drive_id?(id), do: is_binary(id) and Regex.match?(@drive_id_format, id)

  defp unique(entries, key) do
    case entries
         |> Enum.frequencies_by(&Map.fetch!(&1, key))
         |> Enum.find(fn {_, n} -> n > 1 end) do
      nil ->
        :ok

      {value, _} ->
        {:error, "duplicate #{if key == :identifier, do: "url", else: key} #{inspect(value)}"}
    end
  end
end
