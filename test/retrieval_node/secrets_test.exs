defmodule RetrievalNode.SecretsTest do
  # async: false — points the global :data_dir at a tmp dir.
  use ExUnit.Case, async: false

  alias RetrievalNode.Secrets

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    prev = Application.get_env(:retrieval_node, :data_dir)
    Application.put_env(:retrieval_node, :data_dir, Path.join(dir, "data"))
    on_exit(fn -> Application.put_env(:retrieval_node, :data_dir, prev) end)
  end

  test "missing file: nothing stored" do
    assert Secrets.get("google_refresh_token") == nil
    assert :ok = Secrets.delete("google_refresh_token")
  end

  test "put, get, replace, delete — in a 0600 file, without leftovers" do
    assert :ok = Secrets.put("google_refresh_token", "1//first")
    assert :ok = Secrets.put("other_token", "x")
    assert :ok = Secrets.put("google_refresh_token", "1//second")

    assert Secrets.get("google_refresh_token") == "1//second"
    assert Secrets.get("other_token") == "x"
    assert %File.Stat{mode: mode} = File.stat!(Secrets.path())
    assert Bitwise.band(mode, 0o777) == 0o600
    assert File.ls!(Path.dirname(Secrets.path())) == ["secrets.toml"]

    assert :ok = Secrets.delete("google_refresh_token")
    assert Secrets.get("google_refresh_token") == nil
    assert Secrets.get("other_token") == "x"
  end

  test "values round-trip whatever characters they hold" do
    tricky = ~s(a "quoted" \\ back\\slash\nnew line\ttab é)
    :ok = Secrets.put("tricky", tricky)
    assert Secrets.get("tricky") == tricky
  end

  test "keys must be snake_case names" do
    assert_raise ArgumentError, fn -> Secrets.put("Bad Key", "x") end
    assert_raise ArgumentError, fn -> Secrets.put("a = \"b\"\nc", "x") end
  end
end
