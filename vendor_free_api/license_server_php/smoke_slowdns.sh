#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${SLOWDNS_SMOKE_BASE_URL:-${1:-https://license.internetshub.com}}"
USER_AGENT="${SLOWDNS_SMOKE_USER_AGENT:-slowdns-smoke/1.0}"
PUBLIC_HOSTNAME="${SLOWDNS_TEST_HOSTNAME:-dns.example.com}"
PUBLIC_IP="${SLOWDNS_TEST_PUBLIC_IP:-203.0.113.10}"
MACHINE_ID="${SLOWDNS_TEST_MACHINE_ID:-slowdns-smoke-machine}"
SSH_FINGERPRINT="${SLOWDNS_TEST_SSH_FINGERPRINT:-SHA256:slowdns-smoke}"

COOKIE_JAR="$(mktemp)"
BODY_FILE=""
ACTIVATION_ID=""
INSTALL_TOKEN=""
CONFIRMED="false"

cleanup() {
  local release_body release_status
  if [[ -n "${BODY_FILE:-}" && -f "${BODY_FILE:-}" ]]; then
    rm -f "$BODY_FILE"
  fi
  if [[ -n "$ACTIVATION_ID" && "$CONFIRMED" != "true" ]]; then
    BODY_FILE="$(mktemp)"
    release_status="$(curl -fsS -A "$USER_AGENT" \
      -H 'Content-Type: application/json' \
      -o "$BODY_FILE" -w '%{http_code}' \
      -X POST "$BASE_URL/api/v2/slowdns/install/release" \
      -d "{\"activation_id\":\"$ACTIVATION_ID\"}" || true)"
    release_body="$(cat "$BODY_FILE" 2>/dev/null || true)"
    rm -f "$BODY_FILE"
    BODY_FILE=""
    if [[ "$release_status" =~ ^2 ]]; then
      printf 'Released unfinished activation %s\n' "$ACTIVATION_ID"
    elif [[ -n "$release_body" ]]; then
      printf 'Release skipped: %s\n' "$release_body"
    fi
  fi
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

json_get() {
  local path="$1"
  php -r '
    $data = json_decode(stream_get_contents(STDIN), true);
    if (!is_array($data)) {
        fwrite(STDERR, "invalid json\n");
        exit(1);
    }
    $node = $data;
    foreach (explode(".", $argv[1]) as $part) {
        if ($part === "") {
            continue;
        }
        if (!is_array($node) || !array_key_exists($part, $node)) {
            exit(2);
        }
        $node = $node[$part];
    }
    if (is_array($node)) {
        echo json_encode($node, JSON_UNESCAPED_SLASHES);
    } else {
        echo $node;
    }
  ' "$path"
}

request_json() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  BODY_FILE="$(mktemp)"
  if [[ -n "$data" ]]; then
    LAST_STATUS="$(curl -fsS -A "$USER_AGENT" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H 'Content-Type: application/json' \
      -o "$BODY_FILE" -w '%{http_code}' \
      -X "$method" "$BASE_URL$path" \
      -d "$data")"
  else
    LAST_STATUS="$(curl -fsS -A "$USER_AGENT" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -o "$BODY_FILE" -w '%{http_code}' \
      -X "$method" "$BASE_URL$path")"
  fi
  LAST_BODY="$(cat "$BODY_FILE")"
  rm -f "$BODY_FILE"
  BODY_FILE=""
}

printf 'Step 1/6: Seed browser session from %s/slowdns\n' "$BASE_URL"
curl -fsS -A "$USER_AGENT" -c "$COOKIE_JAR" "$BASE_URL/slowdns" >/dev/null

printf 'Step 2/6: Issue install code\n'
request_json POST /api/v2/slowdns/code/issue '{}'
INSTALL_CODE="$(printf '%s' "$LAST_BODY" | json_get 'data.install_code')"
printf 'Issued code: %s\n' "$INSTALL_CODE"

printf 'Step 3/6: Precheck install code\n'
PRECHECK_PAYLOAD="$(printf '{"install_code":"%s","machine_id":"%s","ssh_fingerprint":"%s","product":"slowdns","installer_version":"smoke"}' \
  "$INSTALL_CODE" "$MACHINE_ID" "$SSH_FINGERPRINT")"
request_json POST /api/v2/slowdns/install/precheck "$PRECHECK_PAYLOAD"
PRECHECK_TOKEN="$(printf '%s' "$LAST_BODY" | json_get 'data.precheck_token')"
printf 'Precheck token issued.\n'

printf 'Step 4/6: Activate install\n'
ACTIVATE_PAYLOAD="$(printf '{"install_code":"%s","precheck_token":"%s","hostname":"%s","public_ip":"%s","machine_id":"%s","ssh_fingerprint":"%s","requested_ref":"main","installer_version":"smoke"}' \
  "$INSTALL_CODE" "$PRECHECK_TOKEN" "$PUBLIC_HOSTNAME" "$PUBLIC_IP" "$MACHINE_ID" "$SSH_FINGERPRINT")"
request_json POST /api/v2/slowdns/install/activate "$ACTIVATE_PAYLOAD"
ACTIVATION_ID="$(printf '%s' "$LAST_BODY" | json_get 'data.activation_id')"
INSTALL_TOKEN="$(printf '%s' "$LAST_BODY" | json_get 'data.install_token')"
printf 'Activation id: %s\n' "$ACTIVATION_ID"

printf 'Step 5/6: Confirm install\n'
CONFIRM_PAYLOAD="$(printf '{"activation_id":"%s","install_token":"%s"}' "$ACTIVATION_ID" "$INSTALL_TOKEN")"
request_json POST /api/v2/slowdns/install/confirm "$CONFIRM_PAYLOAD"
CONFIRMED="true"
printf 'Install confirmed.\n'

printf 'Step 6/6: Verify code cannot be reused\n'
set +e
BODY_FILE="$(mktemp)"
REUSE_STATUS="$(curl -sS -A "$USER_AGENT" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
  -H 'Content-Type: application/json' \
  -o "$BODY_FILE" -w '%{http_code}' \
  -X POST "$BASE_URL/api/v2/slowdns/install/precheck" \
  -d "$PRECHECK_PAYLOAD")"
REUSE_BODY="$(cat "$BODY_FILE")"
rm -f "$BODY_FILE"
BODY_FILE=""
set -e

if [[ "$REUSE_STATUS" =~ ^2 ]]; then
  printf 'Smoke test failed: code was unexpectedly reusable.\n' >&2
  exit 1
fi

REUSE_ERROR="$(printf '%s' "$REUSE_BODY" | json_get 'error.code' || true)"
if [[ "$REUSE_ERROR" != "install_code_used" ]]; then
  printf 'Smoke test failed: expected install_code_used, got %s\n' "${REUSE_ERROR:-unknown}" >&2
  printf '%s\n' "$REUSE_BODY" >&2
  exit 1
fi

printf 'Smoke test complete. Code reuse correctly rejected with %s.\n' "$REUSE_ERROR"
