#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"; load_config
require_root
for stage in 00-preflight 10-network 20-firewall 30-observe 40-create-vm 50-verify; do
  log "=== ${stage} ==="
  bash "${HERE}/scripts/${stage}.sh"
done
log "install complete — now do the manual Windows/Cowork/connector steps, then run scripts/90-snapshot.sh"
