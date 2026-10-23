defmodule RetrievalNode.Embedding.OllamaImplTest do
  use ExUnit.Case, async: false

  alias RetrievalNode.Embedding.OllamaImpl

  setup do
    prev = %{
      impl: Application.get_env(:retrieval_node, OllamaImpl),
      req: Application.get_env(:retrieval_node, :embedding_req_options)
    }

    Application.put_env(:retrieval_node, OllamaImpl,
      endpoint: "http://embed.test",
      batch_size: 2
    )

    Application.put_env(:retrieval_node, :embedding_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      Application.put_env(:retrieval_node, OllamaImpl, prev.impl)
      Application.put_env(:retrieval_node, :embedding_req_options, prev.req)
    end)
  end

  # Echo server: each input's vector encodes its position, so order is checkable.
  defp echo do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"model" => model, "input" => inputs} = Jason.decode!(body)
      send(parent, {:request, conn.request_path, model, inputs})

      data =
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {_input, i} ->
          %{"index" => i, "embedding" => [i + 1.0 | List.duplicate(0.0, 767)]}
        end)
        # Servers may answer out of order: the client sorts by index.
        |> Enum.reverse()

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  test "documents get search_document:, batched, vectors in input order, 384 dims, unit norm" do
    echo()

    vectors = OllamaImpl.embed_batch(["a", "b", "c"])

    assert_received {:request, "/v1/embeddings", "nomic-embed-text",
                     ["search_document: a", "search_document: b"]}

    assert_received {:request, "/v1/embeddings", "nomic-embed-text", ["search_document: c"]}

    assert length(vectors) == 3
    assert Enum.all?(vectors, &(length(&1) == 384))
    assert Enum.all?(vectors, fn v -> abs(Enum.sum(Enum.map(v, &(&1 * &1))) - 1.0) < 1.0e-9 end)
  end

  test "queries get search_query:" do
    echo()
    assert [_ | _] = OllamaImpl.embed("how do we deploy?")
    assert_received {:request, _, _, ["search_query: how do we deploy?"]}
  end

  test "prefixes and model are configurable" do
    Application.put_env(:retrieval_node, OllamaImpl,
      endpoint: "http://embed.test",
      model: "qwen3-embedding:0.6b",
      query_prefix: "",
      document_prefix: ""
    )

    echo()
    OllamaImpl.embed_batch(["raw"])
    assert_received {:request, _, "qwen3-embedding:0.6b", ["raw"]}
  end

  test "matryoshka keeps the leading 384 dims and renormalizes" do
    full = List.duplicate(1.0, 384) ++ List.duplicate(5.0, 384)
    v = OllamaImpl.matryoshka(full)

    assert length(v) == 384
    assert_in_delta hd(v), 1 / :math.sqrt(384), 1.0e-12
    assert_raise RuntimeError, ~r/at least 384 dims/, fn -> OllamaImpl.matryoshka([1.0, 2.0]) end
  end

  test "connection errors and 502/503/504 raise Embedding.Unavailable" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert_raise RetrievalNode.Embedding.Unavailable, ~r/unreachable/, fn ->
      OllamaImpl.embed_batch(["a"])
    end

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{})
    end)

    assert_raise RetrievalNode.Embedding.Unavailable, ~r/503/, fn -> OllamaImpl.embed("q") end
  end

  test "a server error raises (so the owner retries the file)" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "model not found"})
    end)

    assert_raise RuntimeError, ~r/Ollama returned 500/, fn -> OllamaImpl.embed_batch(["a"]) end
  end
end
