defmodule RetrievalNode.Ingest.Workers.IssueSyncTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.IssueSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

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
        config: %{"issues" => true}
      })

    %{source: source}
  end

  defp issue(n, updated, extra \\ %{}) do
    Map.merge(
      %{
        "number" => n,
        "title" => "Problem #{n}",
        "body" => "It breaks #{n}.",
        "url" => "https://github.com/acme/app/issues/#{n}",
        "state" => "OPEN",
        "stateReason" => nil,
        "closedAt" => nil,
        "updatedAt" => updated,
        "author" => %{"login" => "alice", "__typename" => "User"},
        "labels" => %{"nodes" => []},
        "assignees" => %{"nodes" => []},
        "closedByPullRequestsReferences" => %{"nodes" => []},
        "comments" => %{"nodes" => []}
      },
      extra
    )
  end

  defp closed(n, closed_at, extra \\ %{}) do
    issue(
      n,
      closed_at,
      Map.merge(
        %{"state" => "CLOSED", "stateReason" => "COMPLETED", "closedAt" => closed_at},
        extra
      )
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

  defp staged_rows(source) do
    Repo.all(
      from p in PendingChunk,
        where: p.source_id == ^source.id,
        order_by: p.natural_key,
        select: %{
          path: p.metadata["path"],
          status: p.status,
          metadata: p.metadata,
          text: p.raw_content
        }
    )
  end

  defp indexed!(source, path, metadata) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :git_repo,
      chunk_key: "k-#{path}",
      content_hash: "h",
      content: "text",
      context_breadcrumb: path,
      metadata: Map.merge(%{"path" => path}, metadata)
    })
  end

  defp days_ago(days, time \\ "T12:00:00Z"),
    do: Date.to_iso8601(Date.add(Date.utc_today(), -days)) <> time

  test "stages open and closed issues as issues/<n>, across pages, with their metadata", %{
    source: source
  } do
    runner(%{
      nil =>
        {[
           issue(1, "2026-01-01T00:00:00Z", %{
             "labels" => %{"nodes" => [%{"name" => "bug"}, %{"name" => "cloud"}]},
             "assignees" => %{"nodes" => [%{"login" => "bob"}]},
             "comments" => %{
               "nodes" => [
                 %{"body" => "Same here", "author" => %{"login" => "carol"}},
                 %{"body" => "stale", "author" => %{"login" => "stale[bot]"}}
               ]
             }
           })
         ], "c1"},
      "c1" =>
        {[
           closed(2, "2026-01-02T00:00:00Z", %{
             "closedByPullRequestsReferences" => %{"nodes" => [%{"number" => 7}]}
           }),
           closed(3, "2026-01-03T00:00:00Z", %{"stateReason" => "NOT_PLANNED"})
         ], nil}
    })

    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

    assert_received {:search, %{"q" => q}}
    assert q == "repo:acme/app is:issue updated:>=1970-01-01T00:00:00Z sort:updated-asc"

    assert [open, fixed, wontfix] = staged_rows(source)

    assert %{
             "issue" => 1,
             "name" => "Issue #1 [open]: Problem 1",
             "state" => "open",
             "author" => "alice",
             "assignees" => ["bob"],
             "labels" => ["bug", "cloud"],
             "updated_at" => "2026-01-01T00:00:00Z"
           } = open.metadata

    assert open.text =~ "Issue #1 in acme/app by @alice, open\n"
    assert open.text =~ "Labels: bug, cloud\nAssignees: @bob"
    assert open.text =~ "**@carol:** Same here"
    refute open.text =~ "stale"

    assert %{
             "name" => "Issue #2: Problem 2",
             "state" => "closed",
             "state_reason" => "completed",
             "linked_prs" => [7],
             "closed_at" => "2026-01-02T00:00:00Z"
           } = fixed.metadata

    refute Map.has_key?(fixed.metadata, "updated_at")
    assert fixed.text =~ "by @alice, closed 2026-01-02\n"
    assert fixed.text =~ "Linked PRs: #7"

    assert %{"state_reason" => "not_planned"} = wontfix.metadata
    assert wontfix.text =~ "closed 2026-01-03 as not planned"

    assert Repo.get_by!(SyncState, source_id: source.id).cursor["issues_updated_since"] ==
             "2026-01-03T00:00:00Z"
  end

  test "resumes from its own watermark, leaving the other cursor keys", %{source: source} do
    Repo.insert!(%SyncState{
      source_id: source.id,
      cursor: %{
        "last_sha" => "abc",
        "prs_updated_since" => "2026-02-01T00:00:00Z",
        "issues_updated_since" => "2026-03-01T00:00:00Z"
      },
      status: :idle
    })

    runner(%{nil => {[issue(4, "2026-03-02T00:00:00Z")], nil}})
    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

    assert_received {:search, %{"q" => q}}
    assert q =~ "updated:>=2026-03-01T00:00:00Z "

    assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{
             "last_sha" => "abc",
             "prs_updated_since" => "2026-02-01T00:00:00Z",
             "issues_updated_since" => "2026-03-02T00:00:00Z"
           }
  end

  test "an issue a bot opened is kept, marked bot", %{source: source} do
    runner(%{
      nil =>
        {[
           issue(5, "2026-01-01T00:00:00Z", %{
             "author" => %{"login" => "renovate", "__typename" => "Bot"}
           })
         ], nil}
    })

    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})
    assert [%{metadata: %{"bot" => true, "author" => "renovate"}}] = staged_rows(source)
  end

  test "a label change re-stages the issue with a new hash", %{source: source} do
    runner(%{nil => {[closed(6, "2026-01-01T00:00:00Z")], nil}})
    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

    runner(%{
      nil =>
        {[closed(6, "2026-01-01T00:00:00Z", %{"labels" => %{"nodes" => [%{"name" => "bug"}]}})],
         nil}
    })

    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

    assert [first, second] =
             Repo.all(
               from p in PendingChunk,
                 where: p.source_id == ^source.id,
                 order_by: p.id,
                 select: p.content_hash
             )

    assert first != second
  end

  describe "max_age" do
    setup %{source: source} do
      source =
        source
        |> Source.update_changeset(%{config: %{"issues" => true, "max_age" => "30d"}})
        |> Repo.update!()

      %{source: source}
    end

    test "searches from the cutoff, skips issues closed before it, purges what left the window",
         %{source: source} do
      indexed!(source, "issues/1", %{
        "issue" => 1,
        "state" => "closed",
        "closed_at" => days_ago(400)
      })

      indexed!(source, "issues/2", %{
        "issue" => 2,
        "state" => "closed",
        "closed_at" => days_ago(10)
      })

      indexed!(source, "issues/3", %{
        "issue" => 3,
        "state" => "open",
        "updated_at" => days_ago(40)
      })

      indexed!(source, "issues/4", %{
        "issue" => 4,
        "state" => "open",
        "updated_at" => days_ago(10)
      })

      indexed!(source, "pulls/9", %{"pr" => 9, "state" => "merged", "merged_at" => days_ago(400)})

      runner(%{
        nil =>
          {[
             closed(5, days_ago(1), %{"closedAt" => days_ago(400)}),
             closed(6, days_ago(1), %{"closedAt" => days_ago(5)})
           ], nil}
      })

      assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

      assert_received {:search, %{"q" => q}}
      assert q =~ "updated:>=#{days_ago(30, "T00:00:00Z")} "

      assert [
               %{path: "issues/1", status: "deleted"},
               %{path: "issues/3", status: "deleted"},
               %{path: "issues/6", status: "raw"}
             ] = staged_rows(source)
    end
  end

  test "with issues turned off, every issue is deleted and the watermark cleared", %{
    source: source
  } do
    source |> Source.update_changeset(%{config: %{"pull_requests" => true}}) |> Repo.update!()
    indexed!(source, "issues/1", %{"issue" => 1, "state" => "open"})
    indexed!(source, "issues/2", %{"issue" => 2, "state" => "closed"})
    indexed!(source, "pulls/3", %{"pr" => 3})
    indexed!(source, "README.md", %{})

    Repo.insert!(%SyncState{
      source_id: source.id,
      cursor: %{"last_sha" => "abc", "issues_updated_since" => "2026-03-01T00:00:00Z"},
      status: :idle
    })

    # No stub: GitHub is never called.
    assert :ok = perform_job(IssueSync, %{"source_id" => source.id})

    assert [%{path: "issues/1", status: "deleted"}, %{path: "issues/2", status: "deleted"}] =
             staged_rows(source)

    assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{"last_sha" => "abc"}
  end

  test "a non-GitHub source is cancelled", %{source: source} do
    source
    |> Ecto.Changeset.change(identifier: "https://gitlab.com/acme/app.git")
    |> Repo.update!()

    assert {:cancel, :not_a_github_repo} = perform_job(IssueSync, %{"source_id" => source.id})
  end

  test "without a GitHub token the job is cancelled", %{source: source} do
    Application.put_env(:retrieval_node, :github, [])
    assert {:cancel, _} = perform_job(IssueSync, %{"source_id" => source.id})
  end
end
