#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"
# load_config unconditionally re-sources config.env, which would clobber any
# caller-supplied DISK_PATH / ZFS_EXPORT_DIR override (e.g. from tests). Preserve them.
_pre_disk_path="${DISK_PATH:-}"
_pre_zfs_export_dir="${ZFS_EXPORT_DIR:-}"
load_config
[ -n "$_pre_disk_path" ] && DISK_PATH="$_pre_disk_path"
[ -n "$_pre_zfs_export_dir" ] && ZFS_EXPORT_DIR="$_pre_zfs_export_dir"

# Recovery model: the qcow2 and the exported domain XML live on the ZFS dataset
# ${ZFS_DATASET} (mounted at /export/coworkvm). "Restore" means getting that
# dataset back to the golden baseline BEFORE running this script:
#   same host, disk intact:  zfs rollback ${ZFS_DATASET}@clean-authed
#   new host / dead pool:     zfs recv ${ZFS_DATASET} < clean-authed.zfs  (from `zfs send`)
# This script then rebuilds the host scaffolding and re-imports the domain; it
# does NOT recreate the disk. recover_check_disk asserts the disk is PRESENT (the
# restore's expected result) — it can't tell a fresh rollback from a stale disk.
recover_check_disk() {
  [ -f "${DISK_PATH}" ] || die "restored disk not found at ${DISK_PATH} — zfs rollback/recv ${ZFS_DATASET:-the dataset} to @clean-authed before recovering"
}

recover_import() {
  need_cmd virsh
  # The network is rebuilt deterministically by stage 10-network; only the domain is re-imported.
  local dom="${ZFS_EXPORT_DIR}/${VM_NAME}.domain.xml"
  [ -f "$dom" ] || die "no exported domain XML at ${dom} — cannot re-import the VM"
  virsh define "$dom"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  for stage in 00-preflight 10-network 20-firewall 30-observe; do
    log "=== ${stage} ==="; bash "${HERE}/scripts/${stage}.sh"
  done
  recover_check_disk
  recover_import
  virsh start "${VM_NAME}" || die "domain ${VM_NAME} failed to start — recovery incomplete; inspect: virsh dominfo ${VM_NAME}"
  bash "${HERE}/scripts/50-verify.sh"
  log "recovery complete"
fi
