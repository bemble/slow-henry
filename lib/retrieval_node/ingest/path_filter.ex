defmodule RetrievalNode.Ingest.PathFilter do
  @moduledoc """
  `.gitignore`-style path exclusion for git sources (`exclude` in a
  `[[git]]` entry of sources.toml):

      exclude = ["homeassistant/components/*", "!homeassistant/components/cloud"]

  * patterns are anchored at the repo root (a leading `/` is optional);
  * `*` matches within one path segment, `**` across segments, `?` one char;
  * a pattern matching a directory covers everything below it;
  * `!pattern` re-includes what an earlier pattern excluded — unlike git,
    even below an excluded directory, which is what makes the example above
    keep `homeassistant/components/cloud/**`;
  * the last pattern that matches a path decides.
  """

  @type t :: [{:exclude | :include, Regex.t()}]

  @doc "Compiles patterns; an empty list excludes nothing."
  @spec compile([String.t()]) :: t()
  def compile(patterns) do
    for pattern <- patterns, pattern = String.trim(pattern), pattern != "" do
      {kind, glob} =
        case pattern do
          "!" <> rest -> {:include, rest}
          _ -> {:exclude, pattern}
        end

      {kind, glob |> String.trim("/") |> to_regex()}
    end
  end

  @doc "Whether `path` is excluded."
  @spec excluded?(t(), String.t()) :: boolean()
  def excluded?([], _path), do: false

  def excluded?(filter, path) do
    Enum.reduce(filter, false, fn {kind, regex}, excluded ->
      if Regex.match?(regex, path), do: kind == :exclude, else: excluded
    end)
  end

  @doc "Whether a pattern list is valid (non-empty strings)."
  def valid?(patterns),
    do:
      is_list(patterns) and
        Enum.all?(patterns, &(is_binary(&1) and String.trim(&1) not in ["", "!"]))

  # A glob becomes `^<glob>(/.*)?$`: the path itself, or anything below it.
  defp to_regex(glob) do
    body =
      ~r/\*\*|\*|\?|[^*?]+/
      |> Regex.scan(glob)
      |> Enum.map_join(fn
        ["**"] -> ".*"
        ["*"] -> "[^/]*"
        ["?"] -> "[^/]"
        [literal] -> Regex.escape(literal)
      end)

    Regex.compile!("\\A" <> body <> "(?:/.*)?\\z", "s")
  end
end
