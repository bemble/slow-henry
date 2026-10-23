defmodule RetrievalNode.Google.OAuthTest do
  use ExUnit.Case, async: false

  alias RetrievalNode.Google.OAuth

  setup do
    prev_google = Application.get_env(:retrieval_node, :google)
    prev_req = Application.get_env(:retrieval_node, :google_req_options)

    Application.put_env(:retrieval_node, :google,
      client_id: "cid",
      client_secret: "csecret",
      refresh_token: "rtok"
    )

    Application.put_env(:retrieval_node, :google_req_options, plug: {Req.Test, __MODULE__})
    OAuth.invalidate()

    on_exit(fn ->
      OAuth.invalidate()
      Application.put_env(:retrieval_node, :google, prev_google)
      Application.put_env(:retrieval_node, :google_req_options, prev_req)
    end)
  end

  test "authorize_url asks for offline, read-only Drive + labels access" do
    query =
      OAuth.authorize_url("st", "http://localhost:4000/google/callback")
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert %{
             "client_id" => "cid",
             "access_type" => "offline",
             "state" => "st",
             "redirect_uri" => "http://localhost:4000/google/callback"
           } = query

    assert query["scope"] =~ "drive.readonly"
    assert query["scope"] =~ "drive.labels.readonly"
  end

  test "exchange_code sends the same redirect_uri and returns the refresh token" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:token_request, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "a", "expires_in" => 3600, "refresh_token" => "r"})
    end)

    assert {:ok, "r"} = OAuth.exchange_code("c0de", "http://localhost:4000/google/callback")

    assert_received {:token_request,
                     %{
                       "grant_type" => "authorization_code",
                       "code" => "c0de",
                       "redirect_uri" => "http://localhost:4000/google/callback"
                     }}
  end

  test "configured?/authorized? and use_refresh_token/1" do
    assert OAuth.configured?()
    assert OAuth.authorized?()

    Application.put_env(:retrieval_node, :google, client_id: "cid", client_secret: "s")
    refute OAuth.authorized?()

    :ok = OAuth.use_refresh_token("new")
    assert OAuth.authorized?()
    assert Application.get_env(:retrieval_node, :google)[:refresh_token] == "new"
  end

  test "access_token refreshes once, then serves the cached token" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:token_request, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "atok", "expires_in" => 3600})
    end)

    assert {:ok, "atok"} = OAuth.access_token()

    assert_received {:token_request,
                     %{"grant_type" => "refresh_token", "refresh_token" => "rtok"}}

    assert {:ok, "atok"} = OAuth.access_token()
    refute_received {:token_request, _}
  end

  test "a revoked refresh token is an error, not a crash" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, {:google_oauth, 400, "invalid_grant"}} = OAuth.access_token()
  end

  test "an empty refresh token (GOOGLE_REFRESH_TOKEN=) means not authorized" do
    Application.put_env(:retrieval_node, :google,
      client_id: "cid",
      client_secret: "s",
      refresh_token: ""
    )

    refute OAuth.authorized?()
    assert {:error, :google_not_authorized} = OAuth.access_token()
  end

  test "no refresh token configured means not authorized" do
    Application.put_env(:retrieval_node, :google, client_id: "cid", client_secret: "s")
    assert {:error, :google_not_authorized} = OAuth.access_token()
  end
end
