defmodule RetrievalNode.SourcesFile.WatcherTest do
  use RetrievalNode.DataCase, async: false
  use Oban.Testing, repo: RetrievalNode.Repo

  alias RetrievalNode.Ingest.Workers.RepoSync
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source
  alias RetrievalNode.SourcesFile.Watcher

  @moduletag :tmp_dir

  defp toml(names) do
    Enum.map_join(names, "\n", fn name ->
      ~s([[git]]\nname = "#{name}"\nurl = "https://github.com/acme/#{name}.git"\n)
    end)
  end

  defp start(path) do
    # A long interval: the test drives checks with check_now/0.
    start_supervised!({Watcher, path: path, interval_ms: :timer.hours(1)})
    Watcher.check_now()
  end

  defp active, do: Repo.all(from s in Source, where: s.active, select: s.name, order_by: s.name)

  test "applies the file at start, then only when its content changes", %{tmp_dir: dir} do
    path = Path.join(dir, "sources.toml")
    File.write!(path, toml(["a"]))

    assert %{applied_at: %DateTime{} = first, changes: 1, error: nil} = start(path)
    assert active() == ["a"]
    assert_enqueued(worker: RepoSync)

    # Same bytes: nothing re-applied.
    File.touch!(path)
    assert %{applied_at: ^first} = Watcher.check_now()

    File.write!(path, toml(["a", "b"]))
    assert %{changes: 1, error: nil} = Watcher.check_now()
    assert active() == ["a", "b"]
  end

  test "an invalid or missing file leaves the sources untouched", %{tmp_dir: dir} do
    path = Path.join(dir, "sources.toml")
    File.write!(path, toml(["a", "b"]))
    start(path)

    File.write!(path, "[[git]]\nname = \"a\"\n")
    assert %{error: "[[git]] #1: `name` and `url` are required strings"} = Watcher.check_now()
    assert active() == ["a", "b"]

    File.rm!(path)
    assert %{error: "cannot read " <> _} = Watcher.check_now()
    assert active() == ["a", "b"]

    # Fixed again: applied, error cleared.
    File.write!(path, toml(["a"]))
    assert %{error: nil, changes: 1} = Watcher.check_now()
    assert active() == ["a"]
  end

  test "status/0 is nil when the watcher isn't running" do
    assert Watcher.status() == nil
  end
end
