defmodule RetrievalNodeWeb.GoogleLive do
  @moduledoc """
  Google Drive authorization, entirely from the UI.

  "Connect" sends the browser to Google's consent screen; Google redirects
  back to `/google/callback` on this same server (a Desktop OAuth client
  accepts any loopback redirect). The code is exchanged there, the refresh
  token is shown **once** and used by this running node until restart — it is
  never written anywhere; persisting it as GOOGLE_REFRESH_TOKEN is up to you.

  When the browser can't reach the redirect (the server runs on another
  machine, so `localhost` is the wrong host), the page that fails to load
  still carries the code in its URL: paste it in the form below instead.

  `state` is a `Phoenix.Token`, so the callback needs no session and works
  whichever host name the page was opened with.
  """
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.Google.OAuth
  alias RetrievalNode.Ingest.Drive

  @state_salt "google-oauth-state"
  @state_max_age 15 * 60

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Google",
       result: nil,
       paste_form: to_form(%{"url" => ""})
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, configured: OAuth.configured?(), authorized: OAuth.authorized?())

    case socket.assigns.live_action do
      :callback ->
        # The exchange must happen once: on the connected mount only, never on
        # the static render (a code can be redeemed a single time).
        if connected?(socket) do
          {:noreply, socket |> complete(params) |> push_patch(to: ~p"/google")}
        else
          {:noreply, assign(socket, auth_url: nil)}
        end

      :index ->
        {:noreply, assign(socket, auth_url: auth_url(socket))}
    end
  end

  @impl true
  def handle_event("paste", %{"url" => url}, socket) do
    params =
      case URI.parse(String.trim(url)) do
        %URI{query: query} when is_binary(query) -> URI.decode_query(query)
        _ -> %{}
      end

    {:noreply, socket |> complete(params) |> assign(paste_form: to_form(%{"url" => ""}))}
  end

  defp auth_url(socket) do
    if socket.assigns.configured do
      state =
        Phoenix.Token.sign(RetrievalNodeWeb.Endpoint, @state_salt, :crypto.strong_rand_bytes(8))

      OAuth.authorize_url(state, redirect_uri())
    end
  end

  # Loopback, as Desktop clients require, on the port this server listens on.
  defp redirect_uri do
    port = RetrievalNodeWeb.Endpoint.config(:http)[:port]
    "http://localhost:#{port}/google/callback"
  end

  defp complete(socket, params) do
    case exchange(params) do
      {:ok, refresh} ->
        OAuth.use_refresh_token(refresh)

        assign(socket,
          authorized: true,
          result: %{token: refresh, label: Drive.classification_label()}
        )

      {:error, reason} ->
        assign(socket, result: %{error: describe(reason)})
    end
  end

  defp exchange(%{"error" => error}), do: {:error, {:denied, error}}

  defp exchange(%{"code" => code, "state" => state}) do
    with {:ok, _nonce} <-
           Phoenix.Token.verify(RetrievalNodeWeb.Endpoint, @state_salt, state,
             max_age: @state_max_age
           ) do
      OAuth.exchange_code(code, redirect_uri())
    end
  end

  defp exchange(_params), do: {:error, :no_code}

  defp describe({:denied, error}), do: "Google returned \"#{error}\" (access not granted)."
  defp describe(:expired), do: "This authorization link expired: start again."
  defp describe(:invalid), do: "The state doesn't match a link from this server: start again."
  defp describe(:no_code), do: "No authorization code in that URL."

  defp describe({:google_oauth, _status, error}),
    do: "Google refused the code (#{error}): start again."

  defp describe(other), do: "Authorization failed: #{inspect(other)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:google}>
      <div>
        <h1 class="text-2xl font-semibold">Google Drive access</h1>
        <p class="text-sm opacity-70">
          Read-only access to your Drive and its labels, for the Drive source in sources.toml.
        </p>
      </div>

      <div :if={!@configured} role="alert" class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          Set <code>GOOGLE_CLIENT_ID</code> and <code>GOOGLE_CLIENT_SECRET</code>
          (a "Desktop app" OAuth client) in the server's environment, then restart it.
        </span>
      </div>

      <div :if={@configured} class="flex flex-wrap items-center gap-3">
        <span class={["badge", if(@authorized, do: "badge-success", else: "badge-ghost")]}>
          {if @authorized, do: "authorized", else: "not authorized"}
        </span>
        <a :if={@auth_url} id="connect-google" href={@auth_url} class="btn btn-primary btn-sm">
          <.icon name="hero-link" class="size-4" />
          {if @authorized, do: "Reconnect Google Drive", else: "Connect Google Drive"}
        </a>
        <span :if={!@auth_url} class="loading loading-spinner loading-sm"></span>
      </div>

      <div :if={@result && @result[:error]} id="auth-error" role="alert" class="alert alert-error">
        <.icon name="hero-x-circle" class="size-5" />
        <span>{@result.error}</span>
      </div>

      <div :if={@result && @result[:token]} id="auth-result" class="space-y-3">
        <div role="alert" class="alert alert-success">
          <.icon name="hero-check-circle" class="size-5" />
          <span>Authorized. This server uses the token now, until it restarts.</span>
        </div>

        <.label_check label={@result.label} />

        <div class="rounded-box border border-base-300 p-4">
          <p class="mb-2 text-sm">
            To keep it across restarts, set this in the server's environment. It grants read access
            to your Drive: store it like a password. <strong>It is shown only once.</strong>
          </p>
          <pre id="refresh-token" class="overflow-x-auto rounded bg-base-200 p-3 text-xs select-all">GOOGLE_REFRESH_TOKEN={@result.token}</pre>
        </div>
      </div>

      <details :if={@configured} class="rounded-box border border-base-300 p-4">
        <summary class="cursor-pointer text-sm font-medium">
          The browser didn't come back here?
        </summary>
        <p class="my-2 text-sm opacity-70">
          When this server runs on another machine, Google's redirect to <code>localhost</code>
          fails to load. Copy that page's URL from the address bar and paste it here.
        </p>
        <.form for={@paste_form} id="paste-redirect" phx-submit="paste" class="flex gap-2">
          <div class="flex-1">
            <.input
              field={@paste_form[:url]}
              placeholder="http://localhost:4000/google/callback?state=…&code=…"
              autocomplete="off"
            />
          </div>
          <div><.button>Finish</.button></div>
        </.form>
      </details>
    </Layouts.app>
    """
  end

  attr :label, :any, required: true

  defp label_check(%{label: {:ok, %{allowed: allowed}}} = assigns) do
    assigns = assign(assigns, :count, MapSet.size(allowed))

    ~H"""
    <p id="label-check" class="text-sm">
      <.icon name="hero-tag" class="size-4" />
      Classification label found: {@count} indexable choice(s) (Public / Internal).
    </p>
    """
  end

  defp label_check(assigns) do
    ~H"""
    <div id="label-check" role="alert" class="alert alert-warning text-sm">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>
        The Classification label could not be read ({inspect(@label)}). Drive sync indexes nothing
        until it can: check that the Drive Labels API is enabled.
      </span>
    </div>
    """
  end
end
