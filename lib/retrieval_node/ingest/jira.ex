defmodule RetrievalNode.Ingest.Jira do
  @moduledoc """
  Thin Jira Cloud REST client for incremental ingest of **resolved** issues
  (status category Done — open issues churn and aren't worth indexing), through
  the enhanced search (`/rest/api/3/search/jql`, paged by `nextPageToken`).

  Each issue is rendered as a short header — key and summary, type, status,
  resolution, and the optional fields the project turns on in sources.toml
  (`assignee`, `reporter`, `parent`: the epic, for a story) — then its
  description, and carries the same fields as metadata, which
  `semantic_search` filters on.

  Credentials come from `RetrievalNode.Jira.Credentials`. The Req request is
  built with `req_options/0` merged in, which tests override (via `Req.Test`)
  to avoid real HTTP.
  """

  alias RetrievalNode.Jira.Credentials

  @fields ~w(summary description resolutiondate issuetype status resolution)
  @page_size 100

  # sources.toml option => the metadata keys it adds.
  @optional_fields %{
    "assignee" => ["assignee"],
    "reporter" => ["reporter"],
    "parent" => ["parent", "parent_type", "parent_summary"]
  }
  @optional_keys @optional_fields |> Map.values() |> List.flatten()

  @type issue :: %{
          key: String.t(),
          text: String.t(),
          resolutiondate: String.t() | nil,
          metadata: map()
        }

  @doc """
  One page of the issues in `project_key` resolved since `watermark` (a Jira
  timestamp, or nil for a full backfill), after `page_token` (nil: first page),
  with the optional fields in `options` (`"assignee"`, `"reporter"`,
  `"parent"`).
  Returns `{:ok, issues, next_page_token | nil}`, `{:snooze, seconds}` on a 429
  (rate limit), or `{:error, reason}` — `:jira_not_configured` without
  credentials.
  """
  @spec fetch_resolved_page(String.t(), String.t() | nil, String.t() | nil, [String.t()]) ::
          {:ok, [issue], String.t() | nil} | {:snooze, pos_integer()} | {:error, term()}
  def fetch_resolved_page(project_key, watermark, page_token, options \\ []) do
    with {:ok, creds} <- Credentials.get() do
      params =
        [
          jql: build_jql(project_key, watermark),
          fields: Enum.join(@fields ++ options, ","),
          maxResults: @page_size
        ] ++ if(page_token, do: [nextPageToken: page_token], else: [])

      case Req.get(req(creds), url: "/rest/api/3/search/jql", params: params) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, parse_issues(body, Credentials.site_url(creds), options), next_page_token(body)}

        {:ok, %{status: 429} = resp} ->
          {:snooze, retry_after(resp)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:jira_http, status, truncate(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Stop on a missing token rather than trusting `isLast` alone.
  defp next_page_token(%{"isLast" => true}), do: nil

  defp next_page_token(%{"nextPageToken" => token}) when is_binary(token) and token != "",
    do: token

  defp next_page_token(_body), do: nil

  @doc """
  Who `creds` authenticate as: `{:ok, display_name}`, or `{:error, reason}` —
  `{:unauthorized, status, message}` when Jira refuses them, with what Jira
  said.
  """
  @spec myself(Credentials.t()) :: {:ok, String.t()} | {:error, term()}
  def myself(creds) do
    case Req.get(req(creds), url: "/rest/api/3/myself") do
      {:ok, %{status: 200, body: %{"displayName" => name}}} ->
        {:ok, name}

      {:ok, %{status: 200}} ->
        {:error, :not_jira}

      {:ok, %{status: status, body: body}} when status in [401, 403] ->
        {:error, {:unauthorized, status, error_message(body)}}

      {:ok, %{status: status}} ->
        {:error, {:jira_http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks credentials typed on the Connections page: `myself/1`, and when an
  Atlassian site refuses them, the same through the scoped-token gateway
  (`https://api.atlassian.com/ex/jira/<cloudId>`) — a token "with scopes" is
  only accepted there. Returns the display name and the credentials that
  worked (the gateway ones keep the site as `site_url`).
  """
  @spec connect(Credentials.t()) :: {:ok, String.t(), Credentials.t()} | {:error, term()}
  def connect(creds) do
    with {:error, {:unauthorized, _, _}} = refused <- myself(creds),
         true <- atlassian_site?(creds.base_url) || refused,
         {:ok, cloud_id} <- cloud_id(creds.base_url) do
      gateway = %{creds | base_url: "https://api.atlassian.com/ex/jira/#{cloud_id}"}
      gateway = Map.put(gateway, :site_url, creds.base_url)

      case myself(gateway) do
        {:ok, name} -> {:ok, name, gateway}
        # Report the gateway's answer: it says why a scoped token was refused.
        {:error, {:unauthorized, _, _}} = error -> error
        _other -> refused
      end
    else
      {:ok, name} -> {:ok, name, creds}
      {:error, _} = error -> error
    end
  end

  defp atlassian_site?(base_url), do: base_url =~ ~r{\Ahttps://[^/]+\.atlassian\.net\z}

  # Public: every Atlassian site answers it without authentication.
  defp cloud_id(site) do
    case Req.get(req(%{base_url: site}), url: "/_edge/tenant_info") do
      {:ok, %{status: 200, body: %{"cloudId" => id}}} when is_binary(id) -> {:ok, id}
      {:ok, %{status: status}} -> {:error, {:jira_http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Jira says why in `errorMessages`, the gateway in `message`; anything else
  # (an HTML page) is not worth showing.
  defp error_message(%{"errorMessages" => [_ | _] = messages}), do: Enum.join(messages, " ")
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(_body), do: nil

  @doc """
  Build the incremental JQL. Public for testing the watermark clause.

  JQL dates have minute precision in the account's time zone, so the clause
  starts a day before the watermark's date: the overlap is re-staged, and the
  owner skips what didn't change.
  """
  @spec build_jql(String.t(), String.t() | nil) :: String.t()
  def build_jql(project_key, nil) do
    ~s|project = "#{project_key}" AND statusCategory = Done ORDER BY resolutiondate ASC, key ASC|
  end

  def build_jql(project_key, watermark) do
    ~s|project = "#{project_key}" AND statusCategory = Done | <>
      ~s|AND resolutiondate >= "#{day_before(watermark)}" ORDER BY resolutiondate ASC, key ASC|
  end

  defp day_before(watermark) do
    case Date.from_iso8601(String.slice(watermark, 0, 10)) do
      {:ok, date} -> date |> Date.add(-1) |> Date.to_iso8601()
      {:error, _} -> raise ArgumentError, "invalid Jira watermark #{inspect(watermark)}"
    end
  end

  @doc "Map a Jira search response body into issues. Public for testing parsing."
  @spec parse_issues(map(), String.t() | nil, [String.t()]) :: [issue]
  def parse_issues(body, site_url \\ nil, options \\ [])

  def parse_issues(%{"issues" => issues}, site_url, options) when is_list(issues) do
    # Only the fields the project opted into, whatever the response carries.
    allowed = Map.take(@optional_fields, options) |> Map.values() |> List.flatten()

    Enum.map(issues, fn issue ->
      fields = issue["fields"] || %{}
      key = issue["key"]
      metadata = key |> metadata(fields, site_url) |> Map.drop(@optional_keys -- allowed)

      %{
        key: key,
        text: issue_text(key, fields, metadata),
        resolutiondate: fields["resolutiondate"],
        metadata: metadata
      }
    end)
  end

  def parse_issues(_body, _site_url, _options), do: []

  # Only the fields that are set: an unassigned issue has no "assignee" key.
  defp metadata(key, fields, site_url) do
    parent = fields["parent"] || %{}

    %{
      "issue_key" => key,
      "name" => Enum.join(Enum.reject([key, fields["summary"]], &blank?/1), ": "),
      "url" => if(site_url, do: "#{site_url}/browse/#{key}"),
      "resolutiondate" => fields["resolutiondate"],
      "issue_type" => get_in(fields, ["issuetype", "name"]),
      "status" => get_in(fields, ["status", "name"]),
      "resolution" => get_in(fields, ["resolution", "name"]),
      "assignee" => get_in(fields, ["assignee", "displayName"]),
      "reporter" => get_in(fields, ["reporter", "displayName"]),
      "parent" => parent["key"],
      "parent_type" => get_in(parent, ["fields", "issuetype", "name"]),
      "parent_summary" => get_in(parent, ["fields", "summary"])
    }
    |> Map.reject(fn {_k, v} -> blank?(v) end)
  end

  defp issue_text(key, fields, m) do
    status = Enum.join(Enum.reject([m["status"], m["resolution"]], &blank?/1), ", ")

    resolved =
      if is_binary(m["resolutiondate"]), do: String.slice(m["resolutiondate"], 0, 10)

    parent =
      if m["parent"] do
        type = if m["parent_type"], do: " (#{m["parent_type"]})"
        Enum.join(Enum.reject(["#{m["parent"]}#{type}", m["parent_summary"]], &blank?/1), ": ")
      end

    header =
      [
        "#{key}: #{fields["summary"]}",
        line([{"Type", m["issue_type"]}, {"Status", status}, {"Resolved", resolved}]),
        line([{"Assignee", m["assignee"]}, {"Reporter", m["reporter"]}]),
        line([{"Parent", parent}])
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    [header, extract_text(fields["description"])]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp line(pairs) do
    pairs
    |> Enum.reject(fn {_label, v} -> blank?(v) end)
    |> Enum.map_join(" · ", fn {label, v} -> "#{label}: #{v}" end)
  end

  defp blank?(v), do: v in [nil, ""]

  # Jira Cloud descriptions are Atlassian Document Format (nested content nodes);
  # walk it collecting text nodes. A plain string (older API) passes through.
  defp extract_text(nil), do: ""
  defp extract_text(text) when is_binary(text), do: text

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", &extract_text/1)
  end

  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(%{"type" => "hardBreak"}), do: "\n"
  defp extract_text(_), do: ""

  # Retry-After may be absent, an HTTP-date (RFC-allowed), or garbage — none of
  # which are a delta-seconds integer. Parse defensively and fall back to 60s so a
  # rate limit always yields {:snooze, _} rather than a raised (crashed) job.
  defp retry_after(resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, _} <- Integer.parse(value),
         true <- seconds > 0 do
      seconds
    else
      _ -> 60
    end
  end

  # Oban persists a failed job's error term to the jobs table (and logs it), so we
  # only keep a short, inspected prefix of the response body — enough to debug an
  # API error without spilling a full (potentially sensitive) payload into storage.
  defp truncate(body), do: body |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  defp req(creds) do
    [
      base_url: creds.base_url,
      auth: if(creds[:api_token], do: {:basic, "#{creds.email}:#{creds.api_token}"}),
      # We handle 429 ourselves ({:snooze, _}); disable Req's own retry so it
      # doesn't block for ~a minute backing off before returning.
      retry: false,
      # Real requests share the app-wide Finch pool started in the supervision
      # tree. Listed before the req_options() merge so a test override (a
      # Req.Test plug) wins — Req.Test doesn't use Finch at all.
      finch: RetrievalNode.Finch
    ]
    |> Keyword.merge(req_options())
    |> Req.new()
  end

  # Overridden in tests to inject a Req.Test plug (no real HTTP).
  defp req_options, do: Application.get_env(:retrieval_node, :jira_req_options, [])
end
