defmodule RetrievalNode.Ingest.Workers.DriveSyncTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Ecto.Query

  alias RetrievalNode.Ingest.Drive
  alias RetrievalNode.Ingest.Workers.DriveSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Chunk, PendingChunk, Source, SyncState}

  @labels %{
    "labels" => [
      %{
        "id" => "lbl",
        "properties" => %{"title" => "Classification"},
        "fields" => [
          %{
            "id" => "fld",
            "selectionOptions" => %{
              "choices" => [
                %{"id" => "pub", "properties" => %{"displayName" => "Public"}},
                %{"id" => "int", "properties" => %{"displayName" => "Internal"}},
                %{"id" => "conf", "properties" => %{"displayName" => "Confidential"}}
              ]
            }
          }
        ]
      }
    ]
  }

  setup do
    prev = Application.get_env(:retrieval_node, :drive_req_options)
    Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.put_env(:retrieval_node, :drive_req_options, prev) end)

    source =
      Repo.insert!(%Source{
        source_type: :drive_folder,
        name: "Google Drive",
        identifier: "drive:me",
        config: %{"my_drive" => true, "include" => []}
      })

    %{source: source}
  end

  defp doc(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => "Doc #{id}",
        "mimeType" => Drive.doc_mime(),
        "modifiedTime" => "2026-10-01T10:00:00.000Z",
        "webViewLink" => "https://docs.google.com/document/d/#{id}",
        "owners" => [%{"me" => true}],
        "parents" => ["root"]
      },
      attrs
    )
  end

  defp classified(file, choice),
    do:
      Map.put(file, "labelInfo", %{
        "labels" => [%{"id" => "lbl", "fields" => %{"fld" => %{"selection" => [choice]}}}]
      })

  # Routes the Drive / Labels API by path; `routes` overrides per test.
  defp stub(routes) do
    Req.Test.stub(__MODULE__, &route(Plug.Conn.fetch_query_params(&1), routes))
  end

  defp route(conn, routes) do
    path = conn.request_path

    case Enum.find(routes, fn {match, _fun} -> match.(path, conn.query_params) end) do
      {_match, handler} -> handler.(conn)
      nil -> default_route(conn, path)
    end
  end

  defp default_route(conn, path) do
    cond do
      path == "/v2/labels" ->
        Req.Test.json(conn, @labels)

      path == "/drive/v3/changes/startPageToken" ->
        Req.Test.json(conn, %{"startPageToken" => "tok-1"})

      String.ends_with?(path, "/export") ->
        Req.Test.text(conn, "# #{export_id(path)}\n\nBody of #{export_id(path)}.")

      true ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
    end
  end

  defp export_id(path), do: path |> String.split("/") |> Enum.at(-2)

  defp files(list), do: &Req.Test.json(&1, %{"files" => list})
  defp my_drive?(path, q), do: path == "/drive/v3/files" and q["q"] =~ "'me' in owners"

  defp raw_keys,
    do:
      Repo.all(from p in PendingChunk, where: p.status == "raw", select: p.natural_key)
      |> Enum.sort()

  defp deleted_keys,
    do:
      Repo.all(from p in PendingChunk, where: p.status == "deleted", select: p.natural_key)
      |> Enum.sort()

  defp indexed!(source, doc_id, modified_time) do
    Repo.insert!(%Chunk{
      source_id: source.id,
      source_type: :drive_folder,
      chunk_key: "k-#{doc_id}-#{System.unique_integer([:positive])}",
      content_hash: "h",
      content: "old",
      context_breadcrumb: doc_id,
      metadata: %{"doc_id" => doc_id, "modified_time" => modified_time}
    })
  end

  defp cursor(source), do: Repo.get_by!(SyncState, source_id: source.id).cursor

  describe "full pass (first run)" do
    test "indexes My Drive docs that are unlabelled, Public or Internal; seeds the cursor", %{
      source: source
    } do
      stub([
        {&my_drive?/2,
         files([
           doc("plain"),
           classified(doc("intern"), "int"),
           classified(doc("secret"), "conf")
         ])}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      assert raw_keys() == ["drive:intern", "drive:plain"]
      assert %{"start_page_token" => "tok-1", "backfill_done" => true} = cursor(source)

      row = Repo.one!(from p in PendingChunk, where: p.natural_key == "drive:plain")
      assert row.raw_content =~ "Body of plain"
      assert row.lang == "markdown"

      assert row.metadata == %{
               "doc_id" => "plain",
               "name" => "Doc plain",
               "modified_time" => "2026-10-01T10:00:00.000Z",
               "url" => "https://docs.google.com/document/d/plain"
             }
    end

    test "filters on the label and choices configured on the source", %{source: source} do
      source
      |> Source.update_changeset(%{
        config: %{
          "my_drive" => true,
          "include" => [],
          "include_labels" => [
            %{"label" => "classification", "values" => ["confidential"], "unlabeled" => true}
          ]
        }
      })
      |> Repo.update!()

      stub([
        {&my_drive?/2,
         files([
           doc("plain"),
           classified(doc("pub"), "pub"),
           classified(doc("secret"), "conf")
         ])}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:plain", "drive:secret"]
    end

    test "no label filter: indexes every doc, without asking for labels", %{source: source} do
      source
      |> Source.update_changeset(%{
        config: %{"my_drive" => true, "include" => [], "include_labels" => []}
      })
      |> Repo.update!()

      stub([
        {fn path, _ -> path == "/v2/labels" end,
         fn _ -> flunk("read labels without filters") end},
        {fn path, q -> my_drive?(path, q) and not Map.has_key?(q, "includeLabels") end,
         files([doc("plain"), classified(doc("secret"), "conf")])}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:plain", "drive:secret"]
    end

    test "skips up-to-date docs and deletes indexed docs that are no longer allowed", %{
      source: source
    } do
      indexed!(source, "same", "2026-10-01T10:00:00.000Z")
      indexed!(source, "edited", "2026-09-01T10:00:00.000Z")
      indexed!(source, "now-secret", "2026-10-01T10:00:00.000Z")
      indexed!(source, "deleted", "2026-10-01T10:00:00.000Z")

      stub([
        {fn path, _ -> path == "/drive/v3/files/same/export" end,
         fn _ -> flunk("exported an up-to-date doc") end},
        {&my_drive?/2,
         files([doc("same"), doc("edited"), classified(doc("now-secret"), "conf"), doc("new")])}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id, "mode" => "full"})

      assert raw_keys() == ["drive:edited", "drive:new"]
      assert deleted_keys() == ["drive:deleted", "drive:now-secret"]
    end

    test "shared_with_me adds the docs shared directly with the user", %{source: source} do
      source
      |> Source.update_changeset(%{
        config: %{"my_drive" => true, "shared_with_me" => true, "include" => []}
      })
      |> Repo.update!()

      shared = %{"owners" => [%{"me" => false}], "sharedWithMeTime" => "2026-10-01T09:00:00.000Z"}

      stub([
        {&my_drive?/2, files([doc("mine")])},
        {fn path, q -> path == "/drive/v3/files" and q["q"] =~ "sharedWithMe = true" end,
         files([doc("from-a-colleague", shared), classified(doc("their-secret", shared), "conf")])}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:from-a-colleague", "drive:mine"]
    end

    test "without shared_with_me, shared docs are not listed", %{source: source} do
      stub([
        {&my_drive?/2, files([doc("mine")])},
        {fn path, q -> path == "/drive/v3/files" and q["q"] =~ "sharedWithMe = true" end,
         fn _ -> flunk("listed shared-with-me docs with the option off") end}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:mine"]
    end

    test "covers included shared drives and folder trees", %{source: source} do
      source
      |> Source.update_changeset(%{config: %{"my_drive" => false, "include" => ["drv", "fold"]}})
      |> Repo.update!()

      stub([
        {fn path, _ -> path == "/drive/v3/drives/drv" end, &Req.Test.json(&1, %{"id" => "drv"})},
        {fn path, _ -> path == "/drive/v3/files/fold" end,
         &Req.Test.json(&1, %{"id" => "fold", "mimeType" => Drive.folder_mime()})},
        {fn path, q -> path == "/drive/v3/files" and q["corpora"] == "drive" end,
         files([doc("in-drive", %{"owners" => []})])},
        {fn path, q -> path == "/drive/v3/files" and q["q"] =~ "'fold' in parents" end,
         files([
           doc("in-folder", %{"owners" => []}),
           %{"id" => "sub", "mimeType" => Drive.folder_mime()}
         ])},
        {fn path, q -> path == "/drive/v3/files" and q["q"] =~ "'sub' in parents" end,
         files([doc("in-subfolder", %{"owners" => []})])},
        {&my_drive?/2, fn _ -> flunk("listed My Drive with my_drive = false") end}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:in-drive", "drive:in-folder", "drive:in-subfolder"]
    end

    test "a large backfill is exported in slices: snooze, then continue", %{source: source} do
      docs = for i <- 1..201, do: doc("d#{String.pad_leading("#{i}", 3, "0")}")
      stub([{&my_drive?/2, files(docs)}])

      assert {:snooze, _} = perform_job(DriveSync, %{"source_id" => source.id})
      assert length(raw_keys()) == 200
      refute cursor(source)["backfill_done"]

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert length(raw_keys()) == 201
      assert cursor(source)["backfill_done"]
    end
  end

  describe "changes pass" do
    setup %{source: source} do
      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"start_page_token" => "tok-1", "backfill_done" => true},
        status: :idle
      })

      :ok
    end

    test "follows pagination, exports allowed changes, deletes what is no longer allowed", %{
      source: source
    } do
      indexed!(source, "reclassified", "2026-09-01T00:00:00.000Z")
      indexed!(source, "trashed", "2026-09-01T00:00:00.000Z")

      stub([
        {fn path, q -> path == "/drive/v3/changes" and q["pageToken"] == "tok-1" end,
         &Req.Test.json(&1, %{
           "nextPageToken" => "page-2",
           "changes" => [
             %{"fileId" => "edited", "file" => doc("edited")},
             %{"fileId" => "reclassified", "file" => classified(doc("reclassified"), "conf")}
           ]
         })},
        {fn path, q -> path == "/drive/v3/changes" and q["pageToken"] == "page-2" end,
         &Req.Test.json(&1, %{
           "newStartPageToken" => "tok-2",
           "changes" => [
             %{"fileId" => "trashed", "removed" => true},
             %{
               "fileId" => "not-mine",
               "file" => doc("not-mine", %{"owners" => [%{"me" => false}]})
             }
           ]
         })}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})

      assert raw_keys() == ["drive:edited"]
      assert deleted_keys() == ["drive:reclassified", "drive:trashed"]
      assert cursor(source)["start_page_token"] == "tok-2"
    end

    test "an export failure keeps the cursor so the page is retried", %{source: source} do
      stub([
        {fn path, _ -> path == "/drive/v3/changes" end,
         &Req.Test.json(&1, %{
           "newStartPageToken" => "tok-2",
           "changes" => [%{"fileId" => "a", "file" => doc("a")}]
         })},
        {fn path, _ -> path == "/drive/v3/files/a/export" end,
         &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{}))}
      ])

      assert {:error, :export_incomplete} = perform_job(DriveSync, %{"source_id" => source.id})
      assert cursor(source)["start_page_token"] == "tok-1"
    end

    test "a doc Drive refuses to export (4xx) is skipped, the rest still lands", %{source: source} do
      stub([
        {fn path, _ -> path == "/drive/v3/changes" end,
         &Req.Test.json(&1, %{
           "newStartPageToken" => "tok-2",
           "changes" => [
             %{"fileId" => "huge", "file" => doc("huge")},
             %{"fileId" => "ok", "file" => doc("ok")}
           ]
         })},
        {fn path, _ -> path == "/drive/v3/files/huge/export" end,
         &(&1
           |> Plug.Conn.put_status(403)
           |> Req.Test.json(%{
             "error" => %{"errors" => [%{"reason" => "exportSizeLimitExceeded"}]}
           }))}
      ])

      assert :ok = perform_job(DriveSync, %{"source_id" => source.id})
      assert raw_keys() == ["drive:ok"]
      assert cursor(source)["start_page_token"] == "tok-2"
    end

    test "rate limits snooze", %{source: source} do
      stub([
        {fn path, _ -> path == "/drive/v3/changes" end,
         &(&1
           |> Plug.Conn.put_resp_header("retry-after", "45")
           |> Plug.Conn.put_status(429)
           |> Req.Test.json(%{}))}
      ])

      assert {:snooze, 45} = perform_job(DriveSync, %{"source_id" => source.id})
    end
  end

  test "fails closed when a filtered label can't be read", %{source: source} do
    stub([
      {fn path, _ -> path == "/v2/labels" end, &Req.Test.json(&1, %{"labels" => []})},
      {&my_drive?/2, fn _ -> flunk("listed files without a classification label") end}
    ])

    assert {:error, {:label_not_found, "Classification"}} =
             perform_job(DriveSync, %{"source_id" => source.id})

    assert Repo.all(PendingChunk) == []
  end
end
