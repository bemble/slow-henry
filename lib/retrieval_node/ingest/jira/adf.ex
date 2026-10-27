defmodule RetrievalNode.Ingest.Jira.Adf do
  @moduledoc """
  Renders an Atlassian Document Format tree (a Jira Cloud description) as
  markdown, so `Chunking.MarkdownImpl` can split it on its headings and keep
  lists and code blocks whole.

  Covers the nodes Jira produces: headings, paragraphs, bullet, ordered and
  task lists (nested), code blocks (with their language), blockquotes,
  panels, expands, rules, tables, and the inline nodes — text with its marks
  (bold, italic, strike, code, link), mentions, emojis, dates, statuses,
  inline cards. Media is dropped; an unknown node renders its children, so
  its text is never lost.

  `:heading_offset` pushes every heading down that many levels (capped at
  6), for a description that sits under the issue's own `#` heading.
  """

  @doc "Markdown for an ADF document (or a plain string, passed through)."
  @spec to_markdown(map() | String.t() | nil, keyword()) :: String.t()
  def to_markdown(doc, opts \\ [])
  def to_markdown(nil, _opts), do: ""
  def to_markdown(text, _opts) when is_binary(text), do: String.trim(text)

  def to_markdown(%{} = doc, opts) do
    offset = Keyword.get(opts, :heading_offset, 0)
    doc |> children() |> blocks(offset) |> String.trim()
  end

  # --- blocks ----------------------------------------------------------------

  defp blocks(nodes, offset) do
    nodes
    |> Enum.map(&block(&1, offset))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp block(%{"type" => "paragraph"} = node, _offset), do: inline(children(node))

  defp block(%{"type" => "heading"} = node, offset) do
    level = min((attr(node, "level") || 1) + offset, 6)
    text = node |> children() |> inline() |> String.replace("\n", " ") |> String.trim()
    if text == "", do: "", else: String.duplicate("#", level) <> " " <> text
  end

  defp block(%{"type" => "bulletList"} = node, offset),
    do: list(node, offset, fn _i -> "- " end)

  defp block(%{"type" => "orderedList"} = node, offset) do
    first = attr(node, "order") || 1
    list(node, offset, fn i -> "#{first + i}. " end)
  end

  defp block(%{"type" => "taskList"} = node, offset) do
    node
    |> children()
    |> Enum.map_join("\n", fn
      %{"type" => "taskItem"} = item ->
        box = if attr(item, "state") == "DONE", do: "[x]", else: "[ ]"
        "- #{box} " <> inline(children(item))

      other ->
        block(other, offset)
    end)
  end

  defp block(%{"type" => "decisionList"} = node, _offset) do
    Enum.map_join(children(node), "\n", &("- " <> inline(children(&1))))
  end

  defp block(%{"type" => "codeBlock"} = node, _offset) do
    code = node |> children() |> Enum.map_join(&(&1["text"] || ""))
    "```#{attr(node, "language")}\n#{code}\n```"
  end

  defp block(%{"type" => "blockquote"} = node, offset),
    do: quote_lines(blocks(children(node), offset))

  defp block(%{"type" => "panel"} = node, offset), do: quote_lines(blocks(children(node), offset))

  defp block(%{"type" => type} = node, offset) when type in ["expand", "nestedExpand"] do
    title = attr(node, "title")
    body = blocks(children(node), offset)
    if title in [nil, ""], do: body, else: "**#{title}**\n\n#{body}"
  end

  defp block(%{"type" => "rule"}, _offset), do: "---"

  defp block(%{"type" => "table"} = node, _offset), do: table(children(node))

  defp block(%{"type" => type} = node, _offset) when type in ["blockCard", "embedCard"],
    do: attr(node, "url") || ""

  defp block(%{"type" => type}, _offset) when type in ["mediaSingle", "mediaGroup", "media"],
    do: ""

  # Unknown block: keep its text. A node with inline children renders as a
  # paragraph, one with block children as blocks.
  defp block(%{"content" => content} = node, offset) when is_list(content) do
    if Enum.all?(content, &inline_node?/1),
      do: inline(content),
      else: blocks(children(node), offset)
  end

  defp block(%{"type" => "text"} = node, _offset), do: inline([node])
  defp block(_node, _offset), do: ""

  # A list item's first block follows the marker; its other blocks and nested
  # lists are indented under it.
  defp list(node, offset, marker) do
    node
    |> children()
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {item, i} ->
      prefix = marker.(i)
      indent = String.duplicate(" ", String.length(prefix))

      item
      |> children()
      |> Enum.map(&block(&1, offset))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {line, 0} -> prefix <> line
        {"", _} -> ""
        {line, _} -> indent <> line
      end)
    end)
  end

  defp quote_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ">"
      line -> "> " <> line
    end)
  end

  # Rows of `| a | b |`; a header separator after the first row when it is
  # made of header cells. Cell text is flattened to one line.
  defp table(rows) do
    lines =
      Enum.map(rows, fn row ->
        cells = Enum.map(children(row), &cell_text/1)
        {"| " <> Enum.join(cells, " | ") <> " |", length(cells), header_row?(row)}
      end)

    case lines do
      [{first, width, true} | rest] ->
        separator = "|" <> String.duplicate(" --- |", width)
        Enum.join([first, separator | Enum.map(rest, &elem(&1, 0))], "\n")

      _ ->
        Enum.map_join(lines, "\n", &elem(&1, 0))
    end
  end

  defp header_row?(row) do
    cells = children(row)
    cells != [] and Enum.all?(cells, &(&1["type"] == "tableHeader"))
  end

  defp cell_text(cell) do
    cell
    |> children()
    |> blocks(0)
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace("|", "\\|")
    |> String.trim()
  end

  # --- inline ----------------------------------------------------------------

  defp inline(nodes), do: Enum.map_join(nodes, &inline_node/1)

  defp inline_node(%{"type" => "text", "text" => text} = node),
    do: marks(text, node["marks"] || [])

  defp inline_node(%{"type" => "hardBreak"}), do: "\n"
  defp inline_node(%{"type" => "mention"} = node), do: attr(node, "text") || ""

  defp inline_node(%{"type" => "emoji"} = node),
    do: attr(node, "text") || attr(node, "shortName") || ""

  defp inline_node(%{"type" => "inlineCard"} = node), do: attr(node, "url") || ""
  defp inline_node(%{"type" => "status"} = node), do: "[#{attr(node, "text")}]"
  defp inline_node(%{"type" => "date"} = node), do: date(attr(node, "timestamp"))
  defp inline_node(%{"content" => content}) when is_list(content), do: inline(content)
  defp inline_node(_node), do: ""

  defp inline_node?(%{"type" => type})
       when type in ~w(text hardBreak mention emoji inlineCard status date placeholder),
       do: true

  defp inline_node?(_node), do: false

  # Code first: no other mark is rendered inside a code span.
  defp marks(text, marks) do
    types = Enum.map(marks, & &1["type"])

    if "code" in types do
      wrap_link("`#{text}`", marks)
    else
      text
      |> wrap_if("strong" in types, "**")
      |> wrap_if("em" in types, "_")
      |> wrap_if("strike" in types, "~~")
      |> wrap_link(marks)
    end
  end

  defp wrap_if(text, true, delim) do
    # Markdown emphasis can't open or close on whitespace.
    trimmed = String.trim(text)
    if trimmed == "", do: text, else: String.replace(text, trimmed, delim <> trimmed <> delim)
  end

  defp wrap_if(text, false, _delim), do: text

  defp wrap_link(text, marks) do
    case Enum.find(marks, &(&1["type"] == "link")) do
      %{"attrs" => %{"href" => href}} when is_binary(href) -> "[#{text}](#{href})"
      _ -> text
    end
  end

  # ADF dates are epoch milliseconds, as a string.
  defp date(ms) do
    with ms when is_binary(ms) <- ms,
         {ms, ""} <- Integer.parse(ms),
         {:ok, datetime} <- DateTime.from_unix(ms, :millisecond) do
      datetime |> DateTime.to_date() |> Date.to_iso8601()
    else
      _ -> ""
    end
  end

  defp children(node), do: List.wrap(node["content"])
  defp attr(node, key), do: get_in(node, ["attrs", key])
end
