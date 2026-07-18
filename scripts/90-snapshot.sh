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
  # Net XML is exported for reference/audit only — recover.sh rebuilds the
  # network from config.env via 10-network.sh, not from this file.
  virsh net-dumpxml "${NET_NAME}" > "${dest}/${NET_NAME}.net.xml"
  virsh dumpxml "${VM_NAME}"      > "${dest}/${VM_NAME}.domain.xml"
  log "exported net + domain XML to ${dest}"
}

snapshot_vm() {
  need_cmd virsh
  need_cmd zfs
  local snap="${ZFS_DATASET}@clean-authed"
  # App-consistent golden baseline: VSS-quiesce the guest's filesystems (via
  # qemu-ga), snapshot the WHOLE dataset (qcow2 + exported XML live under it, so
  # they're captured atomically), then thaw. Recovery is a `zfs rollback` to this.
  virsh domfsfreeze "${VM_NAME}"
  # Always thaw, even if the snapshot fails, so we never leave the guest frozen.
  local rc=0
  zfs snapshot "$snap" || rc=$?
  virsh domfsthaw "${VM_NAME}"
  [ "$rc" -eq 0 ] || die "zfs snapshot ${snap} failed (already exists? destroy it first to re-baseline)"
  log "golden snapshot ${snap} taken (VSS-quiesced)"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # Export XML into the dataset FIRST so the snapshot captures disk + definitions together.
  export_definitions "$@"
  snapshot_vm
  log "snapshot + export complete — recover from ${ZFS_DATASET}@clean-authed"
fi
