#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

create_vm() {
  need_cmd virt-install
  if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    warn "domain ${VM_NAME} already exists — refusing to recreate (use recover.sh to re-import)"
    return 1
  fi
  local args; mapfile -t args < <(virt_install_args)
  virt-install "${args[@]}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then create_vm && log "VM created — attach with: virt-viewer --connect qemu:///system ${VM_NAME}"; fi
