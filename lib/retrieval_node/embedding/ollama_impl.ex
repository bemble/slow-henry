defmodule RetrievalNode.Embedding.OllamaImpl do
  @moduledoc """
  Embeddings from an Ollama server (e.g. on a Mac's GPU) instead of the
  in-process Bumblebee serving on the BEAM's CPU — about 18x faster on an
  Apple Silicon GPU. Selected by `OLLAMA_ENDPOINT` (config/runtime.exs):

      config :retrieval_node, :embedding_impl, RetrievalNode.Embedding.OllamaImpl

      config :retrieval_node, RetrievalNode.Embedding.OllamaImpl,
        endpoint: "http://localhost:11434",   # OLLAMA_ENDPOINT
        model: "nomic-embed-text",            # OLLAMA_EMBEDDING_MODEL
        batch_size: 64

  It calls Ollama's OpenAI-compatible `POST /v1/embeddings`, so any server
  with that API (`llama-server --embedding`, LM Studio) works too.

  Vectors get the same Matryoshka post-processing as
  `Embedding.NxServingImpl` (leading 384 dims, L2-renormalized), so the
  `vector(384)` columns don't change. Unlike it, this applies the task
  prefixes nomic-embed-text v1.5 was trained with: `embed/1` (search queries)
  gets `search_query: `, `embed_batch/1` (indexed chunks) `search_document: `.
  Both are configurable (`:query_prefix`, `:document_prefix`) for other
  models. Vectors from different models or prefixes don't mix: switching
  means re-embedding everything.

  Errors raise, like the in-process serving's, so `SourceOwner` marks the
  file failed and retries it.
  """

  @behaviour RetrievalNode.Embedding

  @dimensions 384
  @norm_epsilon 1.0e-12
  @defaults [
    endpoint: "http://localhost:11434",
    model: "nomic-embed-text",
    batch_size: 64,
    timeout_ms: 120_000,
    query_prefix: "search_query: ",
    document_prefix: "search_document: "
  ]

  @impl true
  def dimensions, do: @dimensions

  @impl true
  def embed(text) when is_binary(text) do
    [vector] = request([config(:query_prefix) <> text])
    vector
  end

  @impl true
  def embed_batch(texts) when is_list(texts) do
    prefix = config(:document_prefix)

    texts
    |> Enum.map(&(prefix <> &1))
    |> Enum.chunk_every(config(:batch_size))
    |> Enum.flat_map(&request/1)
  end

  defp req_options, do: Application.get_env(:retrieval_node, :embedding_req_options, [])

  @doc "Matryoshka post-processing of one full-size embedding (pure)."
  @spec matryoshka([number()]) :: [float()]
  def matryoshka(full) when length(full) >= @dimensions do
    head = Enum.take(full, @dimensions)

    norm =
      head |> Enum.reduce(0.0, fn x, acc -> acc + x * x end) |> :math.sqrt() |> max(@norm_epsilon)

    Enum.map(head, &(&1 / norm))
  end

  def matryoshka(full),
    do: raise("expected an embedding with at least #{@dimensions} dims, got #{length(full)}")

  defp request(inputs) do
    opts =
      [
        url: String.trim_trailing(config(:endpoint), "/") <> "/v1/embeddings",
        json: %{model: config(:model), input: inputs},
        receive_timeout: config(:timeout_ms),
        retry: :transient,
        finch: [name: RetrievalNode.Finch]
      ]
      |> Keyword.merge(req_options())

    case Req.post(opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} when length(data) == length(inputs) ->
        data |> Enum.sort_by(& &1["index"]) |> Enum.map(&matryoshka(&1["embedding"]))

      {:ok, %{status: status, body: body}} ->
        raise "Ollama returned #{status}: #{inspect(body, limit: 5, printable_limit: 200)}"

      {:error, reason} ->
        raise "Ollama unreachable at #{config(:endpoint)}: #{inspect(reason)}"
    end
  end

  defp config(key) do
    Application.get_env(:retrieval_node, __MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
