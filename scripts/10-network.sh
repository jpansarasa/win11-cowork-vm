#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

apply_network() {
  need_cmd virsh
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  gen_net_xml > "$tmp"
  if virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
    # Rebuild deterministically from config. `net-define` CANNOT update a network
    # whose name is already taken — it errors "already exists with uuid ..." — so
    # tear the old one down (stop if active, then undefine) before redefining.
    log "network ${NET_NAME} exists — rebuilding from config"
    virsh net-destroy "${NET_NAME}" >/dev/null 2>&1 || true   # stop if active; ignore if already stopped
    virsh net-undefine "${NET_NAME}"
  else
    log "defining network ${NET_NAME}"
  fi
  virsh net-define "$tmp"
  virsh net-start "${NET_NAME}"
  virsh net-autostart "${NET_NAME}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then apply_network; log "network ready"; fi
