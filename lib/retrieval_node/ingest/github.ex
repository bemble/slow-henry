defmodule RetrievalNode.Ingest.GitHub do
  @moduledoc """
  Merged pull requests of a GitHub repo, through the `gh` CLI (`gh api
  graphql`), so authentication is whatever `gh auth login` set up for the
  user running the server.

  `merged_prs_page/3` walks a search sorted by `updated` ascending, so a
  caller can store the last `updatedAt` it saw as its watermark and resume
  from there. The runner is `:github_runner` in the app env (tests stub it).
  """

  @query """
  query($q: String!, $after: String) {
    search(query: $q, type: ISSUE, first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        ... on PullRequest {
          number title body url mergedAt updatedAt
          author { login __typename }
          comments(first: 100) { nodes { body author { login __typename } } }
          reviews(first: 50) { nodes { body state author { login __typename } } }
        }
      }
    }
  }
  """

  @type pr :: %{
          number: pos_integer(),
          title: String.t(),
          url: String.t(),
          merged_at: String.t(),
          updated_at: String.t(),
          text: String.t()
        }

  @doc "`owner/name` for a github.com clone URL (https or ssh), or :error."
  def repo_from_url(url) do
    case Regex.run(
           ~r{\A(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([\w.-]+)/([\w.-]+?)(?:\.git)?/?\z},
           url
         ) do
      [_, owner, name] -> {:ok, "#{owner}/#{name}"}
      _ -> :error
    end
  end

  @doc """
  One page (up to 50) of merged PRs of `repo` updated at or after `since`
  (ISO 8601), oldest update first. Returns `{:ok, prs, next_cursor | nil}`.
  """
  def merged_prs_page(repo, since, cursor \\ nil) do
    search = "repo:#{repo} is:pr is:merged updated:>=#{since} sort:updated-asc"
    vars = if cursor, do: %{"q" => search, "after" => cursor}, else: %{"q" => search}

    with {:ok, %{"data" => %{"search" => search}}} <- graphql(@query, vars) do
      prs = for node <- search["nodes"] || [], node["number"], do: to_pr(repo, node)
      next = if search["pageInfo"]["hasNextPage"], do: search["pageInfo"]["endCursor"]
      {:ok, prs, next}
    end
  end

  @doc false
  def to_pr(repo, node) do
    %{
      number: node["number"],
      title: node["title"],
      url: node["url"],
      merged_at: node["mergedAt"],
      updated_at: node["updatedAt"],
      text: render(repo, node)
    }
  end

  # Markdown: title, who/when, the description, then the human discussion.
  # Bot comments (CI, coverage, changelog bots) are noise for retrieval.
  defp render(repo, node) do
    header = [
      "# #{node["title"]}",
      "",
      "Pull request ##{node["number"]} in #{repo} by @#{login(node["author"])}, merged #{date(node["mergedAt"])}",
      node["url"]
    ]

    sections =
      [
        blank_to_nil(node["body"]),
        section("Comments", nodes(node, "comments"), fn c ->
          "**@#{login(c["author"])}:** #{String.trim(c["body"])}"
        end),
        section("Reviews", nodes(node, "reviews"), fn r ->
          "**@#{login(r["author"])} (#{r["state"]}):** #{String.trim(r["body"])}"
        end)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([Enum.join(header, "\n") | sections], "\n\n") <> "\n"
  end

  defp nodes(node, key) do
    for n <- get_in(node, [key, "nodes"]) || [],
        not bot?(n["author"]),
        blank_to_nil(n["body"]),
        do: n
  end

  defp section(_title, [], _fun), do: nil
  defp section(title, items, fun), do: Enum.join(["## #{title}" | Enum.map(items, fun)], "\n\n")

  defp bot?(%{"__typename" => "Bot"}), do: true
  defp bot?(%{"login" => login}) when is_binary(login), do: String.ends_with?(login, "[bot]")
  defp bot?(_), do: false

  defp login(%{"login" => login}), do: login
  defp login(_), do: "ghost"

  defp date(nil), do: "?"
  defp date(iso), do: String.slice(iso, 0, 10)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  # --- transport ---

  defp graphql(query, vars) do
    runner = Application.get_env(:retrieval_node, :github_runner, &__MODULE__.gh/2)

    case runner.(query, vars) do
      {:ok, %{"errors" => [_ | _] = errors}} ->
        {:error, {:github, Enum.map(errors, & &1["message"])}}

      other ->
        other
    end
  end

  @doc false
  # sobelow_skip ["CI.System"]
  def gh(query, vars) do
    args =
      ["api", "graphql", "-f", "query=#{query}"] ++
        Enum.flat_map(vars, fn {k, v} -> ["-f", "#{k}=#{v}"] end)

    case System.find_executable("gh") do
      nil ->
        {:error, :gh_not_found}

      gh ->
        case System.cmd(gh, args, stderr_to_stdout: true) do
          {out, 0} -> Jason.decode(out)
          # gh prints the API error (no secrets) — keep a short prefix.
          {out, code} -> {:error, {:gh_exit, code, String.slice(out, 0, 300)}}
        end
    end
  end
end
