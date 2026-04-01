#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_REPO_URL="https://github.com/stellawills/slowdns.git"
BOOTSTRAP_REF="main"
BOOTSTRAP_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/stellawills/slowdns/${BOOTSTRAP_REF}/scripts/install.sh"
BOOTSTRAP_ARCHIVE_URL="https://codeload.github.com/stellawills/slowdns/tar.gz/refs/heads/${BOOTSTRAP_REF}"
BOOTSTRAP_INSTALL_SCRIPT_SHA256="75252bf9de66767549a787bc658435b66cca746c76b6c1d6db66d79513ed1a14"
BOOTSTRAP_TMPDIR=""

cleanup_bootstrap() {
  local tmpdir="${BOOTSTRAP_TMPDIR:-}"
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
    return 0
  fi
  echo "No SHA-256 tool available (sha256sum, shasum, or openssl)." >&2
  exit 1
}

run_local_install() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "$script_dir/scripts/install.sh" || -f "$script_dir/scripts/install.sh" ]]; then
    exec bash "$script_dir/scripts/install.sh" "$@"
  fi
}

bootstrap_install() {
  local installer_path archive_path srcdir actual_hash
  BOOTSTRAP_TMPDIR="$(mktemp -d)"

  if command -v curl >/dev/null 2>&1; then
    archive_path="$BOOTSTRAP_TMPDIR/slowdns.tar.gz"
    curl -4fsSL "$BOOTSTRAP_ARCHIVE_URL" -o "$archive_path"
    tar -xzf "$archive_path" -C "$BOOTSTRAP_TMPDIR"
    srcdir="$(find "$BOOTSTRAP_TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [[ -z "${srcdir:-}" || ! -f "$srcdir/scripts/install.sh" ]]; then
      echo "Unable to prepare installer source tree from GitHub archive." >&2
      exit 1
    fi
    actual_hash="$(sha256_file "$srcdir/scripts/install.sh")"
    if [[ "$actual_hash" != "$BOOTSTRAP_INSTALL_SCRIPT_SHA256" ]]; then
      echo "Refusing to run bootstrap installer: checksum verification failed." >&2
      echo "expected: $BOOTSTRAP_INSTALL_SCRIPT_SHA256" >&2
      echo "actual:   $actual_hash" >&2
      exit 1
    fi
    exec bash "$srcdir/scripts/install.sh" "$@"
  fi

  if command -v git >/dev/null 2>&1; then
    srcdir="$BOOTSTRAP_TMPDIR/slowdns"
    git clone --depth 1 --branch "$BOOTSTRAP_REF" "$BOOTSTRAP_REPO_URL" "$srcdir"
    actual_hash="$(sha256_file "$srcdir/scripts/install.sh")"
    if [[ "$actual_hash" != "$BOOTSTRAP_INSTALL_SCRIPT_SHA256" ]]; then
      echo "Refusing to run cloned bootstrap installer: checksum verification failed." >&2
      echo "expected: $BOOTSTRAP_INSTALL_SCRIPT_SHA256" >&2
      echo "actual:   $actual_hash" >&2
      exit 1
    fi
    exec bash "$srcdir/scripts/install.sh" "$@"
  fi

  echo "Unable to bootstrap installer. Install curl or git, then retry." >&2
  exit 1
}

run_local_install "$@"
bootstrap_install "$@"
