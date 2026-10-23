defmodule RetrievalNodeWeb.SourcesFileStatusTest do
  # async: false — the watcher is a named process writing through the sandbox.
  use RetrievalNodeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RetrievalNode.SourcesFile.Watcher

  @moduletag :tmp_dir

  test "the sources page shows when sources.toml was applied, or why it wasn't", %{
    conn: conn,
    tmp_dir: dir
  } do
    path = Path.join(dir, "sources.toml")
    File.write!(path, ~s([[git]]\nname = "a"\nurl = "https://github.com/acme/a.git"\n))
    start_supervised!({Watcher, path: path, interval_ms: :timer.hours(1)})
    Watcher.check_now()

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~r/applied .* ago/
    assert html =~ "1 source(s) changed"

    File.write!(path, "not = [valid")
    Watcher.check_now()

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "not applied, sources left unchanged"
  end
end
