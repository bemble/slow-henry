defmodule RetrievalNode.Ingest.Workers.PullRequestSync do
  @moduledoc """
  Indexes the merged pull requests of a git source that has
  `pull_requests = true` in sources.toml (off by default) — and its open ones
  too with `open_pull_requests = true` (the ones bots opened only with
  `bot_pull_requests = true`) — through the GitHub App token
  connected on the Settings page (`GitHub.OAuth`).

  Each PR becomes one document of the git source — title, author, state,
  URL, description, then the human comments and reviews — under the virtual
  path `pulls/<number>`, so it shows up next to the repo's files in the UI
  and in search results. Bot and AI comments are left out. The author, the
  human reviewers and the state also go in the metadata (`author`,
  `reviewers`, `state`, `draft`), which `semantic_search` filters on.

  With open PRs on, the search covers every state and each PR is handled by
  its own:

    * merged → indexed;
    * open (drafts included) → indexed, named `PR #<n> [open]: <title>`;
      when a bot opened it (dependabot, renovate…), only with
      `bot_pull_requests`, marked `bot` — otherwise its merge is indexed as
      usual;
    * closed without merge → a deletion entry when it is indexed (an
      abandoned PR indexed while open).

  An open PR that gets merged keeps its path, so its document is replaced.

  The watermark is the last `updatedAt` seen (`cursor["prs_updated_since"]`):
  the GitHub search is sorted by update, oldest first, so a PR edited or
  commented later is picked up again and re-staged (unchanged content is
  skipped by the owner); `SourcesFile` clears it when open PRs are turned
  on (or bot ones), since those not updated since it would be missed. A
  large backlog is staged over several runs, and like the other sync
  workers this one only stages rows (`GitHubDocs`, shared with
  `IssueSync`).

  With `max_age` set (`Ingest.MaxAge`), only the PRs merged — or, for open
  ones, last updated — after its cutoff are kept: the search starts at the
  cutoff when the watermark is older, a merged PR found there but merged
  before it (an old PR commented lately) is skipped, and each run stages the
  deletion of the indexed PRs that left the window. Open PRs carry their
  `updated_at` (metadata and hash) for that.

  Turning the options off is handled here too, from the source's config when
  the job runs: with `pull_requests` off, every PR document of the source is
  staged for deletion and the watermark cleared (so turning it back on
  re-reads everything), without calling GitHub; with `open_pull_requests`
  (or `bot_pull_requests`) off, each run stages the deletion of the open
  PRs (bot-opened ones) still indexed.
  """
  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias RetrievalNode.Ingest.{GitHub, GitHubDocs, MaxAge}
  alias RetrievalNode.Repo
  alias RetrievalNode.Retrieval.Source

  @kind "pr"
  @watermark "prs_updated_since"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    config = source.config || %{}

    with {:ok, repo} <- GitHubDocs.repo(source) do
      if config["pull_requests"] == true,
        do: sync(source, repo, options(config)),
        else: GitHubDocs.purge_all(source, @kind, @watermark)
    end
  end

  defp options(config) do
    open? = config["open_pull_requests"] == true

    %{
      open: open?,
      bots: open? and config["bot_pull_requests"] == true,
      cutoff: MaxAge.cutoff(config)
    }
  end

  defp sync(source, repo, options) do
    state = GitHubDocs.sync_state(source.id)

    # `open_pull_requests` (`bot_pull_requests`) off: the open PRs (opened
    # by bots) still indexed go; with `max_age`, those out of the window.
    cond do
      not options.open -> GitHubDocs.purge(source, @kind, state: "open")
      not options.bots -> GitHubDocs.purge(source, @kind, state: "open", bot: true)
      true -> :ok
    end

    if options.cutoff,
      do: GitHubDocs.purge(source, @kind, older_than: {options.cutoff, "merged_at"})

    since = GitHubDocs.since(state, @watermark, options.cutoff)

    GitHubDocs.walk(
      &GitHub.prs_page(repo, since, &1, open: options.open),
      &stage!(source, &1, &2, options),
      state
    )
  end

  defp stage!(_source, state, [], _options), do: state

  defp stage!(source, state, prs, options) do
    newest = prs |> Enum.map(& &1.updated_at) |> Enum.max()
    GitHubDocs.stage!(source, state, rows(source, prs, options), @watermark, newest)
  end

  # Closed-without-merge PRs are only deleted when they are indexed (or
  # staged): most were never open while the option was on.
  defp rows(source, prs, options) do
    {closed, kept} = Enum.split_with(prs, &(&1.state == :closed))
    indexed = GitHubDocs.indexed_paths(source, Enum.map(closed, &path/1))

    deletions =
      for pr <- closed, path(pr) in indexed, do: GitHubDocs.deletion_row(source, path(pr))

    contents =
      for pr <- kept,
          options.bots or not (pr.state == :open and pr.bot_author),
          in_window?(pr, options.cutoff),
          do: row(source, pr)

    deletions ++ contents
  end

  # The search starts at the cutoff, so only a PR merged before it but
  # updated after it (commented lately) can be out of the window.
  defp in_window?(_pr, nil), do: true
  defp in_window?(%{state: :merged, merged_at: merged_at}, cutoff), do: merged_at >= cutoff
  defp in_window?(_pr, _cutoff), do: true

  defp path(pr), do: "pulls/#{pr.number}"

  defp row(source, pr) do
    people = %{"author" => pr.author, "reviewers" => pr.reviewers}
    open = if pr.state == :open, do: " [open]", else: ""
    # An open PR ages by its activity (`max_age`), so its update date is
    # kept current.
    updated_at = if pr.state == :open, do: pr.updated_at

    # The hash covers the people and the state too: an approval with no
    # comment changes `reviewers` but not the text, and PRs indexed before
    # states existed get theirs; the owner skips a row whose hash is
    # unchanged.
    GitHubDocs.row(
      source,
      path(pr),
      pr.text,
      [pr.text, Jason.encode!(people), Atom.to_string(pr.state), updated_at || ""],
      Map.merge(people, %{
        "name" => "PR ##{pr.number}#{open}: #{pr.title}",
        "pr" => pr.number,
        "url" => pr.url,
        "state" => Atom.to_string(pr.state),
        "merged_at" => pr.merged_at,
        "updated_at" => updated_at,
        "draft" => if(pr.draft, do: true),
        "bot" => if(pr.bot_author, do: true)
      })
    )
  end
end
