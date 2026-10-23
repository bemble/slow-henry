defmodule RetrievalNode.Ingest.GitHubTest do
  use ExUnit.Case, async: false

  alias RetrievalNode.Ingest.GitHub

  setup do
    prev = {
      Application.get_env(:retrieval_node, :github),
      Application.get_env(:retrieval_node, :github_req_options)
    }

    Application.put_env(:retrieval_node, :github, token: "test-token")
    Application.put_env(:retrieval_node, :github_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      {github, req} = prev
      Application.put_env(:retrieval_node, :github, github)
      Application.put_env(:retrieval_node, :github_req_options, req)
    end)
  end

  defp repo(full_name, private \\ false) do
    %{
      "full_name" => full_name,
      "clone_url" => "https://github.com/#{full_name}.git",
      "private" => private,
      "description" => nil
    }
  end

  describe "list_repos/0" do
    test "follows the Link header and sorts by full name" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/user/repos"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        case conn.query_params["page"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://api.github.com/user/repos?per_page=100&page=2>; rel="next", ) <>
                ~s(<https://api.github.com/user/repos?per_page=100&page=2>; rel="last")
            )
            |> Req.Test.json([repo("acme/zeta", true), repo("Acme/alpha")])

          "2" ->
            Req.Test.json(conn, [repo("acme/beta")])
        end
      end)

      assert {:ok, repos} = GitHub.list_repos()
      assert Enum.map(repos, & &1.full_name) == ["Acme/alpha", "acme/beta", "acme/zeta"]

      assert %{clone_url: "https://github.com/acme/zeta.git", private: true} = List.last(repos)
    end

    test "reports an unauthorized token" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 401, ""))
      assert {:error, :github_unauthorized} = GitHub.list_repos()
    end
  end
end
