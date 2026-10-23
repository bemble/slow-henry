defmodule RetrievalNode.Repo.Migrations.AddEmbeddingProfileToChunks do
  use Ecto.Migration

  # Which embedding setup (backend, model, task prefixes) produced each
  # vector, so mixing setups is visible and `mix rn.reembed` can redo only
  # what is stale. NULL = embedded before profiles were recorded.
  def change do
    alter table(:chunks) do
      add :embedding_profile, :text
    end
  end
end
