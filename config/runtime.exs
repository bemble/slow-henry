import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/retrieval_node start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Google OAuth for the Drive source (see RetrievalNode.Google.OAuth and
# the UI's Settings page at /settings, stored by RetrievalNode.Secrets;
# GOOGLE_REFRESH_TOKEN overrides it). Read in every env but test, which stubs it.
if config_env() != :test do
  config :retrieval_node, :google,
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
    refresh_token: System.get_env("GOOGLE_REFRESH_TOKEN")
end

# Embeddings from Ollama (e.g. on the Mac's GPU) when OLLAMA_ENDPOINT is set;
# the in-process Bumblebee serving (~1 GB, CPU) is then not started at all.
if config_env() != :test do
  if endpoint = System.get_env("OLLAMA_ENDPOINT") do
    config :retrieval_node,
      embedding_impl: RetrievalNode.Embedding.OllamaImpl,
      embedding_serving_start: false

    config :retrieval_node, RetrievalNode.Embedding.OllamaImpl,
      endpoint: endpoint,
      model: System.get_env("OLLAMA_EMBEDDING_MODEL") || "nomic-embed-text"
  end
end

# Query-time reranking (the ~91 MB in-process cross-encoder, loaded and
# JIT-compiled at boot) only with RERANKING=true: off by default to spare small
# machines. Off, a `rerank: true` search keeps the RRF ranking.
if config_env() != :test do
  config :retrieval_node, reranking_serving_start: System.get_env("RERANKING") in ~w(true 1)
end

# GitHub App for merged PRs and private clones (RetrievalNode.GitHub.OAuth):
# connected from the Settings page, its refresh token stored by
# RetrievalNode.Secrets. GITHUB_TOKEN (e.g. a fine-grained PAT) overrides it.
if config_env() != :test do
  config :retrieval_node, :github,
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
    token: System.get_env("GITHUB_TOKEN")
end

# Jira Cloud API token for the [[jira]] sources (RetrievalNode.Jira.Credentials):
# entered on the Settings page and stored by RetrievalNode.Secrets. These
# three, when all set, override it.
if config_env() != :test do
  config :retrieval_node, :jira,
    base_url: System.get_env("JIRA_BASE_URL"),
    email: System.get_env("JIRA_EMAIL"),
    api_token: System.get_env("JIRA_API_TOKEN")
end

# Where the app keeps what it writes itself (secrets.toml, …): DATA_DIR,
# else ./data in dev and /var/lib/retrieval_node in a release.
cond do
  dir = System.get_env("DATA_DIR") -> config :retrieval_node, :data_dir, dir
  config_env() == :prod -> config :retrieval_node, :data_dir, "/var/lib/retrieval_node"
  true -> :ok
end

# How often the server re-reads sources.toml for changes (seconds).
if interval = System.get_env("SOURCES_WATCH_INTERVAL") do
  config :retrieval_node, :sources_watch_interval_ms, String.to_integer(interval) * 1000
end

if System.get_env("PHX_SERVER") do
  config :retrieval_node, RetrievalNodeWeb.Endpoint, server: true
end

if config_env() == :prod do
  # DATABASE_URL, or the same libpq PG* variables dev uses (see .env.example).
  connection =
    case System.get_env("DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        [url: url]

      _ ->
        unless System.get_env("PGHOST") && System.get_env("PGDATABASE") do
          raise """
          database connection is not configured: set DATABASE_URL
          (ecto://USER:PASS@HOST/DATABASE) or PGHOST + PGDATABASE
          (with PGUSER, PGPASSWORD, PGPORT as needed).
          """
        end

        [
          hostname: System.get_env("PGHOST"),
          port: String.to_integer(System.get_env("PGPORT") || "5432"),
          username: System.get_env("PGUSER") || "postgres",
          password: System.get_env("PGPASSWORD"),
          database: System.get_env("PGDATABASE")
        ]
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :retrieval_node,
         RetrievalNode.Repo,
         connection ++
           [
             # ssl: true,
             pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
             # For machines with several cores, consider starting multiple pools of `pool_size`
             # pool_count: 4,
             socket_options: maybe_ipv6
           ]

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :retrieval_node, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Bare git mirrors used for repo ingestion (see
  # lib/retrieval_node/ingest/git_mirror.ex). Defaults to the disk layout
  # created by deploy/setup_postgres.sh; override via GIT_MIRROR_ROOT if a
  # host uses a different mount for this.
  config :retrieval_node,
         :git_mirror_root,
         System.get_env("GIT_MIRROR_ROOT") || "/var/lib/retrieval_node/git-mirrors"

  config :retrieval_node, RetrievalNodeWeb.Endpoint,
    # v1 serves plain HTTP on the LAN (see Config.HTTPS's documented
    # LAN-only decision) — TLS termination via a tunnel is a fast-follow
    # once auth lands, so this stays "http" until that ships instead of
    # advertising a scheme/port the endpoint doesn't actually speak.
    url: [host: host, port: port, scheme: "http"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :retrieval_node, RetrievalNodeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :retrieval_node, RetrievalNodeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
