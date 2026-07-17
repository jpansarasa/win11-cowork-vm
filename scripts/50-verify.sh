#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# load_config unconditionally re-sources config.env, which would clobber any
# caller-supplied DNS_LOG/SNI_LOG override (e.g. from tests). Preserve them.
_pre_dns_log="${DNS_LOG:-}"
_pre_sni_log="${SNI_LOG:-}"
load_config
[ -n "$_pre_dns_log" ] && DNS_LOG="$_pre_dns_log"
[ -n "$_pre_sni_log" ] && SNI_LOG="$_pre_sni_log"

_fails=0
_check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$name"
  else printf 'FAIL  %s\n' "$name"; _fails=$((_fails+1)); fi
}

verify_all() {
  _fails=0
  _check "network ${NET_NAME} active"     virsh net-info "${NET_NAME}"
  _check "nft cowork table loaded"        nft list table inet cowork
  _check "domain ${VM_NAME} defined"      virsh dominfo "${VM_NAME}"
  _check "domain has TPM 2.0"             bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"version='2.0'\""
  _check "domain has secure boot"         bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"secure='yes'\""
  _check "cowork-sni.service active"      systemctl is-active cowork-sni.service
  _check "DNS_LOG dir writable"           bash -c "touch '${DNS_LOG}' 2>/dev/null || [ -w \"\$(dirname '${DNS_LOG}')\" ]"
  _check "SNI_LOG dir writable"           bash -c "touch '${SNI_LOG}' 2>/dev/null || [ -w \"\$(dirname '${SNI_LOG}')\" ]"
  [ "$_fails" -eq 0 ] || return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  verify_all
  rc=$?
  echo
  echo "Manual guest-side checks (run inside Windows):"
  echo "  - Test-NetConnection <a LAN host IP>  -> should FAIL (unreachable)"
  echo "  - internet reachable; Get-Tpm / Confirm-SecureBootUEFI -> True"
  echo "  - Cowork launches in the console session after reboot; scheduled run yields drafts only"
  exit $rc
fi
