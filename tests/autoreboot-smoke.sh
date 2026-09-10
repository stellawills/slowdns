#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed '/^need_commands$/,$d' scripts/menu.sh | tr -d '\r')
AUTOREBOOT_UNIT_DIR="$(mktemp -d)"
trap 'rm -r -- "$AUTOREBOOT_UNIT_DIR"' EXIT
mock_enabled=disabled
mock_active=inactive
fail_restart=0
systemctl() {
  case "$1" in
    is-enabled) echo "$mock_enabled" ;;
    is-active) if [[ "${2:-}" != --quiet ]]; then echo "$mock_active"; fi; [[ "$mock_active" == active ]] ;;
    show) echo 'tomorrow 04:00:00' ;;
    stop) mock_active=inactive ;;
    disable) mock_enabled=disabled ;;
    enable) mock_enabled=enabled ;;
    start) mock_active=active ;;
    restart) if (( fail_restart )); then return 1; fi; mock_active=active ;;
    daemon-reload) return 0 ;;
    *) return 99 ;;
  esac
}
autoreboot_save 04:00:00 /sbin/reboot
[[ "$mock_active" == active && "$mock_enabled" == enabled ]]
grep -q 'OnCalendar=\*-\*-\* 04:00:00' "$AUTOREBOOT_UNIT_DIR/slowdns-autoreboot.timer"
autoreboot_save 09:05:00 /sbin/reboot
cp "$AUTOREBOOT_UNIT_DIR/slowdns-autoreboot.timer" "$AUTOREBOOT_UNIT_DIR/expected"
fail_restart=1
if autoreboot_save 12:00:00 /sbin/reboot; then exit 1; fi
cmp "$AUTOREBOOT_UNIT_DIR/expected" "$AUTOREBOOT_UNIT_DIR/slowdns-autoreboot.timer"
[[ "$mock_active" == active && "$mock_enabled" == enabled ]]
mock_active=inactive
if autoreboot_save 13:00:00 /sbin/reboot; then exit 1; fi
[[ "$mock_active" == inactive && "$mock_enabled" == enabled ]]
autoreboot_status | grep -q 'Runtime: inactive'
mock_enabled=disabled
mock_active=active
autoreboot_status | grep -q 'At boot: disabled | Runtime: active'
systemctl disable --now slowdns-autoreboot.timer
[[ "$mock_enabled" == disabled ]]
echo 'PASS: enable, reschedule, failed activation rollback, independent status states'
