#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${IPTUNNEL_CONFIG:-/etc/iptunnel/config.json}"
API_SCHEME="${IPTUNNEL_API_SCHEME:-http}"
API_HOST="${IPTUNNEL_API_HOST:-127.0.0.1}"
API_BASE="${IPTUNNEL_API_BASE:-}"
API_KEY="${IPTUNNEL_API_KEY:-}"
API_PORT=""
DOMAIN=""
PUBLIC_IP=""
API_RESPONSE=""
API_STATUS=""
PROTOCOL_KEY=""
PROTOCOL_LABEL=""
POST_ACTION_PAUSE="1"

# ══════════════════════════════════════════════════════════════════════
#  THEME — Dark, clean, minimal. Matches the web admin panel.
# ══════════════════════════════════════════════════════════════════════

# Colors
C_BG=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'
C_RED=$'\033[38;5;210m'
C_GREEN=$'\033[38;5;114m'
C_YELLOW=$'\033[38;5;222m'
C_BLUE=$'\033[38;5;110m'
C_CYAN=$'\033[38;5;116m'
C_PURPLE=$'\033[38;5;183m'
C_MUTED=$'\033[38;5;243m'
C_WHITE=$'\033[38;5;255m'
C_SURFACE=$'\033[38;5;238m'
MENU_VERSION="2026.09.06.1"

# Box width (inner content)
W=68

# ── Drawing primitives ───────────────────────────────────────────────

_rep() { local i s=""; for ((i=0;i<$1;i++)); do s="${s}${2}"; done; printf '%s' "$s"; }

# Horizontal rule
hr() { printf '  %s%s%s\n' "$C_SURFACE" "$(_rep $W '─')" "$C_RESET"; }

# Section header — styled block
section() {
  local title="$1"
  echo
  printf '  %s%s %s %s\n' "$C_BOLD" "$C_BLUE" "$title" "$C_RESET"
  printf '  %s%s%s\n' "$C_SURFACE" "$(_rep ${#title} '━')" "$C_RESET"
}

# Subsection label
label() {
  printf '  %s%s%s\n' "$C_MUTED" "$1" "$C_RESET"
}

# Menu item — number + title + optional description
mi() {
  local num="$1" title="$2" desc="${3:-}"
  if [[ -n "$desc" ]]; then
    printf '  %s[%s%s%s]%s  %-24s %s%s%s\n' "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" "$title" "$C_MUTED" "$desc" "$C_RESET"
  else
    printf '  %s[%s%s%s]%s  %s\n' "$C_SURFACE" "$C_BLUE" "$num" "$C_SURFACE" "$C_RESET" "$title"
  fi
}

# Status indicator
_dot() {
  if [[ "$1" == "1" ]]; then
    printf '%s●%s' "$C_GREEN" "$C_RESET"
  else
    printf '%s○%s' "$C_RED" "$C_RESET"
  fi
}

_status_label() {
  if [[ "$1" == "1" ]]; then
    printf '%senabled%s' "$C_GREEN" "$C_RESET"
  else
    printf '%sdisabled%s' "$C_MUTED" "$C_RESET"
  fi
}

_blocked_label() {
  if [[ "$1" == "1" ]]; then
    printf '%sblocked%s' "$C_RED" "$C_RESET"
  else
    printf '%sallowed%s' "$C_GREEN" "$C_RESET"
  fi
}

dot_ok()  { printf '%s✔%s' "$C_GREEN" "$C_RESET"; }
dot_err() { printf '%s✘%s' "$C_RED" "$C_RESET"; }

# Prompt — writes to /dev/tty so command substitutions only capture the answer
ask() {
  local reply=""
  if [[ -e /dev/tty ]]; then
    printf '\n  %s>%s ' "$C_BLUE" "$C_RESET" > /dev/tty
    IFS= read -r reply < /dev/tty
  else
    printf '\n  %s>%s ' "$C_BLUE" "$C_RESET"
    IFS= read -r reply
  fi
  printf '%s\n' "$reply"
}

ask_prompt() {
  local prompt="$1" reply=""
  if [[ -e /dev/tty ]]; then
    printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET" > /dev/tty
    IFS= read -r reply < /dev/tty
  else
    printf '  %s%s%s: ' "$C_MUTED" "$prompt" "$C_RESET"
    IFS= read -r reply
  fi
  printf '%s\n' "$reply"
}

pause() {
  echo
  if [[ -e /dev/tty ]]; then
    printf '  %sPress Enter to continue...%s' "$C_MUTED" "$C_RESET" > /dev/tty
    IFS= read -r _ < /dev/tty
  else
    printf '  %sPress Enter to continue...%s' "$C_MUTED" "$C_RESET"
    IFS= read -r _
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════

print_banner() {
  clear
  echo
  printf '  %s%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s                                                                    %s%s║%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██╗%s%s██████╗%s %s████████╗%s%s██╗   ██╗%s%s███╗   ██╗%s%s███╗   ██╗%s%s███████╗%s%s██╗%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██╔══██╗%s%s╚══██╔══╝%s%s██║   ██║%s%s████╗  ██║%s%s████╗  ██║%s%s██╔════╝%s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██████╔╝%s%s   ██║   %s%s██║   ██║%s%s██╔██╗ ██║%s%s██╔██╗ ██║%s%s█████╗  %s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██╔═══╝ %s%s   ██║   %s%s██║   ██║%s%s██║╚██╗██║%s%s██║╚██╗██║%s%s██╔══╝  %s%s██║%s     %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s██║%s%s██║     %s%s   ██║   %s%s╚██████╔╝%s%s██║ ╚████║%s%s██║ ╚████║%s%s███████╗%s%s███████╗%s %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s     %s╚═╝%s%s╚═╝     %s%s   ╚═╝   %s%s ╚═════╝ %s%s╚═╝  ╚═══╝%s%s╚═╝  ╚═══╝%s%s╚══════╝%s%s╚══════╝%s %s%s║%s\n' \
    "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_BLUE" "$C_RESET"
  printf '  %s%s║%s                                                                    %s%s║%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_BLUE" "" "$C_RESET"
  printf '  %s%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  echo
}

print_header() {
  print_banner

  # Server info bar
  printf '  %s┌─────────────────────────────────────────────────────────────────────┐%s\n' "$C_SURFACE" "$C_RESET"
  printf '  %s│%s  %-10s %s%-28s%s  %-8s %s%-17s%s  %s│%s\n' \
    "$C_SURFACE" "$C_RESET" \
    "Domain" "$C_WHITE" "${DOMAIN:-unknown}" "$C_RESET" \
    "IP" "$C_CYAN" "${PUBLIC_IP:-unknown}" "$C_RESET" \
    "$C_SURFACE" "$C_RESET"
  printf '  %s│%s  %-10s %s%-56s%s%s│%s\n' \
    "$C_SURFACE" "$C_RESET" \
    "API" "$C_MUTED" "${API_BASE}" "$C_RESET" \
    "$C_SURFACE" "$C_RESET"
  printf '  %s└─────────────────────────────────────────────────────────────────────┘%s\n' "$C_SURFACE" "$C_RESET"
}

# ══════════════════════════════════════════════════════════════════════
#  UTILITIES
# ══════════════════════════════════════════════════════════════════════

need_commands() {
  command -v curl    >/dev/null 2>&1 || { echo "curl is required";    exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
}

load_config() {
  [[ -f "$CONFIG_PATH" ]] || { echo "IPTunnel config not found at $CONFIG_PATH"; exit 1; }

  local cfg=()
  mapfile -t cfg < <(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("port", 8080))
print(c.get("api_key", ""))
print(c.get("hostname", "localhost"))
print(c.get("public_ip", ""))
PY
  )

  API_PORT="${cfg[0]:-8080}"
  [[ -z "$API_KEY" ]] && API_KEY="${cfg[1]:-}"
  DOMAIN="${cfg[2]:-localhost}"
  PUBLIC_IP="${cfg[3]:-}"
  [[ -n "$API_BASE" ]] || API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
  [[ -n "$API_KEY" ]] || { echo "API key missing. Set IPTUNNEL_API_KEY or fix $CONFIG_PATH"; exit 1; }
}

ensure_api_base() {
  [[ -n "$API_PORT" && -n "$API_KEY" ]] || load_config

  if [[ -z "${API_BASE:-}" ]]; then
    API_BASE="${API_SCHEME}://${API_HOST}:${API_PORT}"
  elif [[ "$API_BASE" != http://* && "$API_BASE" != https://* ]]; then
    if [[ "$API_BASE" == /* ]]; then
      API_BASE=""
    else
      API_BASE="${API_SCHEME}://${API_BASE}"
    fi
  fi

  API_BASE="${API_BASE%/}"
  if [[ ! "$API_BASE" =~ ^https?://[^/]+$ ]]; then
    API_BASE=""
    return 1
  fi

  return 0
}

build_api_url() {
  local path="$1" base host_part
  ensure_api_base || return 1
  base="${API_BASE//$'\r'/}"
  base="${base//$'\n'/}"
  base="${base%/}"
  [[ "$path" == /* ]] || path="/${path}"
  if [[ ! "$base" =~ ^https?://[^/]+$ ]]; then
    return 1
  fi
  printf '%s%s\n' "$base" "$path"
}

api_curl_noproxy_args() {
  # The menu only ever talks to this machine's own iptunnel API, so it must
  # never be routed through an http_proxy/https_proxy set in the environment.
  # A configured public IP/domain base (or a leaked proxy env var) would
  # otherwise send the request to an intercepting proxy (e.g. Squid), which
  # rejects it with ERR_INVALID_URL / HTTP 400. Disable proxying for all hosts.
  printf '%s\n' "--noproxy" "*"
}

api_response_is_squid_invalid_url() {
  local body="$1"
  [[ "$body" == *"ERR_INVALID_URL"* && "$body" == *"Squid"* ]]
}

force_local_api_base() {
  API_BASE="http://127.0.0.1:${API_PORT:-8080}"
}

configured_services() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
svcs = ["iptunnel-api","iptunnel-ssh-ws","iptunnel-ssh-ssl","iptunnel-vmess",
        "iptunnel-vless","iptunnel-trojan","iptunnel-slowdns","iptunnel-slowdns-target",
        "iptunnel-edge-proxy",
        "nginx","dropbear","ssh"]
h = c.get("hysteria") or {}
if h.get("enabled"):
    svcs += ["iptunnel-hysteria","hysteria-server"]
p = (c.get("ssh") or {}).get("ports") or {}
if str(p.get("ovpntcp","-")) != "-" or str(p.get("ovpnudp","-")) != "-":
    svcs += ["openvpn-server@iptunnel-tcp","openvpn-server@iptunnel-udp"]
[print(s) for s in svcs]
PY
}

transport_module_state() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
h = c.get("hysteria") or {}
p = (c.get("ssh") or {}).get("ports") or {}
slowdns = c.get("slowdns") or {}
openvpn = c.get("openvpn") or {}
udp53_mode = str(slowdns.get("udp53_mode", "slowdns") or "slowdns")
ovpn_enabled = bool(openvpn.get("enabled", False))
raw_ports = openvpn.get("udp_public_ports")
if isinstance(raw_ports, str):
    candidates = raw_ports.split(",")
elif isinstance(raw_ports, list):
    candidates = raw_ports
else:
    candidates = []
if not candidates and openvpn.get("udp_public_port") not in {None, "", "-"}:
    candidates = [openvpn.get("udp_public_port")]
ports = []
for candidate in candidates:
    try:
        port = int(str(candidate).strip())
    except (TypeError, ValueError):
        continue
    if 1 <= port <= 65535 and port not in ports:
        ports.append(port)
if udp53_mode in {"openvpn", "shared"}:
    ports = [53, *[port for port in ports if port != 53]]
else:
    ports = [port for port in ports if port != 53]
ovpn_udp_port = ",".join(str(port) for port in ports) if ovpn_enabled and ports else "-"
print("1" if h.get("enabled") else "0")
print(str(p.get("ovpntcp","-")))
print(ovpn_udp_port)
print(udp53_mode)
print(ovpn_udp_port)
print("1" if slowdns.get("enabled", True) else "0")
try:
    mtu = int(slowdns.get("mtu") or 1232)
except (TypeError, ValueError):
    mtu = 1232
print(mtu)
PY
}

domain_state() {
  python3 - "$CONFIG_PATH" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
s = c.get("slowdns") or {}
host = c.get("hostname", "")
print(host)
print(s.get("tunnel_domain", "") or ("dns." + host if host else ""))
PY
}

run_transport_action() {
  IPTUNNEL_CONFIG_PATH="$CONFIG_PATH" /opt/iptunnel/transport_stack.sh "$1"
}

# ══════════════════════════════════════════════════════════════════════
#  API HELPERS
# ══════════════════════════════════════════════════════════════════════

json_message() {
  PAYLOAD="$1" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
if not raw: raise SystemExit(0)
try: payload = json.loads(raw)
except Exception: raise SystemExit(0)
if isinstance(payload, dict):
    error = payload.get("error")
    if isinstance(error, dict) and error.get("message"):
        print(str(error.get("message", "")))
        raise SystemExit(0)
    meta = payload.get("meta")
    if isinstance(meta, dict) and meta.get("message"):
        print(str(meta.get("message", "")))
        raise SystemExit(0)
    if "status" in payload and len(payload) == 1:
        print(str(payload.get("status", "")))
PY
}

json_data_field() {
  PAYLOAD="$1" FIELD="$2" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
field = os.environ.get("FIELD", "")
if not raw or not field:
    raise SystemExit(0)
try:
    payload = json.loads(raw)
except Exception:
    raise SystemExit(0)
if isinstance(payload, dict) and {"data", "meta", "error"}.issubset(payload.keys()):
    payload = payload.get("data")
if not isinstance(payload, dict):
    raise SystemExit(0)
value = payload.get(field)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

render_api_body() {
  PAYLOAD="$1" python3 - <<'PY'
import json, os
raw = os.environ.get("PAYLOAD", "")
if not raw: raise SystemExit(0)
try: payload = json.loads(raw)
except Exception: print(raw); raise SystemExit(0)

def titleize(value):
    text = str(value).replace("_", " ").strip()
    if not text:
        return ""
    return text[:1].upper() + text[1:]

def scalar(value):
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, list):
        return ",".join(str(item) for item in value)
    if value is None:
        return "-"
    return str(value)

def print_rows(rows, indent=2):
    rows = [(label, value) for label, value in rows if value not in ("", None)]
    if not rows:
        return False
    pad = " " * indent
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        print(f"{pad}{label:<{width}} : {scalar(value)}")
    return True

def print_subsection(title, indent=2):
    pad = " " * indent
    line = "-" * max(8, len(title))
    print(f"{pad}{title}")
    print(f"{pad}{line}")

def print_dict_rows(mapping, indent=4, preferred=None, rename=None, skip_values=None):
    if not isinstance(mapping, dict):
        return False
    rename = rename or {}
    skip = {"", None}
    if skip_values:
        skip.update(skip_values)
    rows = []
    seen = set()
    for key in preferred or []:
        if key in mapping:
            value = mapping.get(key)
            if value not in skip:
                rows.append((rename.get(key, titleize(key)), value))
            seen.add(key)
    for key, value in mapping.items():
        if key in seen or value in skip:
            continue
        rows.append((rename.get(key, titleize(key)), value))
    return print_rows(rows, indent=indent)

def print_list_rows(label, value, indent=4):
    if value in ("", None, []):
        return False
    items = value if isinstance(value, list) else [part.strip() for part in str(value).split(",") if part.strip()]
    if not items:
        return False
    print(" " * indent + f"{label}:")
    for item in items:
        print(" " * (indent + 2) + f"- {item}")
    return True

def print_protocol_paths(title, path_info, indent=2):
    if not isinstance(path_info, dict) or not path_info:
        return False
    print_subsection(title, indent=indent)
    rename = {
        "primary": "Primary path",
        "grpc": "gRPC service",
        "multi": "Multi path",
        "stn": "STN path",
        "up": "Upgrade path",
    }
    rendered = False
    for key in ("vmess", "vless", "trojan"):
        block = path_info.get(key)
        if not isinstance(block, dict):
            continue
        print(" " * (indent + 2) + titleize(key))
        print(" " * (indent + 2) + "~" * max(5, len(titleize(key))))
        print_dict_rows(block, indent=indent + 4, preferred=["primary", "grpc", "multi", "stn", "up"], rename=rename)
        print()
        rendered = True
    return rendered

def update_status_label(value):
    mapping = {
        "up_to_date": "Up to date",
        "update_available": "Update available",
        "local_ahead": "Installed build is newer",
        "unavailable": "Update server unavailable",
        "unknown": "Unable to compare versions",
    }
    return mapping.get(str(value), titleize(value))

def render_update(obj):
    rows = [
        ("Installed version", obj.get("installed")),
        ("Latest version", obj.get("remote") or "-"),
        ("Status", update_status_label(obj.get("status"))),
        ("Manifest URL", obj.get("url")),
        ("Installer URL", obj.get("installer_url")),
    ]
    printed = print_rows(rows)
    notes = str(obj.get("notes") or "").strip()
    error = str(obj.get("error") or "").strip()
    if notes:
        if printed:
            print()
        print("  Release notes")
        print("  -------------")
        print(f"  {notes}")
    if error:
        if printed or notes:
            print()
        print("  Error")
        print("  -----")
        print(f"  {error}")

def render_certificate(obj):
    state = "Ready"
    if not obj.get("installed"):
        state = "Not installed"
    elif obj.get("reinstalled"):
        state = "Reinstalled"
    elif obj.get("already_installed"):
        state = "Already installed"
    rows = [
        ("Domain", obj.get("domain")),
        ("State", state),
        ("Installed", obj.get("installed")),
        ("Active", obj.get("active")),
        ("Issuer", obj.get("issuer")),
        ("Valid from", obj.get("valid_from")),
        ("Valid until", obj.get("valid_until")),
        ("Days remaining", obj.get("days_remaining")),
        ("Certificate", obj.get("certificate_path")),
        ("Private key", obj.get("private_key_path")),
        ("Stunnel bundle", obj.get("stunnel_bundle_path")),
        ("Live directory", obj.get("live_directory")),
    ]
    print_rows(rows)

def render_action_result(obj):
    print_subsection("Result")
    rows = []
    if "status" in obj:
        rows.append(("Status", obj.get("status")))
    if "username" in obj:
        rows.append(("Username", obj.get("username")))
    if "from" in obj:
        rows.append(("Previous expiry", obj.get("from")))
    if "to" in obj:
        rows.append(("New expiry", obj.get("to")))
    if "version" in obj:
        rows.append(("Version", obj.get("version")))
    if "remote" in obj:
        rows.append(("Latest version", obj.get("remote")))
    if "quota" in obj:
        rows.append(("Quota", obj.get("quota")))
    if "status_lock" in obj:
        rows.append(("Lock state", obj.get("status_lock")))
    if "expired" in obj:
        rows.append(("Expires on", obj.get("expired")))
    if "pass_uuid" in obj:
        rows.append(("Secret", obj.get("pass_uuid")))
    if "installer_url" in obj:
        rows.append(("Installer URL", obj.get("installer_url")))
    if "installer_cache" in obj:
        rows.append(("Installer cache", obj.get("installer_cache")))
    if "log" in obj:
        rows.append(("Log file", obj.get("log")))
    if "update_unit" in obj:
        rows.append(("Update unit", obj.get("update_unit")))
    if "notes" in obj:
        rows.append(("Notes", obj.get("notes")))
    if "message" in obj:
        rows.append(("Result", obj.get("message")))
    print_rows(rows)

def render_transport_result(obj):
    name = titleize(obj.get("transport") or "transport")
    print_subsection(name)
    openvpn = obj.get("openvpn") or {}
    rows = [
        ("State", "enabled" if obj.get("enabled") is True else "disabled" if obj.get("enabled") is False else obj.get("status")),
        ("UDP53 mode", obj.get("udp53_mode")),
        ("OpenVPN UDP ports", obj.get("udp_public_ports") or openvpn.get("udp_public_ports") or obj.get("udp_public_port") or openvpn.get("udp_public_port")),
    ]
    if isinstance(obj.get("ports"), dict):
        ports = obj.get("ports") or {}
        rows.extend([
            ("TCP port", ports.get("tcp")),
            ("UDP ports", ports.get("udp")),
        ])
    profiles = (openvpn.get("profiles") or {}) if isinstance(openvpn, dict) else {}
    if isinstance(profiles, dict):
        def profile_url(profile):
            if not isinstance(profile, dict) or not profile:
                return None
            url = profile.get("url_https") or profile.get("url_http")
            if profile.get("exists") is False:
                return f"missing file: {profile.get('path') or profile.get('file')}"
            return url

        active_udp_profile = profiles.get("active_udp") or {}
        tcp_profile = profiles.get("tcp") or {}
        udp_profile = profiles.get("udp") or {}
        rows.extend([
            ("Active UDP profile", profile_url(active_udp_profile)),
            ("UDP config port", active_udp_profile.get("port") or udp_profile.get("port")),
            ("TCP profile", profile_url(tcp_profile)),
        ])
        udp_profiles = openvpn.get("udp_profiles") or []
        if isinstance(udp_profiles, list) and udp_profiles:
            for profile in udp_profiles:
                if isinstance(profile, dict):
                    label = profile.get("label") or f"UDP {profile.get('port')}"
                    rows.append((f"{label} profile", profile_url(profile)))
        elif udp_profile:
            rows.append(("UDP profile", profile_url(udp_profile)))
    print_rows(rows)

def render_domain_result(obj):
    print_subsection("Domain Settings")
    rows = [
        ("A record domain", obj.get("hostname") or obj.get("public_hostname")),
        ("NS record", obj.get("tunnel_domain")),
        ("Public IP", obj.get("public_ip")),
    ]
    print_rows(rows)
    records = obj.get("records") or []
    if records:
        print()
        print_subsection("DNS Records")
        for item in records:
            if not isinstance(item, dict):
                continue
            print(f"    {item.get('type', '-'):<4} {item.get('name', '-')} -> {item.get('value', '-')}")

def render_account_rows(account):
    print_subsection("Account")
    rows = [
        ("Username", account.get("username")),
        ("Expires on", account.get("expires_on")),
        ("Days", account.get("days")),
        ("IP limit", account.get("limit_ip")),
        ("Trial", account.get("trial")),
        ("Locked", account.get("locked")),
        ("Status", account.get("status")),
        ("Lock state", account.get("status_lock")),
        ("Used bandwidth", account.get("used_human")),
        ("Quota", account.get("max_human")),
        ("Type", account.get("type")),
        ("Protocol", account.get("protocol")),
    ]
    print_rows(rows)

def render_account_config(protocol, config):
    protocol_name = str(protocol or "").lower()
    port_names = {
        "ssh": "SSH",
        "dropbear": "Dropbear",
        "ssl": "SSL",
        "ws": "WebSocket",
        "slowdns": "SlowDNS",
        "squid": "Squid",
        "hysteria": "Hysteria",
        "ovpntcp": "OpenVPN TCP",
        "ovpnudp": "OpenVPN UDP",
        "ovpnohp": "OpenVPN OHP",
        "any": "All open ports",
    }
    rows = [
        ("Protocol", str(protocol or "").upper()),
        ("Hostname", config.get("hostname")),
        ("Username", config.get("username")),
        ("Password", config.get("password")),
        ("UUID", config.get("uuid")),
        ("Expires on", config.get("exp") or config.get("expired")),
    ]
    print_subsection("Connection")
    printed = print_rows(rows)

    payloadws = config.get("payloadws") or {}
    ssh_ports = config.get("port") or {}
    if protocol_name in {"ssh", "sshvpn"} and (payloadws or ssh_ports):
        if printed:
            print()
        print_subsection("SSH Access")
        if ssh_ports:
            print("    Ports")
            print("    -----")
            print_dict_rows(
                ssh_ports,
                indent=6,
                preferred=["ssh", "dropbear", "ssl", "ws", "slowdns", "squid", "hysteria", "ovpntcp", "ovpnudp", "ovpnohp", "any"],
                rename=port_names,
                skip_values={"", None, "-"},
            )
            print()
        ws_rows = [
            ("Primary WS path", payloadws.get("path")),
            ("CDN payload", payloadws.get("payloadcdn")),
            ("Upgrade payload", payloadws.get("payloadwithpath")),
            ("Root WS ports", payloadws.get("root_compat_port")),
            ("Root WS payload", payloadws.get("payloadrootcompat")),
        ]
        if any(value not in ("", None) for _, value in ws_rows) or payloadws.get("paths"):
            print("    WebSocket")
            print("    ---------")
            print_rows(ws_rows, indent=6)
            print_list_rows("Aliases", payloadws.get("paths"), indent=6)

    slowdns = config.get("slowdns") or {}
    if slowdns:
        print()
        print_subsection("SlowDNS")
        print_rows(
            [
                ("Public host", slowdns.get("public_hostname") or slowdns.get("ns_host")),
                ("Nameserver host", slowdns.get("ns_host")),
                ("Tunnel domain", slowdns.get("tunnel_domain")),
                ("Public port", slowdns.get("public_port") or slowdns.get("listen_port")),
                ("Listen port", slowdns.get("listen_port")),
                ("Target", slowdns.get("target")),
                ("Public key", slowdns.get("public_key")),
            ],
            indent=4,
        )

    path_info = config.get("path") or {}
    xray_ports = config.get("port") or {}
    links = config.get("link") or {}
    if protocol_name not in {"ssh", "sshvpn"} and (path_info or links or xray_ports):
        if printed:
            print()
        print_subsection("Transport")
        if xray_ports:
            print("    Ports")
            print("    -----")
            print_dict_rows(
                xray_ports,
                indent=6,
                preferred=["tls", "none", "ws", "grpc", "slowdns", "ssh", "dropbear", "ssl", "any"],
                rename={
                    "tls": "TLS",
                    "none": "Non-TLS",
                    "ws": "WebSocket",
                    "grpc": "gRPC",
                    "slowdns": "SlowDNS",
                    "ssh": "SSH",
                    "dropbear": "Dropbear",
                    "ssl": "SSL",
                    "any": "All open ports",
                },
                skip_values={"", None, "-"},
            )
            print()
        if path_info:
            print_protocol_paths("Paths", path_info, indent=4)
        if links:
            print()
            print_subsection("Links")
            print_rows(
                [
                    ("TLS WS", links.get("tls")),
                    ("NTLS WS", links.get("none")),
                    ("gRPC", links.get("grpc")),
                    ("Upgrade TLS", links.get("uptls")),
                    ("Upgrade NTLS", links.get("upntls")),
                ],
                indent=4,
            )

def unwrap(value):
    if isinstance(value, dict) and {"data", "meta", "error"}.issubset(value.keys()):
        error = value.get("error")
        if isinstance(error, dict) and error:
            width = max(len(str(k)) for k in error)
            for key, item in error.items():
                print(f"  {str(key):<{width}} : {item}")
            raise SystemExit(0)
        value = value.get("data")
    if isinstance(value, dict) and set(value.keys()) == {"status"}:
        print(f"  Status : {scalar(value['status'])}")
        raise SystemExit(0)
    return value

def print_block(obj, indent=2, heading=None):
    pad = " " * indent
    if heading:
        print(f"{pad}{titleize(heading)}")
        print(f"{pad}{'─' * min(max(len(titleize(heading)), 8), 28)}")
    if isinstance(obj, dict):
        simple = [(k, v) for k, v in obj.items() if not isinstance(v, (dict, list))]
        nested = [(k, v) for k, v in obj.items() if isinstance(v, (dict, list))]
        if simple:
            width = max(len(titleize(k)) for k, _ in simple)
            for key, value in simple:
                print(f"{pad}{titleize(key):<{width}} : {scalar(value)}")
        for idx, (key, value) in enumerate(nested):
            if simple or idx > 0:
                print()
            print_block(value, indent=indent, heading=key)
        return
    if isinstance(obj, list):
        if not obj:
            print(f"{pad}-")
            return
        for item in obj:
            if isinstance(item, (dict, list)):
                print(f"{pad}-")
                print_block(item, indent=indent + 2)
            else:
                print(f"{pad}- {scalar(item)}")
        return
    print(f"{pad}{scalar(obj)}")

payload = unwrap(payload)
if payload in ({}, [], None):
    raise SystemExit(0)
if isinstance(payload, dict) and {"installed", "remote", "status"}.issubset(payload.keys()):
    render_update(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and "certificate_path" in payload and "private_key_path" in payload:
    render_certificate(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and ("transport" in payload or "udp53_mode" in payload):
    render_transport_result(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and {"hostname", "public_hostname", "tunnel_domain"}.issubset(payload.keys()):
    render_domain_result(payload)
    raise SystemExit(0)
if isinstance(payload, dict) and "account" in payload and "config" in payload:
    render_account_rows(payload.get("account") or {})
    print()
    render_account_config(payload.get("protocol"), payload.get("config") or {})
    raise SystemExit(0)
if isinstance(payload, dict) and "config" in payload and isinstance(payload.get("config"), dict):
    render_account_config(payload.get("protocol"), payload.get("config") or {})
    raise SystemExit(0)
if isinstance(payload, dict) and ("username" in payload or "message" in payload) and not any(k in payload for k in ("config", "account")):
    render_action_result(payload)
    raise SystemExit(0)
print_block(payload)
PY
}

json_kv() {
  python3 - "$@" <<'PY'
import json, sys
d = {}
for item in sys.argv[1:]:
    k, v = item.split("=", 1)
    d[k] = v
print(json.dumps(d))
PY
}

urlencode() { python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1],safe=''))" "$1"; }

api_request() {
  local method="$1" path="$2" body="${3:-}" tmp url
  local curl_extra=()
  if ! url="$(build_api_url "$path")"; then
    API_STATUS="000"
    API_RESPONSE="{\"error\":{\"message\":\"Menu API base is invalid. Re-run the installer or repair ${CONFIG_PATH}.\"}}"
    return 0
  fi
  mapfile -t curl_extra < <(api_curl_noproxy_args "$url")
  tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${curl_extra[@]}" \
      -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
      --data "$body" "$url" || true)"
  else
    API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${curl_extra[@]}" \
      -H "Authorization: $API_KEY" "$url" || true)"
  fi
  API_RESPONSE="$(cat "$tmp")"
  if [[ "${API_STATUS:-000}" == "400" ]] && api_response_is_squid_invalid_url "$API_RESPONSE"; then
    force_local_api_base
    url="$(build_api_url "$path")" || true
    curl_extra=(--noproxy "*")
    if [[ -n "${url:-}" ]]; then
      if [[ -n "$body" ]]; then
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
          --data "$body" "$url" || true)"
      else
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" "$url" || true)"
      fi
      API_RESPONSE="$(cat "$tmp")"
    fi
  fi
  rm -f "$tmp"
}

api_request_with_spinner() {
  local method="$1" path="$2" body="${3:-}" label="${4:-Working}"
  local tmp status_tmp url pid waited=0 frame spinner='-\|/' idx=0
  local curl_extra=()
  if ! url="$(build_api_url "$path")"; then
    API_STATUS="000"
    API_RESPONSE="{\"error\":{\"message\":\"Menu API base is invalid. Re-run the installer or repair ${CONFIG_PATH}.\"}}"
    return 0
  fi
  mapfile -t curl_extra < <(api_curl_noproxy_args "$url")
  tmp="$(mktemp)"
  status_tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    (
      curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
        "${curl_extra[@]}" \
        -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
        --data "$body" "$url" >"$status_tmp" || printf '000' >"$status_tmp"
    ) &
  else
    (
      curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
        "${curl_extra[@]}" \
        -H "Authorization: $API_KEY" "$url" >"$status_tmp" || printf '000' >"$status_tmp"
    ) &
  fi
  pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    frame="${spinner:idx%4:1}"
    printf '\r  %s %s %ss' "$frame" "$label" "$waited" > /dev/tty 2>/dev/null || true
    sleep 1
    waited=$((waited + 1))
    idx=$((idx + 1))
  done
  wait "$pid" >/dev/null 2>&1 || true
  printf '\r  %s%s%s\n' "$C_GREEN" "Finished." "$C_RESET" > /dev/tty 2>/dev/null || true
  API_STATUS="$(cat "$status_tmp" 2>/dev/null || printf '000')"
  API_RESPONSE="$(cat "$tmp" 2>/dev/null || true)"
  if [[ "${API_STATUS:-000}" == "400" ]] && api_response_is_squid_invalid_url "$API_RESPONSE"; then
    force_local_api_base
    url="$(build_api_url "$path")" || true
    curl_extra=(--noproxy "*")
    if [[ -n "${url:-}" ]]; then
      if [[ -n "$body" ]]; then
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" -H "Content-Type: application/json" \
          --data "$body" "$url" || true)"
      else
        API_STATUS="$(curl -ksS -o "$tmp" -w "%{http_code}" -X "$method" \
          "${curl_extra[@]}" \
          -H "Authorization: $API_KEY" "$url" || true)"
      fi
      API_RESPONSE="$(cat "$tmp" 2>/dev/null || true)"
    fi
  fi
  rm -f "$tmp" "$status_tmp"
}

show_api_result() {
  local msg rendered
  msg="$(json_message "$API_RESPONSE")"
  rendered="$(render_api_body "$API_RESPONSE")"
  echo
  if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    if [[ -n "$rendered" ]]; then
      printf '%s\n' "$rendered"
    elif [[ -n "$msg" ]]; then
      printf '  %s%s%s\n' "$C_GREEN" "$msg" "$C_RESET"
    else
      printf '  %s%sCompleted successfully.%s\n' "$(dot_ok)" "$C_GREEN" "$C_RESET"
    fi
  else
    printf '  %s %s%s  Request failed%s\n' "$(dot_err)" "$C_BOLD" "$C_RED" "$C_RESET"
    [[ -n "$msg" ]] && printf '  %sMessage :%s %s\n' "$C_MUTED" "$C_RESET" "$msg"
    printf '  %sHTTP    :%s %s\n' "$C_MUTED" "$C_RESET" "${API_STATUS:-000}"
    hr
    if [[ -n "$rendered" ]]; then
      printf '%s\n' "$rendered"
    fi
  fi
}

show_update_progress() {
  local log_path="$1" update_unit="$2" installer_cache="${3:-}" from_version="${4:-}" to_version="${5:-}" status_file="${6:-}"
  local waited=0 max_wait=180 state="" substate="" result="" spinner='-\|/' frame="" status_state="" exit_code=""

  echo
  section "Updating IPTunnel"
  echo
  [[ -n "$from_version" ]] && printf '  %sCurrent build :%s %s\n' "$C_MUTED" "$C_RESET" "$from_version"
  [[ -n "$to_version" ]] && printf '  %sTarget build  :%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
  [[ -n "$installer_cache" ]] && printf '  %sInstaller     :%s %s\n' "$C_MUTED" "$C_RESET" "$installer_cache"
  [[ -n "$update_unit" ]] && printf '  %sBackground job:%s %s\n' "$C_MUTED" "$C_RESET" "$update_unit"
  [[ -n "$status_file" ]] && printf '  %sStatus file   :%s %s\n' "$C_MUTED" "$C_RESET" "$status_file"
  echo

  while (( waited < max_wait )); do
    if [[ -n "$status_file" && -f "$status_file" ]]; then
      mapfile -t __upd_status < <(python3 - "$status_file" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}
for key in ("status", "exit_code"):
    value = data.get(key, "")
    print("" if value is None else value)
PY
)
      status_state="${__upd_status[0]:-}"
      exit_code="${__upd_status[1]:-}"
      if [[ "$status_state" == "success" || "$status_state" == "failed" ]]; then
        break
      fi
    fi
    if [[ -n "$update_unit" ]]; then
      state="$(systemctl is-active "$update_unit" 2>/dev/null || true)"
      substate="$(systemctl show -p SubState --value "$update_unit" 2>/dev/null || true)"
      result="$(systemctl show -p Result --value "$update_unit" 2>/dev/null || true)"
      if [[ "$state" != "active" && "$state" != "activating" && -n "$state" ]]; then
        break
      fi
    fi
    frame="${spinner:$(( waited % ${#spinner} )):1}"
    printf '\r  %s Updating services... %3ss' "$frame" "$waited"
    sleep 1
    waited=$((waited + 1))
  done
  printf '\r'

  if [[ -n "$update_unit" ]]; then
    state="$(systemctl is-active "$update_unit" 2>/dev/null || true)"
    substate="$(systemctl show -p SubState --value "$update_unit" 2>/dev/null || true)"
    result="$(systemctl show -p Result --value "$update_unit" 2>/dev/null || true)"
  fi

  echo
  if [[ "$status_state" == "success" ]]; then
    printf '  %s Update completed successfully.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$to_version" ]] && printf '  %sInstalled build:%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
    [[ -n "$log_path" ]] && printf '  %sLog file       :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    return
  fi

  if [[ "$status_state" == "failed" ]]; then
    printf '  %s Update failed.%s\n' "$(dot_err)" "$C_RESET"
    [[ -n "$exit_code" ]] && printf '  %sExit code :%s %s\n' "$C_MUTED" "$C_RESET" "$exit_code"
    [[ -n "$log_path" ]] && printf '  %sLog file  :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    if [[ -f "$log_path" ]]; then
      echo
      hr
      tail -n 30 "$log_path" 2>/dev/null || true
      hr
    fi
    return
  fi

  if [[ "$result" == "success" || ( "$state" == "inactive" && "$result" == "success" ) ]]; then
    printf '  %s Update completed successfully.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$to_version" ]] && printf '  %sInstalled build:%s %s\n' "$C_MUTED" "$C_RESET" "$to_version"
    [[ -n "$log_path" ]] && printf '  %sLog file       :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    return
  fi

  if [[ "$result" == "failed" || "$state" == "failed" ]]; then
    printf '  %s Update failed.%s\n' "$(dot_err)" "$C_RESET"
    [[ -n "$log_path" ]] && printf '  %sLog file :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
    if [[ -f "$log_path" ]]; then
      echo
      hr
      tail -n 20 "$log_path" 2>/dev/null || true
      hr
    fi
    return
  fi

  printf '  %s Update is still running in the background.%s\n' "$(dot_ok)" "$C_RESET"
  [[ -n "$substate" ]] && printf '  %sState    :%s %s / %s\n' "$C_MUTED" "$C_RESET" "${state:-unknown}" "$substate"
  [[ -n "$log_path" ]] && printf '  %sLog file :%s %s\n' "$C_MUTED" "$C_RESET" "$log_path"
}

# ══════════════════════════════════════════════════════════════════════
#  PROTOCOL SELECTION
# ══════════════════════════════════════════════════════════════════════

choose_protocol() {
  section "Select Protocol"
  echo
  printf '  %s┌──────────┬──────────┬──────────┬──────────┐%s\n' "$C_SURFACE" "$C_RESET"
  printf '  %s│%s %s[1]%s SSH  %s│%s %s[2]%s VMess%s│%s %s[3]%s VLESS%s│%s %s[4]%s Trojan%s│%s\n' \
    "$C_SURFACE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET" \
    "$C_BLUE" "$C_RESET" "$C_SURFACE" "$C_RESET"
  printf '  %s└──────────┴──────────┴──────────┴──────────┘%s\n' "$C_SURFACE" "$C_RESET"
  local ch
  ch="$(ask)"
  case "$ch" in
    1) PROTOCOL_KEY="sshvpn"; PROTOCOL_LABEL="SSH" ;;
    2) PROTOCOL_KEY="vmess";  PROTOCOL_LABEL="VMess" ;;
    3) PROTOCOL_KEY="vless";  PROTOCOL_LABEL="VLESS" ;;
    4) PROTOCOL_KEY="trojan"; PROTOCOL_LABEL="Trojan" ;;
    *) printf '  %s Invalid protocol\n' "$(dot_err)"; return 1 ;;
  esac
}

protocol_slug() {
  case "$PROTOCOL_KEY" in
    sshvpn) echo "ssh" ;;
    vmess|vless|trojan) echo "$PROTOCOL_KEY" ;;
    *) return 1 ;;
  esac
}

route_for() {
  local action="$1"
  local protocol base
  protocol="$(protocol_slug)" || return 1
  base="/api/v2/vps/accounts/${protocol}"
  case "$action" in
    list|create|check|renew|delete|lock|unlock) echo "$base" ;;
    trial) echo "${base}/trials" ;;
    *) return 1 ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════
#  ACCOUNT OPERATIONS
# ══════════════════════════════════════════════════════════════════════

list_accounts() {
  choose_protocol || return
  api_request GET "$(route_for list)"
  echo
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then show_api_result; return; fi
  section "$PROTOCOL_LABEL Accounts"
  echo
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
rows = ((payload.get("data") or {}).get("accounts") or [])
if not rows:
    print("  No accounts found.")
    raise SystemExit(0)
# Header
h = f"\033[38;5;243m  {'USERNAME':<20} {'EXPIRES':<12} {'IP':>3}  {'LOCK':<10} {'STATUS':<10} {'QUOTA':<10}\033[0m"
print(h)
print(f"\033[38;5;238m  {'─'*68}\033[0m")
for row in rows:
    u = str(row.get('username','-'))[:20]
    e = str(row.get('expires_on','-'))[:12]
    i = int(row.get('limit_ip',0) or 0)
    l = 'LOCKED' if row.get('locked') else 'UNLOCKED'
    s = str(row.get('status','-'))[:10]
    q = str(row.get('max_human','-'))[:10]
    # Color active/expired
    sc = "\033[38;5;114m" if s.upper() in {"ACTIVE", "AKTIF"} else "\033[38;5;210m"
    print(f"  {u:<20} {e:<12} {i:>3}  {l:<10} {sc}{s:<10}\033[0m {q:<10}")
PY
}

create_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Create Account"
  echo
  local username="" password="" secret_value="" expired_days="" limit_ip="" kuota="" payload=()

  username="$(ask_prompt "Username")"
  expired_days="$(ask_prompt "Days until expiry")"
  limit_ip="$(ask_prompt "IP limit    [0]")"
  kuota="$(ask_prompt "Quota GB    [0]")"

  limit_ip="${limit_ip:-0}"; kuota="${kuota:-0}"
  payload+=("username=$username" "expires_in_days=$expired_days" "limit_ip=$limit_ip" "quota_gb=$kuota")

  if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
    password="$(ask_prompt "Password")"
    payload+=("password=$password")
  else
    secret_value="$(ask_prompt "Custom UUID [auto]")"
    [[ -n "$secret_value" ]] && payload+=("secret=$secret_value")
  fi

  api_request POST "$(route_for create)" "$(json_kv "${payload[@]}")"
  show_api_result
}

create_trial() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Trial Account"
  echo
  local timelimit="" password="" secret_value="" payload=()

  timelimit="$(ask_prompt "Duration (30m / 1h / 1d)")"
  payload+=("duration=$timelimit")

  if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
    password="$(ask_prompt "Password [auto]")"
    [[ -n "$password" ]] && payload+=("password=$password")
  else
    secret_value="$(ask_prompt "Custom UUID [auto]")"
    [[ -n "$secret_value" ]] && payload+=("secret=$secret_value")
  fi

  api_request POST "$(route_for trial)" "$(json_kv "${payload[@]}")"
  show_api_result
}

show_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Account Details"
  echo
  local username=""
  username="$(ask_prompt "Username")"
  api_request GET "$(route_for check)/$(urlencode "$username")"
  show_api_result
}

renew_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Renew Account"
  echo
  local username="" days="" kuota="" body_items=()

  username="$(ask_prompt "Username")"
  days="$(ask_prompt "Add days")"

  body_items+=("expires_in_days=$days")
  kuota="$(ask_prompt "New quota GB [keep]")"
  [[ -n "$kuota" ]] && body_items+=("quota_gb=$kuota")

  api_request PATCH "$(route_for renew)/$(urlencode "$username")" "$(json_kv "${body_items[@]}")"
  show_api_result
}

delete_account() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Delete Account"
  echo
  local username="" confirm=""

  username="$(ask_prompt "Username")"
  printf '  %s%s⚠  Delete "%s"? This cannot be undone.%s\n' "$C_BOLD" "$C_RED" "$username" "$C_RESET"
  confirm="$(ask_prompt "Type 'yes' to confirm")"
  if [[ "$confirm" != "yes" ]]; then printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; fi

  api_request DELETE "$(route_for delete)/$(urlencode "$username")"
  show_api_result
}

lock_or_unlock() {
  choose_protocol || return
  section "$PROTOCOL_LABEL — Lock / Unlock"
  echo
  local username="" action="" password=""

  username="$(ask_prompt "Username")"
  echo
  mi 1 "Lock account"
  mi 2 "Unlock account"
  action="$(ask)"

  case "$action" in
    1)
      api_request PATCH "$(route_for lock)/$(urlencode "$username")" "$(json_kv "locked=true")"
      ;;
    2)
      if [[ "$PROTOCOL_KEY" == "sshvpn" ]]; then
        password="$(ask_prompt "New password for unlock")"
        api_request PATCH "$(route_for unlock)/$(urlencode "$username")" "$(json_kv "locked=false" "unlock_password=$password")"
      else
        api_request PATCH "$(route_for unlock)/$(urlencode "$username")" "$(json_kv "locked=false")"
      fi
      ;;
    *)
      printf '  %s Invalid choice\n' "$(dot_err)"
      return
      ;;
  esac

  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  SERVICE STATUS
# ══════════════════════════════════════════════════════════════════════

show_status() {
  section "Service Status"
  echo
  local services=()
  mapfile -t services < <(configured_services)
  local svc
  for svc in "${services[@]}"; do
    local state
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
      printf '  %s  %-38s %s%s%s\n' "$(_dot 1)" "$svc" "$C_GREEN" "active" "$C_RESET"
    else
      printf '  %s  %-38s %s%s%s\n' "$(_dot 0)" "$svc" "$C_RED" "${state}" "$C_RESET"
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════
#  RUNTIME INFO
# ══════════════════════════════════════════════════════════════════════

show_runtime_info() {
  section "Runtime Info"
  echo
  printf '  %s%-14s%s %s\n' "$C_MUTED" "Config" "$C_RESET" "$CONFIG_PATH"
  printf '  %s%-14s%s %s%s%s\n' "$C_MUTED" "Domain" "$C_RESET" "$C_WHITE" "$DOMAIN" "$C_RESET"
  printf '  %s%-14s%s %s%s%s\n' "$C_MUTED" "Public IP" "$C_RESET" "$C_CYAN" "${PUBLIC_IP:-unknown}" "$C_RESET"
  printf '  %s%-14s%s %s\n' "$C_MUTED" "API base" "$C_RESET" "$API_BASE"
  printf '  %s%-14s%s %s\n' "$C_MUTED" "API key" "$C_RESET" "$API_KEY"

  # License info
  local lic_enabled lic_url lic_sid
  lic_enabled="$(python3 -c "import json; c=json.load(open('$CONFIG_PATH')); print('1' if c.get('license',{}).get('enabled') else '0')" 2>/dev/null || echo "0")"
  if [[ "$lic_enabled" == "1" ]]; then
    lic_url="$(python3 -c "import json; print(json.load(open('$CONFIG_PATH')).get('license',{}).get('url',''))" 2>/dev/null || echo "")"
    lic_sid="$(cat /etc/iptunnel/license.id 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$lic_sid" ]]; then
      printf '  %s%-14s%s %s %s%sregistered%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 1)" "$C_GREEN" "" "$C_RESET"
    else
      lic_sid="none"
      printf '  %s%-14s%s %s %s%sunregistered%s %s(24h grace)%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 0)" "$C_YELLOW" "" "$C_RESET" "$C_MUTED" "$C_RESET"
    fi
    printf '  %s%-14s%s %s\n' "$C_MUTED" "License URL" "$C_RESET" "$lic_url"
    printf '  %s%-14s%s %s\n' "$C_MUTED" "Server ID" "$C_RESET" "$lic_sid"
  else
    printf '  %s%-14s%s %s %snot configured%s\n' "$C_MUTED" "License" "$C_RESET" "$(_dot 0)" "$C_MUTED" "$C_RESET"
  fi

  # PAM auth status
  if grep -qF "iptunnel-pam-check" /etc/pam.d/sshd 2>/dev/null; then
    printf '  %s%-14s%s %s %s%sactive%s %s(foreign app blocking)%s\n' "$C_MUTED" "PAM auth" "$C_RESET" "$(_dot 1)" "$C_GREEN" "" "$C_RESET" "$C_MUTED" "$C_RESET"
  else
    printf '  %s%-14s%s %s %snot installed%s\n' "$C_MUTED" "PAM auth" "$C_RESET" "$(_dot 0)" "$C_MUTED" "$C_RESET"
  fi

  hr
  api_request GET "/api/v2/vps/runtime"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi
  echo
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
data = payload.get("data") or {}
ssh = data.get("ssh") or {}
xray = data.get("xray") or {}
slowdns = data.get("slowdns") or {}
hysteria = data.get("hysteria") or {}
openvpn = data.get("openvpn") or {}

def yes_no(value):
    return "yes" if value else "no"

def show_rows(title, rows):
    rows = [(label, value) for label, value in rows if value not in ("", None, [], {})]
    if not rows:
        return
    print(f"  {title}")
    print(f"  {'-' * len(title)}")
    width = max(len(label) for label, _ in rows)
    for label, value in rows:
        if isinstance(value, list):
            value = ", ".join(str(item) for item in value if str(item).strip()) or "-"
        elif isinstance(value, dict):
            value = ", ".join(f"{k}={v}" for k, v in value.items() if str(v).strip()) or "-"
        elif isinstance(value, bool):
            value = yes_no(value)
        print(f"  {label:<{width}} : {value}")
    print()

show_rows("SSH", [
    ("Manage users", ssh.get("manage_system_users")),
    ("WS path", ssh.get("ws_path")),
    ("WS aliases", ssh.get("ws_paths")),
    ("Ports", ssh.get("ports")),
])
show_rows("Xray", [
    ("Ports", xray.get("ports")),
    ("Paths", xray.get("paths")),
    ("Services", xray.get("services")),
])
show_rows("SlowDNS", [
    ("Enabled", slowdns.get("enabled")),
    ("Public host", slowdns.get("public_hostname") or slowdns.get("ns_host")),
    ("Tunnel domain", slowdns.get("tunnel_domain")),
    ("Public port", slowdns.get("public_port") or slowdns.get("listen_port")),
    ("Local port", slowdns.get("local_port")),
    ("Target", slowdns.get("target")),
    ("Service", slowdns.get("service")),
])
show_rows("Hysteria", [
    ("Enabled", hysteria.get("enabled")),
    ("Protocol", hysteria.get("protocol")),
    ("Port", hysteria.get("port")),
    ("Obfs", hysteria.get("obfs")),
    ("Password", hysteria.get("password")),
])
show_rows("OpenVPN", [
    ("Enabled", openvpn.get("enabled")),
    ("TCP", openvpn.get("tcp")),
    ("UDP", openvpn.get("udp")),
])
PY
}

# ══════════════════════════════════════════════════════════════════════
#  HYSTERIA CONFIG
# ══════════════════════════════════════════════════════════════════════

configure_hysteria_auth() {
  local values=() enabled="" obfs="" password="" host="" port="" protocol=""
  local service="" hop_ports="" ca_cert_path="" info_path="" reply=""

  mapfile -t values < <(python3 - "$CONFIG_PATH" <<'PY'
import json, pathlib, sys
c = json.load(open(sys.argv[1]))
h = c.get("hysteria") or {}
obfs     = str(h.get("obfs","") or "")
password = str(h.get("password","") or "")
if not obfs or not password:
    p = pathlib.Path("/etc/hysteria/config.json")
    if p.exists():
        try:    hc = json.loads(p.read_text())
        except: hc = {}
        obfs = obfs or str(hc.get("obfs","") or "")
        cfg  = (hc.get("auth") or {}).get("config") or []
        password = password or (str(cfg[0]) if cfg else "")
print(h.get("enabled",""))
print(obfs)
print(password)
print(c.get("hostname",""))
print(h.get("port",5666))
print(h.get("protocol","udp"))
print(h.get("service","hysteria-server"))
print(h.get("hop_ports","-"))
print(h.get("ca_cert_path",""))
print(h.get("info_path","/var/www/html/hysteria-info.txt"))
PY
  )

  enabled="${values[0]:-}"; obfs="${values[1]:-}"; password="${values[2]:-}"
  host="${values[3]:-}"; port="${values[4]:-5666}"; protocol="${values[5]:-udp}"
  service="${values[6]:-hysteria-server}"; hop_ports="${values[7]:--}"
  ca_cert_path="${values[8]:-}"; info_path="${values[9]:-/var/www/html/hysteria-info.txt}"

  section "Hysteria Auth / URI"
  echo
  printf '  %s%-12s%s %s\n' "$C_MUTED" "Current obfs" "$C_RESET" "${obfs:-(not set)}"
  printf '  %s%-12s%s %s\n' "$C_MUTED" "Current pass" "$C_RESET" "${password:-(not set)}"
  hr

  read -r -p "  New obfs [$obfs]: " reply
  [[ -n "$reply" ]] && obfs="$reply"
  read -r -p "  New password [$password]: " reply
  [[ -n "$reply" ]] && password="$reply"

  if [[ -z "$obfs" || -z "$password" ]]; then
    printf '  %s Both obfs and password are required.\n' "$(dot_err)"; return
  fi

  python3 - "$CONFIG_PATH" "$obfs" "$password" <<'PY'
import json, sys
p, o, pw = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(p))
c.setdefault("hysteria",{})["obfs"] = o
c["hysteria"]["password"] = pw
with open(p,"w") as f: json.dump(c, f, indent=2)
PY

  if [[ -f /etc/hysteria/config.json ]]; then
    python3 - "$obfs" "$password" <<'PY'
import json, sys
path = "/etc/hysteria/config.json"
obfs, password = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, encoding="utf-8"))
cfg["obfs"] = obfs
cfg.setdefault("auth", {})["mode"] = "passwords"
cfg["auth"]["config"] = [password]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
    handle.write("\n")
PY
  fi

  printf '  %s Config updated.\n' "$(dot_ok)"

  local hysteria_uri="hysteria://${host}:${port}?obfs=${obfs}&auth=${password}&insecure=1"
  local uri_path; uri_path="$(dirname "$info_path")/hysteria.uri"
  printf '%s\n' "$hysteria_uri" >"$uri_path"
  cat >"$info_path" <<EOF
IPTunnel Hysteria
=================
Host         : ${host}
Port         : ${port}
Protocol     : ${protocol}
Obfs         : ${obfs}
Password     : ${password}
CA cert      : ${ca_cert_path}
Service      : ${service}
Hop range    : ${hop_ports}

Notes:
- Import ${ca_cert_path} into the client if it verifies certificates strictly.
- If the client supports insecure/self-signed mode, you can use that instead of importing the CA.
EOF

  echo
  printf '  %s%s╔══════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '  %s%s║  Hysteria URI                                    ║%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '  %s%s╚══════════════════════════════════════════════════╝%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  echo
  printf '  %s\n' "$hysteria_uri"
  echo
  printf '  %sSaved to: %s%s\n' "$C_MUTED" "$uri_path" "$C_RESET"

  if systemctl is-active --quiet "$service" 2>/dev/null; then
    systemctl restart "$service"
    printf '  %s Hysteria service restarted.\n' "$(dot_ok)"
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  TRANSPORT TOGGLES
# ══════════════════════════════════════════════════════════════════════

toggle_hysteria() {
  local states=() hys_on=""
  mapfile -t states < <(transport_module_state)
  hys_on="${states[0]:-0}"
  if [[ "$hys_on" == "1" ]]; then
    api_request_with_spinner POST "/api/v2/vps/transports/hysteria/disable" "" "Disabling Hysteria..."
  else
    api_request_with_spinner POST "/api/v2/vps/transports/hysteria/enable" "" "Enabling Hysteria..."
  fi
  show_api_result
}

toggle_openvpn() {
  local states=() ovpn_tcp="" ovpn_udp="" openvpn_on="0"
  mapfile -t states < <(transport_module_state)
  ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"
  [[ "$ovpn_tcp" != "-" || "$ovpn_udp" != "-" ]] && openvpn_on="1"
  if [[ "$openvpn_on" == "1" ]]; then
    api_request_with_spinner POST "/api/v2/vps/transports/openvpn/disable" "" "Disabling OpenVPN..."
  else
    api_request_with_spinner POST "/api/v2/vps/transports/openvpn/enable" "" "Enabling OpenVPN..."
  fi
  show_api_result
}

udp53_mode_label() {
  case "${1:-slowdns}" in
    openvpn) printf 'OpenVPN only' ;;
    shared) printf 'Shared (experimental)' ;;
    *) printf 'SlowDNS only' ;;
  esac
}

set_udp53_mode() {
  local label
  label="$(udp53_mode_label "$1")"
  api_request_with_spinner POST "/api/v2/vps/transports/udp53-mode/$1" "" "Switching UDP53 to ${label}..."
  show_api_result
}

set_openvpn_udp_ports() {
  local states=() current_ports="" ports="" udp53_mode=""
  mapfile -t states < <(transport_module_state)
  current_ports="${states[4]:--}"
  udp53_mode="${states[3]:-slowdns}"
  [[ "${current_ports}" != "-" ]] || current_ports="1194"
  section "OpenVPN UDP Multiport"
  echo
  printf '  %sCurrent public UDP ports:%s %s\n' "$C_MUTED" "$C_RESET" "$current_ports"
  printf '  %sUDP53 mode:%s %s\n' "$C_MUTED" "$C_RESET" "$(udp53_mode_label "$udp53_mode")"
  printf '  %sEnter comma-separated ports, for example 53,1194. Port 53 follows the UDP53 mode above.%s\n' "$C_MUTED" "$C_RESET"
  echo
  ports="$(ask_prompt "OpenVPN UDP public ports [${current_ports}]")"
  ports="${ports:-$current_ports}"
  api_request_with_spinner PATCH "/api/v2/vps/transports/openvpn/udp-port" "$(json_kv "ports=$ports")" "Updating OpenVPN UDP ports..."
  show_api_result
}

enable_openvpn_alt_port() {
  set_openvpn_udp_ports
}

change_slowdns_mtu() {
  local states=() current_mtu="1232" choice="" mtu=""
  mapfile -t states < <(transport_module_state)
  current_mtu="${states[6]:-1232}"

  section "SlowDNS MTU"
  echo
  printf '  %sCurrent server MTU:%s %s\n' "$C_MUTED" "$C_RESET" "$current_mtu"
  printf '  %sThis setting applies to all SlowDNS users. Active SlowDNS restarts after a change.%s\n' "$C_MUTED" "$C_RESET"
  echo
  mi 1 "512"  "Recommended"
  mi 2 "1232" "Default / higher throughput"
  mi 3 "800"  "Balanced compatibility"
  mi 4 "296"  "Very restricted resolvers"
  mi 5 "Custom" "Choose 128 to 1500"
  echo
  mi 0 "Back"

  choice="$(ask)"
  case "$choice" in
    1) mtu="512" ;;
    2) mtu="1232" ;;
    3) mtu="800" ;;
    4) mtu="296" ;;
    5) mtu="$(ask_prompt "Custom MTU [128-1500]")" ;;
    0) return ;;
    *) printf '  %s Invalid choice\n' "$(dot_err)"; return ;;
  esac
  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 128 || mtu > 1500 )); then
    printf '  %s MTU must be between 128 and 1500.\n' "$(dot_err)"
    return
  fi
  api_request_with_spinner PATCH "/api/v2/vps/transports/slowdns/mtu" \
    "$(json_kv "mtu=$mtu")" "Updating SlowDNS MTU..."
  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  TORRENT CONTROL
# ══════════════════════════════════════════════════════════════════════

_TORRENT_CHAIN="IPTUNNEL_TORRENT_BLK"

torrent_is_blocked() {
  iptables -L FORWARD 2>/dev/null | grep -qF "$_TORRENT_CHAIN" && echo "1" || echo "0"
}

torrent_block() {
  # Create or flush custom chain
  iptables -N "$_TORRENT_CHAIN" 2>/dev/null || iptables -F "$_TORRENT_CHAIN"

  # String-match rules (DPI-lite)
  iptables -A "$_TORRENT_CHAIN" -m string --string "BitTorrent protocol" --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "info_hash="          --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "peer_id="            --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "get_peers"           --algo bm -j DROP
  iptables -A "$_TORRENT_CHAIN" -m string --string "announce_peer"       --algo bm -j DROP

  # Port-based rules
  iptables -A "$_TORRENT_CHAIN" -p tcp --dport 6881:6889 -j DROP
  iptables -A "$_TORRENT_CHAIN" -p udp --dport 6881:6889 -j DROP

  # Jump from FORWARD
  if ! iptables -L FORWARD 2>/dev/null | grep -qF "$_TORRENT_CHAIN"; then
    iptables -I FORWARD -j "$_TORRENT_CHAIN"
  fi

  _iptables_save
  printf '  %s Torrent traffic blocked.\n' "$(dot_ok)"
}

torrent_unblock() {
  iptables -D FORWARD -j "$_TORRENT_CHAIN" 2>/dev/null || true
  iptables -F "$_TORRENT_CHAIN" 2>/dev/null || true
  iptables -X "$_TORRENT_CHAIN" 2>/dev/null || true
  _iptables_save
  printf '  %s Torrent traffic allowed.\n' "$(dot_ok)"
}

toggle_torrent() {
  if [[ "$(torrent_is_blocked)" == "1" ]]; then
    torrent_unblock
  else
    torrent_block
  fi
}

_iptables_save() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
  elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

# ══════════════════════════════════════════════════════════════════════
#  AUTO REBOOT
# ══════════════════════════════════════════════════════════════════════

_REBOOT_CRON=/etc/cron.d/iptunnel-autoreboot

autoreboot_status() {
  [[ -f "$_REBOOT_CRON" ]] && echo "1" || echo "0"
}

autoreboot_time() {
  [[ -f "$_REBOOT_CRON" ]] || { echo "—"; return; }
  awk '!/^#/ && NF { printf "%02d:%02d", $2, $1 }' "$_REBOOT_CRON"
}

autoreboot_enable() {
  local hour="" minute="" confirm=""
  section "Schedule Auto-Reboot"
  echo
  printf '  %sThe server will reboot daily at the time you set.%s\n' "$C_MUTED" "$C_RESET"
  echo
  hour="$(ask_prompt "Hour   [4]")"
  minute="$(ask_prompt "Minute [0]")"
  hour="${hour:-4}"; minute="${minute:-0}"

  if ! [[ "$hour"   =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    printf '  %s Invalid hour.\n' "$(dot_err)"; return
  fi
  if ! [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]]; then
    printf '  %s Invalid minute.\n' "$(dot_err)"; return
  fi

  printf '\n  Schedule: every day at %s%02d:%02d%s\n' "$C_CYAN" "$hour" "$minute" "$C_RESET"
  confirm="$(ask_prompt "Continue? [y/N]")"
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }

  cat >"$_REBOOT_CRON" <<EOF
# IPTunnel auto-reboot — managed by iptunnel_menu.sh
${minute} ${hour} * * * root /sbin/reboot
EOF
  chmod 644 "$_REBOOT_CRON"
  printf '  %s Auto-reboot set for %02d:%02d daily.\n' "$(dot_ok)" "$hour" "$minute"
}

autoreboot_disable() {
  if [[ ! -f "$_REBOOT_CRON" ]]; then
    printf '  %sAuto-reboot is not enabled.%s\n' "$C_MUTED" "$C_RESET"; return
  fi
  rm -f "$_REBOOT_CRON"
  printf '  %s Auto-reboot disabled.\n' "$(dot_ok)"
}

show_bandwidth_stats() {
  section "Bandwidth Stats"
  echo
  api_request GET "/api/v2/vps/bandwidth"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi
  PAYLOAD="$API_RESPONSE" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PAYLOAD"])
data = payload.get("data") or {}
totals = data.get("totals") or {}
protocols = data.get("protocols") or {}
print(f"  Total accounts : {totals.get('accounts', 0)}")
print(f"  Used bandwidth : {totals.get('used_human', '0 B')}")
print(f"  Quota ceiling  : {totals.get('max_human', '0 B')}")
if protocols:
    print()
for name, info in protocols.items():
    print(f"  {name:<8} used={info.get('used_human', '0 B'):<12} quota={info.get('max_human', '0 B')}")
    for row in (info.get('accounts') or [])[:5]:
        print(f"    - {str(row.get('username', '-')):<20} {row.get('used_human', '0 B')}")
PY
}

backup_configs() {
  section "Backup Configs"
  echo
  api_request POST "/api/v2/vps/backup"
  show_api_result
}

restore_configs() {
  local path confirm
  section "Restore Backup"
  echo
  path="$(ask_prompt "Backup path (/root/iptunnel-backup-*.tar.gz)")"
  [[ -n "$path" && -f "$path" ]] || { printf '  %s Backup file not found.\n' "$(dot_err)"; return; }
  confirm="$(ask_prompt "Type RESTORE to continue")"
  [[ "$confirm" == "RESTORE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
  api_request POST "/api/v2/vps/restore" "$(json_kv "path=$path")"
  show_api_result
}

change_domains() {
  local values=() current_host="" current_tunnel=""
  local hostname="" tunnel_domain="" confirm="" choice=""
  POST_ACTION_PAUSE="1"
  while true; do
    section "Domain Settings"
    echo
    mapfile -t values < <(domain_state)
    current_host="${values[0]:-}"
    current_tunnel="${values[1]:-}"
    printf '  %sA record domain:%s %s\n' "$C_MUTED" "$C_RESET" "${current_host:-unknown}"
    printf '  %sNS record      :%s %s\n' "$C_MUTED" "$C_RESET" "${current_tunnel:-unknown}"
    printf '  %sNS target      :%s %s\n' "$C_MUTED" "$C_RESET" "${current_host:-unknown}"
    echo
    mi 1 "Edit A record domain" "Change the main server domain"
    mi 2 "Edit NS record" "Change the SlowDNS nameserver domain"
    mi 3 "Edit both records" "Change server domain and SlowDNS NS"
    mi 0 "Back"
    choice="$(ask)"
    case "$choice" in
      1)
        hostname="$(ask_prompt "New A record domain [${current_host:-same}]")"
        hostname="${hostname:-$current_host}"
        tunnel_domain="$current_tunnel"
        ;;
      2)
        hostname="$current_host"
        tunnel_domain="$(ask_prompt "New NS record [${current_tunnel:-dns.<A record domain>}]")"
        tunnel_domain="${tunnel_domain:-$current_tunnel}"
        ;;
      3)
        hostname="$(ask_prompt "New A record domain [${current_host:-same}]")"
        hostname="${hostname:-$current_host}"
        tunnel_domain="$(ask_prompt "New NS record [${current_tunnel:-dns.<A record domain>}]")"
        tunnel_domain="${tunnel_domain:-$current_tunnel}"
        ;;
      0)
        POST_ACTION_PAUSE="0"
        return
        ;;
      *)
        printf '  %s Invalid choice\n' "$(dot_err)"
        continue
        ;;
    esac
    echo
    printf '  %sA record domain:%s %s\n' "$C_MUTED" "$C_RESET" "$hostname"
    printf '  %sNS record      :%s %s\n' "$C_MUTED" "$C_RESET" "$tunnel_domain"
    printf '  %sNS target      :%s %s\n' "$C_MUTED" "$C_RESET" "$hostname"
    echo
    confirm="$(ask_prompt "Type CHANGE to apply")"
    [[ "$confirm" == "CHANGE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
    api_request_with_spinner PATCH "/api/v2/vps/domains" \
      "$(json_kv "hostname=$hostname" "tunnel_domain=$tunnel_domain")" \
      "Applying domain settings..."
    show_api_result
    if [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
      load_config
    fi
    return
  done
}

device_provisioning() {
  local status="" server_id="" choice="" confirm="" port="9443" server_name=""
  local certificate="" key="" prepared="0"
  while true; do
    print_header
    section "Device Provisioning"
    echo
    status="$(python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" status 2>&1 || true)"
    printf '  %sCurrent configuration%s\n' "$C_MUTED" "$C_RESET"
    printf '%s\n' "$status" | sed 's/^/  /'
    echo
    hr
    echo
    mi 1 "Prepare managed SSH"      "OpenSSH device-key authentication"
    mi 2 "Prepare managed OpenVPN"  "Client certificates and session monitor"
    mi 3 "Prepare managed Xray"     "Isolated mTLS VMess/VLESS/Trojan"
    mi 4 "Refresh status"
    echo
    mi 0 "Back"
    choice="$(ask)"
    [[ "$choice" == "0" ]] && return
    [[ "$choice" == "4" ]] && continue
    if [[ ! "$choice" =~ ^[123]$ ]]; then
      printf '  %s Invalid choice\n' "$(dot_err)"; pause; continue
    fi

    server_id="$(python3 - "$CONFIG_PATH" <<'PY'
import json, sys
try: print((json.load(open(sys.argv[1])).get('provisioning') or {}).get('server_id',''))
except Exception: print('')
PY
)"
    if [[ -z "$server_id" ]]; then
      server_id="$(ask_prompt "Immutable registry server ID")"
    else
      printf '  %sServer ID:%s %s\n' "$C_MUTED" "$C_RESET" "$server_id"
    fi
    [[ "$server_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
      printf '  %s Invalid server ID.\n' "$(dot_err)"; pause; continue;
    }
    echo
    confirm="$(ask_prompt "Type PREPARE to validate and activate")"
    [[ "$confirm" == "PREPARE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; pause; continue; }

    prepared="0"
    case "$choice" in
      1)
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-ssh --server-id "$server_id"; then
          prepared="1"
        fi
        ;;
      2)
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-openvpn --server-id "$server_id"; then
          prepared="1"
        fi
        ;;
      3)
        server_name="$(ask_prompt "TLS server name [$DOMAIN]")"; server_name="${server_name:-$DOMAIN}"
        port="$(ask_prompt "Dedicated public TLS port [9443]")"; port="${port:-9443}"
        certificate="$(ask_prompt "Server certificate [/etc/letsencrypt/live/$server_name/fullchain.pem]")"
        certificate="${certificate:-/etc/letsencrypt/live/$server_name/fullchain.pem}"
        key="$(ask_prompt "Server key [/etc/letsencrypt/live/$server_name/privkey.pem]")"
        key="${key:-/etc/letsencrypt/live/$server_name/privkey.pem}"
        if python3 /opt/iptunnel/provisioning_setup.py --config "$CONFIG_PATH" prepare-xray \
          --server-id "$server_id" --port "$port" --server-name "$server_name" \
          --certificate "$certificate" --key "$key"; then
          prepared="1"
        fi
        ;;
    esac
    if [[ "$prepared" == "1" ]]; then
      printf '  %s Device provisioning preparation completed.\n' "$(dot_ok)"
    else
      printf '  %s Device provisioning was not activated; previous configuration was restored.\n' "$(dot_err)"
    fi
    pause
  done
}

issue_letsencrypt_cert() {
  local email="" installed="" choice=""
  POST_ACTION_PAUSE="1"
  section "Let's Encrypt"
  echo
  [[ -n "$DOMAIN" ]] || { printf '  %s Domain is not set in config.\n' "$(dot_err)"; return; }
  api_request GET "/api/v2/vps/certificates/letsencrypt"
  show_api_result
  [[ "$API_STATUS" =~ ^2[0-9][0-9]$ ]] || return

  installed="$(json_data_field "$API_RESPONSE" "installed")"
  if [[ "$installed" == "true" ]]; then
    echo
    mi 1 "Reinstall certificate" "Force a fresh certbot renewal"
    mi 0 "Back"
    choice="$(ask)"
    if [[ "$choice" != "1" ]]; then
      POST_ACTION_PAUSE="0"
      return
    fi
    email="$(ask_prompt "Email for Let's Encrypt notices")"
    [[ -n "$email" ]] || { printf '  %s Email is required.\n' "$(dot_err)"; return; }
    api_request POST "/api/v2/vps/certificates/letsencrypt" "$(json_kv "email=$email" "force=true")"
    show_api_result
    return
  fi

  echo
  printf '  %sNo certificate is installed yet. Continue with a new issuance.%s\n' "$C_MUTED" "$C_RESET"
  echo
  email="$(ask_prompt "Email for Let's Encrypt notices")"
  [[ -n "$email" ]] || { printf '  %s Email is required.\n' "$(dot_err)"; return; }
  api_request POST "/api/v2/vps/certificates/letsencrypt" "$(json_kv "email=$email")"
  show_api_result
}

check_updates() {
  section "Update Checker"
  echo
  api_request GET "/api/v2/vps/updates"
  show_api_result
}

apply_update() {
  local confirm="" update_status="" update_log="" update_unit="" installer_cache="" status_file=""
  local current_version="" target_version="" notes="" installer_url=""
  section "Install Update"
  echo
  printf '  %sThis downloads the installer URL from the remote release manifest and reapplies the stack in the background.%s\n' "$C_MUTED" "$C_RESET"
  printf '  %sYour SSH session should stay up, but services may restart during the update.%s\n' "$C_MUTED" "$C_RESET"
  echo
  confirm="$(ask_prompt "Type UPDATE to continue")"
  [[ "$confirm" == "UPDATE" ]] || { printf '  %sCancelled.%s\n' "$C_MUTED" "$C_RESET"; return; }
  api_request POST "/api/v2/vps/updates"
  if [[ ! "$API_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    show_api_result
    return
  fi

  update_status="$(json_data_field "$API_RESPONSE" "status")"
  current_version="$(json_data_field "$API_RESPONSE" "installed")"
  target_version="$(json_data_field "$API_RESPONSE" "remote")"
  notes="$(json_data_field "$API_RESPONSE" "notes")"
  installer_url="$(json_data_field "$API_RESPONSE" "installer_url")"
  update_log="$(json_data_field "$API_RESPONSE" "log")"
  update_unit="$(json_data_field "$API_RESPONSE" "update_unit")"
  installer_cache="$(json_data_field "$API_RESPONSE" "installer_cache")"
  status_file="$(json_data_field "$API_RESPONSE" "status_file")"

  if [[ "$update_status" == "updating" ]]; then
    echo
    printf '  %s Update started.%s\n' "$(dot_ok)" "$C_RESET"
    [[ -n "$current_version" ]] && printf '  %sCurrent build :%s %s\n' "$C_MUTED" "$C_RESET" "$current_version"
    [[ -n "$target_version" ]] && printf '  %sTarget build  :%s %s\n' "$C_MUTED" "$C_RESET" "$target_version"
    [[ -n "$installer_url" ]] && printf '  %sSource        :%s %s\n' "$C_MUTED" "$C_RESET" "$installer_url"
    if [[ -n "$notes" ]]; then
      printf '  %sRelease notes :%s %s\n' "$C_MUTED" "$C_RESET" "$notes"
    fi
    show_update_progress "$update_log" "$update_unit" "$installer_cache" "$current_version" "$target_version" "$status_file"
    return
  fi

  show_api_result
}

# ══════════════════════════════════════════════════════════════════════
#  SUBMENUS
# ══════════════════════════════════════════════════════════════════════

udp_management() {
  while true; do
    local states=() hys_on="" ovpn_tcp="" ovpn_udp="" udp53_mode="" ovpn_public_udp="" slowdns_on=""
    local openvpn_udp_on="0"
    mapfile -t states < <(transport_module_state)
    hys_on="${states[0]:-0}"; ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"; udp53_mode="${states[3]:-slowdns}"; ovpn_public_udp="${states[4]:-53}"; slowdns_on="${states[5]:-1}"
    [[ "$ovpn_udp" != "-" ]] && openvpn_udp_on="1"

    print_header
    section "Mux53 / UDP Management"
    echo

    printf '  %s  %-22s %s\n' "$(_dot "$slowdns_on")" "SlowDNS" "$(_status_label "$slowdns_on")"
    printf '  %s  %-22s %s\n' "$(_dot "$openvpn_udp_on")" "OpenVPN UDP" "$(_status_label "$openvpn_udp_on")"
    printf '  %s  %-22s %s\n' "$(_dot 1)" "UDP53 mode" "$(udp53_mode_label "$udp53_mode")"
    printf '  %s  %-22s %s\n' "$(_dot "$([[ "$ovpn_public_udp" != "-" ]] && echo 1 || echo 0)")" "OpenVPN UDP ports" "$ovpn_public_udp"
    echo
    hr
    echo

    mi 1 "SlowDNS owns port 53"           "OpenVPN extra ports stay active"
    mi 2 "OpenVPN owns port 53"           "Supports extra ports such as 1194"
    mi 3 "Share port 53"                  "Experimental SlowDNS and OpenVPN mux"
    mi 4 "Configure OpenVPN UDP ports"    "Multiport, for example 53,1194"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) set_udp53_mode slowdns ;;
      2) set_udp53_mode openvpn ;;
      3) set_udp53_mode shared ;;
      4) enable_openvpn_alt_port ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    pause
  done
}

transport_settings() {
  while true; do
    local states=() hys_on="" ovpn_tcp="" ovpn_udp="" udp53_mode="" slowdns_mtu="1232" torrent_on="" openvpn_on="0"
    mapfile -t states < <(transport_module_state)
    hys_on="${states[0]:-0}"; ovpn_tcp="${states[1]:--}"; ovpn_udp="${states[2]:--}"; udp53_mode="${states[3]:-slowdns}"
    slowdns_mtu="${states[6]:-1232}"
    torrent_on="$(torrent_is_blocked)"
    [[ "$ovpn_tcp" != "-" || "$ovpn_udp" != "-" ]] && openvpn_on="1"

    print_header
    section "Transport & Protocols"
    echo

    printf '  %s  %-20s %s\n' "$(_dot "$hys_on")"     "Hysteria UDP"    "$(_status_label "$hys_on")"
    printf '  %s  %-20s %s\n' "$(_dot "$openvpn_on")"  "OpenVPN"         "$(_status_label "$openvpn_on")"
    printf '  %s  %-20s %s\n' "$(_dot 1)"             "UDP53 mode"       "$(udp53_mode_label "$udp53_mode")"
    printf '  %s  %-20s %s\n' "$(_dot 1)"             "SlowDNS MTU"      "$slowdns_mtu"
    printf '  %s  %-20s %s\n' \
      "$(_dot "$([[ "$torrent_on" == "1" ]] && echo 0 || echo 1)")" \
      "Torrent traffic" \
      "$(_blocked_label "$torrent_on")"
    echo
    hr
    echo

    mi 1 "$([[ "$hys_on" == "1" ]] && echo "Disable Hysteria" || echo "Enable Hysteria")"
    mi 2 "Hysteria auth / URI"          "Configure obfs & password"
    mi 3 "Mux53 / UDP management"       "SlowDNS, OpenVPN UDP, shared 53"
    mi 4 "SlowDNS MTU"                   "Tune resolver compatibility"
    mi 5 "$([[ "$torrent_on" == "1" ]] && echo "Allow torrent traffic" || echo "Block torrent traffic")"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) toggle_hysteria ;;
      2) configure_hysteria_auth ;;
      3) udp_management ;;
      4) change_slowdns_mtu ;;
      5) toggle_torrent ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    pause
  done
}

system_settings() {
  while true; do
    local rb_on rb_time
    rb_on="$(autoreboot_status)"
    rb_time="$(autoreboot_time)"
    POST_ACTION_PAUSE="1"

    print_header
    section "System Settings"
    echo

    printf '  %s  %-20s %s' "$(_dot "$rb_on")" "Auto-reboot" "$(_status_label "$rb_on")"
    [[ "$rb_on" == "1" ]] && printf '  %s(daily at %s)%s' "$C_MUTED" "$rb_time" "$C_RESET"
    echo
    echo
    hr
    echo

    mi 1 "Enable auto-reboot"          "Schedule daily server restart"
    mi 2 "Disable auto-reboot"
    mi 3 "Bandwidth stats"             "Usage totals by protocol"
    mi 4 "Backup configs"              "Create /root tar.gz snapshot"
    mi 5 "Restore backup"              "Extract saved tarball"
    mi 6 "Let's Encrypt cert"          "Inspect or install trusted TLS"
    mi 7 "Check for updates"           "Compare installed vs latest release"
    mi 8 "Install latest update"       "Use the release manifest installer"
    mi 9 "Change domains"              "Edit A record domain or SlowDNS NS"
    echo
    mi 0 "Back"

    local ch
    ch="$(ask)"
    case "$ch" in
      1) autoreboot_enable ;;
      2) autoreboot_disable ;;
      3) show_bandwidth_stats ;;
      4) backup_configs ;;
      5) restore_configs ;;
      6) issue_letsencrypt_cert ;;
      7) check_updates ;;
      8) apply_update ;;
      9) change_domains ;;
      0) return ;;
      *) printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac
    [[ "${POST_ACTION_PAUSE:-1}" == "1" ]] && pause
  done
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════════════════════════


main_menu() {
  while true; do
    print_header

    section "Account Management"
    echo
    mi 1  "List accounts"               "View all users by protocol"
    mi 2  "Create account"              "New user with expiry & limits"
    mi 3  "Create trial"                "Time-limited trial account"
    mi 4  "Account details"             "Check a specific user"
    mi 5  "Renew account"               "Extend expiry date"
    mi 6  "Delete account"              "Permanently remove a user"
    mi 7  "Lock / Unlock"               "Suspend or reactivate access"

    section "Server"
    echo
    mi 8  "Service status"              "Check all running services"
    mi 9  "Runtime info"                "Domain, IP, API, license"
    mi 10 "Transport & Protocols"       "Hysteria, Mux53, OpenVPN, torrent"
    mi 11 "System settings"             "Auto-reboot schedule"
    mi 12 "Device provisioning"         "Keys, certificates, readiness"
    echo
    mi 0  "Exit"

    local ch
    ch="$(ask)"
    print_header

    case "$ch" in
      1)  list_accounts ;;
      2)  create_account ;;
      3)  create_trial ;;
      4)  show_account ;;
      5)  renew_account ;;
      6)  delete_account ;;
      7)  lock_or_unlock ;;
      8)  show_status ;;
      9)  show_runtime_info ;;
      10) transport_settings ;;
      11) system_settings ;;
      12) device_provisioning ;;
      0)  echo; printf '  %sGoodbye.%s\n\n' "$C_MUTED" "$C_RESET"; exit 0 ;;
      *)  printf '  %s Invalid choice\n' "$(dot_err)" ;;
    esac

    pause
  done
}

need_commands
load_config
main_menu
