defmodule RetrievalNode.Ingest.DriveTest do
  use ExUnit.Case, async: false

  alias RetrievalNode.Ingest.Drive

  setup do
    prev = Application.get_env(:retrieval_node, :drive_req_options)
    Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.put_env(:retrieval_node, :drive_req_options, prev) end)
  end

  describe "describe/1" do
    test "a shared drive, a folder, another file, an unknown id" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/drive/v3/drives/0AbC" ->
            Req.Test.json(conn, %{"id" => "0AbC", "name" => "Engineering"})

          "/drive/v3/drives/" <> _ ->
            Plug.Conn.send_resp(conn, 404, "")

          "/drive/v3/files/1fold" ->
            Req.Test.json(conn, %{"name" => "Specs", "mimeType" => Drive.folder_mime()})

          "/drive/v3/files/1doc" ->
            Req.Test.json(conn, %{"name" => "A doc", "mimeType" => Drive.doc_mime()})

          "/drive/v3/files/" <> _ ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, %{name: "Engineering", kind: :shared_drive}} = Drive.describe("0AbC")
      assert {:ok, %{name: "Specs", kind: :folder}} = Drive.describe("1fold")
      assert {:error, :not_a_folder} = Drive.describe("1doc")
      assert {:error, :not_found} = Drive.describe("nope")
    end
  end

  describe "id_from_input/1" do
    test "accepts ids and Drive URLs" do
      assert {:ok, "0ANp5Xo_-k"} = Drive.id_from_input("  0ANp5Xo_-k ")

      assert {:ok, "1abc"} =
               Drive.id_from_input("https://drive.google.com/drive/folders/1abc?usp=sharing")

      assert {:ok, "1abc"} =
               Drive.id_from_input("https://drive.google.com/drive/u/0/folders/1abc")

      assert {:ok, "1abc"} = Drive.id_from_input("https://drive.google.com/open?id=1abc")
      assert :error = Drive.id_from_input("https://example.com/nothing here")
      assert :error = Drive.id_from_input("")
    end
  end
end
