defmodule RetrievalNode.Chunking.MarkdownImpl do
  @moduledoc """
  Pure-Elixir chunker for everything that isn't code: markdown prose (merged
  PRs, Drive docs, Jira issues, repo docs) and verbatim text (config files,
  plain text).

  **Markdown** (`"markdown"`) is read as blocks — runs of lines separated by
  blank lines, ATX headings (`#` … `######`), and fenced code blocks
  (```` ``` ```` / `~~~`, never split on a blank line, and whose `#` lines are
  not headings). Blocks are packed into chunks of about `@target_bytes`:

    * a heading starts a new chunk once the current one has `@min_bytes`;
      smaller sections merge into one chunk;
    * a heading is never left alone at the end of a chunk — it stays with the
      content after it;
    * the breadcrumb is the heading trail the chunk's blocks share
      (`"Incident log > Timeline"`), without emphasis markers or backslash
      escapes;
    * a block larger than the target is split on line boundaries, at a blank
      line when there is one;
    * a last chunk under `@min_bytes` merges into the previous one.

  **Verbatim** languages (`verbatim_languages/0`: YAML, JSON, TOML,
  Dockerfile, plain text…) are read as one fenced block: `#` is a comment
  there, so no heading is detected, and lines are packed up to the target,
  splitting at blank lines when possible. Their breadcrumb is empty.

  Same pre-flight guards as `TreeSitterImpl` (size cap, binary content), so
  `Ingest.FileIngest` skips the same inputs whichever chunker runs.
  """

  @behaviour RetrievalNode.Chunking

  @max_bytes Application.compile_env(:retrieval_node, [:chunking, :max_bytes], 2_000_000)

  # Same soft target as HeuristicImpl, so chunk sizes stay comparable.
  @target_bytes 1_500
  # Below this, a chunk is a fragment: it absorbs the next section, or merges
  # into the previous chunk when it is the last one.
  @min_bytes 400

  @verbatim_languages ~w(yaml json toml ini properties terraform dockerfile ignore text)

  @heading ~r/\A {0,3}(\#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+\#+)?[ \t]*\z/
  @fence ~r/\A {0,3}(`{3,}|~{3,})/
  # Emphasis around a run of text (`**Notes**`, `_Draft_`), not inside a word,
  # so `process_payment` keeps its underscore.
  @emphasis ~r/(?<![\w*])(\*{1,3}|_{1,3})(?=\S)(.+?)(?<=\S)\1(?![\w*])/u
  # CommonMark backslash escapes, as Google Docs exports them (`2024.11.12 \-`).
  @escape ~r/\\([!-\/:-@\[-`{-~])/

  @impl true
  def allowed_languages, do: ["markdown" | @verbatim_languages]

  @doc "The languages chunked line by line, without heading detection."
  @spec verbatim_languages() :: [String.t()]
  def verbatim_languages, do: @verbatim_languages

  @impl true
  def chunk(source, language) when is_binary(source) do
    cond do
      byte_size(source) > @max_bytes -> {:error, :too_large}
      RetrievalNode.Chunking.binary_content?(source) -> {:error, :binary_content}
      language == "markdown" -> {:ok, chunk_markdown(lines(source))}
      language in @verbatim_languages -> {:ok, chunk_verbatim(lines(source))}
      true -> {:error, :unsupported_language}
    end
  end

  # {line, 1-based line number}, CRLF/CR normalized like HeuristicImpl.
  defp lines(source) do
    source
    |> String.replace(~r/\r\n?/, "\n")
    |> String.split("\n")
    |> Enum.with_index(1)
  end

  # --- verbatim --------------------------------------------------------------

  defp chunk_verbatim(lines) do
    lines
    |> split_lines()
    |> Enum.map(&build(&1, "", "config_block"))
  end

  # --- markdown --------------------------------------------------------------

  defp chunk_markdown(lines) do
    lines
    |> blocks()
    |> with_trails()
    |> pack()
    |> merge_small_tail()
    |> Enum.map(&build(&1.lines, Enum.join(&1.trail, " > "), "markdown_section"))
  end

  # Blocks in document order: %{type: :heading | :text | :fence, lines, level,
  # title}. `lines` is accumulated reversed and put back in order on close.
  defp blocks(lines) do
    {blocks, current, _fence} = Enum.reduce(lines, {[], nil, nil}, &block_step/2)
    blocks |> close(current) |> Enum.reverse()
  end

  # Inside a fence: every line belongs to it, until the closing one.
  defp block_step({line, _n} = entry, {blocks, current, fence}) when fence != nil do
    current = add_line(current, entry)

    if closes_fence?(line, fence),
      do: {close(blocks, current), nil, nil},
      else: {blocks, current, fence}
  end

  defp block_step({line, _n} = entry, {blocks, current, nil}) do
    cond do
      blank?(line) ->
        {close(blocks, current), nil, nil}

      opener = fence_opener(line) ->
        {close(blocks, current), new_block(:fence, entry), opener}

      heading = heading(line) ->
        {level, title} = heading
        block = %{new_block(:heading, entry) | level: level, title: title}
        {close(close(blocks, current), block), nil, nil}

      current == nil ->
        {blocks, new_block(:text, entry), nil}

      true ->
        {blocks, add_line(current, entry), nil}
    end
  end

  defp new_block(type, entry), do: %{type: type, lines: [entry], level: nil, title: nil}

  defp add_line(block, entry), do: %{block | lines: [entry | block.lines]}

  defp close(blocks, nil), do: blocks
  defp close(blocks, block), do: [%{block | lines: Enum.reverse(block.lines)} | blocks]

  defp heading(line) do
    case Regex.run(@heading, line) do
      [_, hashes, title] when title != "" -> {String.length(hashes), clean_title(title)}
      _ -> nil
    end
  end

  # The title goes into the breadcrumb, which is embedded: drop markup that
  # isn't words. The chunk text keeps the heading as written.
  defp clean_title(title) do
    title
    |> String.replace(@emphasis, "\\2")
    |> String.replace(@escape, "\\1")
  end

  defp fence_opener(line) do
    case Regex.run(@fence, line) do
      [_, marker] -> marker
      nil -> nil
    end
  end

  # Closed by a line of the same character, at least as long, and nothing else.
  defp closes_fence?(line, opener) do
    trimmed = String.trim(line)
    length = String.length(trimmed)

    length >= String.length(opener) and
      trimmed == String.duplicate(String.first(opener), length)
  end

  # Each block gets the heading trail it sits under (a heading, its own).
  defp with_trails(blocks) do
    {blocks, _stack} =
      Enum.map_reduce(blocks, [], fn block, stack ->
        stack = enter(stack, block)
        {Map.put(block, :trail, Enum.map(stack, &elem(&1, 1))), stack}
      end)

    blocks
  end

  # A heading closes the sections at its level or deeper, then opens its own.
  defp enter(stack, %{type: :heading, level: level, title: title}),
    do: Enum.reject(stack, fn {open, _} -> open >= level end) ++ [{level, title}]

  defp enter(stack, _block), do: stack

  # Chunks are %{lines, bytes, trail, content?}; `content?` is false while the
  # chunk only holds headings, which must not be cut from what follows.
  defp pack(blocks) do
    {done, current} = Enum.reduce(blocks, {[], nil}, &pack_step/2)
    done |> push(current) |> Enum.reverse()
  end

  defp pack_step(block, {done, nil}), do: start(done, block)

  defp pack_step(%{type: :heading} = block, {done, current}) do
    if current.bytes >= @min_bytes,
      do: start([current | done], block),
      else: {done, append(current, block, block.lines)}
  end

  defp pack_step(block, {done, current}) do
    size = bytes(block.lines)

    cond do
      not current.content? and size > @target_bytes -> split_into(done, current, block)
      not current.content? -> {done, append(current, block, block.lines)}
      current.bytes + size <= @target_bytes -> {done, append(current, block, block.lines)}
      true -> start([current | done], block)
    end
  end

  defp push(chunks, nil), do: chunks
  defp push(chunks, chunk), do: [chunk | chunks]

  defp start(done, block) do
    if block.type != :heading and bytes(block.lines) > @target_bytes,
      do: split_into(done, nil, block),
      else: {done, new_chunk(block, block.lines)}
  end

  # An oversized block: its first piece completes `current` (which then only
  # holds headings), the middle pieces are chunks of their own, and the last
  # piece stays open so the small blocks after it can join.
  defp split_into(done, current, block) do
    [first | rest] = split_lines(block.lines)
    first_chunk = if current, do: append(current, block, first), else: new_chunk(block, first)

    case rest do
      [] ->
        {done, first_chunk}

      _ ->
        {middle, [last]} = Enum.split(rest, -1)
        middle_chunks = Enum.map(middle, &new_chunk(block, &1))
        {Enum.reverse(middle_chunks, [first_chunk | done]), new_chunk(block, last)}
    end
  end

  defp new_chunk(block, lines) do
    %{lines: lines, bytes: bytes(lines), trail: block.trail, content?: block.type != :heading}
  end

  defp append(chunk, block, lines) do
    %{
      chunk
      | lines: chunk.lines ++ lines,
        bytes: chunk.bytes + bytes(lines),
        trail: common_prefix(chunk.trail, block.trail),
        content?: chunk.content? or block.type != :heading
    }
  end

  defp merge_small_tail(chunks) do
    case Enum.reverse(chunks) do
      [last, prev | rest]
      when last.bytes < @min_bytes and prev.bytes + last.bytes <= @target_bytes + @min_bytes ->
        merged = %{
          prev
          | lines: prev.lines ++ last.lines,
            bytes: prev.bytes + last.bytes,
            trail: common_prefix(prev.trail, last.trail)
        }

        Enum.reverse([merged | rest])

      _ ->
        chunks
    end
  end

  defp common_prefix([x | a], [x | b]), do: [x | common_prefix(a, b)]
  defp common_prefix(_a, _b), do: []

  # --- line splitting --------------------------------------------------------

  # Pieces of about @target_bytes, without leading or trailing blank lines. A
  # piece ends at its last blank line once past half the target, else at the
  # line that reaches the target — so a line longer than the target is a piece
  # of its own.
  defp split_lines(lines) do
    case Enum.drop_while(lines, fn {line, _} -> blank?(line) end) do
      [] ->
        []

      lines ->
        {piece, rest} = take_piece(lines, [], 0, nil)
        [drop_trailing_blanks(piece) | split_lines(rest)]
    end
  end

  # `acc` is reversed; `cut` is how many lines to keep when stopping at the
  # last blank line seen past half the target.
  defp take_piece([], acc, _bytes, _cut), do: {Enum.reverse(acc), []}

  defp take_piece([{line, _} = entry | rest], acc, bytes, cut) do
    bytes = bytes + byte_size(line) + 1
    acc = [entry | acc]
    cut = if blank?(line) and bytes >= div(@target_bytes, 2), do: length(acc), else: cut

    cond do
      bytes < @target_bytes ->
        take_piece(rest, acc, bytes, cut)

      cut != nil ->
        {piece, back} = acc |> Enum.reverse() |> Enum.split(cut)
        {piece, back ++ rest}

      true ->
        {Enum.reverse(acc), rest}
    end
  end

  defp drop_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(fn {line, _} -> blank?(line) end)
    |> Enum.reverse()
  end

  # --- output ----------------------------------------------------------------

  defp build(lines, breadcrumb, kind) do
    {_, start_line} = List.first(lines)
    {_, end_line} = List.last(lines)

    %{
      text: text(lines),
      breadcrumb: breadcrumb,
      start_line: start_line,
      end_line: end_line,
      kind: kind,
      parse_status: :ok
    }
  end

  # The blank lines between a chunk's blocks aren't in `lines`: put one back
  # wherever the line numbers jump.
  defp text(lines) do
    {parts, _prev} =
      Enum.reduce(lines, {[], nil}, fn {line, n}, {acc, prev} ->
        acc = if prev != nil and n > prev + 1, do: ["" | acc], else: acc
        {[line | acc], n}
      end)

    parts |> Enum.reverse() |> Enum.join("\n")
  end

  defp bytes(lines), do: Enum.reduce(lines, 0, fn {line, _}, acc -> acc + byte_size(line) + 1 end)

  defp blank?(line), do: String.trim(line) == ""
end
