#!/usr/bin/env bash
set -euo pipefail

export SLOWDNS_LICENSE_URL="${SLOWDNS_LICENSE_URL:-https://license.internetshub.com/slowdns}"
export SLOWDNS_LICENSE_ENFORCE="${SLOWDNS_LICENSE_ENFORCE:-true}"

exec bash <(curl -4fsSL https://raw.githubusercontent.com/stellawills/slowdns/main/install.sh) "$@"
