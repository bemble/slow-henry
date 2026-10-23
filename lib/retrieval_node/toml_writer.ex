defmodule RetrievalNode.TomlWriter do
  @moduledoc """
  TOML values for the files the app writes itself (`Secrets`,
  `SourcesFile`): the `toml` dependency only decodes.
  """

  @doc "A TOML value: a basic string, a boolean, or an array of those."
  def value(value) when is_binary(value), do: string(value)
  def value(value) when is_boolean(value), do: to_string(value)
  def value(values) when is_list(values), do: "[" <> Enum.map_join(values, ", ", &value/1) <> "]"

  @doc "A TOML basic string: escape backslash, quote and control characters."
  def string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(~r/[\x00-\x1f\x7f]/u, fn <<c>> ->
        "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
      end)

    "\"" <> escaped <> "\""
  end
end
