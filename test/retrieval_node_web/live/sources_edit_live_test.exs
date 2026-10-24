defmodule RetrievalNodeWeb.SourcesEditLiveTest do
  # async: false — the watcher is a named process, the HTTP config global.
  use RetrievalNodeWeb.ConnCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  import Phoenix.LiveViewTest

  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source
  alias RetrievalNode.SourcesFile
  alias RetrievalNode.SourcesFile.Watcher

  @moduletag :tmp_dir

  @initial """
  [[git]]
  name = "adr"
  url = "https://github.com/acme/adr.git"

  [[git]]
  name = "local"
  url = "file:///srv/git/local.git"

  [drive]
  my_drive = true
  include = ["0AbC"]
  """

  setup %{tmp_dir: dir} do
    prev = %{
      github: Application.get_env(:retrieval_node, :github),
      github_req: Application.get_env(:retrieval_node, :github_req_options),
      drive_req: Application.get_env(:retrieval_node, :drive_req_options)
    }

    Application.put_env(:retrieval_node, :github, token: "test-token")
    Application.put_env(:retrieval_node, :github_req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:retrieval_node, :drive_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:retrieval_node, :github, prev.github)
      Application.put_env(:retrieval_node, :github_req_options, prev.github_req)
      Application.put_env(:retrieval_node, :drive_req_options, prev.drive_req)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/user/repos" ->
          Req.Test.json(conn, [
            repo("acme/adr"),
            repo("acme/api", true),
            repo("other/api"),
            repo("acme/web")
          ])

        "/drive/v3/drives/0AbC" ->
          Req.Test.json(conn, %{"id" => "0AbC", "name" => "Engineering"})

        "/drive/v3/drives/" <> _ ->
          Plug.Conn.send_resp(conn, 404, "")

        "/drive/v3/files/1fold" ->
          Req.Test.json(conn, %{
            "name" => "Specs",
            "mimeType" => "application/vnd.google-apps.folder"
          })

        "/drive/v3/files/" <> _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    path = Path.join(dir, "sources.toml")
    File.write!(path, @initial)
    start_supervised!({Watcher, path: path, interval_ms: :timer.hours(1)})
    Watcher.check_now()

    %{path: path}
  end

  defp repo(full_name, private \\ false) do
    %{
      "full_name" => full_name,
      "clone_url" => "https://github.com/#{full_name}.git",
      "private" => private,
      "description" => "The #{full_name} repo"
    }
  end

  defp key(view, name) do
    [_, key] = Regex.run(~r/name="repos\[(r\d+)\]\[name\]" value="#{name}"/, render(view))
    key
  end

  defp saved!(path) do
    {:ok, entries, _hash} = SourcesFile.load_with_hash(path)
    entries
  end

  test "shows the file's repos by section and resolves Drive ids", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    html = render_async(view)

    assert has_element?(view, "#github-repos-form input[value=adr]")
    assert has_element?(view, "#other-repos-form input[value='file:///srv/git/local.git']")
    assert html =~ "Engineering"
    # The picker marks what is already selected.
    assert has_element?(view, "#match-acme-adr button", "Added")
    assert has_element?(view, "#match-acme-web button", "Add")
  end

  test "filters, adds a GitHub repo and saves the file", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)

    view |> form("#repo-search", %{query: "API"}) |> render_change()
    assert has_element?(view, "#match-acme-api")
    assert has_element?(view, "#match-other-api")
    refute has_element?(view, "#match-acme-web")

    view |> element("#match-acme-api button") |> render_click()
    # Same short name: the second one is prefixed with its owner.
    view |> element("#match-other-api button") |> render_click()
    assert has_element?(view, "#github-repos-form input[value=api]")
    assert has_element?(view, "#github-repos-form input[value=other-api]")

    view |> element("#review-button") |> render_click()
    assert has_element?(view, "#review-plan", "Add api, then sync it")
    assert has_element?(view, "#review-plan", "Add other-api, then sync it")
    assert has_element?(view, "#review-plan", "3 source(s) unchanged")

    {:ok, _view, html} =
      view |> element("#save-button") |> render_click() |> follow_redirect(conn, ~p"/")

    assert html =~ "Sources saved and applied."

    assert Enum.map(saved!(path), & &1.name) == [
             "adr",
             "local",
             "api",
             "other-api",
             "Google Drive"
           ]

    assert Repo.get_by!(Source, name: "other-api").identifier ==
             "https://github.com/other/api.git"
  end

  test "edits excludes, removes a repo, adds a URL", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)
    adr = key(view, "adr")

    view |> element("#repo-#{adr} button", "Exclude a path") |> render_click()
    view |> element("#repo-#{adr} button", "Exclude a path") |> render_click()

    view
    |> form("#github-repos-form", %{
      "repos" => %{
        adr => %{
          "name" => "adr",
          "active" => "true",
          "pull_requests" => "true",
          "exclude" => ["docs/*", "  "]
        }
      }
    })
    |> render_change()

    local = key(view, "local")
    view |> element("#repo-#{local} button[title^=Remove]") |> render_click()

    view
    |> form("#add-url-0", %{url: "https://github.com/home-assistant/core.git"})
    |> render_submit()

    view |> element("#review-button") |> render_click()
    assert has_element?(view, "#review-plan", "Deactivate local (its chunks stay searchable)")
    assert has_element?(view, "#review-plan", "Update adr: options changed")
    view |> element("#save-button") |> render_click()

    assert [
             %{name: "adr", config: %{"exclude" => ["docs/*"], "pull_requests" => true}},
             %{name: "core", identifier: "https://github.com/home-assistant/core.git"},
             %{source_type: :drive_folder}
           ] = saved!(path)

    refute Repo.get_by!(Source, name: "local").active
  end

  test "Drive: a pasted folder URL becomes its id", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)

    view |> element("#add-include") |> render_click()

    view
    |> form("#drive-form", %{
      "drive" => %{
        "my_drive" => "false",
        "shared_with_me" => "true",
        "active" => "true",
        "include" => ["0AbC", "https://drive.google.com/drive/folders/1fold?usp=sharing"]
      }
    })
    |> render_change()

    assert has_element?(view, "#drive-include-1[value='1fold']")
    assert render_async(view) =~ "Specs"

    view |> element("#review-button") |> render_click()
    view |> element("#save-button") |> render_click()

    assert %{
             config: %{
               "my_drive" => false,
               "shared_with_me" => true,
               "include" => ["0AbC", "1fold"]
             }
           } =
             List.last(saved!(path))
  end

  test "Drive: label filters are editable", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)

    assert has_element?(view, "#drive-label-0[value='Classification']")
    assert has_element?(view, "#drive-label-values-0[value='Public, Internal']")

    view |> element("#add-label") |> render_click()

    view
    |> form("#drive-form", %{
      "drive" => %{
        "labels" => %{
          "0" => %{"label" => "Classification", "values" => "Public", "unlabeled" => "true"},
          "1" => %{"label" => " Team ", "values" => "Cloud, , Core ", "unlabeled" => "false"}
        }
      }
    })
    |> render_change()

    view |> element("#review-button") |> render_click()
    view |> element("#save-button") |> render_click()

    assert %{
             config: %{
               "include_labels" => [
                 %{"label" => "Classification", "values" => ["Public"], "unlabeled" => true},
                 %{"label" => "Team", "values" => ["Cloud", "Core"], "unlabeled" => false}
               ]
             }
           } = List.last(saved!(path))

    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    view |> element("button[phx-click=remove_label][phx-value-index='0']") |> render_click()
    view |> element("button[phx-click=remove_label][phx-value-index='0']") |> render_click()
    view |> element("#review-button") |> render_click()
    view |> element("#save-button") |> render_click()

    assert %{config: %{"include_labels" => []}} = List.last(saved!(path))
  end

  test "reports invalid input without saving", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)

    view |> form("#add-url-0", %{url: "https://git.example.com/x/adr.git"}) |> render_submit()
    # The name was made unique; force a clash.
    other = key(view, "adr-2")

    view
    |> form("#other-repos-form", %{
      "repos" => %{other => %{"name" => "adr", "active" => "true", "pull_requests" => "false"}}
    })
    |> render_change()

    view |> element("#review-button") |> render_click()
    assert has_element?(view, "#review-error", ~s(duplicate name "adr"))
    refute has_element?(view, "#save-button")
    assert File.read!(path) == @initial
  end

  test "refuses to overwrite a file changed on disk", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, ~p"/sources/edit")
    render_async(view)

    File.write!(path, @initial <> "\n# edited by hand\n")

    view |> element("#review-button") |> render_click()
    html = view |> element("#save-button") |> render_click()

    assert html =~ "changed on disk since this page was loaded"
    assert File.read!(path) =~ "edited by hand"
  end

  test "an invalid file is not editable", %{conn: conn, path: path} do
    File.write!(path, "[[git]]\nname = \"adr\"\n")
    {:ok, view, _html} = live(conn, ~p"/sources/edit")

    assert has_element?(view, "#load-error", "`name` and `url` are required strings")
    refute has_element?(view, "#review-button")
  end

  test "the sources page links to the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> element("#edit-sources") |> render_click() |> follow_redirect(conn)
  end
end
