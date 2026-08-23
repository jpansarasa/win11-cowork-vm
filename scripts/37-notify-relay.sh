#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

# shellcheck disable=SC2119,SC2120 # called bare by design in the guard below; args are for the test harness only
install_relay() {
  local bin="${1:-/usr/local/sbin/cowork-notify-relay}"
  local env="${2:-/etc/cowork/notify-relay.env}"
  local svc="${3:-/etc/systemd/system/cowork-notify-relay.service}"
  local tmr="${4:-/etc/systemd/system/cowork-notify-relay.timer}"
  install -m 0755 "${HERE}/../host/cowork-notify-relay" "$bin"
  gen_relay_env     > "$env"
  chmod 0640 "$env"
  gen_relay_service > "$svc"
  gen_relay_timer   > "$tmr"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  if [ -z "${NTFY_URL:-}" ]; then
    log "NTFY_URL empty — skipping the notification relay (nothing to publish to)"
    exit 0
  fi
  need_cmd virsh
  need_cmd python3
  install -d -m 0750 /etc/cowork
  install_relay
  # The token is operator-supplied: never generated, never in the repo.
  if [ ! -s "${NTFY_TOKEN_FILE}" ]; then
    warn "${NTFY_TOKEN_FILE} is missing or empty — create it (publish-only ntfy token, chmod 600)."
    warn "The relay will fail loudly until it exists; nothing else is affected."
  fi
  systemctl daemon-reload
  systemctl enable --now cowork-notify-relay.timer
  log "notification relay installed (guest spools; host publishes to ${NTFY_URL})"
fi
