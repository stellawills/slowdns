#!/usr/bin/env bash
# ---------------------------------------------------------------
# IPTunnel PAM Authentication Script
# Called by pam_exec.so during SSH password authentication.
#
# Flow:
#   1. Check if the password is a valid session token (via API)
#   2. If yes → allow (exit 0)
#   3. If no  → reject with user-facing message (exit 1)
#
# The IPTunnel Android app calls /session-token first to get a
# one-time token, then uses it as the SSH password.
# Foreign apps use the raw static password → rejected here.
#
# Install:
#   In /etc/pam.d/sshd, add BEFORE @include common-auth:
#     auth requisite pam_exec.so expose_authtok quiet /usr/local/bin/iptunnel-pam-check
# ---------------------------------------------------------------

API_URL="http://127.0.0.1:8080"
SKIP_USERS="root"

# PAM provides the username
USER="${PAM_USER:-}"

# Skip PAM check for admin users (root, etc.)
for skip in $SKIP_USERS; do
    if [ "$USER" = "$skip" ]; then
        exit 0
    fi
done

# Read the password from stdin (pam_exec expose_authtok)
read -r PASSWORD

if [ -z "$PASSWORD" ]; then
    echo "⚠ Authentication rejected: This server only accepts connections from the IPTunnel app." >&2
    echo "  Download IPTunnel VPN on the Google Play Store to connect." >&2
    exit 1
fi

# Ask the API if this is a valid session token
RESPONSE=$(curl -sf -X POST "$API_URL/verify-session" \
    -H "Content-Type: application/json" \
    -d "{\"token\": \"${PASSWORD}\"}" \
    --max-time 3 2>/dev/null) || RESPONSE=""

# Check for "status":"ok" without python3 (avoids ~100ms startup penalty per SSH)
if echo "$RESPONSE" | grep -qF '"status":"ok"' 2>/dev/null; then
    exit 0
fi
if echo "$RESPONSE" | grep -qF '"status": "ok"' 2>/dev/null; then
    exit 0
fi

# Not a valid session token → reject with message
echo "⚠ Authentication rejected: This server only accepts connections from the IPTunnel app." >&2
echo "  Download IPTunnel VPN on the Google Play Store to connect." >&2
exit 1
