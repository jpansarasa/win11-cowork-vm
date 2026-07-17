#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
load_config

export_definitions() {
  local dest="${1:-$ZFS_EXPORT_DIR}"
  need_cmd virsh
  mkdir -p "$dest"
  virsh net-dumpxml "${NET_NAME}" > "${dest}/${NET_NAME}.net.xml"
  virsh dumpxml "${VM_NAME}"      > "${dest}/${VM_NAME}.domain.xml"
  log "exported net + domain XML to ${dest}"
}

snapshot_vm() {
  need_cmd virsh
  virsh snapshot-create-as "${VM_NAME}" clean-authed "post-setup, connectors authed" --disk-only --atomic
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  export_definitions "$@"
  snapshot_vm
  log "snapshot + export complete — ensure ${ZFS_EXPORT_DIR} and the qcow2 are in the ZFS dataset"
fi
