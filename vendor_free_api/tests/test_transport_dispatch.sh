#!/usr/bin/env bash
set -euo pipefail
PATH="/usr/bin:/bin:${PATH}"

# Sourcing computes the default interface; the dispatcher smoke has no network side effects.
ip() { :; }

TEST_DIR="${BASH_SOURCE[0]%/*}"
[[ "${TEST_DIR}" != "${BASH_SOURCE[0]}" ]] || TEST_DIR="."
source "${TEST_DIR}/../transport_stack.sh"

load_runtime_context() {
  SLOWDNS_UDP53_MODE="slowdns"
  OPENVPN_UDP_PUBLIC_PORTS="1194"
}
current_hysteria_enabled() { printf '0\n'; }
current_openvpn_enabled() { printf '0\n'; }
disable_openvpn_tcp_runtime() { :; }
configure_openvpn_server() { :; }
enable_openvpn_udp_runtime() { :; }
disable_openvpn_udp_runtime() { :; }
disable_slowdns_runtime() { :; }
configure_slowdns() { :; }
configure_udp53_mux() { :; }
sync_runtime_config() {
  printf '%s|%s|%s\n' "${SLOWDNS_UDP53_MODE}" "${ENABLE_OPENVPN}" "${OPENVPN_UDP_PUBLIC_PORTS}"
}

assert_mode() {
  local requested="$1"
  local expected="$2"
  local actual=""
  actual="$(dispatch_action set-udp53-mode "${requested}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'mode %s: expected %s, got %s\n' "${requested}" "${expected}" "${actual}" >&2
    return 1
  fi
}

assert_mode slowdns 'slowdns|0|1194'
assert_mode openvpn 'openvpn|1|53,1194'
assert_mode shared 'shared|1|53,1194'

printf 'transport dispatcher smoke: ok\n'
