defmodule RetrievalNodeWeb.ConnectionsLiveTest do
  use RetrievalNodeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RetrievalNode.Google.OAuth

  @labels %{
    "labels" => [
      %{
        "id" => "lbl",
        "properties" => %{"title" => "Classification"},
        "fields" => [
          %{
            "id" => "fld",
            "selectionOptions" => %{
              "choices" => [%{"id" => "pub", "properties" => %{"displayName" => "Public"}}]
            }
          }
        ]
      }
    ]
  }

  setup do
    prev = %{
      google: Application.get_env(:retrieval_node, :google),
      google_req: Application.get_env(:retrieval_node, :google_req_options),
      drive_req: Application.get_env(:retrieval_node, :drive_req_options)
    }

    Application.put_env(:retrieval_node, :google, client_id: "cid", client_secret: "csecret")
    Application.put_env(:retrieval_node, :google_req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
    OAuth.invalidate()

    on_exit(fn ->
      OAuth.invalidate()
      Application.put_env(:retrieval_node, :google, prev.google)
      Application.put_env(:retrieval_node, :google_req_options, prev.google_req)
      Application.put_env(:retrieval_node, :drive_req_options, prev.drive_req)
    end)

    # Token endpoint (code exchange + refresh) and the Labels API.
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v2/labels" ->
          Req.Test.json(conn, @labels)

        _token ->
          Req.Test.json(conn, %{
            "access_token" => "atok",
            "expires_in" => 3600,
            "refresh_token" => "rtok-123"
          })
      end
    end)

    :ok
  end

  defp state_from(view) do
    href =
      view
      |> element("#connect-google")
      |> render()
      |> then(&Regex.run(~r/href="([^"]+)"/, &1))
      |> List.last()

    query =
      href
      |> String.replace("&amp;", "&")
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["redirect_uri"] == "http://localhost:4002/google/callback"
    query["state"]
  end

  test "connect, come back with a code: the token is shown once and used", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/connections")
    assert html =~ "not authorized"
    state = state_from(view)

    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[state: state, code: "c0de"]}")

    html = render(view)
    assert html =~ "GOOGLE_REFRESH_TOKEN=rtok-123"
    assert html =~ "Classification label found"
    assert Application.get_env(:retrieval_node, :google)[:refresh_token] == "rtok-123"

    # A fresh visit doesn't show it again.
    {:ok, _view, html} = live(conn, ~p"/connections")
    refute html =~ "rtok-123"
    assert html =~ "authorized"
  end

  test "pasting the redirected URL finishes the same way", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/connections")
    state = state_from(view)

    html =
      view
      |> form("#paste-redirect", %{
        "url" => "http://localhost:4000/google/callback?state=#{state}&code=c0de"
      })
      |> render_submit()

    assert html =~ "GOOGLE_REFRESH_TOKEN=rtok-123"
  end

  test "a forged state or a denial is refused without exchanging", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[state: "forged", code: "c0de"]}")
    assert render(view) =~ "doesn&#39;t match a link from this server"
    refute Application.get_env(:retrieval_node, :google)[:refresh_token]

    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[error: "access_denied"]}")
    assert render(view) =~ "access not granted"
  end

  test "without a client id, explains what to configure", %{conn: conn} do
    Application.put_env(:retrieval_node, :google, [])
    {:ok, _view, html} = live(conn, ~p"/connections")
    assert html =~ "GOOGLE_CLIENT_ID"
    refute html =~ "connect-google"
  end

  describe "Ollama" do
    setup do
      prev = %{
        impl: Application.get_env(:retrieval_node, :embedding_impl),
        ollama: Application.get_env(:retrieval_node, RetrievalNode.Embedding.OllamaImpl),
        req: Application.get_env(:retrieval_node, :embedding_req_options)
      }

      Application.put_env(:retrieval_node, :embedding_impl, RetrievalNode.Embedding.OllamaImpl)

      Application.put_env(:retrieval_node, RetrievalNode.Embedding.OllamaImpl,
        endpoint: "http://ollama.test"
      )

      Application.put_env(:retrieval_node, :embedding_req_options,
        plug: {Req.Test, RetrievalNodeWeb.ConnectionsLiveTest.Ollama},
        retry: false
      )

      on_exit(fn ->
        Application.put_env(:retrieval_node, :embedding_impl, prev.impl)
        Application.put_env(:retrieval_node, RetrievalNode.Embedding.OllamaImpl, prev.ollama)
        Application.put_env(:retrieval_node, :embedding_req_options, prev.req)
      end)
    end

    defp ollama(models) do
      Req.Test.stub(RetrievalNodeWeb.ConnectionsLiveTest.Ollama, fn conn ->
        case conn.request_path do
          "/api/version" ->
            Req.Test.json(conn, %{"version" => "0.40.9"})

          "/api/tags" ->
            Req.Test.json(conn, %{"models" => Enum.map(models, &%{"name" => &1})})

          "/v1/embeddings" ->
            Req.Test.json(conn, %{
              "data" => [%{"index" => 0, "embedding" => List.duplicate(0.1, 768)}]
            })
        end
      end)
    end

    test "connected: version, model and a round trip", %{conn: conn} do
      ollama(["nomic-embed-text:latest"])
      {:ok, view, _html} = live(conn, ~p"/connections")
      html = render_async(view)

      assert html =~ "connected"
      assert html =~ "Ollama 0.40.9 at"
      assert html =~ ~r/answered in \d+ ms/
    end

    test "model not pulled is flagged with the command to run", %{conn: conn} do
      ollama(["llama3:latest"])
      {:ok, view, _html} = live(conn, ~p"/connections")
      assert render_async(view) =~ "ollama pull nomic-embed-text"
    end

    test "unreachable", %{conn: conn} do
      Req.Test.stub(
        RetrievalNodeWeb.ConnectionsLiveTest.Ollama,
        &Req.Test.transport_error(&1, :econnrefused)
      )

      {:ok, view, _html} = live(conn, ~p"/connections")
      html = render_async(view)
      assert html =~ "unreachable"
      assert html =~ "econnrefused"
    end
  end

  test "shows how much of the index is on the current embedding profile", %{conn: conn} do
    source =
      RetrievalNode.Repo.insert!(%RetrievalNode.Retrieval.Source{
        source_type: :git_repo,
        name: "p",
        identifier: "file:///p"
      })

    for profile <- ["stub", "stub", "bumblebee:old", nil] do
      RetrievalNode.Repo.insert!(%RetrievalNode.Retrieval.Chunk{
        source_id: source.id,
        source_type: :git_repo,
        chunk_key: "k-#{System.unique_integer([:positive])}",
        content_hash: "h",
        content: "x",
        context_breadcrumb: "x",
        embedding_profile: profile
      })
    end

    {:ok, _view, html} = live(conn, ~p"/connections")
    assert html =~ ~r/Index:\s*<strong>2<\/strong> of 4 chunks/
    assert html =~ "mix rn.reembed"
    assert html =~ "bumblebee:old"
    assert html =~ "unrecorded (before profiles)"
  end

  test "without Ollama, says embeddings run on the CPU", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/connections")
    assert html =~ "Computed in-process on the CPU"
  end
end
