#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
load_config

PACKAGES=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
          virtinst virt-viewer ovmf swtpm swtpm-tools nftables tshark)

preflight_check_virt() {
  local cpuinfo="${CPUINFO_FILE:-/proc/cpuinfo}" kvm="${KVM_DEV:-/dev/kvm}"
  local flags
  flags="$(cat "$cpuinfo")" || die "cannot read ${cpuinfo} to check CPU virtualization"
  cpu_has_virt "$flags" || die "no CPU virtualization (vmx/svm) present"
  [ -e "$kvm" ] || die "KVM device $kvm missing — is virtualization enabled in BIOS?"
}

install_packages() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  # Preseed wireshark-common so tshark installs without the dumpcap prompt.
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
  apt-get update
  apt-get install -y "${PACKAGES[@]}"
  systemctl enable --now libvirtd
  virt-host-validate qemu || warn "virt-host-validate reported issues (review above)"
}

# Only run side effects when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  preflight_check_virt
  install_packages
  log "preflight complete"
fi
