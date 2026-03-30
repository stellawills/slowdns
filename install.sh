#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_REPO_URL="${SLOWDNS_BOOTSTRAP_REPO_URL:-https://github.com/stellawills/slowdns.git}"
BOOTSTRAP_REF="${SLOWDNS_BOOTSTRAP_REF:-main}"
BOOTSTRAP_ARCHIVE_URL="${SLOWDNS_BOOTSTRAP_ARCHIVE_URL:-https://codeload.github.com/stellawills/slowdns/tar.gz/refs/heads/${BOOTSTRAP_REF}}"
BOOTSTRAP_TMPDIR=""

cleanup_bootstrap() {
  local tmpdir="${BOOTSTRAP_TMPDIR:-}"
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}

run_local_install() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "$script_dir/scripts/install.sh" || -f "$script_dir/scripts/install.sh" ]]; then
    exec bash "$script_dir/scripts/install.sh" "$@"
  fi
}

bootstrap_install() {
  local archive_path srcdir
  BOOTSTRAP_TMPDIR="$(mktemp -d)"
  archive_path="$BOOTSTRAP_TMPDIR/slowdns.tar.gz"
  trap cleanup_bootstrap EXIT

  if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    curl -4fsSL "$BOOTSTRAP_ARCHIVE_URL" -o "$archive_path"
    tar -xzf "$archive_path" -C "$BOOTSTRAP_TMPDIR"
    srcdir="$(find "$BOOTSTRAP_TMPDIR" -maxdepth 1 -type d -name 'slowdns-*' | head -n1)"
    if [[ -n "$srcdir" && -f "$srcdir/scripts/install.sh" ]]; then
      bash "$srcdir/scripts/install.sh" "$@"
      return $?
    fi
  fi

  if command -v git >/dev/null 2>&1; then
    srcdir="$BOOTSTRAP_TMPDIR/slowdns"
    git clone --depth 1 --branch "$BOOTSTRAP_REF" "$BOOTSTRAP_REPO_URL" "$srcdir"
    bash "$srcdir/scripts/install.sh" "$@"
    return $?
  fi

  echo "Unable to bootstrap installer. Install curl+tar or git, then retry." >&2
  exit 1
}

run_local_install "$@"
bootstrap_install "$@"
