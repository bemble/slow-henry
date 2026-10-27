defmodule RetrievalNode.Ingest.Workers.IssueSync do
  @moduledoc """
  Indexes the issues of a git source that has `issues = true` in
  sources.toml (off by default), through the GitHub App token connected on
  the Settings page (`GitHub.OAuth`) — open and closed ones alike: a closed
  issue keeps its discussion and how it was resolved.

  Each issue becomes one document of the git source — title, author, state,
  URL, labels, assignees, the linked PRs (that closed it or will close it
  once merged), description, then the human comments — under the virtual path `issues/<number>`, named
  `Issue #<n> [open]: <title>` while open. Bot and AI comments are left
  out; issues bots opened (dependency dashboards…) are kept, marked `bot`.
  The metadata carries `author`, `assignees`, `labels`, `state`,
  `state_reason` and `linked_prs`; `semantic_search` filters on the people
  and the state.

  Same walk as `PullRequestSync` (`GitHubDocs`), with its own watermark
  (`cursor["issues_updated_since"]`). With `max_age`, an open issue ages by
  its last activity (`updated_at`, kept in its metadata and hash), a closed
  one by its closing date; each run stages the deletion of the issues that
  left the window. With `issues` off, every issue document of the source is
  staged for deletion and the watermark cleared, without calling GitHub.
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

  @kind "issue"
  @watermark "issues_updated_since"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    source = Repo.get!(Source, source_id)
    config = source.config || %{}

    with {:ok, repo} <- GitHubDocs.repo(source) do
      if config["issues"] == true,
        do: sync(source, repo, MaxAge.cutoff(config)),
        else: GitHubDocs.purge_all(source, @kind, @watermark)
    end
  end

  defp sync(source, repo, cutoff) do
    state = GitHubDocs.sync_state(source.id)
    if cutoff, do: GitHubDocs.purge(source, @kind, older_than: {cutoff, "closed_at"})
    since = GitHubDocs.since(state, @watermark, cutoff)

    GitHubDocs.walk(
      &GitHub.issues_page(repo, since, &1),
      &stage!(source, &1, &2, cutoff),
      state
    )
  end

  defp stage!(_source, state, [], _cutoff), do: state

  defp stage!(source, state, issues, cutoff) do
    newest = issues |> Enum.map(& &1.updated_at) |> Enum.max()
    rows = for issue <- issues, in_window?(issue, cutoff), do: row(source, issue)
    GitHubDocs.stage!(source, state, rows, @watermark, newest)
  end

  # The search starts at the cutoff, so only an issue closed before it but
  # updated after it (commented lately) can be out of the window.
  defp in_window?(_issue, nil), do: true
  defp in_window?(%{state: :closed, closed_at: closed_at}, cutoff), do: closed_at >= cutoff
  defp in_window?(_issue, _cutoff), do: true

  defp row(source, issue) do
    open? = issue.state == :open
    people = %{"author" => issue.author, "assignees" => issue.assignees}
    # An open issue ages by its activity (`max_age`), so its update date is
    # kept current.
    updated_at = if open?, do: issue.updated_at

    # Labels and assignees change without the text changing; the owner
    # skips a row whose hash is unchanged.
    GitHubDocs.row(
      source,
      "issues/#{issue.number}",
      issue.text,
      [
        issue.text,
        Jason.encode!(people),
        Jason.encode!(issue.labels),
        Atom.to_string(issue.state),
        updated_at || ""
      ],
      Map.merge(people, %{
        "name" => "Issue ##{issue.number}#{if open?, do: " [open]"}: #{issue.title}",
        "issue" => issue.number,
        "url" => issue.url,
        "state" => Atom.to_string(issue.state),
        "state_reason" => issue.state_reason,
        "labels" => issue.labels,
        "linked_prs" => if(issue.linked_prs != [], do: issue.linked_prs),
        "closed_at" => issue.closed_at,
        "updated_at" => updated_at,
        "bot" => if(issue.bot_author, do: true)
      })
    )
  end
end
