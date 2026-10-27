defmodule RetrievalNode.MCP.Tools.ListReleases do
  @moduledoc """
  The GitHub releases indexed for a repo (git sources with `releases =
  true`), newest first: `{release, name, published_at, prerelease, previous,
  prs, url, author}`, where `prs` are the PR numbers it shipped since its
  `previous` release. With `pr`, only the releases that shipped that PR
  ("which release fixed #123?"); with `tag`, that release's full document —
  notes, PRs and other commits — as `{repo, release, metadata, content}`.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias RetrievalNode.Ingest

  schema do
    field(:repo, :string, required: true, description: "Repo slug (see list_repos)")
    field(:pr, :integer, description: "A PR number: only the releases that shipped it")
    field(:tag, :string, description: "A release tag: its full document instead of the list")
  end

  @impl true
  def execute(%{repo: repo, tag: tag}, frame) when is_binary(tag) do
    case Ingest.release(repo, tag) do
      {:ok, %{metadata: metadata, content: content}} ->
        payload = %{
          repo: repo,
          release: tag,
          metadata: Map.drop(metadata, ["release_key", "path"]),
          content: content
        }

        {:reply, Response.json(Response.tool(), payload), frame}

      {:error, :not_found} ->
        reply_error("release #{inspect(tag)} of #{repo} is not indexed", frame)

      {:error, :repo_not_found} ->
        reply_error("repo not found (see list_repos)", frame)
    end
  end

  def execute(%{repo: repo} = params, frame) do
    case Ingest.releases(repo, Map.get(params, :pr)) do
      {:ok, releases} ->
        {:reply, Response.json(Response.tool(), %{repo: repo, releases: releases}), frame}

      {:error, :repo_not_found} ->
        reply_error("repo not found (see list_repos)", frame)
    end
  end

  defp reply_error(msg, frame), do: {:reply, Response.error(Response.tool(), msg), frame}
end
