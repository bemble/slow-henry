defmodule RetrievalNode.Ingest.Releases do
  @moduledoc """
  The document of a GitHub release (`GitHub.releases/1`), for `ReleaseSync`:
  its notes and what it contains, computed from the repo's mirror rather
  than the API.

  What it contains is the first-parent history between the previous release
  and its tag (`GitMirror.log/4`): squash merges (`Fix login (#123)`) and
  merge commits (`Merge pull request #123 from …`, titled by their body)
  give its pull requests, the rest are listed as other commits. The
  previous release is the newest earlier one whose commit is an ancestor of
  this one — pre-releases skipped for a stable release — so a patch release
  on a maintenance branch is compared to its own branch, and `2.0.0` to
  `1.9.0` rather than to `2.0.0b3`. Without one, it is the whole history up
  to the tag.
  """

  alias RetrievalNode.Ingest.GitMirror

  # First release of a long history: commits looked at, and lines listed.
  @max_commits 5_000
  @max_lines 300
  # Earlier releases tried as the previous one.
  @max_candidates 20

  @squash ~r/\A(.+?)\s*\(#(\d+)\)\z/
  @merge ~r/\AMerge pull request #(\d+) from /

  @type changes :: %{
          previous: String.t() | nil,
          prs: [{pos_integer(), String.t()}],
          others: [String.t()]
        }

  @doc """
  What `release` contains: its previous release's tag, its PRs and other
  commits. `older` are the releases published before it, newest first.
  `:unknown` when its commit isn't in the mirror (published since the last
  fetch, or its tag is gone).
  """
  @spec changes(String.t(), map(), [map()]) :: changes() | :unknown
  def changes(slug, %{commit: commit} = release, older) when is_binary(commit) do
    # An unknown commit isn't its own ancestor.
    if GitMirror.ancestor?(slug, commit, commit) do
      previous = previous(slug, release, older)

      case GitMirror.log(slug, previous && previous.commit, commit, @max_commits) do
        {:ok, commits} -> Map.put(parse(commits), :previous, previous && previous.tag)
        {:error, _} -> :unknown
      end
    else
      :unknown
    end
  end

  def changes(_slug, _release, _older), do: :unknown

  defp previous(slug, release, older) do
    older
    |> Enum.reject(&(is_nil(&1.commit) or (&1.prerelease and not release.prerelease)))
    |> Enum.take(@max_candidates)
    |> Enum.find(&GitMirror.ancestor?(slug, &1.commit, release.commit))
  end

  @doc "The PRs (`{number, title}`, oldest first) and other commit subjects of `commits` (newest first)."
  @spec parse([%{subject: String.t(), body: String.t()}]) :: map()
  def parse(commits) do
    {prs, others} =
      commits
      |> Enum.reverse()
      |> Enum.map(&classify/1)
      |> Enum.split_with(&match?({:pr, _, _}, &1))

    %{
      prs: prs |> Enum.map(fn {:pr, n, title} -> {n, title} end) |> Enum.uniq_by(&elem(&1, 0)),
      others: Enum.map(others, fn {:other, subject} -> subject end)
    }
  end

  defp classify(%{subject: subject, body: body}) do
    cond do
      match = Regex.run(@merge, subject) ->
        title = body |> String.split("\n", parts: 2) |> hd() |> String.trim()
        {:pr, String.to_integer(Enum.at(match, 1)), if(title == "", do: subject, else: title)}

      match = Regex.run(@squash, subject) ->
        [_, title, number] = match
        {:pr, String.to_integer(number), title}

      true ->
        {:other, subject}
    end
  end

  @doc "The document's name: `Release v1.2.0`, with the release's own name when it has one."
  def name(%{tag: tag, name: name}) when name in [nil, tag], do: "Release #{tag}"
  def name(%{tag: tag, name: name}), do: "Release #{tag}: #{name}"

  @doc """
  Markdown: title, tag/date/author, URL, the previous release, the notes,
  then its PRs and other commits (`@max_lines` at most).
  """
  @spec render(String.t(), map(), changes() | :unknown) :: String.t()
  def render(repo, release, changes) do
    pre = if release.prerelease, do: ", pre-release", else: ""

    header =
      [
        "# #{release.name || release.tag}",
        "",
        "Release #{release.tag} of #{repo}, published #{String.slice(release.published_at, 0, 10)} by @#{release.author}#{pre}",
        release.url,
        since(changes)
      ]
      |> Enum.reject(&is_nil/1)

    sections = [release.notes | contents(changes)] |> Enum.reject(&is_nil/1)
    Enum.join([Enum.join(header, "\n") | sections], "\n\n") <> "\n"
  end

  defp since(:unknown), do: nil
  defp since(%{previous: nil}), do: "Since: the beginning of the history"
  defp since(%{previous: tag}), do: "Since: #{tag}"

  defp contents(:unknown), do: []

  defp contents(changes) do
    prs = Enum.take(changes.prs, @max_lines)
    others = Enum.take(changes.others, @max_lines - length(prs))
    hidden = length(changes.prs) + length(changes.others) - length(prs) - length(others)

    [
      section("Pull requests", Enum.map(prs, fn {n, title} -> "- ##{n} #{title}" end)),
      section("Other commits", Enum.map(others, &"- #{&1}")),
      if(hidden > 0, do: "… and #{hidden} more")
    ]
  end

  defp section(_title, []), do: nil
  defp section(title, lines), do: Enum.join(["## #{title}", "" | lines], "\n")
end
