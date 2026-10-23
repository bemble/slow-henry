defmodule RetrievalNode.Ingest.Workers.PullRequestSyncTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Ecto.Query

  alias RetrievalNode.Ingest.GitHub
  alias RetrievalNode.Ingest.Workers.PullRequestSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{PendingChunk, Source, SyncState}

  setup do
    prev = {
      Application.get_env(:retrieval_node, :github),
      Application.get_env(:retrieval_node, :github_req_options)
    }

    # A static token (as GITHUB_TOKEN would give): no OAuth refresh.
    Application.put_env(:retrieval_node, :github, token: "test-token")
    Application.put_env(:retrieval_node, :github_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      {github, req} = prev
      Application.put_env(:retrieval_node, :github, github)
      Application.put_env(:retrieval_node, :github_req_options, req)
    end)

    source =
      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "app",
        identifier: "https://github.com/acme/app.git",
        config: %{"pull_requests" => true}
      })

    %{source: source}
  end

  defp node(n, updated, extra \\ %{}) do
    Map.merge(
      %{
        "number" => n,
        "title" => "Change #{n}",
        "body" => "Why #{n}.",
        "url" => "https://github.com/acme/app/pull/#{n}",
        "mergedAt" => updated,
        "updatedAt" => updated,
        "author" => %{"login" => "alice", "__typename" => "User"},
        "comments" => %{"nodes" => []},
        "reviews" => %{"nodes" => []}
      },
      extra
    )
  end

  # pages: %{cursor_or_nil => {nodes, next_cursor_or_nil}}; records each query.
  defp runner(pages) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      vars = Jason.decode!(body)["variables"]
      send(parent, {:search, vars})
      {nodes, next} = Map.fetch!(pages, vars["after"])

      Req.Test.json(conn, %{
        "data" => %{
          "repository" => %{"id" => "R_1"},
          "search" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => next != nil, "endCursor" => next}
          }
        }
      })
    end)
  end

  defp staged(source) do
    Repo.all(
      from p in PendingChunk,
        where: p.source_id == ^source.id,
        order_by: p.natural_key,
        select: {p.metadata["path"], p.raw_content}
    )
  end

  test "stages each merged PR as pulls/<n>, across pages, and stores the watermark", %{
    source: source
  } do
    runner(%{
      nil => {[node(1, "2026-01-01T00:00:00Z")], "c1"},
      "c1" => {[node(2, "2026-02-01T00:00:00Z")], nil}
    })

    assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

    assert [{"pulls/1", text1}, {"pulls/2", _}] = staged(source)
    assert text1 =~ "# Change 1"
    assert text1 =~ "Pull request #1 in acme/app by @alice, merged 2026-01-01"
    assert text1 =~ "Why 1."

    assert_received {:search, %{"q" => q}}
    assert q == "repo:acme/app is:pr is:merged updated:>=1970-01-01T00:00:00Z sort:updated-asc"

    state = Repo.get_by!(SyncState, source_id: source.id)
    assert state.cursor["prs_updated_since"] == "2026-02-01T00:00:00Z"
  end

  test "resumes from the watermark and keeps the repo's other cursor keys", %{source: source} do
    Repo.insert!(%SyncState{
      source_id: source.id,
      cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-03-01T00:00:00Z"},
      status: :idle
    })

    runner(%{nil => {[], nil}})
    assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

    assert_received {:search, %{"q" => q}}
    assert q =~ "updated:>=2026-03-01T00:00:00Z"
    assert %{"last_sha" => "abc"} = Repo.get_by!(SyncState, source_id: source.id).cursor
  end

  test "renders human comments and reviews, drops bots" do
    pr =
      GitHub.to_pr(
        "acme/app",
        node(3, "2026-01-01T00:00:00Z", %{
          "comments" => %{
            "nodes" => [
              %{
                "body" => "LGTM, but see the edge case",
                "author" => %{"login" => "bob", "__typename" => "User"}
              },
              %{
                "body" => "Coverage 98%",
                "author" => %{"login" => "codecov", "__typename" => "Bot"}
              },
              %{"body" => "deployed", "author" => %{"login" => "deploy[bot]"}}
            ]
          },
          "reviews" => %{
            "nodes" => [
              %{"body" => "Ship it", "state" => "APPROVED", "author" => %{"login" => "carol"}},
              %{"body" => "", "state" => "APPROVED", "author" => %{"login" => "dan"}}
            ]
          }
        })
      )

    assert pr.text =~ "## Comments\n\n**@bob:** LGTM, but see the edge case"
    assert pr.text =~ "## Reviews\n\n**@carol (APPROVED):** Ship it"
    refute pr.text =~ "Coverage"
    refute pr.text =~ "deployed"
    refute pr.text =~ "@dan"
  end

  test "repo_from_url understands github https and ssh URLs" do
    assert {:ok, "acme/app"} = GitHub.repo_from_url("https://github.com/acme/app.git")
    assert {:ok, "acme/app"} = GitHub.repo_from_url("https://github.com/acme/app")

    assert {:ok, "home-assistant/core"} =
             GitHub.repo_from_url("git@github.com:home-assistant/core.git")

    assert :error = GitHub.repo_from_url("https://gitlab.com/acme/app.git")
  end

  test "a non-GitHub source is cancelled, not retried" do
    source =
      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "local",
        identifier: "file:///srv/repo.git",
        config: %{"pull_requests" => true}
      })

    assert {:cancel, :not_a_github_repo} =
             perform_job(PullRequestSync, %{"source_id" => source.id})
  end

  test "GitHub errors fail the job (so Oban retries)", %{source: source} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "API rate limit exceeded"}]})
    end)

    assert {:error, {:github, ["API rate limit exceeded"]}} =
             perform_job(PullRequestSync, %{"source_id" => source.id})
  end

  test "without a GitHub token the job is cancelled", %{source: source} do
    Application.put_env(:retrieval_node, :github, [])

    assert {:cancel, :github_not_authorized} =
             perform_job(PullRequestSync, %{"source_id" => source.id})
  end

  test "a 401 fails the job", %{source: source} do
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 401, ~s({"message":"Bad credentials"})))

    assert {:error, :github_unauthorized} =
             perform_job(PullRequestSync, %{"source_id" => source.id})
  end

  test "a repo the token can't see fails the job instead of finding nothing",
       %{source: source} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"repository" => nil, "search" => %{"nodes" => []}},
        "errors" => [%{"type" => "NOT_FOUND", "message" => "Could not resolve to a Repository"}]
      })
    end)

    assert {:error, {:github_repo_not_visible, "acme/app"}} =
             perform_job(PullRequestSync, %{"source_id" => source.id})
  end
end
