#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/env python3 /opt/slowdns/api/slowdns_only_api.py --config /opt/slowdns/config/config.json >>/opt/slowdns/logs/api.log 2>&1
