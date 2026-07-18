#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# load_config re-sources config.env, which would clobber any caller/test override
# of these. Preserve them (mirrors recover.sh) so the snapshot flow is testable.
_pre_disk="${DISK_PATH:-}"; _pre_exp="${ZFS_EXPORT_DIR:-}"; _pre_ds="${ZFS_DATASET:-}"
load_config
[ -n "$_pre_disk" ] && DISK_PATH="$_pre_disk"
[ -n "$_pre_exp" ]  && ZFS_EXPORT_DIR="$_pre_exp"
[ -n "$_pre_ds" ]   && ZFS_DATASET="$_pre_ds"

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

  # The disk and the exported XML must actually live on the dataset we snapshot,
  # or the "golden baseline" captures neither and recovery silently restores
  # nothing. A fresh host may have created ${ZFS_DATASET} with a default
  # mountpoint (/${ZFS_DATASET}), not /export/coworkvm — assert before trusting it.
  local mp
  mp="$(zfs list -H -o mountpoint "${ZFS_DATASET}")" || die "ZFS dataset ${ZFS_DATASET} not found — create it (mounted at the parent of ${DISK_PATH}) before snapshotting"
  case "${DISK_PATH}/"      in "${mp%/}/"*) : ;; *) die "DISK_PATH ${DISK_PATH} is not under ${ZFS_DATASET} (mount ${mp}) — the snapshot would not capture the disk" ;; esac
  case "${ZFS_EXPORT_DIR}/" in "${mp%/}/"*) : ;; *) die "ZFS_EXPORT_DIR ${ZFS_EXPORT_DIR} is not under ${ZFS_DATASET} (mount ${mp}) — the snapshot would not capture the XML" ;; esac

  # App-consistent golden baseline: VSS-quiesce the guest (needs a RUNNING guest
  # with qemu-ga), snapshot the WHOLE dataset — disk + exported XML together. The
  # snapshot is NON-recursive, so ${ZFS_EXPORT_DIR} must be a directory inside the
  # dataset, not a child dataset, or its contents won't be captured.
  local rc=0
  virsh domfsfreeze "${VM_NAME}" || rc=$?
  if [ "$rc" -eq 0 ]; then
    zfs snapshot "$snap" || rc=$?
  fi
  # ALWAYS thaw, before anything can exit — a freeze that returned non-zero (e.g.
  # a VSS timeout) may still have frozen some filesystems, so thaw even on failure.
  # A failed thaw is an emergency (Windows I/O hangs) and must be surfaced loudly.
  local thaw_rc=0
  virsh domfsthaw "${VM_NAME}" || thaw_rc=$?
  [ "$thaw_rc" -eq 0 ] || die "GUEST MAY BE FROZEN: virsh domfsthaw ${VM_NAME} failed — run it manually NOW (snapshot rc=${rc})"
  [ "$rc" -eq 0 ] || die "snapshot step failed for ${snap} — domfsfreeze failed (guest running with qemu-ga?) or the snapshot already exists (zfs destroy it to re-baseline)"
  log "golden snapshot ${snap} taken (VSS-quiesced)"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # Export XML into the dataset FIRST — always ZFS_EXPORT_DIR (never a caller path),
  # so it lands inside the dataset and the snapshot captures disk + definitions together.
  export_definitions "${ZFS_EXPORT_DIR}"
  snapshot_vm
  log "snapshot + export complete — recover from ${ZFS_DATASET}@clean-authed"
fi
