defmodule RetrievalNode.Repo.Migrations.ResyncPullRequestsForPeople do
  use Ecto.Migration

  # PR chunks now carry `author`/`reviewers` metadata. Dropping the PR
  # watermark makes the next `PullRequestSync` run re-stage every merged PR;
  # their content hash now covers the people, so the owner re-applies them
  # instead of skipping them as unchanged (reusing the existing embeddings,
  # since the chunk text is the same).
  def up do
    execute("""
    UPDATE sync_states SET cursor = cursor - 'prs_updated_since'
    WHERE cursor ? 'prs_updated_since'
    """)
  end

  def down, do: :ok
end
