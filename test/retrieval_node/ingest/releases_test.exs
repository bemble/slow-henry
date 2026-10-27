defmodule RetrievalNode.Ingest.ReleasesTest do
  # async: false — ReleaseRepo mutates the global :git_mirror_root config.
  use ExUnit.Case, async: false

  alias RetrievalNode.Ingest.{GitMirror, Releases}
  alias RetrievalNode.ReleaseRepo

  setup do
    %{shas: ReleaseRepo.build!("acme/app")}
  end

  # Newest first, as GitHub.releases/1 lists them.
  defp releases(shas) do
    [
      release("v1.0.1", "2026-03-01T00:00:00Z", shas),
      release("v1.1.0", "2026-02-10T00:00:00Z", shas),
      release("v1.1.0b1", "2026-02-01T00:00:00Z", shas, prerelease: true),
      release("v1.0.0", "2026-01-01T00:00:00Z", shas)
    ]
  end

  defp release(tag, published_at, shas, opts \\ []) do
    %{
      tag: tag,
      name: nil,
      notes: "Notes of #{tag}",
      url: "https://github.com/acme/app/releases/tag/#{tag}",
      prerelease: Keyword.get(opts, :prerelease, false),
      published_at: published_at,
      author: "alice",
      commit: shas[tag]
    }
  end

  defp changes_of(tag, shas) do
    all = releases(shas)
    i = Enum.find_index(all, &(&1.tag == tag))
    Releases.changes("acme/app", Enum.at(all, i), Enum.drop(all, i + 1))
  end

  describe "GitMirror" do
    test "log/4 is the first-parent history of a range, newest first", %{shas: shas} do
      assert {:ok, commits} = GitMirror.log("acme/app", shas["v1.0.0"], shas["v1.1.0"], 10)

      assert commits == [
               %{subject: "Bump version", body: ""},
               %{subject: "Merge pull request #2 from acme/feature", body: "Fix logout"}
             ]

      assert {:ok, [_, _]} = GitMirror.log("acme/app", nil, shas["v1.0.0"], 10)
      assert {:ok, [_]} = GitMirror.log("acme/app", nil, shas["v1.0.0"], 1)
      assert {:error, :invalid_ref} = GitMirror.log("acme/app", "--all", shas["v1.0.0"], 1)
    end

    test "ancestor?/3", %{shas: shas} do
      assert GitMirror.ancestor?("acme/app", shas["v1.0.0"], shas["v1.1.0"])
      assert GitMirror.ancestor?("acme/app", shas["v1.1.0"], shas["v1.1.0"])
      refute GitMirror.ancestor?("acme/app", shas["v1.1.0"], shas["v1.0.1"])
      refute GitMirror.ancestor?("acme/app", String.duplicate("a", 40), shas["v1.0.0"])
      refute GitMirror.ancestor?("acme/app", "-x", shas["v1.0.0"])
    end
  end

  describe "changes/3" do
    test "a stable release skips the pre-releases before it", %{shas: shas} do
      assert %{previous: "v1.0.0", prs: [{2, "Fix logout"}], others: ["Bump version"]} =
               changes_of("v1.1.0", shas)
    end

    test "a pre-release is compared to the release before it", %{shas: shas} do
      assert %{previous: "v1.0.0", prs: [{2, "Fix logout"}], others: []} =
               changes_of("v1.1.0b1", shas)
    end

    test "a maintenance release is compared to its own branch", %{shas: shas} do
      assert %{previous: "v1.0.0", prs: [{3, "Fix crash"}], others: []} =
               changes_of("v1.0.1", shas)
    end

    test "the first release covers the whole history", %{shas: shas} do
      assert %{previous: nil, prs: [{1, "Add login"}], others: ["Initial commit"]} =
               changes_of("v1.0.0", shas)
    end

    test "a commit not in the mirror (or no commit) is :unknown", %{shas: shas} do
      [_, release | older] = releases(shas)
      missing = %{release | commit: String.duplicate("a", 40)}
      assert Releases.changes("acme/app", missing, older) == :unknown
      assert Releases.changes("acme/app", %{release | commit: nil}, older) == :unknown
    end
  end

  test "parse/1 reads squash and merge commits, oldest first, each PR once" do
    commits = [
      %{subject: "Revert \"Add x (#5)\" (#6)", body: ""},
      %{subject: "Merge pull request #4 from a/b", body: ""},
      %{subject: "Merge pull request #3 from a/c", body: "Better title\n\nmore"},
      %{subject: "Add x (#5)", body: ""},
      %{subject: "Add x again (#5)", body: ""},
      %{subject: "chore: bump", body: ""}
    ]

    assert Releases.parse(commits) == %{
             prs: [
               {5, "Add x again"},
               {3, "Better title"},
               {4, "Merge pull request #4 from a/b"},
               {6, "Revert \"Add x (#5)\""}
             ],
             others: ["chore: bump"]
           }
  end

  test "name/1" do
    assert Releases.name(%{tag: "v1", name: nil}) == "Release v1"
    assert Releases.name(%{tag: "v1", name: "v1"}) == "Release v1"
    assert Releases.name(%{tag: "v1", name: "Spring"}) == "Release v1: Spring"
  end

  describe "render/3" do
    test "header, notes, PRs and other commits", %{shas: shas} do
      release = %{release("v1.1.0", "2026-02-10T08:00:00Z", shas) | name: "Spring"}
      text = Releases.render("acme/app", release, changes_of("v1.1.0", shas))

      assert text == """
             # Spring

             Release v1.1.0 of acme/app, published 2026-02-10 by @alice
             https://github.com/acme/app/releases/tag/v1.1.0
             Since: v1.0.0

             Notes of v1.1.0

             ## Pull requests

             - #2 Fix logout

             ## Other commits

             - Bump version
             """
    end

    test "a pre-release, unknown changes, no notes", %{shas: shas} do
      release = %{
        release("v2.0.0b1", "2026-04-01T00:00:00Z", shas, prerelease: true)
        | notes: nil
      }

      assert Releases.render("acme/app", release, :unknown) == """
             # v2.0.0b1

             Release v2.0.0b1 of acme/app, published 2026-04-01 by @alice, pre-release
             https://github.com/acme/app/releases/tag/v2.0.0b1
             """
    end

    test "caps the listed lines", %{shas: shas} do
      changes = %{
        previous: nil,
        prs: for(n <- 1..299, do: {n, "PR #{n}"}),
        others: ~w(one two three)
      }

      text = Releases.render("acme/app", release("v1.0.0", "2026-01-01T00:00:00Z", shas), changes)

      assert text =~ "Since: the beginning of the history"
      assert text =~ "- #299 PR 299\n\n## Other commits\n\n- one\n\n… and 2 more\n"
      refute text =~ "- two"
    end
  end
end
