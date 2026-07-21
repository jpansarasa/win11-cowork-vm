#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

# shellcheck disable=SC2119,SC2120 # called bare by design in the guard below; args are for the test harness only
install_wandns() {
  local bin="${1:-/usr/local/sbin/cowork-wandns}"
  local svc="${2:-/etc/systemd/system/cowork-wandns.service}"
  local tmr="${3:-/etc/systemd/system/cowork-wandns.timer}"
  gen_wandns_script  > "$bin"
  chmod 0755 "$bin"
  gen_wandns_service > "$svc"
  gen_wandns_timer   > "$tmr"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  # Opt-in: only meaningful when a DNS override must track a dynamic WAN address.
  if [ -z "${DNS_WAN_HOSTS:-}" ]; then
    log "DNS_WAN_HOSTS empty — skipping WAN DNS refresh timer (nothing to track)"
    exit 0
  fi
  need_cmd virsh
  need_cmd curl
  install_wandns
  systemctl daemon-reload
  systemctl enable --now cowork-wandns.timer
  log "WAN DNS refresh timer installed for: ${DNS_WAN_HOSTS}"
fi
