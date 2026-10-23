defmodule RetrievalNode.SearchFallbackTest do
  # async: false — swaps the global :embedding_impl.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source}
  alias RetrievalNode.Search

  setup do
    prev = Application.get_env(:retrieval_node, :embedding_impl)
    Application.put_env(:retrieval_node, :embedding_impl, RetrievalNode.Embedding.UnavailableImpl)
    on_exit(fn -> Application.put_env(:retrieval_node, :embedding_impl, prev) end)

    source = Repo.insert!(%Source{source_type: :git_repo, name: "repo-a", identifier: "repo-a"})
    %{source: source}
  end

  defp chunk!(source, content, axis) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      repo: "repo-a",
      chunk_key: "k-#{System.unique_integer([:positive])}",
      content_hash: "h",
      content: content,
      context_breadcrumb: "lib/x.ex",
      metadata: %{"path" => "lib/x.ex"},
      embedding: Pgvector.new(for(j <- 0..383, do: if(j == axis, do: 1.0, else: 0.0)))
    })
  end

  test "without an embedding backend, search falls back to full-text ranking and says so",
       %{source: source} do
    match = chunk!(source, "rotate the tunnel certificates", 0)
    _other = chunk!(source, "unrelated lorem ipsum", 1)

    assert %{mode: :text_only, hits: [%{chunk: %{id: id}}]} = Search.search("tunnel certificates")
    assert id == match.id
  end
end
