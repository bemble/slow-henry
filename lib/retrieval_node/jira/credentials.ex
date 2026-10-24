defmodule RetrievalNode.Jira.Credentials do
  @moduledoc """
  Jira Cloud credentials: a site URL, an Atlassian account email and an API
  token (id.atlassian.com → Security → API tokens), sent as HTTP Basic auth.

  Entered on the UI's Connections page (`RetrievalNodeWeb.ConnectionsLive`),
  checked against Jira, then stored in `Secrets` (`jira_base_url`,
  `jira_email`, `jira_api_token` in `<data dir>/secrets.toml`); the token is
  never displayed. The environment overrides them as a set
  (`config/runtime.exs`):

      config :retrieval_node, :jira,
        base_url: "https://my-site.atlassian.net",   # JIRA_BASE_URL
        email: "me@example.com",                     # JIRA_EMAIL
        api_token: "..."                             # JIRA_API_TOKEN

  A scoped API token goes through `https://api.atlassian.com/ex/jira/<cloudId>`
  instead of the site URL; both work as `base_url`. The Connections page
  switches to it by itself when the site refuses a token
  (`RetrievalNode.Ingest.Jira.connect/1`), keeping the site as `site_url`
  (`jira_site_url`) for links to issues.
  """

  alias RetrievalNode.Secrets

  @keys [:base_url, :email, :api_token]

  @type t :: %{
          required(:base_url) => String.t(),
          required(:email) => String.t(),
          required(:api_token) => String.t(),
          optional(:site_url) => String.t() | nil
        }

  @doc "Where the credentials come from: `:env`, `:secrets` or nil."
  def source do
    cond do
      complete?(from_env()) -> :env
      complete?(from_secrets()) -> :secrets
      true -> nil
    end
  end

  @doc "Whether credentials are available."
  def configured?, do: source() != nil

  @doc "The credentials in use, environment first."
  @spec get() :: {:ok, t()} | {:error, :jira_not_configured}
  def get do
    case source() do
      :env -> {:ok, from_env()}
      :secrets -> {:ok, from_secrets()}
      nil -> {:error, :jira_not_configured}
    end
  end

  @doc "Stores credentials (after `RetrievalNode.Ingest.Jira.connect/1` accepted them)."
  @spec store(t()) :: :ok
  def store(%{base_url: base_url, email: email, api_token: token} = creds) do
    :ok = Secrets.put("jira_base_url", base_url)
    :ok = Secrets.put("jira_email", email)
    :ok = Secrets.put("jira_api_token", token)

    case creds[:site_url] do
      site when is_binary(site) and site != "" -> Secrets.put("jira_site_url", site)
      _ -> Secrets.delete("jira_site_url")
    end
  end

  @doc "Forgets the stored credentials (Disconnect)."
  def forget, do: Enum.each([:site_url | @keys], &Secrets.delete("jira_#{&1}"))

  @doc """
  Normalizes what was typed as the site: `my-site.atlassian.net`, a pasted
  Jira page URL or the scoped-token gateway URL. `:error` when it isn't a URL.
  """
  @spec normalize_base_url(String.t()) :: {:ok, String.t()} | :error
  def normalize_base_url(input) do
    input = String.trim(input)
    input = if input =~ ~r{\A[a-z]+://}i, do: input, else: "https://" <> input

    case URI.parse(input) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        {:ok, base(uri)}

      _ ->
        :error
    end
  end

  # The gateway keeps its /ex/jira/<cloudId> prefix; a site keeps only its host
  # (a pasted board or issue URL included).
  defp base(%URI{host: "api.atlassian.com", path: path} = uri) do
    case Regex.run(~r{\A/ex/jira/[^/]+}, path || "") do
      [prefix] -> "#{uri.scheme}://#{uri.host}#{prefix}"
      nil -> "#{uri.scheme}://#{uri.host}"
    end
  end

  defp base(%URI{port: port} = uri) when port in [80, 443, nil],
    do: "#{uri.scheme}://#{String.downcase(uri.host)}"

  defp base(uri), do: "#{uri.scheme}://#{String.downcase(uri.host)}:#{uri.port}"

  @doc "Whether `base_url` is the scoped-token gateway rather than a site."
  def gateway?(base_url), do: String.starts_with?(base_url, "https://api.atlassian.com/")

  @doc """
  The site that serves the Jira UI, for links to issues: `site_url`, else
  `base_url` unless it is the gateway (which doesn't serve the UI).
  """
  @spec site_url(t()) :: String.t() | nil
  def site_url(creds) do
    cond do
      is_binary(creds[:site_url]) and creds[:site_url] != "" -> creds.site_url
      gateway?(creds.base_url) -> nil
      true -> creds.base_url
    end
  end

  defp from_env do
    config = Application.get_env(:retrieval_node, :jira, [])
    Map.new(@keys, &{&1, config[&1]})
  end

  defp from_secrets, do: Map.new([:site_url | @keys], &{&1, Secrets.get("jira_#{&1}")})

  defp complete?(creds), do: Enum.all?(@keys, &present?(creds[&1]))

  defp present?(value), do: is_binary(value) and value != ""
end
