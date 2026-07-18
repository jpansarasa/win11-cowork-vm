#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

# shellcheck disable=SC2119,SC2120 # called bare by design in the guard below; args are for the test harness only
install_timesync() {
  local svc="${1:-/etc/systemd/system/cowork-timesync.service}" tmr="${2:-/etc/systemd/system/cowork-timesync.timer}"
  gen_timesync_service > "$svc"
  gen_timesync_timer   > "$tmr"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  need_cmd virsh
  install_timesync
  systemctl daemon-reload
  systemctl enable --now cowork-timesync.timer
  log "guest time-sync timer installed (host pushes time via qemu-ga; guest NTP stays blocked)"
fi
