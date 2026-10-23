defmodule RetrievalNode.SourcesFileTest do
  use RetrievalNode.DataCase, async: true
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.{DriveSync, PullRequestSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source
  alias RetrievalNode.SourcesFile

  @url_a "https://github.com/my-org/adr.git"
  @url_b "https://github.com/my-org/other.git"

  defp git(name, url, extra \\ %{}), do: Map.merge(%{"name" => name, "url" => url}, extra)

  defp source!(name, url, active \\ true) do
    Repo.insert!(%Source{source_type: :git_repo, name: name, identifier: url, active: active})
  end

  describe "load/1 and parse/1" do
    @tag :tmp_dir
    test "reads [[git]] tables, active defaults to true", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")

      File.write!(path, """
      [[git]]
      name = "adr"
      url = "#{@url_a}"

      [[git]]
      name = "snitun"
      url = "#{@url_b}"
      active = false
      """)

      assert {:ok,
              [
                %{source_type: :git_repo, name: "adr", identifier: @url_a, active: true},
                %{source_type: :git_repo, name: "snitun", identifier: @url_b, active: false}
              ]} = SourcesFile.load(path)
    end

    test "the default path is DATA_DIR/sources.toml" do
      assert SourcesFile.default_path() == Path.join(RetrievalNode.data_dir(), "sources.toml")
    end

    test "the committed sources.example.toml is valid" do
      assert {:ok, [_ | _]} = SourcesFile.load("sources.example.toml")
    end

    test "an empty document means no git sources" do
      assert {:ok, []} = SourcesFile.parse(%{})
    end

    test "reports a missing file" do
      assert {:error, "cannot read /nope/sources.toml" <> _} =
               SourcesFile.load("/nope/sources.toml")
    end

    test "rejects invalid entries with their position" do
      assert {:error, "[[git]] #1: `name` and `url` are required strings"} =
               SourcesFile.parse(%{"git" => [%{"name" => "adr"}]})

      assert {:error, "[[git]] #2: invalid name \"../etc\""} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("../etc", @url_b)]})

      assert {:error, "[[git]] #1: invalid url \"ext::sh -c id\""} =
               SourcesFile.parse(%{"git" => [git("adr", "ext::sh -c id")]})

      assert {:error, "[[git]] #1: unknown key(s) branch"} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"branch" => "main"})]})

      assert {:error, "[[git]] #1: `active` and `pull_requests` must be true or false"} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"active" => "no"})]})
    end

    test "rejects duplicate names and urls" do
      assert {:error, "duplicate name \"adr\""} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("adr", @url_b)]})

      assert {:error, "duplicate url " <> _} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("other", @url_a)]})
    end
  end

  describe "[[git]] options" do
    test "exclude and pull_requests are stored only when set" do
      assert {:ok, [%{config: config}]} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})
      assert config == %{}

      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{
                 "git" => [
                   git("core", @url_a, %{
                     "exclude" => [
                       "homeassistant/components/*",
                       "!homeassistant/components/cloud"
                     ],
                     "pull_requests" => true
                   })
                 ]
               })

      assert config == %{
               "exclude" => ["homeassistant/components/*", "!homeassistant/components/cloud"],
               "pull_requests" => true
             }

      assert {:error, "[[git]] #1: `exclude` must be a list of path patterns"} =
               SourcesFile.parse(%{"git" => [git("core", @url_a, %{"exclude" => "docs"})]})
    end

    test "a new repo with pull_requests gets both syncs" do
      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"pull_requests" => true})]})

      assert {:ok, [{:add, _}]} = SourcesFile.apply(entries)
      source = Repo.get_by!(Source, identifier: @url_a)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id})
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
    end

    test "changing exclude queues a full pass; turning on pull_requests queues only a PR sync" do
      source = source!("adr", @url_a)

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"exclude" => ["docs"]})]})

      SourcesFile.apply(entries)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id, "mode" => "full"})
      refute_enqueued(worker: PullRequestSync)
      Repo.delete_all(Oban.Job)

      {:ok, entries} =
        SourcesFile.parse(%{
          "git" => [git("adr", @url_a, %{"exclude" => ["docs"], "pull_requests" => true})]
        })

      SourcesFile.apply(entries)
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
      refute_enqueued(worker: RepoSync)
    end
  end

  describe "[drive]" do
    test "parses scope with defaults" do
      assert {:ok, [drive]} = SourcesFile.parse(%{"drive" => %{"include" => ["0AbC", "1x_Y-z"]}})

      assert %{
               source_type: :drive_folder,
               identifier: "drive:me",
               active: true,
               config: %{"my_drive" => true, "include" => ["0AbC", "1x_Y-z"]}
             } = drive
    end

    test "shared_with_me is off by default and stored only when on" do
      assert {:ok, [%{config: config}]} = SourcesFile.parse(%{"drive" => %{}})
      refute Map.has_key?(config, "shared_with_me")

      assert {:ok, [%{config: %{"shared_with_me" => true}}]} =
               SourcesFile.parse(%{"drive" => %{"shared_with_me" => true}})

      assert {:ok, [_]} =
               SourcesFile.parse(%{"drive" => %{"my_drive" => false, "shared_with_me" => true}})

      assert {:error, "[drive]: `my_drive`, `shared_with_me` and `active` must be true or false"} =
               SourcesFile.parse(%{"drive" => %{"shared_with_me" => "yes"}})
    end

    test "rejects bad drive tables and unknown sections" do
      assert {:error, "[drive]: unknown key(s) folders"} =
               SourcesFile.parse(%{"drive" => %{"folders" => []}})

      assert {:error, "[drive]: `include` must be a list of Drive ids"} =
               SourcesFile.parse(%{"drive" => %{"include" => ["a/b"]}})

      assert {:error, "[drive]: nothing to index" <> _} =
               SourcesFile.parse(%{"drive" => %{"my_drive" => false}})

      assert {:error, "unknown section(s) slack"} = SourcesFile.parse(%{"slack" => %{}})
    end

    test "adding Drive queues a sync; changing its scope queues a full pass" do
      {:ok, entries} = SourcesFile.parse(%{"drive" => %{}})
      assert {:ok, [{:add, _}]} = SourcesFile.apply(entries)

      source = Repo.get_by!(Source, source_type: :drive_folder)
      assert_enqueued(worker: DriveSync, args: %{"source_id" => source.id})
      Repo.delete_all(Oban.Job)

      {:ok, entries} = SourcesFile.parse(%{"drive" => %{"include" => ["0AbC"]}})
      assert {:ok, [{:update, _, _}]} = SourcesFile.apply(entries)
      assert %{config: %{"include" => ["0AbC"]}} = Repo.get!(Source, source.id)
      assert_enqueued(worker: DriveSync, args: %{"source_id" => source.id, "mode" => "full"})
    end

    test "removing [drive] deactivates the Drive source" do
      drive =
        Repo.insert!(%Source{
          source_type: :drive_folder,
          name: "Google Drive",
          identifier: "drive:me"
        })

      assert {:ok, [{:deactivate, _}]} = SourcesFile.apply([])
      assert %{active: false} = Repo.get!(Source, drive.id)
    end
  end

  describe "apply/1" do
    test "adds new sources and queues their first sync" do
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:add, _}]} = SourcesFile.apply(entries)

      source = Repo.get_by!(Source, identifier: @url_a)
      assert %{name: "adr", active: true, source_type: :git_repo} = source
      assert_enqueued(worker: RepoSync, args: %{"source_id" => source.id})
    end

    test "is idempotent: a second apply changes nothing" do
      existing = source!("adr", @url_a)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:unchanged, %{id: id}}]} = SourcesFile.apply(entries)
      assert id == existing.id
      refute_enqueued(worker: RepoSync)
    end

    test "deactivates sources missing from the file without deleting them" do
      kept = source!("adr", @url_a)
      gone = source!("snitun", @url_b)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, changes} = SourcesFile.apply(entries)
      assert {:deactivate, %{id: gone.id}} in Enum.map(changes, &strip/1)

      assert %{active: false} = Repo.get!(Source, gone.id)
      assert %{active: true} = Repo.get!(Source, kept.id)
    end

    test "re-activating a source queues a sync; a rename does not" do
      inactive = source!("snitun", @url_b, false)
      renamed = source!("adr-old", @url_a)

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a), git("snitun", @url_b)]})

      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr"} = Repo.get!(Source, renamed.id)
      assert %{active: true} = Repo.get!(Source, inactive.id)
      assert_enqueued(worker: RepoSync, args: %{"source_id" => inactive.id})
      refute_enqueued(worker: RepoSync, args: %{"source_id" => renamed.id})
    end

    test "leaves Jira sources alone" do
      jira =
        Repo.insert!(%Source{
          source_type: :jira_project,
          name: "Jira: CLOUD",
          identifier: "CLOUD"
        })

      assert {:ok, []} = SourcesFile.apply([])
      assert %{active: true} = Repo.get!(Source, jira.id)
    end
  end

  describe "encode/1, load_with_hash/1 and save/3" do
    @describetag :tmp_dir

    defp entries! do
      {:ok, entries} =
        SourcesFile.parse(%{
          "git" => [
            git("adr", @url_a),
            git("core", @url_b, %{
              "active" => false,
              "exclude" => ["docs/*", "!docs/\"quoted\""],
              "pull_requests" => true
            })
          ],
          "drive" => %{"my_drive" => false, "shared_with_me" => true, "include" => ["0AbC"]}
        })

      entries
    end

    test "encoding then parsing gives the same entries back" do
      entries = entries!()
      assert {:ok, doc} = Toml.decode(SourcesFile.encode(entries))
      assert SourcesFile.parse(doc) == {:ok, entries}

      assert {:ok, doc} = Toml.decode(SourcesFile.encode([]))
      assert SourcesFile.parse(doc) == {:ok, []}
    end

    test "only non-default git options are written" do
      {:ok, [adr]} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})
      body = SourcesFile.encode([adr])

      assert body =~ ~s([[git]]\nname = "adr"\nurl = "#{@url_a}"\n)
      refute body =~ "active"
      refute body =~ "exclude"
    end

    test "a missing file reads as no entries; save creates it", %{tmp_dir: dir} do
      path = Path.join([dir, "sub", "sources.toml"])
      assert {:ok, [], nil} = SourcesFile.load_with_hash(path)

      entries = entries!()
      assert {:ok, hash} = SourcesFile.save(path, entries, nil)
      assert {:ok, ^entries, ^hash} = SourcesFile.load_with_hash(path)
      assert hash == SourcesFile.hash(File.read!(path))
    end

    test "refuses to overwrite a file changed since it was read", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")
      File.write!(path, ~s([[git]]\nname = "adr"\nurl = "#{@url_a}"\n))
      {:ok, _entries, hash} = SourcesFile.load_with_hash(path)

      File.write!(path, ~s([[git]]\nname = "other"\nurl = "#{@url_b}"\n))
      assert {:error, :conflict} = SourcesFile.save(path, entries!(), hash)
      assert {:error, :conflict} = SourcesFile.save(path, entries!(), nil)
      assert File.read!(path) =~ "other"
    end

    test "refuses invalid entries without writing", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")
      [adr | _] = entries!()

      assert {:error, "duplicate name \"adr\""} =
               SourcesFile.save(path, [adr, %{adr | identifier: @url_b}], nil)

      refute File.exists?(path)
    end

    test "reports a file it can't write", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")
      File.write!(path, "")
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      assert {:error, "cannot write " <> _} =
               SourcesFile.save(path, entries!(), SourcesFile.hash(""))

      assert File.ls!(dir) == ["sources.toml"]
    end

    test "reports an invalid file", %{tmp_dir: dir} do
      path = Path.join(dir, "sources.toml")
      File.write!(path, "[[git]]\nname = \"adr\"\n")
      assert {:error, "[[git]] #1: " <> _} = SourcesFile.load_with_hash(path)
    end
  end

  defp strip({:deactivate, s}), do: {:deactivate, %{id: s.id}}
  defp strip(other), do: other
end
