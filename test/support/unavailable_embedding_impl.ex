defmodule RetrievalNode.Embedding.UnavailableImpl do
  @moduledoc "Test-only embedding impl simulating an unreachable embedding server."
  @behaviour RetrievalNode.Embedding

  alias RetrievalNode.Embedding.Unavailable

  @impl true
  def dimensions, do: 384

  @impl true
  def embed(_text), do: raise(Unavailable, "embedding server down (test)")

  @impl true
  def embed_batch(_texts), do: raise(Unavailable, "embedding server down (test)")
end
