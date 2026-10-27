defmodule RetrievalNode.Ingest.SourcesTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Jira

  alias RetrievalNode.Ingest.Workers.{
    JiraSync,
    RepoSync,
    SyncScheduler
  }

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{PendingChunk, Source, SyncState}

  @full_issue %{
    "issues" => [
      %{
        "key" => "PROJ-7",
        "fields" => %{
          "summary" => "Login loops",
          "resolutiondate" => "2026-02-01T09:00:00.000+0000",
          "issuetype" => %{"name" => "Bug"},
          "status" => %{"name" => "Done"},
          "resolution" => %{"name" => "Fixed"},
          "assignee" => %{"displayName" => "Ada Lovelace", "accountId" => "a1"},
          "reporter" => %{"displayName" => "Alan Turing"},
          "parent" => %{
            "key" => "PROJ-1",
            "fields" => %{"summary" => "Auth revamp", "issuetype" => %{"name" => "Epic"}}
          },
          "description" => "the cookie expired"
        }
      }
    ]
  }

  describe "Jira client (pure)" do
    test "build_jql adds a resolutiondate clause a day before the watermark when present" do
      assert Jira.build_jql("PROJ", nil) =~ "project = \"PROJ\" AND statusCategory = Done"
      refute Jira.build_jql("PROJ", nil) =~ "resolutiondate >="

      assert Jira.build_jql("PROJ", "2026-03-01T10:30:00.000+0200") =~
               "resolutiondate >= \"2026-02-28\""
    end

    test "parse_issues renders a header and keeps type, status, people and parent as metadata" do
      assert [issue] =
               Jira.parse_issues(
                 @full_issue,
                 "https://acme.atlassian.net",
                 ~w(assignee reporter parent)
               )

      assert issue.text == """
             # PROJ-7: Login loops
             Type: Bug · Status: Done, Fixed · Resolved: 2026-02-01
             Assignee: Ada Lovelace · Reporter: Alan Turing
             Parent: PROJ-1 (Epic): Auth revamp

             the cookie expired\
             """

      assert issue.metadata == %{
               "issue_key" => "PROJ-7",
               "name" => "PROJ-7: Login loops",
               "url" => "https://acme.atlassian.net/browse/PROJ-7",
               "resolutiondate" => "2026-02-01T09:00:00.000+0000",
               "issue_type" => "Bug",
               "status" => "Done",
               "resolution" => "Fixed",
               "assignee" => "Ada Lovelace",
               "reporter" => "Alan Turing",
               "parent" => "PROJ-1",
               "parent_type" => "Epic",
               "parent_summary" => "Auth revamp"
             }
    end

    test "parse_issues keeps only the optional fields turned on" do
      assert [issue] = Jira.parse_issues(@full_issue, nil, ["reporter"])

      assert issue.text == """
             # PROJ-7: Login loops
             Type: Bug · Status: Done, Fixed · Resolved: 2026-02-01
             Reporter: Alan Turing

             the cookie expired\
             """

      assert issue.metadata["reporter"] == "Alan Turing"

      refute Enum.any?(
               ~w(url assignee parent parent_type parent_summary),
               &Map.has_key?(issue.metadata, &1)
             )
    end

    test "parse_issues leaves unset fields out" do
      body = %{
        "issues" => [%{"key" => "P-1", "fields" => %{"summary" => "Bare", "assignee" => nil}}]
      }

      assert [%{text: "# P-1: Bare", metadata: metadata}] = Jira.parse_issues(body)
      assert metadata == %{"issue_key" => "P-1", "name" => "P-1: Bare"}
    end

    test "parse_issues renders the ADF description as markdown, under the issue heading" do
      body = %{
        "issues" => [
          %{
            "key" => "PROJ-1",
            "fields" => %{
              "summary" => "Fix the bug",
              "resolutiondate" => "2026-02-01T00:00:00.000+0000",
              "description" => %{
                "type" => "doc",
                "content" => [
                  %{
                    "type" => "heading",
                    "attrs" => %{"level" => 1},
                    "content" => [%{"type" => "text", "text" => "Cause"}]
                  },
                  %{
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "text" => "root cause was X"}]
                  }
                ]
              }
            }
          }
        ]
      }

      assert [issue] = Jira.parse_issues(body)
      assert issue.key == "PROJ-1"
      assert issue.text =~ "# PROJ-1: Fix the bug\n"
      assert issue.text =~ "\n\n## Cause\n\nroot cause was X"
    end
  end

  describe "SyncScheduler" do
    setup do
      :ok
    end

    test "git_prs fans out only to git sources with pull_requests = true" do
      opted =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "with-prs",
          identifier: "https://github.com/o/a.git",
          config: %{"pull_requests" => true}
        })

      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "plain",
        identifier: "https://github.com/o/b.git"
      })

      assert :ok = perform_job(SyncScheduler, %{"kind" => "git_prs"})

      assert [%{args: %{"source_id" => id}}] =
               all_enqueued(worker: RetrievalNode.Ingest.Workers.PullRequestSync)

      assert id == opted.id
    end

    test "fans out one sync job per active, allow-policy source of the kind" do
      git = Repo.insert!(%Source{source_type: :git_repo, name: "g", identifier: "file:///g"})

      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "inactive",
        identifier: "file:///x",
        active: false
      })

      Repo.insert!(%Source{source_type: :jira_project, name: "j", identifier: "PROJ"})

      assert :ok = perform_job(SyncScheduler, %{"kind" => "git"})
      assert_enqueued(worker: RepoSync, args: %{"source_id" => git.id})
      refute_enqueued(worker: JiraSync)

      assert :ok = perform_job(SyncScheduler, %{"kind" => "jira"})
      assert_enqueued(worker: JiraSync)
    end
  end

  describe "JiraSync (Req.Test)" do
    setup do
      prev = Application.get_env(:retrieval_node, :jira_req_options)
      prev_creds = Application.get_env(:retrieval_node, :jira)
      Application.put_env(:retrieval_node, :jira_req_options, plug: {Req.Test, __MODULE__})

      Application.put_env(:retrieval_node, :jira,
        base_url: "https://acme.atlassian.net",
        email: "me@example.com",
        api_token: "tok"
      )

      on_exit(fn ->
        Application.put_env(:retrieval_node, :jira_req_options, prev)
        Application.put_env(:retrieval_node, :jira, prev_creds)
      end)

      :ok
    end

    test "follows nextPageToken, staging every page" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      issue = fn key, date ->
        %{"key" => key, "fields" => %{"summary" => key, "resolutiondate" => date}}
      end

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/rest/api/3/search/jql"

        case conn.query_params do
          %{"nextPageToken" => "page2"} ->
            Req.Test.json(conn, %{
              "issues" => [issue.("P-2", "2026-03-02T00:00:00.000+0000")],
              "isLast" => true
            })

          _first ->
            Req.Test.json(conn, %{
              "issues" => [issue.("P-1", "2026-03-01T00:00:00.000+0000")],
              "nextPageToken" => "page2"
            })
        end
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      assert ["jira:P-1", "jira:P-2"] =
               PendingChunk |> Repo.all() |> Enum.map(& &1.natural_key) |> Enum.sort()

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-02T00:00:00.000+0000"
    end

    test "never moves the watermark backwards (the search overlaps by a day)" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"resolutiondate_watermark" => "2026-03-05T00:00:00.000+0000"},
        status: :idle
      })

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "P-1",
              "fields" => %{"summary" => "s", "resolutiondate" => "2026-03-04T00:00:00.000+0000"}
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-05T00:00:00.000+0000"
    end

    test "asks for the project's optional fields; a full pass ignores the watermark" do
      source =
        Repo.insert!(%Source{
          source_type: :jira_project,
          name: "p",
          identifier: "P",
          config: %{"assignee" => true}
        })

      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"resolutiondate_watermark" => "2026-03-05T00:00:00.000+0000"},
        status: :idle
      })

      Req.Test.stub(__MODULE__, fn conn ->
        fields = String.split(conn.query_params["fields"], ",")
        assert "assignee" in fields
        refute "reporter" in fields
        refute conn.query_params["jql"] =~ "resolutiondate >="
        Req.Test.json(conn, @full_issue)
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id, "mode" => "full"})

      [raw] = Repo.all(PendingChunk)
      assert raw.metadata["assignee"] == "Ada Lovelace"
      refute Map.has_key?(raw.metadata, "reporter")
    end

    test "is cancelled without credentials" do
      Application.put_env(:retrieval_node, :jira, [])
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      assert {:cancel, :jira_not_configured} = perform_job(JiraSync, %{"source_id" => source.id})
    end

    test "stages a raw row per resolved issue, advances the watermark" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "proj", identifier: "PROJ"})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "PROJ-42",
              "fields" => %{
                "summary" => "A resolved issue",
                "resolutiondate" => "2026-03-01T00:00:00.000+0000"
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      [raw] = Repo.all(PendingChunk)
      assert raw.natural_key == "jira:PROJ-42"
      assert raw.source_type == "jira_project"
      assert raw.status == "raw"
      assert raw.raw_content =~ "A resolved issue"
      assert raw.metadata["url"] == "https://acme.atlassian.net/browse/PROJ-42"

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-01T00:00:00.000+0000"
    end

    test "no resolved issues still advances nothing but is not an error" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"issues" => []}) end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})
      assert Repo.all(PendingChunk) == []

      state = Repo.get_by!(SyncState, source_id: source.id)
      # Cursor (watermark) stays untouched, but last_synced_at is set (it was nil
      # on the freshly created state) so operational status doesn't read "never"
      # for a project that syncs successfully with no resolved issues.
      refute Map.has_key?(state.cursor, "resolutiondate_watermark")
      refute is_nil(state.last_synced_at)
    end

    test "issues with no resolutiondate stage work and still refresh last_synced_at" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "P-1",
              "fields" => %{"summary" => "no resolution date", "resolutiondate" => nil}
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})
      assert [_row] = Repo.all(PendingChunk)

      state = Repo.get_by!(SyncState, source_id: source.id)
      # new_watermark is nil (no resolutiondate), but last_synced_at is still
      # refreshed — a sync that staged work must not read stale.
      refute Map.has_key?(state.cursor, "resolutiondate_watermark")
      refute is_nil(state.last_synced_at)
    end

    test "a 429 returns {:snooze, _} instead of failing" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:snooze, 30} = perform_job(JiraSync, %{"source_id" => source.id})
    end

    test "a 429 with a non-integer Retry-After falls back to the default (no crash)" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "p", identifier: "P"})

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        # an HTTP-date is RFC-valid but not delta-seconds — must NOT raise
        |> Plug.Conn.put_resp_header("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      assert {:snooze, 60} = perform_job(JiraSync, %{"source_id" => source.id})
    end

    test "an issue whose extracted text is binary stages a deletion entry instead of a content row" do
      source = Repo.insert!(%Source{source_type: :jira_project, name: "proj", identifier: "PROJ"})

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "issues" => [
            %{
              "key" => "PROJ-99",
              "fields" => %{
                # a NUL byte is valid UTF-8 but trips Chunking.binary_content?/1 —
                # defensive: Jira's own ADF extraction shouldn't produce this.
                "summary" => "weird\u0000issue",
                "resolutiondate" => "2026-03-01T00:00:00.000+0000"
              }
            }
          ]
        })
      end)

      assert :ok = perform_job(JiraSync, %{"source_id" => source.id})

      [row] = Repo.all(PendingChunk)
      assert row.natural_key == "jira:PROJ-99"
      assert row.status == "deleted"
      assert row.raw_content == nil

      state = Repo.get_by!(SyncState, source_id: source.id)
      assert state.cursor["resolutiondate_watermark"] == "2026-03-01T00:00:00.000+0000"
    end
  end
end
