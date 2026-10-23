defmodule RetrievalNodeWeb.ConnectionsLive do
  @moduledoc """
  The external services Slow Henry talks to: the Ollama embedding server
  (when `OLLAMA_ENDPOINT` is set), and Google Drive authorization, entirely
  from the UI.

  Ollama's status is probed asynchronously on each visit (version, model
  pulled, a one-text embedding round trip); "Check again" re-probes.

  "Connect" sends the browser to Google's consent screen; Google redirects
  back to `/google/callback` on the endpoint's URL (`localhost:<port>`, or
  `PHX_HOST` in prod). A Desktop OAuth client accepts any loopback redirect;
  another host needs a "Web application" client with that exact redirect URI
  registered. The code is exchanged there and the refresh
  token stored in `<data dir>/secrets.toml` (`RetrievalNode.Secrets`); it is
  never displayed. "Disconnect" forgets it. `GOOGLE_REFRESH_TOKEN`, when set,
  overrides the stored one.

  When the browser can't reach the redirect (the server runs on another
  machine, so `localhost` is the wrong host), the page that fails to load
  still carries the code in its URL: paste it in the form below instead.

  `state` is a `Phoenix.Token`, so the callback needs no session and works
  whichever host name the page was opened with.
  """
  use RetrievalNodeWeb, :live_view

  alias RetrievalNode.Embedding
  alias RetrievalNode.Embedding.OllamaImpl
  alias RetrievalNode.GitHub.OAuth, as: GitHubOAuth
  alias RetrievalNode.Google.OAuth
  alias RetrievalNode.Ingest.Drive

  @state_salt "google-oauth-state"
  @state_max_age 15 * 60

  @impl true
  def mount(_params, _session, socket) do
    ollama? = Embedding.impl() == OllamaImpl

    socket =
      assign(socket,
        page_title: "Connections",
        result: nil,
        paste_form: to_form(%{"url" => ""}),
        ollama?: ollama?,
        ollama: nil,
        profile: Embedding.profile(),
        profiles: RetrievalNode.Inventory.embedding_profiles(),
        github: github_state(),
        device: nil,
        github_error: nil
      )

    socket = if ollama? and connected?(socket), do: probe_ollama(socket), else: socket
    {:ok, if(connected?(socket), do: fetch_github_login(socket), else: socket)}
  end

  defp github_state,
    do: %{configured: GitHubOAuth.configured?(), source: GitHubOAuth.token_source(), login: nil}

  defp fetch_github_login(socket) do
    if socket.assigns.github.source,
      do: start_async(socket, :github_login, &GitHubOAuth.login/0),
      else: socket
  end

  defp probe_ollama(socket) do
    socket |> assign(ollama: :checking) |> start_async(:ollama, &OllamaImpl.status/0)
  end

  @impl true
  def handle_async(:ollama, {:ok, status}, socket), do: {:noreply, assign(socket, ollama: status)}

  def handle_async(:github_login, {:ok, {:ok, login}}, socket),
    do: {:noreply, update(socket, :github, &Map.put(&1, :login, login))}

  def handle_async(:github_login, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, github_error: "Token rejected: #{inspect(reason)}")}

  def handle_async(:github_login, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:ollama, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket,
         ollama: %{reachable: false, error: inspect(reason), endpoint: nil, model: nil}
       )}

  @impl true
  def handle_info(:poll_github, %{assigns: %{device: nil}} = socket), do: {:noreply, socket}

  def handle_info(:poll_github, socket) do
    device = socket.assigns.device

    case GitHubOAuth.poll_device_flow(device.device_code) do
      :ok ->
        socket = assign(socket, device: nil, github: github_state())
        {:noreply, fetch_github_login(socket)}

      :pending ->
        Process.send_after(self(), :poll_github, device.interval * 1000)
        {:noreply, socket}

      {:slow_down, interval} ->
        Process.send_after(self(), :poll_github, interval * 1000)
        {:noreply, assign(socket, device: %{device | interval: interval})}

      {:error, reason} ->
        message =
          case reason do
            "expired_token" -> "The code expired: connect again."
            "access_denied" -> "Access was denied on GitHub."
            other -> "GitHub authorization failed: #{inspect(other)}"
          end

        {:noreply, assign(socket, device: nil, github_error: message)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        configured: OAuth.configured?(),
        authorized: OAuth.authorized?(),
        token_source: OAuth.token_source()
      )

    case socket.assigns.live_action do
      :callback ->
        # The exchange must happen once: on the connected mount only, never on
        # the static render (a code can be redeemed a single time).
        if connected?(socket) do
          {:noreply, socket |> complete(params) |> push_patch(to: ~p"/connections")}
        else
          {:noreply, assign(socket, auth_url: nil)}
        end

      :index ->
        {:noreply, assign(socket, auth_url: auth_url(socket))}
    end
  end

  @impl true
  def handle_event("check_ollama", _params, socket), do: {:noreply, probe_ollama(socket)}

  # GitHub device flow: show the code, then poll GitHub at its interval.
  def handle_event("connect_github", _params, socket) do
    case GitHubOAuth.start_device_flow() do
      {:ok, device} ->
        Process.send_after(self(), :poll_github, device.interval * 1000)
        {:noreply, assign(socket, device: device, github_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, github_error: "GitHub refused to start: #{inspect(reason)}")}
    end
  end

  def handle_event("disconnect_github", _params, socket) do
    :ok = GitHubOAuth.forget()
    {:noreply, assign(socket, github: github_state(), device: nil)}
  end

  def handle_event("disconnect_google", _params, socket) do
    :ok = OAuth.forget_refresh_token()

    {:noreply,
     assign(socket,
       authorized: OAuth.authorized?(),
       token_source: OAuth.token_source(),
       result: nil
     )}
  end

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

  # The endpoint's public URL: `localhost:<port>` unless PHX_HOST says
  # otherwise (a non-loopback host needs a "Web application" client).
  defp redirect_uri, do: url(~p"/google/callback")

  defp complete(socket, params) do
    case exchange(params) do
      {:ok, refresh} ->
        :ok = OAuth.store_refresh_token(refresh)

        assign(socket,
          authorized: true,
          token_source: OAuth.token_source(),
          result: %{stored: true, label: Drive.classification_label()}
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
    <Layouts.app flash={@flash} active={:connections}>
      <h1 class="text-2xl font-semibold">Connections</h1>

      <section id="ollama" class="space-y-2">
        <h2 class="text-lg font-semibold">Embeddings</h2>
        <p :if={!@ollama?} class="text-sm opacity-70">
          Computed in-process on the CPU. Set <code>OLLAMA_ENDPOINT</code>
          to use an Ollama server instead (see the README).
        </p>
        <.ollama_status :if={@ollama?} status={@ollama} />
        <.index_profiles profile={@profile} profiles={@profiles} />
      </section>

      <.github_section github={@github} device={@device} error={@github_error} />

      <div>
        <h2 class="text-lg font-semibold">Google Drive</h2>
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
        <button
          :if={@token_source == :secrets}
          id="disconnect-google"
          phx-click="disconnect_google"
          data-confirm="Forget the stored Google token? Drive sync stops until you reconnect."
          class="btn btn-ghost btn-sm"
        >
          Disconnect
        </button>
      </div>
      <p :if={@token_source} id="token-source" class="text-xs opacity-70">
        <span :if={@token_source == :secrets}>
          Token stored in <code>{RetrievalNode.Secrets.path()}</code>.
        </span>
        <span :if={@token_source == :env}>
          Token from <code>GOOGLE_REFRESH_TOKEN</code> (environment), which overrides
          <code>{RetrievalNode.Secrets.path()}</code>.
        </span>
      </p>

      <div :if={@result && @result[:error]} id="auth-error" role="alert" class="alert alert-error">
        <.icon name="hero-x-circle" class="size-5" />
        <span>{@result.error}</span>
      </div>

      <div :if={@result && @result[:stored]} id="auth-result" class="space-y-3">
        <div role="alert" class="alert alert-success">
          <.icon name="hero-check-circle" class="size-5" />
          <span>Authorized. The token is stored and used from now on, across restarts.</span>
        </div>

        <.label_check label={@result.label} />
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

  attr :github, :map, required: true
  attr :device, :any, required: true
  attr :error, :any, required: true

  defp github_section(assigns) do
    ~H"""
    <section id="github" class="space-y-2">
      <h2 class="text-lg font-semibold">GitHub</h2>
      <p class="text-sm opacity-70">
        A GitHub App's read-only token, for merged pull requests and private repo clones.
      </p>

      <div :if={!@github.configured} role="alert" class="alert alert-warning text-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          Set <code>GITHUB_CLIENT_ID</code> and <code>GITHUB_CLIENT_SECRET</code>
          (a GitHub App with Device Flow enabled) in the server's environment, then restart it.
        </span>
      </div>

      <div :if={@github.configured} class="flex flex-wrap items-center gap-3 text-sm">
        <span class={["badge", if(@github.source, do: "badge-success", else: "badge-ghost")]}>
          {if @github.source, do: "connected", else: "not connected"}
        </span>
        <span :if={@github.login}>as <strong>@{@github.login}</strong></span>
        <span :if={@github.source == :env} class="opacity-70">
          (token from <code>GITHUB_TOKEN</code>, which overrides the stored one)
        </span>
        <button
          :if={!@device}
          id="connect-github"
          phx-click="connect_github"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-link" class="size-4" />
          {if @github.source, do: "Reconnect GitHub", else: "Connect GitHub"}
        </button>
        <button
          :if={@github.source == :secrets}
          id="disconnect-github"
          phx-click="disconnect_github"
          data-confirm="Forget the stored GitHub token? PR sync stops until you reconnect."
          class="btn btn-ghost btn-sm"
        >
          Disconnect
        </button>
      </div>

      <div :if={@device} id="github-device" class="rounded-box border border-base-300 p-4 text-sm">
        <p>
          Open <a href={@device.verification_uri} target="_blank" class="link">{@device.verification_uri}</a>
          and enter this code:
        </p>
        <p class="my-2 font-mono text-2xl tracking-widest">{@device.user_code}</p>
        <p class="flex items-center gap-2 opacity-70">
          <span class="loading loading-spinner loading-xs"></span> Waiting for GitHub…
        </p>
      </div>

      <div :if={@error} id="github-error" role="alert" class="alert alert-error text-sm">
        <.icon name="hero-x-circle" class="size-5" />
        <span>{@error}</span>
      </div>
    </section>
    """
  end

  attr :profile, :string, required: true
  attr :profiles, :list, required: true

  # How much of the index was embedded with the current setup.
  defp index_profiles(assigns) do
    total = Enum.sum_by(assigns.profiles, &elem(&1, 1))

    current =
      Enum.find_value(assigns.profiles, 0, fn {p, n} -> if p == assigns.profile, do: n end)

    others = Enum.reject(assigns.profiles, fn {p, _} -> p == assigns.profile end)
    assigns = assign(assigns, total: total, current: current, others: others)

    ~H"""
    <div id="index-profiles" class="text-sm">
      <p>
        Index: <strong>{@current}</strong> of {@total} chunks embedded with the current setup
        <code class="text-xs">{@profile}</code>.
      </p>
      <div :if={@others != []} role="alert" class="alert alert-warning mt-2 text-sm">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <p>
            {@total - @current} chunks come from another setup, and vectors from different
            setups don't mix well: run <code>mix rn.reembed</code> (server stopped).
          </p>
          <ul class="mt-1 list-inside list-disc">
            <li :for={{p, n} <- @others}>
              <code class="text-xs">{p || "unrecorded (before profiles)"}</code>: {n}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :any, required: true

  defp ollama_status(%{status: s} = assigns) when s in [nil, :checking] do
    ~H"""
    <p id="ollama-status" class="flex items-center gap-2 text-sm">
      <span class="loading loading-spinner loading-xs"></span> Checking Ollama…
    </p>
    """
  end

  defp ollama_status(%{status: %{reachable: true}} = assigns) do
    ~H"""
    <div id="ollama-status" class="flex flex-wrap items-center gap-2 text-sm">
      <span class={["badge", if(ok?(@status), do: "badge-success", else: "badge-warning")]}>
        {if ok?(@status), do: "connected", else: "degraded"}
      </span>
      <span>Ollama {@status.version} at <code>{@status.endpoint}</code></span>
      <span :if={@status.model_pulled}>
        · model <code>{@status.model}</code>
        <span :if={match?({:ok, _}, @status.probe)}>· answered in {@status.probe_ms} ms</span>
      </span>
      <span :if={!@status.model_pulled} class="text-warning">
        · model <code>{@status.model}</code> is not pulled: <code>ollama pull {@status.model}</code>
      </span>
      <span :if={match?({:error, _}, @status.probe) and @status.model_pulled} class="text-error">
        · embedding failed: {elem(@status.probe, 1)}
      </span>
      <button phx-click="check_ollama" class="btn btn-ghost btn-xs">
        <.icon name="hero-arrow-path" class="size-4" /> Check again
      </button>
    </div>
    """
  end

  defp ollama_status(assigns) do
    ~H"""
    <div id="ollama-status" class="flex flex-wrap items-center gap-2 text-sm">
      <span class="badge badge-error">unreachable</span>
      <span>Ollama at <code>{@status.endpoint}</code>: {@status.error}</span>
      <button phx-click="check_ollama" class="btn btn-ghost btn-xs">
        <.icon name="hero-arrow-path" class="size-4" /> Check again
      </button>
    </div>
    """
  end

  defp ok?(status), do: status.model_pulled and match?({:ok, _}, status.probe)

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
