defmodule RetrievalNode.Embedding.Unavailable do
  @moduledoc """
  The embedding backend can't be reached right now (connection refused,
  timeout, 502/503/504). Callers treat it as transient: ingestion defers the
  source's staged files without spending an attempt, search falls back to
  full-text ranking only.
  """
  defexception [:message]
end
