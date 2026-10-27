defmodule RetrievalNode.Ingest.Workers.ReleaseSync do
  @moduledoc """
  Indexes the published GitHub releases of a git source that has
  `releases = true` in sources.toml (off by default), through the GitHub App
  token connected on the Settings page (`GitHub.OAuth`); pre-releases are
  kept, marked `prerelease`, drafts left out.

  Each release becomes one document of the git source under the virtual
  path `releases/<tag>`, named `Release <tag>`: its notes, then the PRs and
  other commits it contains since the previous release, computed from the
  mirror `RepoSync` keeps (`Ingest.Releases`). The metadata carries
  `release` (the tag), `published_at`, `prerelease`, `previous` and `prs`,
  which the `list_releases` tool reads ("which release shipped #123?").

  Releases are few and GitHub can't list them by update date, so each run
  lists them all and reconciles, with no watermark: a release is staged
  again only when its GitHub data (`release_key`) changed or its PRs weren't
  known yet (its commit wasn't in the mirror: published since the last
  fetch), and the deletion of the indexed releases no longer listed —
  deleted on GitHub, or published before the `max_age` cutoff — is staged.
  With `releases` off, every release document is staged for deletion,
  without calling GitHub.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.{GitHub, GitHubDocs, MaxAge, Releases}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.{Source, SyncState}

  @kind "release"
  @prefix "releases/"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    config = source.config || %{}

    with {:ok, repo} <- GitHubDocs.repo(source) do
      if config["releases"] == true,
        do: sync(source, repo, MaxAge.cutoff(config)),
        else: GitHubDocs.purge(source, @kind, [])
    end
  end

  defp sync(source, repo, cutoff) do
    case GitHub.releases(repo) do
      {:ok, releases} ->
        indexed = GitHubDocs.indexed_values(source, @prefix, "release_key")
        listed = in_window(releases, cutoff)

        rows =
          for {release, older} <- listed,
              key <- [key(release)],
              Map.get(indexed, path(release)) != key,
              do: row(source, repo, release, older, key)

        deletions =
          for path <- Map.keys(indexed) -- Enum.map(listed, &path(elem(&1, 0))),
              do: GitHubDocs.deletion_row(source, path)

        GitHubDocs.stage_rows!(source, deletions ++ rows)

        source.id
        |> GitHubDocs.sync_state()
        |> SyncState.changeset(%{last_synced_at: DateTime.utc_now()})
        |> Repo.update!()

        :ok

      # Not connected: nothing a retry fixes; the next hourly run tries again.
      {:error, :github_not_authorized} ->
        {:cancel, :github_not_authorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Each release in the window with the ones published before it (newest
  # first), which its previous release is picked from — those out of the
  # window included.
  defp in_window(releases, cutoff) do
    releases
    |> Enum.with_index(1)
    |> Enum.filter(fn {release, _i} -> is_nil(cutoff) or release.published_at >= cutoff end)
    |> Enum.map(fn {release, i} -> {release, Enum.drop(releases, i)} end)
  end

  defp path(release), do: @prefix <> release.tag

  # What GitHub says about the release, which the document follows. Its PRs
  # come from the mirror and only change when the tag moves (`commit`).
  defp key(release) do
    :crypto.hash(:sha256, :erlang.term_to_binary(release, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp row(source, repo, release, older, key) do
    changes = Releases.changes(Source.mirror_slug(source), release, older)
    text = Releases.render(repo, release, changes)

    GitHubDocs.row(source, path(release), text, [text], %{
      "name" => Releases.name(release),
      "release" => release.tag,
      "url" => release.url,
      "published_at" => release.published_at,
      "prerelease" => if(release.prerelease, do: true),
      "author" => release.author,
      "previous" => if(changes != :unknown, do: changes.previous),
      "prs" => if(changes != :unknown, do: Enum.map(changes.prs, &elem(&1, 0))),
      # Its commit not fetched yet: no key, so the next run tries again.
      "release_key" => if(changes != :unknown or is_nil(release.commit), do: key)
    })
  end
end
