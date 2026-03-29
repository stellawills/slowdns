#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/env python3 /opt/slowdns-only/api/slowdns_only_api.py --config /opt/slowdns-only/config/config.json --expire-sync >>/opt/slowdns-only/logs/expire-sync.log 2>&1
