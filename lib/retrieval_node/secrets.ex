defmodule RetrievalNode.Secrets do
  @moduledoc """
  Credentials the app obtains itself (OAuth refresh tokens…), persisted in
  `<data dir>/secrets.toml` — as opposed to configuration (client ids and
  secrets, database URL), which comes from the environment.

      # data/secrets.toml — written by Slow Henry, mode 0600
      google_refresh_token = "1//0g…"

  The data dir is `DATA_DIR` (`config :retrieval_node, :data_dir`; `./data`
  in dev, `/var/lib/retrieval_node` in a release). Keys are plain
  `snake_case` names and values strings. Writes go through a temp file and
  a rename, so the file is never half-written, and keep mode 0600.
  """

  @file_name "secrets.toml"
  @key_format ~r/\A[a-z][a-z0-9_]*\z/

  @doc "Path of the secrets file."
  def path, do: Path.join(data_dir(), @file_name)

  defp data_dir, do: RetrievalNode.data_dir()

  @doc "A stored secret, or nil (also when the file is missing or unreadable)."
  @spec get(String.t()) :: String.t() | nil
  def get(key) do
    case read() do
      {:ok, secrets} -> secrets[key]
      _ -> nil
    end
  end

  @doc "Stores (or replaces) a secret."
  @spec put(String.t(), String.t()) :: :ok
  def put(key, value) when is_binary(value) do
    valid_key!(key)

    secrets =
      case read() do
        {:ok, secrets} -> secrets
        _ -> %{}
      end

    write!(Map.put(secrets, key, value))
  end

  @doc "Removes a secret (no-op when absent)."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    case read() do
      {:ok, secrets} when is_map_key(secrets, key) -> write!(Map.delete(secrets, key))
      _ -> :ok
    end
  end

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, doc} <- Toml.decode(body) do
      {:ok, for({k, v} <- doc, is_binary(v), into: %{}, do: {k, v})}
    end
  end

  defp write!(secrets) do
    File.mkdir_p!(data_dir())
    tmp = path() <> ".tmp-#{System.unique_integer([:positive])}"

    body =
      [
        "# Credentials obtained by Slow Henry (OAuth tokens). Keep it private:",
        "# git-ignored, mode 0600. Configuration goes in the environment instead.",
        ""
      ] ++ for({k, v} <- Enum.sort(secrets), do: "#{k} = #{encode(v)}")

    File.write!(tmp, Enum.join(body, "\n") <> "\n")
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path())
    :ok
  end

  # A TOML basic string: escape backslash, quote and control characters.
  defp encode(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(~r/[\x00-\x1f\x7f]/u, fn <<c>> ->
        "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
      end)

    "\"" <> escaped <> "\""
  end

  defp valid_key!(key) do
    unless is_binary(key) and Regex.match?(@key_format, key),
      do: raise(ArgumentError, "invalid secret key #{inspect(key)}")
  end
end
