#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

create_vm() {
  if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    warn "domain ${VM_NAME} already exists — skipping create (use recover.sh to re-import)"
    return 0
  fi
  need_cmd virt-install
  # Command substitution (not process substitution) so a die() inside
  # virt_install_args propagates its nonzero status here instead of being swallowed.
  local raw
  raw="$(virt_install_args)" || die "cannot assemble virt-install arguments (OVMF firmware missing? install the 'ovmf' package)"
  local args; mapfile -t args <<< "$raw"
  [ "${#args[@]}" -gt 0 ] || die "virt_install_args produced no arguments"
  virt-install "${args[@]}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  create_vm
  log "create-vm stage complete — if the domain is new, attach with: virt-viewer --connect qemu:///system ${VM_NAME}"
fi
