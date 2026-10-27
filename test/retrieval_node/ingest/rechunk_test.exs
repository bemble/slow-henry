defmodule RetrievalNode.Ingest.RechunkTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Rechunk
  alias RetrievalNode.Ingest.Workers.{DriveSync, JiraSync, PullRequestSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, Source, SyncState}

  defp source(type, name, attrs \\ %{}) do
    Repo.insert!(struct(%Source{source_type: type, name: name, identifier: name}, attrs))
  end

  defp chunk(source, lang, metadata \\ %{}) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: source.source_type,
      lang: lang,
      chunk_key: "key-#{System.unique_integer([:positive])}",
      content_hash: "c",
      content: "text",
      context_breadcrumb: "crumb",
      metadata: metadata,
      file_hash: "file-hash"
    })
  end

  test "clears file_hash on non-code chunks, Drive modified_time and the PR watermark, then enqueues full syncs" do
    with_prs = source(:git_repo, "with-prs", %{config: %{"pull_requests" => true}})
    plain = source(:git_repo, "plain")
    drive = source(:drive_folder, "drive")
    jira = source(:jira_project, "jira")
    off = source(:git_repo, "off", %{active: false})

    code = chunk(plain, "python")
    md = chunk(plain, "markdown")
    other = chunk(plain, nil)
    pr = chunk(with_prs, "markdown", %{"pr" => 1})
    doc = chunk(drive, "markdown", %{"doc_id" => "d", "modified_time" => "2026-01-01T00:00:00Z"})
    issue = chunk(jira, nil)

    Repo.insert!(%SyncState{
      source_id: with_prs.id,
      cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-10-01T00:00:00Z"}
    })

    assert {:ok, %{chunks_reset: 5, enqueued: 5, upgraded: 0, busy: []}} = Rechunk.run()

    assert Repo.reload!(code).file_hash == "file-hash"

    for c <- [md, other, pr, doc, issue] do
      assert Repo.reload!(c).file_hash == nil
    end

    assert Repo.reload!(doc).metadata == %{"doc_id" => "d"}
    assert Repo.get_by!(SyncState, source_id: with_prs.id).cursor == %{"last_sha" => "abc"}

    for source <- [with_prs, plain] do
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id, "full" => true})
    end

    assert_enqueued(worker: PullRequestSync, args: %{"source_id" => with_prs.id})
    assert_enqueued(worker: DriveSync, args: %{"source_id" => drive.id, "mode" => "full"})
    assert_enqueued(worker: JiraSync, args: %{"source_id" => jira.id, "mode" => "full"})

    refute_enqueued(worker: RepoSync, args: %{"source_id" => off.id})
    refute_enqueued(worker: PullRequestSync, args: %{"source_id" => plain.id})
  end

  test "upgrades a sync still waiting, reports one already executing" do
    waiting = source(:git_repo, "waiting")
    running = source(:git_repo, "running")
    {:ok, _} = Oban.insert(RepoSync.new(%{"source_id" => waiting.id}))
    {:ok, job} = Oban.insert(RepoSync.new(%{"source_id" => running.id}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

    assert {:ok, %{enqueued: 0, upgraded: 1, busy: ["running"]}} = Rechunk.run()
    assert_enqueued(worker: RepoSync, args: %{"source_id" => waiting.id, "full" => true})
  end
end
