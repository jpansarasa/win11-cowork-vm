#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"
# load_config unconditionally re-sources config.env, which would clobber any
# caller-supplied DISK_PATH override (e.g. from tests). Preserve it.
_pre_disk_path="${DISK_PATH:-}"
load_config
[ -n "$_pre_disk_path" ] && DISK_PATH="$_pre_disk_path"

recover_check_disk() {
  [ -f "${DISK_PATH}" ] || die "restored disk not found at ${DISK_PATH} — restore it from ZFS before recovering"
}

recover_import() {
  need_cmd virsh
  local net="${ZFS_EXPORT_DIR}/${NET_NAME}.net.xml" dom="${ZFS_EXPORT_DIR}/${VM_NAME}.domain.xml"
  if [ -f "$net" ]; then virsh net-define "$net"; else warn "no exported net XML; network already rebuilt by stage 10"; fi
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
  virsh start "${VM_NAME}" || warn "domain start failed — inspect with virsh dominfo ${VM_NAME}"
  bash "${HERE}/scripts/50-verify.sh"
  log "recovery complete"
fi
