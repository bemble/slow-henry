defmodule RetrievalNode.Ingest.PathFilterTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Ingest.PathFilter

  test "home-assistant/core: every integration except cloud" do
    f = PathFilter.compile(["homeassistant/components/*", "!homeassistant/components/cloud"])

    assert PathFilter.excluded?(f, "homeassistant/components/hue/light.py")
    assert PathFilter.excluded?(f, "homeassistant/components/zha/core/device.py")
    refute PathFilter.excluded?(f, "homeassistant/components/cloud/http_api.py")
    refute PathFilter.excluded?(f, "homeassistant/components/cloud/manifest.json")
    refute PathFilter.excluded?(f, "homeassistant/core.py")
    refute PathFilter.excluded?(f, "tests/components/hue/test_light.py")
    # `*` stays within a segment: a sibling with the same prefix is untouched.
    refute PathFilter.excluded?(f, "homeassistant/components_extra/x.py")
  end

  test "** crosses directories, ? matches one character, leading / is optional" do
    assert PathFilter.excluded?(PathFilter.compile(["**/fixtures"]), "tests/a/b/fixtures/x.json")
    assert PathFilter.excluded?(PathFilter.compile(["docs/v?/*.md"]), "docs/v2/intro.md")
    refute PathFilter.excluded?(PathFilter.compile(["docs/v?/*.md"]), "docs/v10/intro.md")
    assert PathFilter.excluded?(PathFilter.compile(["/vendor/"]), "vendor/lib/a.js")
  end

  test "the last matching pattern wins" do
    f = PathFilter.compile(["docs", "!docs/adr", "docs/adr/drafts"])

    assert PathFilter.excluded?(f, "docs/guide.md")
    refute PathFilter.excluded?(f, "docs/adr/0001.md")
    assert PathFilter.excluded?(f, "docs/adr/drafts/x.md")
  end

  test "regex metacharacters in patterns are literal" do
    f = PathFilter.compile(["a+b(c)/[x]"])
    assert PathFilter.excluded?(f, "a+b(c)/[x]/file")
    refute PathFilter.excluded?(f, "aab(c)/[x]/file")
  end

  test "no patterns excludes nothing; validation" do
    refute PathFilter.excluded?(PathFilter.compile([]), "anything")
    assert PathFilter.valid?(["a/*", "!a/b"])
    refute PathFilter.valid?(["a", ""])
    refute PathFilter.valid?(["!"])
    refute PathFilter.valid?("a/*")
  end
end
