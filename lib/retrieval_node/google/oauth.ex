defmodule RetrievalNode.Google.OAuth do
  @moduledoc """
  OAuth 2.0 for a Google "Desktop app" client, read-only Drive + Drive Labels.

  One-time consent, from the UI's Connections page (`RetrievalNodeWeb.ConnectionsLive`),
  yields a **refresh token**; from then on `access_token/0` trades it for
  short-lived access tokens, cached in `:persistent_term` until a minute
  before expiry. The redirect goes to the UI itself, at the endpoint's URL
  (`http://localhost:<port>/google/callback`, or `PHX_HOST` in prod): Desktop
  clients accept any loopback redirect, other hosts need a "Web application"
  client with that redirect URI registered.

  The client comes from the environment (`config/runtime.exs`):

      config :retrieval_node, :google,
        client_id: "...",        # GOOGLE_CLIENT_ID
        client_secret: "...",    # GOOGLE_CLIENT_SECRET
        refresh_token: "..."     # GOOGLE_REFRESH_TOKEN (optional override)

  The refresh token obtained on the Connections page is stored in
  `Secrets` (`google_refresh_token` in `<data dir>/secrets.toml`).
  `GOOGLE_REFRESH_TOKEN`, when set, takes precedence over it.

  Tests set `access_token:` directly to skip the token endpoint.
  """

  alias RetrievalNode.Secrets

  @scopes ~w(
    https://www.googleapis.com/auth/drive.readonly
    https://www.googleapis.com/auth/drive.labels.readonly
  )
  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @cache_key {__MODULE__, :access_token}
  @secret_key "google_refresh_token"
  @expiry_margin_s 60

  @doc "Whether a client id and secret are configured."
  def configured?, do: present?(config()[:client_id]) and present?(config()[:client_secret])

  @doc "Whether a refresh token (or a test access token) is configured."
  def authorized?, do: present?(refresh_token()) or present?(config()[:access_token])

  @doc "Where the refresh token comes from: `:env`, `:secrets` or nil."
  def token_source do
    cond do
      present?(config()[:refresh_token]) -> :env
      present?(Secrets.get(@secret_key)) -> :secrets
      true -> nil
    end
  end

  # The environment wins, so an operator can always override the stored token.
  defp refresh_token do
    case config()[:refresh_token] do
      token when is_binary(token) and token != "" -> token
      _ -> Secrets.get(@secret_key)
    end
  end

  @doc "URL the user opens to grant access; Google sends them back to `redirect_uri`."
  def authorize_url(state, redirect_uri) do
    query =
      URI.encode_query(%{
        client_id: fetch!(:client_id),
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: Enum.join(@scopes, " "),
        # offline + consent: always hand back a refresh token, even on re-consent.
        access_type: "offline",
        prompt: "consent",
        state: state
      })

    @auth_url <> "?" <> query
  end

  @doc """
  Exchanges an authorization code for tokens; returns the refresh token.
  `redirect_uri` must be the one the authorization was started with.
  """
  def exchange_code(code, redirect_uri) do
    case token_request(
           grant_type: "authorization_code",
           code: code,
           redirect_uri: redirect_uri
         ) do
      {:ok, %{"refresh_token" => refresh}} -> {:ok, refresh}
      {:ok, _} -> {:error, :no_refresh_token}
      error -> error
    end
  end

  @doc """
  Checks a refresh token obtained elsewhere (e.g. on a local run with the
  same client) by trading it once for an access token. Nothing is stored.
  """
  def verify_refresh_token(refresh) do
    case token_request(grant_type: "refresh_token", refresh_token: refresh) do
      {:ok, %{"access_token" => _}} -> :ok
      {:ok, _} -> {:error, :bad_token_response}
      error -> error
    end
  end

  @doc "A valid access token, refreshed when the cached one is about to expire."
  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    cfg = config()

    cond do
      present?(cfg[:access_token]) ->
        {:ok, cfg[:access_token]}

      # An empty GOOGLE_REFRESH_TOKEN= is "not authorized", not a token to send.
      not present?(refresh_token()) ->
        {:error, :google_not_authorized}

      true ->
        cached_or_refresh()
    end
  end

  defp cached_or_refresh do
    case :persistent_term.get(@cache_key, nil) do
      {token, expires_at} when is_binary(token) ->
        if System.system_time(:second) < expires_at, do: {:ok, token}, else: refresh()

      _ ->
        refresh()
    end
  end

  @doc "Drops the cached access token (after a 401)."
  def invalidate, do: :persistent_term.erase(@cache_key)

  @doc """
  Stores `refresh` (from a consent on the Connections page) in `Secrets`;
  it is used right away and after restarts.
  """
  def store_refresh_token(refresh) when is_binary(refresh) do
    :ok = Secrets.put(@secret_key, refresh)
    invalidate()
    :ok
  end

  @doc "Forgets the stored refresh token (Disconnect)."
  def forget_refresh_token do
    :ok = Secrets.delete(@secret_key)
    invalidate()
    :ok
  end

  defp refresh do
    case token_request(grant_type: "refresh_token", refresh_token: refresh_token()) do
      {:ok, %{"access_token" => token, "expires_in" => ttl}} ->
        expires_at = System.system_time(:second) + ttl - @expiry_margin_s
        :persistent_term.put(@cache_key, {token, expires_at})
        {:ok, token}

      {:ok, _} ->
        {:error, :bad_token_response}

      error ->
        error
    end
  end

  defp token_request(params) do
    form =
      Keyword.merge(params, client_id: fetch!(:client_id), client_secret: fetch!(:client_secret))

    opts =
      [url: config()[:token_url] || @token_url, form: form, retry: false]
      |> Keyword.merge(Application.get_env(:retrieval_node, :google_req_options, []))

    case Req.post(opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      # Google's error body is {"error": "...", "error_description": "..."} — no secrets.
      {:ok, %{status: status, body: body}} -> {:error, {:google_oauth, status, error_of(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_of(%{"error" => error}), do: error
  defp error_of(_), do: :unknown

  defp config, do: Application.get_env(:retrieval_node, :google, [])

  defp present?(value), do: is_binary(value) and value != ""

  defp fetch!(key) do
    case config()[key] do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise ArgumentError,
              "Google OAuth #{key} is not configured (GOOGLE_#{String.upcase(to_string(key))})"
    end
  end
end
