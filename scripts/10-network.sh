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
    log "network ${NET_NAME} exists — refreshing definition"
    virsh net-define "$tmp"
    local d; d="$(virsh net-destroy "${NET_NAME}" 2>&1)" || warn "net-destroy ${NET_NAME}: ${d}"
    virsh net-start "${NET_NAME}"
  else
    log "defining network ${NET_NAME}"
    virsh net-define "$tmp"
    virsh net-start "${NET_NAME}"
  fi
  virsh net-autostart "${NET_NAME}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then apply_network; log "network ready"; fi
