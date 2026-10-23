defmodule RetrievalNode.GitHub.OAuthTest do
  # async: false — global app env (:github, :data_dir) and :persistent_term.
  use ExUnit.Case, async: false

  alias RetrievalNode.GitHub.OAuth
  alias RetrievalNode.Secrets

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    prev = %{
      github: Application.get_env(:retrieval_node, :github),
      req: Application.get_env(:retrieval_node, :github_req_options),
      data_dir: Application.get_env(:retrieval_node, :data_dir)
    }

    Application.put_env(:retrieval_node, :github, client_id: "Iv23cid", client_secret: "csecret")
    Application.put_env(:retrieval_node, :github_req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:retrieval_node, :data_dir, dir)
    OAuth.invalidate()

    on_exit(fn ->
      OAuth.invalidate()
      Application.put_env(:retrieval_node, :github, prev.github)
      Application.put_env(:retrieval_node, :github_req_options, prev.req)
      Application.put_env(:retrieval_node, :data_dir, prev.data_dir)
    end)
  end

  defp form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {conn, URI.decode_query(body)}
  end

  test "device flow: start, pending, slow down, then tokens are stored" do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> [:pending, :slow_down, :ok] end)

    Req.Test.stub(__MODULE__, fn conn ->
      {conn, params} = form(conn)
      send(parent, {conn.request_path, params})

      case conn.request_path do
        "/login/device/code" ->
          Req.Test.json(conn, %{
            "device_code" => "dev-1",
            "user_code" => "ABCD-1234",
            "verification_uri" => "https://github.com/login/device",
            "interval" => 5,
            "expires_in" => 899
          })

        "/login/oauth/access_token" ->
          case Agent.get_and_update(agent, fn [h | t] -> {h, t} end) do
            :pending ->
              Req.Test.json(conn, %{"error" => "authorization_pending"})

            :slow_down ->
              Req.Test.json(conn, %{"error" => "slow_down", "interval" => 10})

            :ok ->
              Req.Test.json(conn, %{
                "access_token" => "ghu_1",
                "expires_in" => 28_800,
                "refresh_token" => "ghr_1"
              })
          end
      end
    end)

    assert {:ok, %{device_code: "dev-1", user_code: "ABCD-1234", interval: 5}} =
             OAuth.start_device_flow()

    assert_received {"/login/device/code", %{"client_id" => "Iv23cid"}}

    assert :pending = OAuth.poll_device_flow("dev-1")
    assert {:slow_down, 10} = OAuth.poll_device_flow("dev-1")
    assert :ok = OAuth.poll_device_flow("dev-1")

    assert_received {"/login/oauth/access_token",
                     %{
                       "device_code" => "dev-1",
                       "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
                     }}

    assert Secrets.get("github_refresh_token") == "ghr_1"
    assert OAuth.token_source() == :secrets
    assert {:ok, "ghu_1"} = OAuth.access_token()
  end

  test "an expired access token is refreshed and the rotated refresh token stored" do
    :ok = Secrets.put("github_refresh_token", "ghr_old")
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {conn, params} = form(conn)
      send(parent, {:refresh, params})

      Req.Test.json(conn, %{
        "access_token" => "ghu_new",
        "expires_in" => 28_800,
        "refresh_token" => "ghr_new"
      })
    end)

    assert {:ok, "ghu_new"} = OAuth.access_token()

    assert_received {:refresh,
                     %{
                       "grant_type" => "refresh_token",
                       "refresh_token" => "ghr_old",
                       "client_secret" => "csecret"
                     }}

    assert Secrets.get("github_refresh_token") == "ghr_new"

    # Cached: no second refresh.
    assert {:ok, "ghu_new"} = OAuth.access_token()
    refute_received {:refresh, _}
  end

  test "concurrent callers trigger a single refresh (refresh tokens work once)" do
    :ok = Secrets.put("github_refresh_token", "ghr_old")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(50)

      Req.Test.json(conn, %{
        "access_token" => "ghu_new",
        "expires_in" => 28_800,
        "refresh_token" => "ghr_new"
      })
    end)

    test_pid = self()

    results =
      1..5
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Req.Test.allow(__MODULE__, test_pid, self())
          OAuth.access_token()
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &(&1 == {:ok, "ghu_new"}))
    assert Agent.get(counter, & &1) == 1
  end

  test "GITHUB_TOKEN overrides the stored token; nothing means not authorized" do
    assert {:error, :github_not_authorized} = OAuth.access_token()
    assert OAuth.token_source() == nil

    Application.put_env(:retrieval_node, :github, client_id: "Iv23cid", token: "github_pat_x")
    assert OAuth.token_source() == :env
    assert {:ok, "github_pat_x"} = OAuth.access_token()
  end

  test "forget/0 removes the stored token" do
    :ok = Secrets.put("github_refresh_token", "ghr_1")
    :ok = OAuth.forget()
    assert OAuth.token_source() == nil
  end
end
