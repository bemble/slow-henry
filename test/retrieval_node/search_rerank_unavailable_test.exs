defmodule RetrievalNode.SearchRerankUnavailableTest do
  # async: false — swaps the GLOBAL :reranking_impl app env.
  use RetrievalNode.DataCase, async: false

  alias RetrievalNode.Repo
  alias RetrievalNode.Reranking
  alias RetrievalNode.Reranking.NxServingImpl
  alias RetrievalNode.Retrieval.{Chunk, Source}
  alias RetrievalNode.Search

  defmodule UnavailableReranking do
    @moduledoc false
    @behaviour RetrievalNode.Reranking

    @impl true
    def available?, do: false

    @impl true
    def rerank_scores(_query, _passages), do: raise("must not be called when unavailable")
  end

  defp use_impl(mod) do
    original = Application.fetch_env!(:retrieval_node, :reranking_impl)
    Application.put_env(:retrieval_node, :reranking_impl, mod)
    on_exit(fn -> Application.put_env(:retrieval_node, :reranking_impl, original) end)
  end

  test "rerank: true keeps the RRF ranking when the reranker is unavailable" do
    use_impl(UnavailableReranking)
    embedding = for j <- 0..383, do: if(j == 0, do: 1.0, else: 0.0)
    source = Repo.insert!(%Source{source_type: :git_repo, name: "repo-a", identifier: "repo-a"})

    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      repo: "repo-a",
      chunk_key: "key-1",
      content_hash: "hash-1",
      content: "the quick brown fox",
      context_breadcrumb: "lib/foo.ex",
      metadata: %{},
      embedding: Pgvector.new(embedding)
    })

    assert [hit] = Search.hybrid_search("quick brown fox", embedding: embedding, rerank: true)
    refute Map.has_key?(hit, :fused_score)
  end

  describe "Reranking.available?/0" do
    test "an impl without available?/0 is available" do
      assert Reranking.available?()
    end

    test "NxServingImpl follows :reranking_serving_start" do
      use_impl(NxServingImpl)
      original = Application.get_env(:retrieval_node, :reranking_serving_start)
      on_exit(fn -> Application.put_env(:retrieval_node, :reranking_serving_start, original) end)

      Application.put_env(:retrieval_node, :reranking_serving_start, false)
      refute Reranking.available?()

      Application.put_env(:retrieval_node, :reranking_serving_start, true)
      assert Reranking.available?()
    end
  end
end
