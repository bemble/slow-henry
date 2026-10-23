defmodule RetrievalNode.GitHub.OAuth do
  @moduledoc """
  GitHub user-to-server tokens from a **GitHub App**, through the OAuth
  device flow: the Connections page shows a code, the user enters it at
  github.com/login/device, and the app polls until GitHub hands back the
  tokens. No redirect, so it works from a headless server too.

  The App's permissions bound what the token can do (read-only Contents,
  Pull requests, Metadata), and it only reaches repos where the App is
  installed and the user has access. Access tokens last 8 h and are cached
  in `:persistent_term`; the refresh token (6 months) is stored in
  `Secrets` (`github_refresh_token`).

  GitHub **rotates** the refresh token on every refresh and a refresh token
  works once, so refreshes are serialized (`:global.trans/2`) and the new
  refresh token is stored before the access token is used: two concurrent
  refreshes would otherwise lose access.

  Config (`config/runtime.exs`): `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`
  (needed to refresh). `GITHUB_TOKEN`, when set (e.g. a fine-grained PAT),
  overrides the stored token and is never refreshed.
  """

  alias RetrievalNode.Secrets

  @device_code_url "https://github.com/login/device/code"
  @token_url "https://github.com/login/oauth/access_token"
  @api "https://api.github.com"
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  @secret_key "github_refresh_token"
  @cache_key {__MODULE__, :access_token}
  @expiry_margin_s 60

  @doc "Whether a GitHub App client id is configured."
  def configured?, do: present?(config()[:client_id])

  @doc "Where the token comes from: `:env`, `:secrets` or nil."
  def token_source do
    cond do
      present?(config()[:token]) -> :env
      present?(Secrets.get(@secret_key)) -> :secrets
      true -> nil
    end
  end

  @doc "Whether a token is available."
  def authorized?, do: token_source() != nil

  # --- device flow ---

  @doc """
  Starts the device flow. Returns `{:ok, %{device_code:, user_code:,
  verification_uri:, interval:, expires_in:}}`.
  """
  def start_device_flow do
    case post(@device_code_url, client_id: fetch!(:client_id)) do
      {:ok, %{"device_code" => code, "user_code" => user_code} = body} ->
        {:ok,
         %{
           device_code: code,
           user_code: user_code,
           verification_uri: body["verification_uri"],
           interval: body["interval"] || 5,
           expires_in: body["expires_in"] || 900
         }}

      {:ok, body} ->
        {:error, error_of(body)}

      error ->
        error
    end
  end

  @doc """
  Polls once for the device flow's result: `:ok` (tokens stored),
  `:pending`, `{:slow_down, interval}` or `{:error, reason}`.
  """
  def poll_device_flow(device_code) do
    case post(@token_url,
           client_id: fetch!(:client_id),
           device_code: device_code,
           grant_type: @device_grant
         ) do
      {:ok, %{"access_token" => _} = tokens} -> store(tokens)
      {:ok, %{"error" => "authorization_pending"}} -> :pending
      {:ok, %{"error" => "slow_down"} = body} -> {:slow_down, body["interval"] || 10}
      {:ok, body} -> {:error, error_of(body)}
      error -> error
    end
  end

  @doc "Forgets the stored token (Disconnect)."
  def forget do
    # Under the refresh lock: an in-flight refresh would store its rotated
    # token right after the delete.
    :global.trans({__MODULE__, self()}, fn ->
      :ok = Secrets.delete(@secret_key)
      invalidate()
    end)
  end

  @doc "Drops the cached access token (after a 401)."
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # --- access token ---

  @doc "A valid access token: `GITHUB_TOKEN`, the cached one, or a fresh refresh."
  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    cond do
      present?(config()[:token]) -> {:ok, config()[:token]}
      not present?(Secrets.get(@secret_key)) -> {:error, :github_not_authorized}
      true -> cached() || :global.trans({__MODULE__, self()}, &cached_or_refresh/0)
    end
  end

  # Another caller may have refreshed while this one waited for the lock.
  defp cached_or_refresh, do: cached() || refresh()

  defp cached do
    case :persistent_term.get(@cache_key, nil) do
      {token, expires_at} ->
        if System.system_time(:second) < expires_at, do: {:ok, token}

      nil ->
        nil
    end
  end

  defp refresh do
    case post(@token_url,
           client_id: fetch!(:client_id),
           client_secret: fetch!(:client_secret),
           grant_type: "refresh_token",
           refresh_token: Secrets.get(@secret_key)
         ) do
      {:ok, %{"access_token" => _} = tokens} ->
        :ok = store(tokens)
        cached()

      {:ok, body} ->
        {:error, {:github_oauth, error_of(body)}}

      error ->
        error
    end
  end

  # The new refresh token first: if it were lost, so would the access.
  defp store(%{"access_token" => access} = tokens) do
    if refresh = tokens["refresh_token"], do: :ok = Secrets.put(@secret_key, refresh)

    ttl = tokens["expires_in"] || 8 * 3600

    :persistent_term.put(
      @cache_key,
      {access, System.system_time(:second) + ttl - @expiry_margin_s}
    )

    :ok
  end

  # --- account ---

  @doc "The login of the token's user, for the Connections page."
  def login do
    with {:ok, token} <- access_token() do
      case Req.get(req(), url: @api <> "/user", auth: {:bearer, token}) do
        {:ok, %{status: 200, body: %{"login" => login}}} -> {:ok, login}
        {:ok, %{status: status}} -> {:error, {:github_http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- http ---

  defp post(url, form) do
    case Req.post(req(), url: url, form: form, headers: [accept: "application/json"]) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:github_http, status, error_of(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    [retry: false, finch: [name: RetrievalNode.Finch]]
    |> Keyword.merge(Application.get_env(:retrieval_node, :github_req_options, []))
    |> Req.new()
  end

  # GitHub's OAuth errors carry no secrets: {"error": "...", "error_description": "..."}.
  defp error_of(%{"error" => error}), do: error
  defp error_of(_), do: :unknown

  defp config, do: Application.get_env(:retrieval_node, :github, [])

  defp present?(value), do: is_binary(value) and value != ""

  defp fetch!(key) do
    case config()[key] do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise ArgumentError,
              "GitHub App #{key} is not configured (GITHUB_#{String.upcase(to_string(key))})"
    end
  end
end
