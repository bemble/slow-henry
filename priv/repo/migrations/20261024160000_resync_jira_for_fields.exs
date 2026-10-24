defmodule RetrievalNode.Repo.Migrations.ResyncJiraForFields do
  use Ecto.Migration

  # Jira chunks now carry the issue type, status, people and parent (metadata
  # and a text header). Dropping the Jira watermark makes the next `JiraSync`
  # run re-stage every resolved issue; their text changed, so the owner
  # re-applies them.
  def up do
    execute("""
    UPDATE sync_states SET cursor = cursor - 'resolutiondate_watermark'
    WHERE cursor ? 'resolutiondate_watermark'
    """)
  end

  def down, do: :ok
end
