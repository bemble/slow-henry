defmodule RetrievalNode.Ingest.Workers.PullRequestSyncTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Ecto.Query

  alias RetrievalNode.Ingest.GitHub
  alias RetrievalNode.Ingest.Workers.PullRequestSync
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

  test "records the author and the human reviewers, without bots or AI" do
    review = fn login, typename ->
      %{
        "body" => "",
        "state" => "COMMENTED",
        "author" => %{"login" => login, "__typename" => typename}
      }
    end

    pr =
      GitHub.to_pr(
        "acme/app",
        node(4, "2026-01-01T00:00:00Z", %{
          "reviews" => %{
            "nodes" => [
              review.("carol", "User"),
              review.("copilot-pull-request-reviewer", "Bot"),
              review.("CodeRabbitAI", "User"),
              review.("gemini-code-assist", nil),
              review.("alice", "User"),
              review.("carol", "User"),
              review.("dan", "User"),
              %{"body" => "", "state" => "APPROVED", "author" => nil}
            ]
          }
        })
      )

    assert pr.author == "alice"
    assert pr.reviewers == ["carol", "dan"]
  end

  test "stages author and reviewers as metadata; a new reviewer changes the hash", %{
    source: source
  } do
    approved = %{
      "updatedAt" => "2026-01-02T00:00:00Z",
      "reviews" => %{
        "nodes" => [%{"body" => "", "state" => "APPROVED", "author" => %{"login" => "bob"}}]
      }
    }

    runner(%{nil => {[node(1, "2026-01-01T00:00:00Z")], nil}})
    assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})
    runner(%{nil => {[node(1, "2026-01-01T00:00:00Z", approved)], nil}})
    assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

    assert [first, second] =
             Repo.all(
               from p in PendingChunk,
                 where: p.source_id == ^source.id,
                 order_by: p.id,
                 select: %{metadata: p.metadata, hash: p.content_hash, text: p.raw_content}
             )

    assert %{"author" => "alice", "reviewers" => []} = first.metadata
    assert %{"author" => "alice", "reviewers" => ["bob"]} = second.metadata
    assert first.text == second.text
    assert first.hash != second.hash
  end

  describe "open PRs" do
    setup %{source: source} do
      source =
        source
        |> Source.update_changeset(%{
          config: %{"pull_requests" => true, "open_pull_requests" => true}
        })
        |> Repo.update!()

      %{source: source}
    end

    defp open_node(n, updated, extra \\ %{}),
      do: node(n, updated, Map.merge(%{"state" => "OPEN", "mergedAt" => nil}, extra))

    defp indexed!(source, path, metadata \\ %{}) do
      Repo.insert!(%Chunk{
        source_id: source.id,
        source_type: :git_repo,
        chunk_key: "k-#{path}",
        content_hash: "h",
        content: "text",
        context_breadcrumb: path,
        metadata:
          if(String.starts_with?(path, "pulls/"), do: %{"pr" => 1}, else: %{})
          |> Map.merge(%{"path" => path})
          |> Map.merge(metadata)
      })
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

    test "searches every state; stages open PRs and drafts, not those a bot opened", %{
      source: source
    } do
      runner(%{
        nil =>
          {[
             node(1, "2026-01-01T00:00:00Z", %{"state" => "MERGED"}),
             open_node(2, "2026-01-02T00:00:00Z"),
             open_node(3, "2026-01-03T00:00:00Z", %{"isDraft" => true}),
             open_node(4, "2026-01-04T00:00:00Z", %{
               "author" => %{"login" => "dependabot", "__typename" => "Bot"}
             })
           ], nil}
      })

      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

      assert_received {:search, %{"q" => q}}
      assert q == "repo:acme/app is:pr updated:>=1970-01-01T00:00:00Z sort:updated-asc"

      assert [merged, open, draft] = staged_rows(source)
      assert %{"state" => "merged", "name" => "PR #1: Change 1"} = merged.metadata
      assert merged.text =~ "by @alice, merged 2026-01-01"

      assert %{"state" => "open", "name" => "PR #2 [open]: Change 2"} = open.metadata
      refute Map.has_key?(open.metadata, "merged_at")
      refute Map.has_key?(open.metadata, "draft")
      assert open.text =~ "by @alice, open\n"

      assert %{"state" => "open", "draft" => true} = draft.metadata
      assert draft.text =~ "open (draft)"

      # The bot's PR is skipped, but the watermark still moves past it.
      assert Repo.get_by!(SyncState, source_id: source.id).cursor["prs_updated_since"] ==
               "2026-01-04T00:00:00Z"
    end

    test "with bot_pull_requests, the open PRs bots opened are staged, marked bot", %{
      source: source
    } do
      source
      |> Source.update_changeset(%{
        config: %{
          "pull_requests" => true,
          "open_pull_requests" => true,
          "bot_pull_requests" => true
        }
      })
      |> Repo.update!()

      runner(%{
        nil =>
          {[
             open_node(2, "2026-01-02T00:00:00Z"),
             open_node(4, "2026-01-04T00:00:00Z", %{
               "author" => %{"login" => "dependabot", "__typename" => "Bot"}
             })
           ], nil}
      })

      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

      assert [human, bot] = staged_rows(source)
      refute Map.has_key?(human.metadata, "bot")
      assert %{"state" => "open", "author" => "dependabot", "bot" => true} = bot.metadata
    end

    test "with bot_pull_requests turned off, the open bot PRs still indexed are deleted", %{
      source: source
    } do
      indexed!(source, "pulls/7", %{"state" => "open", "bot" => true})
      indexed!(source, "pulls/8", %{"state" => "open"})
      indexed!(source, "pulls/9", %{"state" => "merged", "bot" => true})
      runner(%{nil => {[], nil}})

      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})
      assert [%{path: "pulls/7", status: "deleted"}] = staged_rows(source)
    end

    test "a PR closed without merge is deleted when indexed, ignored otherwise", %{
      source: source
    } do
      indexed!(source, "pulls/5", %{"state" => "open"})

      runner(%{
        nil =>
          {[
             open_node(5, "2026-01-05T00:00:00Z", %{"state" => "CLOSED"}),
             open_node(6, "2026-01-06T00:00:00Z", %{"state" => "CLOSED"})
           ], nil}
      })

      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})
      assert [%{path: "pulls/5", status: "deleted"}] = staged_rows(source)
    end

    test "a backlog snoozes and the re-run resumes from the watermark", %{source: source} do
      pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

      nodes =
        for n <- 1..301, do: node(n, "2026-01-01T00:#{pad.(div(n, 60))}:#{pad.(rem(n, 60))}Z")

      pages =
        nodes
        |> Enum.chunk_every(50)
        |> Enum.with_index()
        |> Map.new(fn {page, i} ->
          {if(i == 0, do: nil, else: "c#{i}"), {page, if(i < 6, do: "c#{i + 1}")}}
        end)

      runner(pages)
      assert {:snooze, _} = perform_job(PullRequestSync, %{"source_id" => source.id})

      watermark = Repo.get_by!(SyncState, source_id: source.id).cursor["prs_updated_since"]
      assert watermark > "1970-01-01T00:00:00Z"

      runner(%{nil => {[], nil}})
      flush_searches()
      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})
      assert_received {:search, %{"q" => q}}
      assert q =~ "updated:>=#{watermark}"
    end

    defp flush_searches do
      receive do
        {:search, _} -> flush_searches()
      after
        0 -> :ok
      end
    end

    test "with open PRs turned off, the open PRs still indexed are deleted", %{source: source} do
      source
      |> Source.update_changeset(%{config: %{"pull_requests" => true}})
      |> Repo.update!()

      indexed!(source, "pulls/7", %{"state" => "open"})
      indexed!(source, "pulls/8", %{"state" => "merged"})
      runner(%{nil => {[], nil}})

      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})
      assert [%{path: "pulls/7", status: "deleted"}] = staged_rows(source)

      assert_received {:search, %{"q" => q}}
      assert q =~ " is:merged "
    end

    test "with pull_requests turned off, every PR is deleted and the watermark cleared", %{
      source: source
    } do
      source |> Source.update_changeset(%{config: %{}}) |> Repo.update!()
      indexed!(source, "pulls/7", %{"state" => "open"})
      indexed!(source, "pulls/8")
      indexed!(source, "README.md")

      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-03-01T00:00:00Z"},
        status: :idle
      })

      # No stub: GitHub is never called.
      assert :ok = perform_job(PullRequestSync, %{"source_id" => source.id})

      assert [%{path: "pulls/7", status: "deleted"}, %{path: "pulls/8", status: "deleted"}] =
               staged_rows(source)

      assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{"last_sha" => "abc"}
    end
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
