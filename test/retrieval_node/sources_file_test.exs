defmodule RetrievalNode.SourcesFileTest do
  use RetrievalNode.DataCase, async: true
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.{DriveSync, JiraSync, PullRequestSync, RepoSync}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}
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

      assert {:error,
              "[[git]] #1: `active`, `pull_requests`, `open_pull_requests` and `bot_pull_requests` must be true or false"} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"active" => "no"})]})
    end

    test "rejects duplicate names and urls" do
      assert {:error, "duplicate name \"adr\""} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("adr", @url_b)]})

      assert {:error, "duplicate url " <> _} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a), git("other", @url_a)]})
    end

    test "accepts a leading dot in names like .github" do
      assert {:ok, [%{name: ".github"}]} = SourcesFile.parse(%{"git" => [git(".github", @url_a)]})
    end

    test "rejects names that are just a dot or path traversal patterns" do
      invalid_names = [".", "..", "..github", ".-x", "./x", "../etc"]

      Enum.each(invalid_names, fn invalid_name ->
        assert {:error, "[[git]] #1: invalid name " <> _} =
                 SourcesFile.parse(%{"git" => [git(invalid_name, @url_a)]})
      end)
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

    test "a full pass upgrades a repo sync still waiting" do
      source = source!("adr", @url_a)
      {:ok, _} = Oban.insert(RepoSync.new(%{"source_id" => source.id}))

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"exclude" => ["docs"]})]})

      SourcesFile.apply(entries)

      assert [%{args: %{"mode" => "full"}}] =
               Repo.all(from j in Oban.Job, where: j.worker == ^inspect(RepoSync))
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

  describe "open_pull_requests" do
    defp prs!(source, config) do
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a, config)]})
      SourcesFile.apply(entries)
      Repo.get!(Source, source.id)
    end

    test "is stored only when set, and must be a boolean" do
      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{
                 "git" => [
                   git("adr", @url_a, %{"pull_requests" => true, "open_pull_requests" => true})
                 ]
               })

      assert config == %{"pull_requests" => true, "open_pull_requests" => true}

      assert {:error, _} =
               SourcesFile.parse(%{
                 "git" => [git("adr", @url_a, %{"open_pull_requests" => "yes"})]
               })
    end

    test "turning it on clears the PR watermark and queues a PR sync, never a repo pass" do
      source = source!("adr", @url_a)
      prs!(source, %{"pull_requests" => true})
      Repo.delete_all(Oban.Job)

      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-03-01T00:00:00Z"},
        status: :idle
      })

      prs!(source, %{"pull_requests" => true, "open_pull_requests" => true})

      assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{"last_sha" => "abc"}
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
      refute_enqueued(worker: RepoSync)
    end

    test "turning it or pull_requests off queues a PR sync, which removes them" do
      source = source!("adr", @url_a)
      prs!(source, %{"pull_requests" => true, "open_pull_requests" => true})
      Repo.delete_all(Oban.Job)

      source = prs!(source, %{"pull_requests" => true})
      assert source.config == %{"pull_requests" => true}
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
      Repo.delete_all(Oban.Job)

      source = prs!(source, %{})
      assert source.config == %{}
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
      refute_enqueued(worker: RepoSync)
    end

    test "is ignored without pull_requests" do
      source = source!("adr", @url_a)
      prs!(source, %{"open_pull_requests" => true})
      refute_enqueued(worker: PullRequestSync)
    end
  end

  describe "bot_pull_requests" do
    @open %{"pull_requests" => true, "open_pull_requests" => true}

    test "is stored only when set, and must be a boolean" do
      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{
                 "git" => [git("adr", @url_a, Map.put(@open, "bot_pull_requests", true))]
               })

      assert config == Map.put(@open, "bot_pull_requests", true)

      assert {:error, _} =
               SourcesFile.parse(%{
                 "git" => [git("adr", @url_a, Map.put(@open, "bot_pull_requests", 1))]
               })
    end

    test "turning it on clears the PR watermark and queues a PR sync; off queues one too" do
      source = source!("adr", @url_a)
      prs!(source, @open)
      Repo.delete_all(Oban.Job)

      Repo.insert!(%SyncState{
        source_id: source.id,
        cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-03-01T00:00:00Z"},
        status: :idle
      })

      prs!(source, Map.put(@open, "bot_pull_requests", true))

      assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{"last_sha" => "abc"}
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
      refute_enqueued(worker: RepoSync)
      Repo.delete_all(Oban.Job)

      prs!(source, @open)
      assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
    end

    test "is ignored without open_pull_requests" do
      source = source!("adr", @url_a)
      prs!(source, %{"pull_requests" => true})
      Repo.delete_all(Oban.Job)

      prs!(source, %{"pull_requests" => true, "bot_pull_requests" => true})
      refute_enqueued(worker: PullRequestSync)
    end
  end

  describe "max_age" do
    test "is stored only when set, and must be a number and a unit" do
      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"max_age" => "2y"})]})

      assert config == %{"max_age" => "2y"}

      assert {:ok, [%{config: %{}}]} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      for bad <- ["2 years", 2, "0d"] do
        assert {:error, "[[git]] #1: `max_age` must be" <> _} =
                 SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"max_age" => bad})]})
      end
    end

    test "changing it clears the PR watermark and queues a PR sync, never a repo pass" do
      source = source!("adr", @url_a)
      prs!(source, %{"pull_requests" => true})

      for age <- ["2y", "6m", nil] do
        Repo.delete_all(Oban.Job)

        Repo.insert!(
          %SyncState{
            source_id: source.id,
            cursor: %{"last_sha" => "abc", "prs_updated_since" => "2026-03-01T00:00:00Z"},
            status: :idle
          },
          on_conflict: {:replace, [:cursor]},
          conflict_target: :source_id
        )

        prs!(
          source,
          Map.reject(%{"pull_requests" => true, "max_age" => age}, &is_nil(elem(&1, 1)))
        )

        assert Repo.get_by!(SyncState, source_id: source.id).cursor == %{"last_sha" => "abc"}
        assert_enqueued(worker: PullRequestSync, args: %{"source_id" => source.id})
        refute_enqueued(worker: RepoSync)
      end
    end

    test "without pull_requests, changing it queues nothing" do
      source = source!("adr", @url_a)
      prs!(source, %{"max_age" => "2y"})
      refute_enqueued(worker: PullRequestSync)
      refute_enqueued(worker: RepoSync)
    end

    test "is written back" do
      {:ok, entries} =
        SourcesFile.parse(%{
          "git" => [git("adr", @url_a, %{"pull_requests" => true, "max_age" => "18m"})]
        })

      assert SourcesFile.encode(entries) =~ ~s(max_age = "18m")
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

    test "include_labels defaults to the Classification filter, stored only when changed" do
      default = %{
        "label" => "Classification",
        "values" => ["Public", "Internal"],
        "unlabeled" => true
      }

      assert {:ok, [%{config: config}]} = SourcesFile.parse(%{"drive" => %{}})
      refute Map.has_key?(config, "include_labels")

      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{"drive" => %{"include_labels" => [default]}})

      refute Map.has_key?(config, "include_labels")

      assert {:ok, [%{config: %{"include_labels" => []}}]} =
               SourcesFile.parse(%{"drive" => %{"include_labels" => []}})

      assert {:ok, [%{config: %{"include_labels" => filters}}]} =
               SourcesFile.parse(%{
                 "drive" => %{
                   "include_labels" => [default, %{"label" => "Team", "values" => ["Cloud"]}]
                 }
               })

      assert filters == [
               default,
               %{"label" => "Team", "values" => ["Cloud"], "unlabeled" => false}
             ]
    end

    test "rejects bad label filters" do
      bad = fn filters -> SourcesFile.parse(%{"drive" => %{"include_labels" => filters}}) end

      assert {:error, "[drive]: `include_labels` must be an array of tables"} = bad.("x")
      assert {:error, "[drive]: include_labels #1: must be a table"} = bad.(["x"])

      assert {:error, "[drive]: include_labels #1: `label` must be a non-empty string"} =
               bad.([%{"label" => " ", "values" => ["A"]}])

      assert {:error, "[drive]: include_labels #1: `values` must be a list of choice names"} =
               bad.([%{"label" => "A", "values" => "B"}])

      assert {:error, "[drive]: include_labels #1: `unlabeled` must be true or false"} =
               bad.([%{"label" => "A", "unlabeled" => "yes"}])

      assert {:error, "[drive]: include_labels #1: matches no doc" <> _} =
               bad.([%{"label" => "A"}])

      assert {:error, "[drive]: include_labels #1: unknown key(s) choices"} =
               bad.([%{"label" => "A", "choices" => ["B"]}])

      assert {:error, "[drive]: duplicate label in `include_labels`"} =
               bad.([
                 %{"label" => "A", "values" => ["B"]},
                 %{"label" => "a", "unlabeled" => true}
               ])
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

    test "re-activating a deny-policy source updates it but queues no sync" do
      denied =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "snitun",
          identifier: @url_b,
          active: false,
          policy: :deny
        })

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("snitun", @url_b, %{"pull_requests" => true})]})

      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{active: true, policy: :deny} = Repo.get!(Source, denied.id)
      refute_enqueued(worker: RepoSync)
      refute_enqueued(worker: PullRequestSync)
    end
  end

  describe "config and slugs" do
    test "an unchanged entry keeps the pinned slug" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr",
          identifier: @url_a,
          config: %{"mirror_slug" => "adr-old"}
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})

      assert {:ok, [{:unchanged, _}]} = SourcesFile.plan(entries)
      assert {:ok, _} = SourcesFile.apply(entries)
      assert %{config: %{"mirror_slug" => "adr-old"}} = Repo.get!(Source, s.id)
    end

    test "renaming pins the old slug next to the file's options, without a full pass" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr-old",
          identifier: @url_a,
          config: %{"exclude" => ["docs"]}
        })

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"exclude" => ["docs"]})]})

      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr", config: %{"mirror_slug" => "adr-old", "exclude" => ["docs"]}} =
               Repo.get!(Source, s.id)

      refute_enqueued(worker: RepoSync)
    end

    test "changing options keeps an existing mirror_slug" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr",
          identifier: @url_a,
          config: %{"mirror_slug" => "pinned"}
        })

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a, %{"exclude" => ["docs"]})]})

      assert {:ok, [{:update, _, _}]} = SourcesFile.apply(entries)

      assert %{config: %{"mirror_slug" => "pinned", "exclude" => ["docs"]}} =
               Repo.get!(Source, s.id)

      assert_enqueued(worker: RepoSync, args: %{"source_id" => s.id, "mode" => "full"})
    end

    test "renaming leaves an existing mirror_slug alone" do
      s =
        Repo.insert!(%Source{
          source_type: :git_repo,
          name: "adr-old",
          identifier: @url_a,
          config: %{"mirror_slug" => "pinned"}
        })

      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_a)]})
      assert {:ok, _} = SourcesFile.apply(entries)

      assert %{name: "adr", config: %{"mirror_slug" => "pinned"}} = Repo.get!(Source, s.id)
    end

    test "an add that reuses an inactive source's slug is rejected" do
      source!("adr", @url_a, false)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_b)]})

      assert {:error, msg} = SourcesFile.plan(entries)
      assert msg =~ ~s|name "adr" is already the mirror slug of #{@url_a} (inactive)|
      assert {:error, ^msg} = SourcesFile.apply(entries)
      refute Repo.get_by(Source, identifier: @url_b)
    end

    test "changing a url while keeping the name is rejected" do
      source!("adr", @url_a)
      {:ok, entries} = SourcesFile.parse(%{"git" => [git("adr", @url_b)]})

      assert {:error, msg} = SourcesFile.plan(entries)
      assert msg =~ "#{@url_a} (active)"
      assert %{active: true} = Repo.get_by!(Source, identifier: @url_a)
    end

    test "an add that reuses a renamed source's pinned slug is rejected" do
      Repo.insert!(%Source{
        source_type: :git_repo,
        name: "adr",
        identifier: @url_a,
        config: %{"mirror_slug" => "adr-old"}
      })

      {:ok, entries} =
        SourcesFile.parse(%{"git" => [git("adr", @url_a), git("adr-old", @url_b)]})

      assert {:error, "name \"adr-old\" is already the mirror slug of " <> _} =
               SourcesFile.plan(entries)
    end
  end

  describe "Mix.Tasks.Rn.Sources.parse_args!/1" do
    alias Mix.Tasks.Rn.Sources, as: Task

    test "accepts known switches" do
      assert [dry_run: true, file: "x.toml"] = Task.parse_args!(["--dry-run", "--file", "x.toml"])
    end

    test "rejects invalid switches, missing values and positional args" do
      assert_raise Mix.Error, ~r/invalid option.*--dryrun/, fn ->
        Task.parse_args!(["--dryrun"])
      end

      assert_raise Mix.Error, ~r/invalid option.*--file/, fn -> Task.parse_args!(["--file"]) end

      assert_raise Mix.Error, ~r/unexpected argument.*extra/, fn ->
        Task.parse_args!(["extra"])
      end
    end
  end

  describe "[[jira]]" do
    test "parses projects, active defaults to true" do
      assert {:ok, [cloud, ops]} =
               SourcesFile.parse(%{
                 "jira" => [%{"project" => "CLOUD"}, %{"project" => "OPS_2", "active" => false}]
               })

      assert cloud == %{
               source_type: :jira_project,
               identifier: "CLOUD",
               name: "Jira: CLOUD",
               active: true,
               config: %{}
             }

      assert %{identifier: "OPS_2", active: false} = ops
    end

    test "assignee, reporter and parent are stored only when on" do
      assert {:ok, [%{config: config}]} =
               SourcesFile.parse(%{
                 "jira" => [
                   %{
                     "project" => "CLOUD",
                     "assignee" => true,
                     "reporter" => false,
                     "parent" => true
                   }
                 ]
               })

      assert config == %{"assignee" => true, "parent" => true}

      assert {:error, "[[jira]] #1: `active`, `assignee`" <> _} =
               SourcesFile.parse(%{"jira" => [%{"project" => "X", "parent" => "yes"}]})
    end

    test "changing an option queues a full pass" do
      jira =
        Repo.insert!(%Source{
          source_type: :jira_project,
          name: "Jira: CLOUD",
          identifier: "CLOUD"
        })

      {:ok, entries} = SourcesFile.parse(%{"jira" => [%{"project" => "CLOUD", "parent" => true}]})
      assert {:ok, [{:update, _, _}]} = SourcesFile.apply(entries)

      assert %{config: %{"parent" => true}} = Repo.get!(Source, jira.id)
      assert_enqueued(worker: JiraSync, args: %{"source_id" => jira.id, "mode" => "full"})
    end

    test "rejects bad projects with their position" do
      bad = fn item -> SourcesFile.parse(%{"jira" => [%{"project" => "OK"}, item]}) end

      assert {:error, "[[jira]] #2: invalid project key" <> _} = bad.(%{"project" => "cloud"})
      assert {:error, "[[jira]] #2: `project`" <> _} = bad.(%{})
      assert {:error, "[[jira]] #2: unknown key(s) jql"} = bad.(%{"project" => "X", "jql" => ""})
      assert {:error, "[[jira]] #2: `active`" <> _} = bad.(%{"project" => "X", "active" => 1})
      assert {:error, "duplicate project \"OK\""} = bad.(%{"project" => "OK"})
      assert {:error, "`jira` must be" <> _} = SourcesFile.parse(%{"jira" => %{}})
    end

    test "adding a project queues a Jira sync; removing it deactivates it" do
      {:ok, entries} = SourcesFile.parse(%{"jira" => [%{"project" => "CLOUD"}]})
      assert {:ok, [{:add, _}]} = SourcesFile.apply(entries)

      jira = Repo.get_by!(Source, source_type: :jira_project, identifier: "CLOUD")
      assert_enqueued(worker: JiraSync, args: %{"source_id" => jira.id})

      assert {:ok, [{:deactivate, _}]} = SourcesFile.apply([])
      assert %{active: false} = Repo.get!(Source, jira.id)
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
              "pull_requests" => true,
              "open_pull_requests" => true
            })
          ],
          "jira" => [
            %{"project" => "CLOUD", "assignee" => true, "parent" => true},
            %{"project" => "OPS", "active" => false}
          ],
          "drive" => %{
            "my_drive" => false,
            "shared_with_me" => true,
            "include" => ["0AbC"],
            "include_labels" => [
              %{"label" => "Sensitivity", "values" => ["Open"]},
              %{"label" => "Team", "values" => [], "unlabeled" => true}
            ]
          }
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

    test "Drive label filters are written even when they are the default" do
      {:ok, [drive]} = SourcesFile.parse(%{"drive" => %{}})
      body = SourcesFile.encode([drive])

      assert body =~ """
             [[drive.include_labels]]
             label = "Classification"
             values = ["Public", "Internal"]
             unlabeled = true
             """

      assert {:ok, doc} = Toml.decode(body)
      assert SourcesFile.parse(doc) == {:ok, [drive]}
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
