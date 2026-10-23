defmodule RetrievalNode do
  @moduledoc """
  RetrievalNode keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  The app's own data directory: `sources.toml`, `secrets.toml`. `DATA_DIR`,
  else `./data` in dev and `/var/lib/retrieval_node` in a release
  (`config :retrieval_node, :data_dir`).
  """
  def data_dir, do: Application.get_env(:retrieval_node, :data_dir, "data")
end
