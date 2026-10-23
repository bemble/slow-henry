# Production image: a `mix release` on Debian (glibc, which EXLA's XLA
# archive needs). Built natively per architecture (amd64, arm64) by
# .github/workflows/docker.yml — never under QEMU emulation: the EXLA and
# tree-sitter NIFs are arch-specific (see scripts/build_arm64.sh).
#
#   docker build -t slow-henry .
#
# Versions match .mise.toml and .github/workflows/ci.yml.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261005-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- Build ---------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# build-essential: EXLA's NIF shim; git: the heroicons/daisyui git deps.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Secret scanner used by Ingest.Scrubber (same version as .mise.toml). Fetched
# here so the runtime image needs no download tools beyond curl.
ARG GITLEAKS_VERSION=8.30.1
ARG TARGETARCH
RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${arch}.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Dependencies first, so their (slow: EXLA, NIFs) compile is cached until
# mix.lock or the compile-time config changes.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/

# GitHub-hosted artifacts (tree-sitter NIF, XLA archive, Tailwind) fetched with
# curl: OTP 29.1 :httpc rejects the ~11 KB headers of GitHub release downloads.
ENV RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/root/.cache/github-artifacts/rustler_precompiled \
    XLA_CACHE_DIR=/root/.cache/github-artifacts/xla
COPY scripts/prefetch_github_artifacts.sh scripts/
RUN scripts/prefetch_github_artifacts.sh --tailwind

RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile

# Tailwind scans lib/ for classes, so this runs after the sources are in.
RUN mix assets.deploy

# Prefetch the tree-sitter grammars straight into the release overlay:
# rel/env.sh.eex points XDG_CACHE_HOME at $RELEASE_ROOT/grammar-cache, so the
# image boots with a warm cache and needs no download at the first parse.
COPY rel rel
RUN XDG_CACHE_HOME=/app/rel/overlays/grammar-cache mix rn.grammars.prefetch

# Changes to runtime config don't require recompiling the code.
COPY config/runtime.exs config/
RUN mix release

# --- Runtime -------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

# git: bare mirrors of the indexed repos; curl: the healthcheck.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 ca-certificates git curl tini \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/gitleaks /usr/local/bin/gitleaks

# Everything the app writes lives under one volume: sources.toml and
# secrets.toml (DATA_DIR), the git mirrors, and the Bumblebee model cache
# (~1 GB, downloaded at first boot unless OLLAMA_ENDPOINT is set).
ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    HOME=/var/lib/retrieval_node \
    DATA_DIR=/var/lib/retrieval_node \
    GIT_MIRROR_ROOT=/var/lib/retrieval_node/git-mirrors \
    BUMBLEBEE_CACHE_DIR=/var/lib/retrieval_node/bumblebee

RUN useradd --system --uid 1000 --user-group --home-dir /var/lib/retrieval_node app \
  && mkdir -p /var/lib/retrieval_node/git-mirrors /var/lib/retrieval_node/bumblebee \
  && chown -R app:app /var/lib/retrieval_node

WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/retrieval_node ./
COPY --chmod=755 rel/docker/entrypoint.sh /usr/local/bin/entrypoint.sh

USER app
VOLUME /var/lib/retrieval_node
EXPOSE 4000

# /healthz is readiness: it waits for the embedding model to warm up, which
# takes a while on first boot (model download + JIT compile).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 \
  CMD curl -fsS "http://localhost:${PORT}/healthz" > /dev/null || exit 1

ENTRYPOINT ["tini", "--", "entrypoint.sh"]
CMD ["start"]
