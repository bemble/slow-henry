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

  describe "Jira client (pure)" do
    test "build_jql adds a resolutiondate watermark clause when present" do
      assert Jira.build_jql("PROJ", nil) =~ "project = \"PROJ\""
      refute Jira.build_jql("PROJ", nil) =~ "resolutiondate >="
      assert Jira.build_jql("PROJ", "2026-01-01") =~ "resolutiondate >= \"2026-01-01\""
    end

    test "parse_issues extracts summary + ADF description text" do
      body = %{
        "issues" => [
          %{
            "key" => "PROJ-1",
            "fields" => %{
              "summary" => "Fix the bug",
              "resolutiondate" => "2026-02-01T00:00:00.000+0000",
              "description" => %{
                "content" => [%{"content" => [%{"type" => "text", "text" => "root cause was X"}]}]
              }
            }
          }
        ]
      }

      assert [issue] = Jira.parse_issues(body)
      assert issue.key == "PROJ-1"
      assert issue.text =~ "Fix the bug"
      assert issue.text =~ "root cause was X"
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
      Application.put_env(:retrieval_node, :jira_req_options, plug: {Req.Test, __MODULE__})
      on_exit(fn -> Application.put_env(:retrieval_node, :jira_req_options, prev) end)
      :ok
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
