#!/usr/bin/env bash
# ---------------------------------------------------------------
# IPTunnel License Server — Quick Installer
# Deploy on: license.internetshub.com
#
# Usage:
#   bash install-license-server.sh
#   bash install-license-server.sh --token YOUR_MASTER_TOKEN
# ---------------------------------------------------------------
set -euo pipefail

INSTALL_DIR="/opt/license-server"
SERVICE_NAME="license-server"

# --- Parse args ------------------------------------------------
MASTER_TOKEN=""
PORT=9090
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)  MASTER_TOKEN="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    *)        echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Generate token if not provided ----------------------------
if [[ -z "$MASTER_TOKEN" ]]; then
  MASTER_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Generated master token (SAVE THIS — you need it later):   ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  printf "║  %-58s  ║\n" "$MASTER_TOKEN"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
fi

# --- Create directories ----------------------------------------
mkdir -p "$INSTALL_DIR"

# --- Write config ----------------------------------------------
cat >"${INSTALL_DIR}/config.json" <<EOF
{
    "bind": "0.0.0.0",
    "port": ${PORT},
    "master_token": "${MASTER_TOKEN}",
    "db_path": "${INSTALL_DIR}/license.db",
    "schema_path": "${INSTALL_DIR}/license_schema.sql"
}
EOF

echo "[+] Config written to ${INSTALL_DIR}/config.json"

# --- Deploy files ----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cp "${SCRIPT_DIR}/license_server.py"  "${INSTALL_DIR}/license_server.py"
cp "${SCRIPT_DIR}/license_schema.sql" "${INSTALL_DIR}/license_schema.sql"
chmod 755 "${INSTALL_DIR}/license_server.py"

echo "[+] Server files deployed to ${INSTALL_DIR}/"

# --- Install systemd service -----------------------------------
cp "${SCRIPT_DIR}/license-server.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "[+] Service '${SERVICE_NAME}' enabled and started"

# --- Verify ----------------------------------------------------
sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  License Server is RUNNING                                  ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  printf "║  URL:   http://0.0.0.0:%-37s  ║\n" "${PORT}"
  printf "║  Token: %-50s  ║\n" "${MASTER_TOKEN}"
  echo "║                                                              ║"
  echo "║  Test:  curl http://localhost:${PORT}/healthz                ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
else
  echo "[!] Service failed to start. Check: journalctl -u $SERVICE_NAME"
  exit 1
fi
