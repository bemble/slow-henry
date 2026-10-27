defmodule RetrievalNode.Ingest.GitHub do
  @moduledoc """
  Pull requests of a GitHub repo — merged ones, and open ones on request —
  and its issues, through GitHub's GraphQL API with the GitHub App user
  token (`GitHub.OAuth`, connected from the Settings page).

  `prs_page/4` and `issues_page/3` walk a search sorted by `updated`
  ascending, so a caller can
  store the last `updatedAt` it saw as its watermark and resume from there. `list_repos/0` feeds the Sources editor's repo picker. Req
  options are extended by `:github_req_options` (tests point them at a
  `Req.Test` plug).
  """

  alias RetrievalNode.GitHub.OAuth

  @api_url "https://api.github.com"
  @graphql_url @api_url <> "/graphql"
  # 100 repos a page.
  @max_repo_pages 30

  @query """
  query($q: String!, $after: String, $owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) { id }
    search(query: $q, type: ISSUE, first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        ... on PullRequest {
          number title body url state isDraft mergedAt updatedAt
          author { login __typename }
          comments(first: 100) { nodes { body author { login __typename } } }
          reviews(first: 50) { nodes { body state author { login __typename } } }
        }
      }
    }
  }
  """

  @issue_query """
  query($q: String!, $after: String, $owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) { id }
    search(query: $q, type: ISSUE, first: 50, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        ... on Issue {
          number title body url state stateReason closedAt updatedAt
          author { login __typename }
          labels(first: 20) { nodes { name } }
          assignees(first: 10) { nodes { login } }
          closedByPullRequestsReferences(first: 10) { nodes { number } }
          comments(first: 100) { nodes { body author { login __typename } } }
        }
      }
    }
  }
  """

  # AI reviewers/commenters that don't come through as a GitHub App bot
  # (`__typename: "Bot"` or a `[bot]` login), compared lowercased. They are
  # left out of the rendered discussion and of `reviewers`.
  @ai_logins ~w(copilot copilot-pull-request-reviewer copilot-swe-agent coderabbitai
                gemini-code-assist sourcery-ai greptile-apps ellipsis-dev
                qodo-merge-pro devin-ai-integration cursor claude)

  @type pr :: %{
          number: pos_integer(),
          title: String.t(),
          url: String.t(),
          state: :open | :merged | :closed,
          draft: boolean(),
          merged_at: String.t() | nil,
          updated_at: String.t(),
          author: String.t(),
          bot_author: boolean(),
          reviewers: [String.t()],
          text: String.t()
        }

  @type issue :: %{
          number: pos_integer(),
          title: String.t(),
          url: String.t(),
          state: :open | :closed,
          state_reason: String.t() | nil,
          closed_at: String.t() | nil,
          updated_at: String.t(),
          author: String.t(),
          bot_author: boolean(),
          assignees: [String.t()],
          labels: [String.t()],
          linked_prs: [pos_integer()],
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
  One page (up to 50) of the PRs of `repo` updated at or after `since`
  (ISO 8601), oldest update first: merged ones only, or — with `open: true`
  — every state (open, merged, and closed without merge, which the caller
  needs to drop a PR it indexed while open). Returns
  `{:ok, prs, next_cursor | nil}`.
  """
  def prs_page(repo, since, cursor \\ nil, opts \\ []) do
    search = search_query(repo, since, Keyword.get(opts, :open, false))

    with {:ok, nodes, next} <- search_page(@query, repo, search, cursor) do
      {:ok, Enum.map(nodes, &to_pr(repo, &1)), next}
    end
  end

  defp search_page(query, repo, search, cursor) do
    [owner, name] = String.split(repo, "/", parts: 2)
    vars = %{"q" => search, "owner" => owner, "name" => name}
    vars = if cursor, do: Map.put(vars, "after", cursor), else: vars

    # A search on a repo the token can't see just finds nothing; asking for
    # the repository too turns that into an error instead of a silent no-op.
    case graphql(query, vars) do
      {:ok, %{"data" => %{"repository" => %{"id" => _}, "search" => search}}} ->
        nodes = for node <- search["nodes"] || [], node["number"], do: node
        next = if search["pageInfo"]["hasNextPage"], do: search["pageInfo"]["endCursor"]
        {:ok, nodes, next}

      {:ok, %{"data" => %{"repository" => nil}}} ->
        {:error, {:github_repo_not_visible, repo}}

      {:error, :github_not_found} ->
        {:error, {:github_repo_not_visible, repo}}

      other ->
        other
    end
  end

  @doc """
  One page (up to 50) of the issues of `repo` updated at or after `since`
  (ISO 8601), oldest update first, open and closed. Returns
  `{:ok, issues, next_cursor | nil}`.
  """
  def issues_page(repo, since, cursor \\ nil) do
    search = "repo:#{repo} is:issue updated:>=#{since} sort:updated-asc"

    with {:ok, nodes, next} <- search_page(@issue_query, repo, search, cursor) do
      {:ok, Enum.map(nodes, &to_issue(repo, &1)), next}
    end
  end

  defp search_query(repo, since, open?) do
    state = if open?, do: "", else: " is:merged"
    "repo:#{repo} is:pr#{state} updated:>=#{since} sort:updated-asc"
  end

  @doc """
  The repos the token can read, sorted by full name: `GET /user/repos`,
  which for a GitHub App token means those where the App is installed and
  the user has access. Each is `%{full_name:, clone_url:, private:,
  description:}`.
  """
  def list_repos do
    collect_repos(@api_url <> "/user/repos?per_page=100&sort=full_name", [], @max_repo_pages)
  end

  defp collect_repos(_url, _acc, 0), do: {:error, :github_too_many_repos}

  defp collect_repos(url, acc, pages_left) do
    with {:ok, resp} <- request(method: :get, url: url) do
      repos =
        for r <- resp.body do
          %{
            full_name: r["full_name"],
            clone_url: r["clone_url"],
            private: r["private"] == true,
            description: r["description"]
          }
        end

      case next_link(resp) do
        nil -> {:ok, Enum.sort_by(acc ++ repos, &String.downcase(&1.full_name))}
        next -> collect_repos(next, acc ++ repos, pages_left - 1)
      end
    end
  end

  # `Link: <https://api.github.com/user/repos?page=2>; rel="next", ...`
  defp next_link(resp) do
    resp
    |> Req.Response.get_header("link")
    |> Enum.find_value(fn header ->
      case Regex.run(~r/<([^>]+)>;\s*rel="next"/, header) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  @doc false
  def to_pr(repo, node) do
    %{
      number: node["number"],
      title: node["title"],
      url: node["url"],
      state: state(node),
      draft: node["isDraft"] == true,
      merged_at: node["mergedAt"],
      updated_at: node["updatedAt"],
      author: login(node["author"]),
      bot_author: bot?(node["author"]),
      reviewers: reviewers(node),
      text: render(repo, node)
    }
  end

  @doc false
  def to_issue(repo, node) do
    %{
      number: node["number"],
      title: node["title"],
      url: node["url"],
      state: if(node["state"] == "OPEN", do: :open, else: :closed),
      state_reason: node["stateReason"] && String.downcase(node["stateReason"]),
      closed_at: node["closedAt"],
      updated_at: node["updatedAt"],
      author: login(node["author"]),
      bot_author: bot?(node["author"]),
      assignees: for(a <- get_in(node, ["assignees", "nodes"]) || [], do: login(a)),
      labels: for(l <- get_in(node, ["labels", "nodes"]) || [], do: l["name"]),
      linked_prs:
        for(
          pr <- get_in(node, ["closedByPullRequestsReferences", "nodes"]) || [],
          do: pr["number"]
        ),
      text: render_issue(repo, node)
    }
  end

  # Older payloads (and the merged-only search) may lack `state`: a merge
  # date says enough.
  defp state(%{"state" => "OPEN"}), do: :open
  defp state(%{"state" => "CLOSED"}), do: :closed
  defp state(%{"state" => "MERGED"}), do: :merged
  defp state(%{"mergedAt" => merged_at}) when is_binary(merged_at), do: :merged
  defp state(_node), do: :closed

  # Everyone who submitted a review — an approval with no comment counts —
  # except bots, AI reviewers, deleted accounts and the author's own replies.
  defp reviewers(node) do
    author = login(node["author"])

    for r <- get_in(node, ["reviews", "nodes"]) || [],
        not bot?(r["author"]),
        login = login(r["author"]),
        login not in ["ghost", author],
        uniq: true,
        do: login
  end

  # Markdown: title, who/when, the description, then the human discussion.
  # Bot comments (CI, coverage, changelog bots) are noise for retrieval.
  defp render(repo, node) do
    header = [
      "# #{node["title"]}",
      "",
      "Pull request ##{node["number"]} in #{repo} by @#{login(node["author"])}, #{status(node)}",
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

  # Markdown, as for PRs: title, who/state, what it's about, the
  # description, then the human comments.
  defp render_issue(repo, node) do
    header =
      [
        "# #{node["title"]}",
        "",
        "Issue ##{node["number"]} in #{repo} by @#{login(node["author"])}, #{issue_status(node)}",
        node["url"],
        listed("Labels", node, "labels", & &1["name"]),
        listed("Assignees", node, "assignees", &"@#{login(&1)}"),
        listed("Linked PRs", node, "closedByPullRequestsReferences", &"##{&1["number"]}")
      ]
      |> Enum.reject(&is_nil/1)

    sections =
      [
        blank_to_nil(node["body"]),
        section("Comments", nodes(node, "comments"), fn c ->
          "**@#{login(c["author"])}:** #{String.trim(c["body"])}"
        end)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([Enum.join(header, "\n") | sections], "\n\n") <> "\n"
  end

  # `Labels: bug, cloud`, or nil when there are none.
  defp listed(title, node, key, fun) do
    case get_in(node, [key, "nodes"]) || [] do
      [] -> nil
      items -> "#{title}: #{Enum.map_join(items, ", ", fun)}"
    end
  end

  defp issue_status(%{"state" => "OPEN"}), do: "open"

  defp issue_status(node) do
    reason =
      case node["stateReason"] do
        r when r in [nil, "COMPLETED"] -> ""
        r -> " as " <> String.replace(String.downcase(r), "_", " ")
      end

    "closed #{date(node["closedAt"])}#{reason}"
  end

  defp status(node) do
    case state(node) do
      :merged -> "merged #{date(node["mergedAt"])}"
      :open -> if node["isDraft"] == true, do: "open (draft)", else: "open"
      :closed -> "closed"
    end
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

  defp bot?(%{"login" => login}) when is_binary(login),
    do: String.ends_with?(login, "[bot]") or String.downcase(login) in @ai_logins

  defp bot?(_), do: false

  defp login(%{"login" => login}), do: login
  defp login(_), do: "ghost"

  defp date(nil), do: "?"
  defp date(iso), do: String.slice(iso, 0, 10)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  # --- transport ---

  defp graphql(query, vars) do
    with {:ok, %{body: body}} <-
           request(method: :post, url: @graphql_url, json: %{query: query, variables: vars}) do
      case body do
        %{"errors" => [_ | _] = errors} -> graphql_errors(errors)
        body -> {:ok, body}
      end
    end
  end

  defp request(opts) do
    with {:ok, token} <- OAuth.access_token() do
      req =
        [auth: {:bearer, token}, retry: false, finch: [name: RetrievalNode.Finch]]
        |> Keyword.merge(opts)
        |> Keyword.merge(Application.get_env(:retrieval_node, :github_req_options, []))

      case Req.request(req) do
        {:ok, %{status: 200} = resp} ->
          {:ok, resp}

        {:ok, %{status: 401}} ->
          OAuth.invalidate()
          {:error, :github_unauthorized}

        # GitHub's error bodies hold no secrets; keep a short prefix.
        {:ok, %{status: status, body: body}} ->
          {:error, {:github_http, status, body |> inspect(limit: 5) |> String.slice(0, 200)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp graphql_errors(errors) do
    if Enum.any?(errors, &(&1["type"] == "NOT_FOUND")),
      do: {:error, :github_not_found},
      else: {:error, {:github, Enum.map(errors, & &1["message"])}}
  end
end
