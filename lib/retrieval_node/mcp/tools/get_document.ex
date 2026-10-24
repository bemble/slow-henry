defmodule RetrievalNode.MCP.Tools.GetDocument do
  @moduledoc """
  Fetch the indexed text of a Google Drive doc or a Jira issue — the
  full-content companion to `semantic_search` hits on non-git sources (git
  files go through `get_file`). The text is rebuilt from the indexed chunks, so
  it is what search ranked (secrets redacted, images stripped). Returns
  `{source, id, name, url, metadata, content}`.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest

  @source_map %{"drive" => {"drive_folder", "doc_id"}, "jira" => {"jira_project", "issue_key"}}

  schema do
    field(:source, :string, required: true, description: "Source kind: drive | jira")

    field(:id, :string,
      required: true,
      description: "Drive doc_id or Jira issue_key, from a semantic_search hit's metadata"
    )
  end

  @impl true
  def execute(%{source: source, id: id}, frame) do
    with {:ok, {source_type, _field}} <- Map.fetch(@source_map, source),
         {:ok, %{metadata: metadata, content: content}} <- Ingest.document(source_type, id) do
      payload = %{
        source: source,
        id: id,
        name: metadata["name"],
        url: metadata["url"],
        metadata: metadata,
        content: content
      }

      {:reply, Response.json(Response.tool(), payload), frame}
    else
      :error ->
        reply_error("unknown source #{inspect(source)} — use drive | jira (git: get_file)", frame)

      {:error, :not_found} ->
        reply_error("#{elem(@source_map[source], 1)} #{inspect(id)} is not indexed", frame)
    end
  end

  defp reply_error(msg, frame), do: {:reply, Response.error(Response.tool(), msg), frame}
end
