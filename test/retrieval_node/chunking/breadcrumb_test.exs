defmodule RetrievalNode.Chunking.BreadcrumbTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Chunking.Breadcrumb

  test "joins a path prefix with a symbol trail (code)" do
    assert Breadcrumb.build("lib/foo.ex", "Foo > bar") == "lib/foo.ex > Foo > bar"
  end

  test "joins a doc title with a section (docs)" do
    assert Breadcrumb.build("Design Doc", "Overview") == "Design Doc > Overview"
  end

  test "returns just the prefix when the symbol trail is empty or nil" do
    assert Breadcrumb.build("lib/foo.ex", "") == "lib/foo.ex"
    assert Breadcrumb.build("lib/foo.ex", nil) == "lib/foo.ex"
  end

  test "drops a leading heading that repeats the prefix" do
    assert Breadcrumb.build("Design Doc", "Design Doc > Overview") == "Design Doc > Overview"
    assert Breadcrumb.build("CLOUD-1: Fix login", "CLOUD-1: Fix login") == "CLOUD-1: Fix login"

    assert Breadcrumb.build("PR #12: Fix login", "Fix login > Proposed change") ==
             "PR #12: Fix login > Proposed change"
  end

  test "keeps a leading heading that only resembles the prefix" do
    assert Breadcrumb.build("Fix login", "Fix") == "Fix login > Fix"
    assert Breadcrumb.build("lib/foo.ex", "Foo > bar") == "lib/foo.ex > Foo > bar"
  end

  test "prepends the breadcrumb to the chunk text" do
    assert Breadcrumb.prepend("lib/foo.ex > Foo", "def bar, do: :ok") ==
             "lib/foo.ex > Foo\n\ndef bar, do: :ok"
  end

  test "collapses newlines/whitespace in an untrusted symbol trail" do
    assert Breadcrumb.build("lib/foo.ex", "Foo\n> injected") == "lib/foo.ex > Foo > injected"
  end
end
