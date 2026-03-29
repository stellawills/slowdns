#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/env python3 /opt/slowdns-only/api/slowdns_only_api.py --config /opt/slowdns-only/config/config.json >>/opt/slowdns-only/logs/api.log 2>&1
