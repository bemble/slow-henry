defmodule RetrievalNode.ReleaseRepo do
  @moduledoc """
  A git repo with a release history, mirrored as `slug` under a throwaway
  `:git_mirror_root` (restored on exit), for the release tests:

      Initial commit
      Add login (#1)                    <- v1.0.0
      |\\
      | Fix crash (#3)                  <- v1.0.1 (maintenance branch)
      Merge pull request #2 from …      <- v1.1.0b1 (pre-release)
      Bump version                      <- v1.1.0

  Returns the commit sha of each tag, by tag.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias RetrievalNode.Ingest.GitMirror

  def build!(slug) do
    root = Path.join(System.tmp_dir!(), "release-repo-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:retrieval_node, :git_mirror_root)
    Application.put_env(:retrieval_node, :git_mirror_root, Path.join(root, "mirrors"))

    on_exit(fn ->
      Application.put_env(:retrieval_node, :git_mirror_root, prev)
      File.rm_rf(root)
    end)

    src = Path.join(root, "src")
    File.mkdir_p!(src)
    git!(src, ["init", "-q", "-b", "main"])
    git!(src, ["config", "user.email", "t@t"])
    git!(src, ["config", "user.name", "t"])

    commit!(src, "a.txt", "Initial commit")
    commit!(src, "b.txt", "Add login (#1)")
    git!(src, ["tag", "v1.0.0"])

    git!(src, ["checkout", "-q", "-b", "feature"])
    commit!(src, "c.txt", "wip logout")
    git!(src, ["checkout", "-q", "main"])

    git!(src, [
      "merge",
      "-q",
      "--no-ff",
      "feature",
      "-m",
      "Merge pull request #2 from acme/feature",
      "-m",
      "Fix logout"
    ])

    git!(src, ["tag", "v1.1.0b1"])
    commit!(src, "d.txt", "Bump version")
    git!(src, ["tag", "v1.1.0"])

    git!(src, ["checkout", "-q", "-b", "maint", "v1.0.0"])
    commit!(src, "e.txt", "Fix crash (#3)")
    git!(src, ["tag", "v1.0.1"])

    {:ok, _} = GitMirror.ensure_mirror(slug, "file://" <> src)

    Map.new(~w(v1.0.0 v1.0.1 v1.1.0b1 v1.1.0), fn tag ->
      {tag, String.trim(git!(src, ["rev-parse", tag <> "^{commit}"]))}
    end)
  end

  defp commit!(src, file, message) do
    File.write!(Path.join(src, file), message)
    git!(src, ["add", "."])
    git!(src, ["commit", "-qm", message])
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end
end
