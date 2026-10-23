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

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    prev = %{
      data_dir: Application.get_env(:retrieval_node, :data_dir),
      google: Application.get_env(:retrieval_node, :google),
      google_req: Application.get_env(:retrieval_node, :google_req_options),
      drive_req: Application.get_env(:retrieval_node, :drive_req_options)
    }

    Application.put_env(:retrieval_node, :data_dir, dir)
    Application.put_env(:retrieval_node, :google, client_id: "cid", client_secret: "csecret")
    Application.put_env(:retrieval_node, :google_req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
    OAuth.invalidate()

    on_exit(fn ->
      OAuth.invalidate()
      Application.put_env(:retrieval_node, :data_dir, prev.data_dir)
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

  test "connect, come back with a code: the token is stored in secrets.toml, never shown",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/connections")
    assert html =~ "not authorized"
    state = state_from(view)

    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[state: state, code: "c0de"]}")

    html = render(view)
    refute html =~ "rtok-123"
    assert html =~ "The token is stored"
    assert html =~ "Classification label found"
    assert RetrievalNode.Secrets.get("google_refresh_token") == "rtok-123"

    {:ok, view, html} = live(conn, ~p"/connections")
    assert html =~ "Token stored in"
    assert html =~ "secrets.toml"

    # Disconnect forgets it.
    html = view |> element("#disconnect-google") |> render_click()
    assert html =~ "not authorized"
    assert RetrievalNode.Secrets.get("google_refresh_token") == nil
  end

  test "shows the app version and how to add the MCP server", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/connections?from=somewhere")
    version = to_string(Application.spec(:retrieval_node, :vsn))

    assert has_element?(view, "#app-version", "Slow Henry v#{version}")
    # Built from the URL the page was opened with, without its query.
    assert has_element?(view, "#mcp-url", "http://www.example.com/mcp")

    assert has_element?(
             view,
             "#mcp pre",
             "claude mcp add --transport http slow-henry http://www.example.com/mcp"
           )
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

    assert html =~ "The token is stored"
    assert RetrievalNode.Secrets.get("google_refresh_token") == "rtok-123"
  end

  test "a forged state or a denial is refused without exchanging", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[state: "forged", code: "c0de"]}")
    assert render(view) =~ "doesn&#39;t match a link from this server"
    refute RetrievalNode.Secrets.get("google_refresh_token")

    {:ok, view, _html} = live(conn, ~p"/google/callback?#{[error: "access_denied"]}")
    assert render(view) =~ "access not granted"
  end

  test "a token from the environment is shown as overriding the stored one", %{conn: conn} do
    Application.put_env(:retrieval_node, :google,
      client_id: "cid",
      client_secret: "csecret",
      refresh_token: "1//env"
    )

    {:ok, _view, html} = live(conn, ~p"/connections")
    assert html =~ "GOOGLE_REFRESH_TOKEN"
    assert html =~ "overrides"
    refute html =~ "disconnect-google"
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

  describe "GitHub" do
    alias RetrievalNode.GitHub.OAuth, as: GitHubOAuth
    alias RetrievalNode.Secrets

    setup do
      prev = %{
        github: Application.get_env(:retrieval_node, :github),
        req: Application.get_env(:retrieval_node, :github_req_options)
      }

      Application.put_env(:retrieval_node, :github, client_id: "Iv23cid", client_secret: "cs")
      Application.put_env(:retrieval_node, :github_req_options, plug: {Req.Test, __MODULE__})
      GitHubOAuth.invalidate()

      on_exit(fn ->
        GitHubOAuth.invalidate()
        Application.put_env(:retrieval_node, :github, prev.github)
        Application.put_env(:retrieval_node, :github_req_options, prev.req)
      end)

      # interval: long enough that the scheduled poll never fires during a
      # test; the tests send :poll_github themselves.
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/login/device/code" ->
            Req.Test.json(conn, %{
              "device_code" => "dev-1",
              "user_code" => "WDJB-MJHT",
              "verification_uri" => "https://github.com/login/device",
              "interval" => 600,
              "expires_in" => 899
            })

          "/login/oauth/access_token" ->
            Req.Test.json(conn, %{
              "access_token" => "ghu_1",
              "expires_in" => 28_800,
              "refresh_token" => "ghr_1"
            })

          "/user" ->
            Req.Test.json(conn, %{"login" => "octocat"})
        end
      end)

      :ok
    end

    test "device flow: shows the code, stores the token, shows the account", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/connections")
      assert html =~ "not connected"

      view |> element("#connect-github") |> render_click()
      assert view |> element("#github-device") |> render() =~ "WDJB-MJHT"

      send(view.pid, :poll_github)
      html = render_async(view)

      refute html =~ "WDJB-MJHT"
      assert html =~ "@octocat"
      assert Secrets.get("github_refresh_token") == "ghr_1"
      refute html =~ "ghr_1"
      refute html =~ "ghu_1"
      assert has_element?(view, "#disconnect-github")
    end

    test "a denied authorization is reported", %{conn: conn} do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/login/device/code" ->
            Req.Test.json(conn, %{
              "device_code" => "dev-1",
              "user_code" => "WDJB-MJHT",
              "verification_uri" => "https://github.com/login/device",
              "interval" => 600
            })

          "/login/oauth/access_token" ->
            Req.Test.json(conn, %{"error" => "access_denied"})
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/connections")
      view |> element("#connect-github") |> render_click()
      send(view.pid, :poll_github)

      assert view |> element("#github-error") |> render() =~ "Access was denied"
      refute has_element?(view, "#github-device")
    end

    test "disconnect forgets the stored token", %{conn: conn} do
      :ok = Secrets.put("github_refresh_token", "ghr_0")
      {:ok, view, _html} = live(conn, ~p"/connections")
      # The account lookup (and its token refresh) has finished.
      assert render_async(view) =~ "@octocat"

      view |> element("#disconnect-github") |> render_click()

      assert Secrets.get("github_refresh_token") == nil
      assert render(view) =~ "not connected"
    end

    test "without a client id, explains what to configure", %{conn: conn} do
      Application.put_env(:retrieval_node, :github, [])
      {:ok, _view, html} = live(conn, ~p"/connections")
      assert html =~ "GITHUB_CLIENT_ID"
    end
  end
end
