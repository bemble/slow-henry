defmodule RetrievalNode.Ingest.GitMirrorGitHubAuthTest do
  # async: false — swaps PATH and the global :github / :git_mirror_root config.
  use ExUnit.Case, async: false

  alias RetrievalNode.Ingest.GitMirror

  @moduletag :tmp_dir

  # A fake `git` that records the auth env it gets and answers like GitHub
  # does for a token without access to the repo.
  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/bin/sh
    echo "$GIT_CONFIG_KEY_0 $GIT_CONFIG_VALUE_0" > "#{dir}/env"
    echo "remote: Write access to repository not granted." >&2
    echo "fatal: unable to access 'https://github.com/acme/app.git/': The requested URL returned error: 403" >&2
    exit 128
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)

    prev = %{
      path: System.get_env("PATH"),
      github: Application.get_env(:retrieval_node, :github),
      root: Application.get_env(:retrieval_node, :git_mirror_root)
    }

    System.put_env("PATH", bin <> ":" <> prev.path)
    Application.put_env(:retrieval_node, :github, token: "tok")
    Application.put_env(:retrieval_node, :git_mirror_root, Path.join(dir, "mirrors"))

    on_exit(fn ->
      System.put_env("PATH", prev.path)
      Application.put_env(:retrieval_node, :github, prev.github)
      Application.put_env(:retrieval_node, :git_mirror_root, prev.root)
    end)

    %{dir: dir}
  end

  test "github.com gets the token through the environment; a refusal is explained",
       %{dir: dir} do
    assert {:error, {:git, 128, msg}} =
             GitMirror.ensure_mirror("acme/app", "https://github.com/acme/app.git")

    assert msg =~ "is the GitHub App installed on this repo"
    assert msg =~ "returned error: 403"

    basic = Base.encode64("x-access-token:tok")

    assert File.read!(Path.join(dir, "env")) ==
             "http.https://github.com/.extraheader AUTHORIZATION: basic #{basic}\n"
  end

  test "other hosts get no token and git's own message", %{dir: dir} do
    assert {:error, {:git, 128, msg}} =
             GitMirror.ensure_mirror("acme/app", "https://gitlab.com/acme/app.git")

    refute msg =~ "GitHub App"
    assert File.read!(Path.join(dir, "env")) == " \n"
  end
end
