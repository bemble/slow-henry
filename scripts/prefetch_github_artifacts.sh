#!/usr/bin/env bash
#
# Downloads the build artifacts that deps fetch from GitHub releases, with curl,
# into the cache locations those deps already check before downloading.
#
# Why: since OTP 29.0.6 / 29.1, :httpc rejects responses whose headers exceed
# 10 KB by default ({:header_too_long, {:max, 10240}}), and GitHub's release
# download redirect sends ~11 KB (mostly content-security-policy). The deps
# below download with :httpc and don't raise that limit, so a build without a
# warm cache fails. Drop this script once they pass :max_header_size.
#
#   rustler_precompiled NIFs   $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
#     (tree_sitter_language_pack, tokenizers: any dep with a checksum-*.exs)
#   xla archive                $XLA_CACHE_DIR/<vsn>/download
#   tailwind (--tailwind)      _build/tailwind-<target>-<vsn>
#
# Run after `mix deps.get`, from the project root. Both cache variables must be
# absolute paths, set the same way for the later `mix compile`: under GitHub
# Actions the defaults below are exported through $GITHUB_ENV.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

with_tailwind=false
[ "${1:-}" = "--tailwind" ] && with_tailwind=true

: "${RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH:=$HOME/.cache/github-artifacts/rustler_precompiled}"
: "${XLA_CACHE_DIR:=$HOME/.cache/github-artifacts/xla}"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH" >>"$GITHUB_ENV"
  echo "XLA_CACHE_DIR=$XLA_CACHE_DIR" >>"$GITHUB_ENV"
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 tailwind_target=linux-x64 ;;
  aarch64 | arm64) arch=aarch64 tailwind_target=linux-arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# Version of a hex package in mix.lock.
locked_version() {
  grep -oE "\"$1\": \{:hex, :$1, \"[^\"]+\"" mix.lock | grep -oE '"[^"]+"$' | tr -d '"' ||
    die "$1 not found in mix.lock"
}

# fetch URL DEST [SHA256]: download unless DEST exists, then check the checksum.
fetch() {
  local url="$1" dest="$2" sha="${3:-}"
  if [ -f "$dest" ]; then
    log "cached: $dest"
  else
    log "downloading $url"
    mkdir -p "$(dirname "$dest")"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if [ -n "$sha" ] && ! echo "$sha  $dest" | sha256sum -c --quiet -; then
    rm -f "$dest"
    die "checksum mismatch for $dest"
  fi
}

# --- rustler_precompiled NIFs (every dep with a checksum-*.exs) ---------------
runtime_nif="$(erl -noshell -eval 'io:put_chars(erlang:system_info(nif_version)), halt().')"

for checksum in deps/*/checksum-*.exs; do
  [ -e "$checksum" ] || continue
  dep="$(basename "$(dirname "$checksum")")"
  vsn="$(locked_version "$dep")"
  crate="$(grep -rhoE 'crate: *"[^"]+"' "deps/$dep/lib" | head -1 | grep -oE '"[^"]+"' | tr -d '"')"
  repo="$(grep -oE '<<"GitHub">>,<<"https://github.com/[^"]+">>' "deps/$dep/hex_metadata.config" |
    grep -oE 'https://github.com/[^"]+')"
  [ -n "$crate" ] && [ -n "$repo" ] || die "$dep: could not find its crate name or GitHub repo"

  # Like rustler_precompiled: the newest of the dep's nif_versions (default
  # 2.15) that is not above the runtime's.
  declared="$(grep -rhoE 'nif_versions: *\[[^]]*\]' "deps/$dep/lib" | grep -oE '[0-9]+\.[0-9]+' || true)"
  nif=""
  for v in $(echo "${declared:-2.15}" | sort -uV); do
    [ "$(printf '%s\n%s\n' "$v" "$runtime_nif" | sort -V | head -1)" = "$v" ] && nif="$v"
  done
  [ -n "$nif" ] || die "$dep: no NIF version at or below the runtime's ($runtime_nif)"

  file="lib$crate-v$vsn-nif-$nif-$arch-unknown-linux-gnu.so.tar.gz"
  sha="$(grep -oE "\"$file\" => \"sha256:[0-9a-f]+\"" "$checksum" | grep -oE '[0-9a-f]{64}')"
  [ -n "$sha" ] || die "$dep: no checksum for $file"
  fetch "$repo/releases/download/v$vsn/$file" "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/$file" "$sha"
done

# --- XLA archive (used to build EXLA's NIF) -----------------------------------
# Fetched even when _build has EXLA compiled: a _build restored from another OTP
# version is recompiled, which needs the archive again.
vsn="$(locked_version xla)"
file="xla_extension-$vsn-$arch-linux-gnu-cpu.tar.gz"
sha="$(awk -v f="$file" '$2 == f { print $1 }' deps/xla/checksum.txt)"
[ -n "$sha" ] || die "no checksum for $file in deps/xla/checksum.txt"
fetch "https://github.com/elixir-nx/xla/releases/download/v$vsn/$file" \
  "$XLA_CACHE_DIR/$vsn/download/$file" "$sha"

# --- Tailwind binary (mix assets.setup installs it --if-missing) --------------
if $with_tailwind; then
  vsn="$(awk '/^config :tailwind,/ { f = 1 } f && /version:/ { gsub(/[^0-9.]/, "", $2); print $2; exit }' config/config.exs)"
  [ -n "$vsn" ] || die "tailwind version not found in config/config.exs"
  dest="_build/tailwind-$tailwind_target-$vsn"
  fetch "https://github.com/tailwindlabs/tailwindcss/releases/download/v$vsn/tailwindcss-$tailwind_target" "$dest"
  chmod +x "$dest"
fi
