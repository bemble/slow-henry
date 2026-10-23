defmodule RetrievalNode.Search do
  @moduledoc """
  Search context — the public entry point for hybrid retrieval.

  One of the two contexts (with `Ingest`) allowed to touch `Repo`. Embeds the
  query text via the configured `Embedding` impl, runs the RRF `HybridQuery`, and
  assembles back-link results (`%{chunk, score}`) — deliberately *not* full
  content, which callers fetch separately when a hit is expanded.
  """

  alias RetrievalNode.Embedding
  alias RetrievalNode.Embedding.Unavailable
  alias RetrievalNode.Search.HybridQuery

  @type hit :: %{chunk: map(), score: float()}

  @doc """
  Hybrid (dense + BM25/RRF) search over the query text.

  Options:
    * `:source_id` / `:source_type` / `:repo` / `:lang` — optional filters applied
      inside both ranking CTEs (see `HybridQuery`). `:source_type` is the DB enum
      string (`"git_repo"`/`"jira_project"`/`"drive_folder"`)
    * `:top_k` — result count (default 20)
    * `:embedding` — a precomputed 384-float query vector; when given, skips the
      embedding step (used by tests and callers that already hold an embedding)

  Returns hits ordered by fused score descending. Each `:chunk` is a back-link
  projection (`id`, `source_type`, `repo`, `lang`, `context_breadcrumb`,
  `metadata`) — never `content`.
  """
  @spec hybrid_search(String.t(), keyword()) :: [hit]
  def hybrid_search(query_text, opts \\ []) when is_binary(query_text),
    do: search(query_text, opts).hits

  @doc """
  Like `hybrid_search/2`, but says how it ranked: `:hybrid`, or `:text_only`
  when the embedding backend is unavailable (`Embedding.Unavailable`) — the
  search then falls back to full-text ranking alone instead of failing.
  """
  @spec search(String.t(), keyword()) :: %{mode: :hybrid | :text_only, hits: [hit]}
  def search(query_text, opts \\ []) when is_binary(query_text) do
    {mode, embedding} =
      case Keyword.fetch(opts, :embedding) do
        {:ok, embedding} -> {:hybrid, embedding}
        :error -> embed_query(query_text)
      end

    %{mode: mode, hits: run(query_text, embedding, opts)}
  end

  defp embed_query(query_text) do
    {:hybrid, Embedding.embed(query_text)}
  rescue
    Unavailable -> {:text_only, nil}
  end

  defp run(query_text, embedding, opts) do
    query_opts =
      opts
      |> Keyword.take([:source_id, :source_type, :repo, :lang, :top_k])
      |> Keyword.merge(embedding: embedding, text_query: query_text)

    query_opts
    |> HybridQuery.search()
    |> Enum.map(&to_hit/1)
  end

  defp to_hit(%{fused_score: score} = row) do
    %{
      chunk: %{
        id: row.chunk_id,
        source_type: row.source_type,
        repo: row.repo,
        lang: row.lang,
        context_breadcrumb: row.context_breadcrumb,
        metadata: row.metadata
      },
      score: score
    }
  end
end
