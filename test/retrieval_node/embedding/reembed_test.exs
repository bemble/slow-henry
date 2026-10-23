defmodule RetrievalNode.Embedding.ReembedTest do
  use RetrievalNode.DataCase, async: true

  alias RetrievalNode.Embedding.{Reembed, StubImpl}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}

  defp source!(name),
    do: Repo.insert!(%Source{source_type: :git_repo, name: name, identifier: "file:///#{name}"})

  defp chunk!(source, crumb, content) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "k-#{System.unique_integer([:positive])}",
      content_hash: "h",
      content: content,
      context_breadcrumb: crumb,
      # Stale vector from "another model".
      embedding: Pgvector.new(List.duplicate(0.0, 383) ++ [1.0])
    })
  end

  defp vector(chunk), do: Repo.get!(Chunk, chunk.id).embedding |> Pgvector.to_list()

  test "re-embeds every chunk from its breadcrumb + content, in batches, reporting progress" do
    a = source!("a")
    c1 = chunk!(a, "lib/x.ex > X", "def x, do: 1")
    c2 = chunk!(a, "", "plain text")
    c3 = chunk!(a, "lib/y.ex", "def y, do: 2")
    parent = self()

    assert {:ok, 3} = Reembed.run(batch: 2, progress: &send(parent, {:progress, &1}))

    assert_received {:progress, %{done: 2, total: 3}}
    assert_received {:progress, %{done: 3, total: 3}}

    assert_in_delta Enum.sum(vector(c1)),
                    Enum.sum(StubImpl.embed("lib/x.ex > X\n\ndef x, do: 1")),
                    1.0e-4

    assert_in_delta Enum.sum(vector(c2)), Enum.sum(StubImpl.embed("plain text")), 1.0e-4
    refute vector(c3) == List.duplicate(0.0, 383) ++ [1.0]
  end

  test "--source limits the run to one source; --after resumes" do
    a = source!("a")
    b = source!("b")
    in_a = chunk!(a, "", "a text")
    in_b = chunk!(b, "", "b text")

    assert {:ok, 1} = Reembed.run(source: "a")
    refute vector(in_a) == List.duplicate(0.0, 383) ++ [1.0]
    assert vector(in_b) == List.duplicate(0.0, 383) ++ [1.0]

    [first, second] = Enum.sort([in_a.id, in_b.id])
    assert {:ok, 1} = Reembed.run(after: first)
    assert_raise ArgumentError, ~r/no source named/, fn -> Reembed.run(source: "nope") end
    _ = second
  end
end
