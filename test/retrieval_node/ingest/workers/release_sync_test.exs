defmodule RetrievalNode.Ingest.Workers.ReleaseSyncTest do
  # async: false — global GitHub and :git_mirror_root config.
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Ecto.Query

  alias RetrievalNode.Ingest.Workers.ReleaseSync
  alias RetrievalNode.ReleaseRepo
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
        config: %{"releases" => true}
      })

    %{source: source, shas: ReleaseRepo.build!("app")}
  end

  defp node(tag, published_at, shas, extra \\ %{}) do
    Map.merge(
      %{
        "tagName" => tag,
        "name" => "",
        "description" => "Notes of #{tag}",
        "url" => "https://github.com/acme/app/releases/tag/#{tag}",
        "isDraft" => false,
        "isPrerelease" => false,
        "publishedAt" => published_at,
        "author" => %{"login" => "alice", "__typename" => "User"},
        "tagCommit" => %{"oid" => shas[tag]}
      },
      extra
    )
  end

  # Newest first, as GitHub lists them.
  defp history(shas) do
    [
      node("v1.0.1", days_ago(10), shas),
      node("v1.1.0", days_ago(20), shas),
      node("v1.1.0b1", days_ago(30), shas, %{"isPrerelease" => true}),
      node("v1.0.0", days_ago(400), shas),
      node("v2.0.0", nil, shas, %{"isDraft" => true, "tagCommit" => nil})
    ]
  end

  # pages: %{cursor_or_nil => {nodes, next_cursor_or_nil}}; records each query.
  defp runner(pages) do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      vars = Jason.decode!(body)["variables"]
      send(parent, {:releases, vars})
      {nodes, next} = Map.fetch!(pages, vars["after"])

      Req.Test.json(conn, %{
        "data" => %{
          "repository" => %{
            "releases" => %{
              "nodes" => nodes,
              "pageInfo" => %{"hasNextPage" => next != nil, "endCursor" => next}
            }
          }
        }
      })
    end)
  end

  defp staged_rows(source) do
    Repo.all(
      from p in PendingChunk,
        where: p.source_id == ^source.id,
        order_by: p.id,
        select: %{
          path: p.metadata["path"],
          status: p.status,
          metadata: p.metadata,
          text: p.raw_content
        }
    )
  end

  # The owner applying the staged rows: chunks with the row's metadata and
  # its hash, the pending rows gone.
  defp apply_staged!(source) do
    for row <- Repo.all(from p in PendingChunk, where: p.source_id == ^source.id) do
      if row.status == "raw" do
        Repo.insert!(%Chunk{
          source_id: source.id,
          source_type: :git_repo,
          repo: "app",
          chunk_key: "k-#{row.metadata["path"]}",
          content_hash: "h",
          content: row.raw_content,
          context_breadcrumb: row.metadata["path"],
          file_hash: row.content_hash,
          metadata: Map.put(row.metadata, "chunk_index", 0)
        })
      else
        Repo.delete_all(
          from c in Chunk, where: fragment("?->>'path'", c.metadata) == ^row.metadata["path"]
        )
      end

      Repo.delete!(row)
    end
  end

  defp days_ago(days), do: Date.to_iso8601(Date.add(Date.utc_today(), -days)) <> "T12:00:00Z"

  test "stages each published release as releases/<tag>, with its PRs from the mirror", %{
    source: source,
    shas: shas
  } do
    runner(%{
      nil => {Enum.take(history(shas), 2), "c1"},
      "c1" => {Enum.drop(history(shas), 2), nil}
    })

    assert :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    assert_received {:releases, %{"owner" => "acme", "name" => "app"}}
    assert_received {:releases, %{"after" => "c1"}}

    rows = staged_rows(source)

    assert Enum.map(rows, & &1.path) ==
             ~w(releases/v1.0.1 releases/v1.1.0 releases/v1.1.0b1 releases/v1.0.0)

    [maint, stable, beta, first] = rows

    assert %{
             "name" => "Release v1.1.0",
             "release" => "v1.1.0",
             "previous" => "v1.0.0",
             "prs" => [2],
             "author" => "alice",
             "url" => "https://github.com/acme/app/releases/tag/v1.1.0",
             "release_key" => _
           } = stable.metadata

    refute Map.has_key?(stable.metadata, "prerelease")

    assert stable.text =~
             "Since: v1.0.0\n\nNotes of v1.1.0\n\n## Pull requests\n\n- #2 Fix logout"

    assert %{"previous" => "v1.0.0", "prs" => [3]} = maint.metadata
    assert %{"prerelease" => true, "prs" => [2]} = beta.metadata
    assert %{"prs" => [1]} = first.metadata
    refute Map.has_key?(first.metadata, "previous")

    assert Repo.get_by!(SyncState, source_id: source.id).last_synced_at
  end

  test "a second run stages only what changed, and deletes what's gone", %{
    source: source,
    shas: shas
  } do
    runner(%{nil => {history(shas), nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    apply_staged!(source)

    runner(%{nil => {history(shas), nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    assert staged_rows(source) == []

    # v1.1.0's notes edited, v1.0.1 deleted on GitHub.
    [_maint, stable | rest] = history(shas)
    runner(%{nil => {[%{stable | "description" => "Edited"} | rest], nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    assert [
             %{path: "releases/v1.0.1", status: "deleted"},
             %{path: "releases/v1.1.0", status: "raw", text: text}
           ] = staged_rows(source)

    assert text =~ "Edited"
  end

  test "a release whose commit isn't fetched yet is staged again until it is", %{
    source: source,
    shas: shas
  } do
    missing = String.duplicate("a", 40)
    release = node("v1.2.0", days_ago(1), shas, %{"tagCommit" => %{"oid" => missing}})
    runner(%{nil => {[release | history(shas)], nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    [unfetched | _] = staged_rows(source)
    assert unfetched.path == "releases/v1.2.0"
    refute Map.has_key?(unfetched.metadata, "prs")
    refute Map.has_key?(unfetched.metadata, "release_key")
    refute unfetched.text =~ "Since:"

    apply_staged!(source)
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    assert [%{path: "releases/v1.2.0"}] = staged_rows(source)
  end

  test "a cleared file_hash (Rechunk) stages the release again", %{source: source, shas: shas} do
    runner(%{nil => {history(shas), nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    apply_staged!(source)

    Repo.update_all(
      from(c in Chunk, where: fragment("?->>'release'", c.metadata) == "v1.0.0"),
      set: [file_hash: nil]
    )

    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    assert [%{path: "releases/v1.0.0"}] = staged_rows(source)
  end

  test "max_age keeps the releases published in the window, still compared to older ones", %{
    source: source,
    shas: shas
  } do
    runner(%{nil => {history(shas), nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    apply_staged!(source)

    source
    |> Ecto.Changeset.change(config: %{"releases" => true, "max_age" => "1y"})
    |> Repo.update!()

    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    # v1.0.0 (400 days old) leaves; v1.1.0 still lists its PRs since it.
    assert [%{path: "releases/v1.0.0", status: "deleted"}] = staged_rows(source)

    Repo.delete_all(PendingChunk)
    Repo.delete_all(Chunk)
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    assert Enum.map(staged_rows(source), & &1.path) ==
             ~w(releases/v1.0.1 releases/v1.1.0 releases/v1.1.0b1)

    assert %{"previous" => "v1.0.0", "prs" => [2]} =
             Enum.at(staged_rows(source), 1).metadata
  end

  test "with releases off, stages the deletion of every release without calling GitHub", %{
    source: source,
    shas: shas
  } do
    runner(%{nil => {history(shas), nil}})
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})
    apply_staged!(source)

    Req.Test.stub(__MODULE__, fn _conn -> flunk("GitHub called") end)
    source |> Ecto.Changeset.change(config: %{}) |> Repo.update!()
    :ok = perform_job(ReleaseSync, %{"source_id" => source.id})

    assert Enum.sort(Enum.map(staged_rows(source), &{&1.path, &1.status})) == [
             {"releases/v1.0.0", "deleted"},
             {"releases/v1.0.1", "deleted"},
             {"releases/v1.1.0", "deleted"},
             {"releases/v1.1.0b1", "deleted"}
           ]
  end

  test "a repo not on GitHub is cancelled", %{source: source} do
    source
    |> Ecto.Changeset.change(identifier: "https://gitlab.com/acme/app.git")
    |> Repo.update!()

    assert {:cancel, :not_a_github_repo} = perform_job(ReleaseSync, %{"source_id" => source.id})
  end
end
