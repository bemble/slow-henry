defmodule RetrievalNode.Embedding.ReembedTest do
  use RetrievalNode.DataCase, async: true

  import Ecto.Query

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
    # all: true — in_a is already on the current profile after the first run.
    assert {:ok, 1} = Reembed.run(after: first, all: true)
    assert_raise ArgumentError, ~r/no source named/, fn -> Reembed.run(source: "nope") end
    _ = second
  end

  test "only chunks not on the current profile are redone, unless all: true" do
    a = source!("a")
    stale = chunk!(a, "", "stale text")
    current = chunk!(a, "", "current text")

    Repo.update_all(from(c in Chunk, where: c.id == ^current.id),
      set: [embedding_profile: "stub"]
    )

    assert {:ok, 1} = Reembed.run()
    assert Repo.get!(Chunk, stale.id).embedding_profile == "stub"
    assert vector(current) == List.duplicate(0.0, 383) ++ [1.0]

    assert {:ok, 0} = Reembed.run()
    assert {:ok, 2} = Reembed.run(all: true)
  end

  test "a chunk the server re-embeds during the run is not redone" do
    a = source!("a")
    c = chunk!(a, "", "old text")

    # Simulate the server rewriting the chunk between the read and the write:
    # the progress callback runs after a batch, so use a 1-chunk batch and
    # rewrite a second chunk before its turn.
    c2 = chunk!(a, "", "will change")
    [first, second] = Enum.sort_by([c, c2], & &1.id)

    rewrite = fn %{done: 1} ->
      Repo.update_all(from(x in Chunk, where: x.id == ^second.id),
        set: [content: "new text", content_hash: "h2", embedding_profile: "stub"]
      )
    end

    assert {:ok, _} = Reembed.run(batch: 1, progress: fn p -> if p.done == 1, do: rewrite.(p) end)
    assert Repo.get!(Chunk, first.id).embedding_profile == "stub"
    # The rewritten chunk was no longer stale (profile "stub"), so it was left alone.
    assert Repo.get!(Chunk, second.id).content == "new text"
  end
end
