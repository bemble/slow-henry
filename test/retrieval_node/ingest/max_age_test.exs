defmodule RetrievalNode.Ingest.MaxAgeTest do
  use ExUnit.Case, async: true

  alias RetrievalNode.Ingest.MaxAge

  test "valid?/1 takes a number and a unit" do
    for value <- ~w(90d 2w 6m 2y 1y), do: assert(MaxAge.valid?(value))

    for value <- ["0y", "2", "y", "2 y", "2Y", "1.5y", "-1y", "10000d", 2, nil],
        do: refute(MaxAge.valid?(value))
  end

  test "cutoff/2 is the date that far back, at midnight UTC" do
    today = ~D[2026-03-31]
    assert MaxAge.cutoff(%{"max_age" => "10d"}, today) == "2026-03-21T00:00:00Z"
    assert MaxAge.cutoff(%{"max_age" => "2w"}, today) == "2026-03-17T00:00:00Z"
    assert MaxAge.cutoff(%{"max_age" => "1m"}, today) == "2026-02-28T00:00:00Z"
    assert MaxAge.cutoff(%{"max_age" => "2y"}, today) == "2024-03-31T00:00:00Z"
  end

  test "cutoff/2 is nil without a (valid) max_age" do
    assert MaxAge.cutoff(%{}, ~D[2026-03-31]) == nil
    assert MaxAge.cutoff(nil, ~D[2026-03-31]) == nil
    assert MaxAge.cutoff(%{"max_age" => "soon"}, ~D[2026-03-31]) == nil
  end
end
