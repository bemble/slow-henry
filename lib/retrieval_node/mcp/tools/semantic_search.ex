defmodule RetrievalNode.MCP.Tools.SemanticSearch do
  @moduledoc """
  Hybrid semantic + keyword search across indexed code, Jira issues, and Drive
  docs. Returns ranked back-links — `{source_type, repo, breadcrumb, metadata,
  score}` — **not** full content; expand a hit with `get_file`.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Search

  # Friendly shorthands the caller may pass for `source`, mapped to the DB enum.
  @source_map %{"git" => "git_repo", "jira" => "jira_project", "drive" => "drive_folder"}

  schema do
    field(:query, :string, required: true, description: "Natural-language or keyword query")
    field(:source, :string, description: "Filter by source kind: git | jira | drive")
    field(:repo, :string, description: "Filter by repo slug (see list_repos)")
    field(:lang, :string, description: "Filter by language, e.g. python, elixir")
    field(:author, :string, description: "GitHub login: merged PRs this person authored")
    field(:reviewer, :string, description: "GitHub login: merged PRs this person reviewed")

    field(:involves, :string,
      description: "GitHub login: merged PRs this person authored or reviewed"
    )
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    case normalize_source(Map.get(params, :source)) do
      {:ok, source_type} ->
        opts =
          params
          |> Map.take([:repo, :lang, :author, :reviewer, :involves])
          |> Enum.to_list()
          |> Keyword.put(:source_type, source_type)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        # mode is "text_only" when the embedding backend is down (BM25 only).
        %{mode: mode, hits: hits} = Search.search(query, opts)
        results = Enum.map(hits, &result/1)
        {:reply, Response.json(Response.tool(), %{mode: mode, results: results}), frame}

      {:error, msg} ->
        {:reply, Response.error(Response.tool(), msg), frame}
    end
  end

  # Reject an unknown `source` rather than silently returning zero results.
  defp normalize_source(nil), do: {:ok, nil}

  defp normalize_source(source) when is_map_key(@source_map, source),
    do: {:ok, @source_map[source]}

  defp normalize_source(other),
    do: {:error, "unknown source #{inspect(other)} — use git | jira | drive"}

  defp result(%{chunk: chunk, score: score}) do
    %{
      chunk_id: chunk.id,
      source_type: chunk.source_type,
      repo: chunk.repo,
      lang: chunk.lang,
      breadcrumb: chunk.context_breadcrumb,
      metadata: chunk.metadata,
      score: score
    }
  end
end
