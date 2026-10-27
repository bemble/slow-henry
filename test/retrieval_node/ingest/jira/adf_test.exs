defmodule RetrievalNode.Ingest.Jira.AdfTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Ingest.Jira.Adf

  defp doc(content), do: %{"type" => "doc", "version" => 1, "content" => content}
  defp text(t, marks \\ []), do: %{"type" => "text", "text" => t, "marks" => marks}
  defp p(inline), do: %{"type" => "paragraph", "content" => inline}
  defp li(blocks), do: %{"type" => "listItem", "content" => blocks}

  test "headings and paragraphs, separated by blank lines" do
    adf =
      doc([
        %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [text("Context")]},
        p([text("First line"), %{"type" => "hardBreak"}, text("second line")]),
        p([text("Next paragraph")])
      ])

    assert Adf.to_markdown(adf) == "## Context\n\nFirst line\nsecond line\n\nNext paragraph"
  end

  test ":heading_offset pushes headings down, capped at 6" do
    adf =
      doc([
        %{"type" => "heading", "attrs" => %{"level" => 1}, "content" => [text("Top")]},
        %{"type" => "heading", "attrs" => %{"level" => 6}, "content" => [text("Deep")]}
      ])

    assert Adf.to_markdown(adf, heading_offset: 1) == "## Top\n\n###### Deep"
  end

  test "nested bullet and ordered lists" do
    adf =
      doc([
        %{
          "type" => "bulletList",
          "content" => [
            li([p([text("one")])]),
            li([
              p([text("two")]),
              %{
                "type" => "orderedList",
                "attrs" => %{"order" => 3},
                "content" => [li([p([text("three")])]), li([p([text("four")])])]
              }
            ])
          ]
        }
      ])

    assert Adf.to_markdown(adf) == "- one\n- two\n  3. three\n  4. four"
  end

  test "task lists" do
    adf =
      doc([
        %{
          "type" => "taskList",
          "content" => [
            %{"type" => "taskItem", "attrs" => %{"state" => "DONE"}, "content" => [text("ship")]},
            %{"type" => "taskItem", "attrs" => %{"state" => "TODO"}, "content" => [text("test")]}
          ]
        }
      ])

    assert Adf.to_markdown(adf) == "- [x] ship\n- [ ] test"
  end

  test "code blocks keep their language and blank lines" do
    adf =
      doc([
        %{
          "type" => "codeBlock",
          "attrs" => %{"language" => "elixir"},
          "content" => [text("# comment\n\nIO.puts(1)")]
        }
      ])

    assert Adf.to_markdown(adf) == "```elixir\n# comment\n\nIO.puts(1)\n```"
  end

  test "blockquotes, panels, expands and rules" do
    adf =
      doc([
        %{"type" => "blockquote", "content" => [p([text("quoted")]), p([text("again")])]},
        %{
          "type" => "panel",
          "attrs" => %{"panelType" => "info"},
          "content" => [p([text("note")])]
        },
        %{"type" => "expand", "attrs" => %{"title" => "Logs"}, "content" => [p([text("stack")])]},
        %{"type" => "rule"}
      ])

    assert Adf.to_markdown(adf) ==
             "> quoted\n>\n> again\n\n> note\n\n**Logs**\n\nstack\n\n---"
  end

  test "tables, with a header separator when the first row is header cells" do
    cell = fn type, t -> %{"type" => type, "content" => [p([text(t)])]} end

    adf =
      doc([
        %{
          "type" => "table",
          "content" => [
            %{
              "type" => "tableRow",
              "content" => [cell.("tableHeader", "Region"), cell.("tableHeader", "Node")]
            },
            %{
              "type" => "tableRow",
              "content" => [cell.("tableCell", "eu"), cell.("tableCell", "a|b")]
            }
          ]
        }
      ])

    assert Adf.to_markdown(adf) == "| Region | Node |\n| --- | --- |\n| eu | a\\|b |"
  end

  test "marks: bold, italic, strike, code, link" do
    adf =
      doc([
        p([
          text("bold", [%{"type" => "strong"}]),
          text(" "),
          text("it", [%{"type" => "em"}]),
          text(" "),
          text("old", [%{"type" => "strike"}]),
          text(" "),
          text("mix test", [%{"type" => "code"}, %{"type" => "strong"}]),
          text(" "),
          text("docs", [%{"type" => "link", "attrs" => %{"href" => "https://x.dev"}}])
        ])
      ])

    assert Adf.to_markdown(adf) == "**bold** _it_ ~~old~~ `mix test` [docs](https://x.dev)"
  end

  test "inline nodes: mention, emoji, inline card, status, date" do
    adf =
      doc([
        p([
          %{"type" => "mention", "attrs" => %{"id" => "1", "text" => "@Ada"}},
          text(" "),
          %{"type" => "emoji", "attrs" => %{"shortName" => ":tada:"}},
          text(" "),
          %{"type" => "inlineCard", "attrs" => %{"url" => "https://jira/CLOUD-1"}},
          text(" "),
          %{"type" => "status", "attrs" => %{"text" => "DONE"}},
          text(" "),
          %{"type" => "date", "attrs" => %{"timestamp" => "1767225600000"}}
        ])
      ])

    assert Adf.to_markdown(adf) == "@Ada :tada: https://jira/CLOUD-1 [DONE] 2026-01-01"
  end

  test "media is dropped; an unknown node keeps its text" do
    adf =
      doc([
        %{
          "type" => "mediaSingle",
          "content" => [%{"type" => "media", "attrs" => %{"id" => "x"}}]
        },
        %{"type" => "someFutureBlock", "content" => [p([text("kept")])]},
        %{"type" => "someFutureInline", "content" => [text("also kept")]}
      ])

    assert Adf.to_markdown(adf) == "kept\n\nalso kept"
  end

  test "nil and plain strings" do
    assert Adf.to_markdown(nil) == ""
    assert Adf.to_markdown("  plain text  ") == "plain text"
  end
end
