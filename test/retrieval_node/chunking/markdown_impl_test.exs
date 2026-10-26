defmodule RetrievalNode.Chunking.MarkdownImplTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Chunking.MarkdownImpl

  defp chunk(source, lang \\ "markdown") do
    {:ok, chunks} = MarkdownImpl.chunk(source, lang)
    chunks
  end

  defp paragraph(words), do: Enum.map_join(1..words, " ", &"word#{&1}")

  describe "markdown" do
    test "a short document is one chunk, headings and all" do
      source = "# Title\n\nIntro.\n\n## Part\n\nBody.\n"

      assert [chunk] = chunk(source)
      assert chunk.text == "# Title\n\nIntro.\n\n## Part\n\nBody."
      assert {chunk.start_line, chunk.end_line} == {1, 7}
      assert chunk.kind == "markdown_section"
      assert chunk.parse_status == :ok
    end

    test "a heading starts a new chunk once the current one is big enough" do
      source = "# Doc\n\n#{paragraph(80)}\n\n## Next\n\n#{paragraph(80)}\n"

      assert [first, second] = chunk(source)
      assert first.text =~ ~r/\A# Doc\n\nword1 /
      assert second.text =~ ~r/\A## Next\n\nword1 /
      assert first.breadcrumb == "Doc"
      assert second.breadcrumb == "Doc > Next"
    end

    test "a heading is never the last line of a chunk" do
      source = "## A\n\n#{paragraph(80)}\n\n## B\n\n#{paragraph(200)}\n"

      for chunk <- chunk(source) do
        refute chunk.text |> String.split("\n") |> List.last() |> String.starts_with?("#")
      end
    end

    test "small sections merge, and the breadcrumb is the trail they share" do
      source = "# Doc\n\n## A\n\nshort a\n\n## B\n\nshort b\n"

      assert [chunk] = chunk(source)
      assert chunk.breadcrumb == "Doc"
    end

    test "blocks pack up to the target size" do
      source = Enum.map_join(1..30, "\n\n", fn _ -> paragraph(20) end)
      chunks = chunk(source)

      assert length(chunks) in 3..5
      assert Enum.all?(chunks, &(byte_size(&1.text) <= 1_500 + 400))
    end

    test "a small last chunk merges into the previous one" do
      source = "#{paragraph(200)}\n\n## Additional\n\n- [ ] done\n"

      assert List.last(chunk(source)).text =~ "## Additional\n\n- [ ] done"
      refute Enum.any?(chunk(source), &String.starts_with?(&1.text, "## Additional"))
    end

    test "a # line inside a fence is not a heading, and a fence is not split on blank lines" do
      source = "# Doc\n\n```sh\n# install\n\nmix deps.get\n```\n\nAfter.\n"

      assert [chunk] = chunk(source)
      assert chunk.breadcrumb == "Doc"
      assert chunk.text =~ "```sh\n# install\n\nmix deps.get\n```"
    end

    test "a ~~~ fence closes only on a ~~~ line at least as long" do
      source = "~~~~\n```\n~~~\n# not a heading\n~~~~\n\n# Real\n\ntext\n"

      assert [chunk] = chunk(source)
      assert chunk.breadcrumb == ""
      assert chunk.text =~ "# not a heading"
    end

    test "an oversized block is split on line boundaries, at blank lines when it can" do
      code = Enum.map_join(1..40, "\n\n", fn i -> "step_#{i}(#{paragraph(8)})" end)
      source = "# Doc\n\n```\n#{code}\n```\n"
      chunks = chunk(source)

      assert length(chunks) >= 2
      assert hd(chunks).text =~ ~r/\A# Doc\n\n```\nstep_1/
      assert Enum.all?(chunks, &(byte_size(&1.text) <= 1_500 + 400))
      refute Enum.any?(chunks, &(&1.text =~ ~r/\A\s|\s\z/))
    end

    test "a single line longer than the target is a chunk of its own" do
      long = String.duplicate("x", 3_000)

      assert [chunk] = chunk(long)
      assert chunk.text == long
    end

    test "the heading trail follows levels" do
      source = """
      # A

      #{paragraph(80)}

      ## B

      #{paragraph(80)}

      ### C

      #{paragraph(80)}

      ## D

      #{paragraph(80)}
      """

      assert Enum.map(chunk(source), & &1.breadcrumb) == ["A", "A > B", "A > B > C", "A > D"]
    end

    test "closing #s, #hashtags and empty headings" do
      assert [%{breadcrumb: "Title"}] = chunk("## Title ##\n\ntext\n")
      assert [%{breadcrumb: ""}] = chunk("#hashtag\n\ntext\n")
      assert [%{breadcrumb: ""}] = chunk("#\n\ntext\n")
      assert [%{breadcrumb: "C#"}] = chunk("# C#\n\ntext\n")
    end

    test "a merged PR with a title, a description and sections is one or two chunks" do
      source = """
      # CLOUD-1 Route every sign-up through the new handler

      Pull request #12 in acme/app by @dev, merged 2026-08-10
      https://github.com/acme/app/pull/12

      #{paragraph(60)}

      ## Proposed change

      #{paragraph(15)}

      #{Enum.map_join(1..5, "\n", fn i -> "- `apps/file_#{i}.ts` — #{paragraph(25)}" end)}

      ## Additional

      - [ ] Secrets has been updated or is not applicable.
      - [ ] The deployment configuration has been updated or is not applicable.

      ## Reviews

      **@lead (APPROVED):** LGTM
      """

      chunks = chunk(source)
      assert length(chunks) in 1..2
      assert Enum.all?(chunks, &String.starts_with?(&1.breadcrumb, "CLOUD-1 Route"))
      assert Enum.join(Enum.map(chunks, & &1.text)) =~ "LGTM"
    end

    test "empty and blank documents have no chunks" do
      assert chunk("") == []
      assert chunk("\n\n  \n") == []
    end

    test "CRLF is normalized" do
      assert [chunk] = chunk("# T\r\n\r\na\r\nb\r\n")
      assert chunk.text == "# T\n\na\nb"
    end
  end

  describe "verbatim languages" do
    test "# is a comment, not a heading" do
      source = "# Settings\nkey: value\n\n# More\nother: 1\n"

      assert [chunk] = chunk(source, "yaml")
      assert chunk.breadcrumb == ""
      assert chunk.kind == "config_block"
      assert chunk.text == String.trim_trailing(source)
    end

    test "a large file is packed into pieces of about the target size" do
      source = Enum.map_join(1..400, "\n", &~s(  "key_#{&1}": "value number #{&1}",))
      chunks = chunk("{\n#{source}\n}\n", "json")

      assert length(chunks) > 5
      assert Enum.all?(chunks, &(byte_size(&1.text) <= 1_500 + 100))
      assert hd(chunks).start_line == 1
      assert List.last(chunks).text =~ ~r/}\z/
    end

    test "every verbatim language is accepted" do
      for lang <- MarkdownImpl.verbatim_languages() do
        assert {:ok, [_]} = MarkdownImpl.chunk("a = 1\n", lang)
      end
    end
  end

  test "rejects what TreeSitterImpl rejects" do
    assert MarkdownImpl.chunk(<<0, 1, 2>>, "markdown") == {:error, :binary_content}
    assert MarkdownImpl.chunk(String.duplicate("a", 2_000_001), "text") == {:error, :too_large}
    assert MarkdownImpl.chunk("x", "python") == {:error, :unsupported_language}
  end
end
