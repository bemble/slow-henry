defmodule RetrievalNode.Chunking.Breadcrumb do
  @moduledoc """
  Builds the context breadcrumb that is prepended to a chunk's text before
  embedding, so the vector captures *where* the chunk lives, not just its content.

  A chunk carries an in-source symbol trail from the chunker (e.g. `"Foo > bar"`
  for code, `""` for a heuristic block). `build/2` prefixes that with the
  provenance the chunker doesn't know — the file path for code, or the document
  title for docs — yielding e.g. `"lib/foo.ex > Foo > bar"` or
  `"Design Doc > Overview"`. `prepend/2` then attaches it to the text.
  """

  @separator " > "

  @doc """
  Combine a `prefix` (file path for code, doc title for docs) with the chunk's
  in-source `symbol_trail`. An empty/nil trail yields just the prefix.

  A document's first heading is usually its title, which the prefix already
  says: a leading trail entry equal to the prefix, or to what follows its
  `": "` (`"PR #12: Fix login"` and `"Fix login"`), is dropped.
  """
  @spec build(String.t(), String.t() | nil) :: String.t()
  def build(prefix, symbol_trail) when symbol_trail in [nil, ""], do: prefix

  def build(prefix, symbol_trail) do
    trail = sanitize(symbol_trail)
    [first | rest] = String.split(trail, @separator, parts: 2)

    if prefix == first or String.ends_with?(prefix, ": " <> first),
      do: build(prefix, Enum.join(rest)),
      else: prefix <> @separator <> trail
  end

  # The symbol trail comes from parsed (untrusted) identifiers. Collapse any
  # newlines/control whitespace to spaces so a malformed name can't inject line
  # breaks into the breadcrumb (which is embedded and stored).
  defp sanitize(trail), do: String.replace(trail, ~r/\s+/, " ")

  @doc "Prepend a breadcrumb to chunk text (the string that actually gets embedded)."
  @spec prepend(String.t(), String.t()) :: String.t()
  def prepend(breadcrumb, text), do: breadcrumb <> "\n\n" <> text
end
