#!/usr/bin/env bash
# No `-e`: verify_all's own nonzero return (aggregated failures) must not abort
# the script before the manual-checklist printout, and every _check must run.
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
  local out
  if out="$("$@" 2>&1)"; then printf 'PASS  %s\n' "$name"
  else printf 'FAIL  %s\n' "$name"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/      /'; _fails=$((_fails+1)); fi
}

# systemctl is-active, but tolerate a unit that was just (re)started and is still
# settling. Recovery restarts the SNI capture right after the bridge is recreated,
# so an immediate is-active can catch it "activating" — a false FAIL (and a false
# recover.sh exit 1) even though it comes up a moment later.
_svc_active() {
  local unit="$1"
  for _ in 1 2 3 4 5; do
    systemctl is-active "$unit" >/dev/null 2>&1 && return 0
    sleep 1
  done
  systemctl is-active "$unit"   # final try surfaces the real state if still not active
}

verify_all() {
  _fails=0
  _check "network ${NET_NAME} active"     virsh net-info "${NET_NAME}"
  _check "nft cowork table loaded"        nft list table inet cowork
  _check "domain ${VM_NAME} defined"      virsh dominfo "${VM_NAME}"
  _check "domain ${VM_NAME} running"      bash -c "virsh domstate '${VM_NAME}' | grep -q '^running$'"
  _check "domain has TPM 2.0"             bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"version='2.0'\""
  _check "domain has secure boot"         bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"secure='yes'\""
  _check "SPICE console bound to loopback" bash -c "virsh dumpxml '${VM_NAME}' | grep -Eq \"listen[^>]*127.0.0.1\""
  _check "cowork-sni.service active"      _svc_active cowork-sni.service
  _check "cowork-timesync.timer active"   _svc_active cowork-timesync.timer
  _check "DNS_LOG dir writable"           bash -c "if [ -e '${DNS_LOG}' ]; then [ -w '${DNS_LOG}' ]; else [ -w \"\$(dirname '${DNS_LOG}')\" ]; fi"
  _check "SNI_LOG dir writable"           bash -c "if [ -e '${SNI_LOG}' ]; then [ -w '${SNI_LOG}' ]; else [ -w \"\$(dirname '${SNI_LOG}')\" ]; fi"
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
