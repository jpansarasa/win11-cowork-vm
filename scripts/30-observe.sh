#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

# shellcheck disable=SC2119,SC2120 # called bare by design in the guard below; args are for the test harness only
install_observability() {
  local unit="${1:-/etc/systemd/system/cowork-sni.service}" lr="${2:-/etc/logrotate.d/cowork}"
  gen_sni_unit > "$unit"
  gen_logrotate > "$lr"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  need_cmd tshark
  install_observability
  systemctl daemon-reload
  systemctl enable --now cowork-sni.service
  log "SNI capture service + logrotate installed"
fi
