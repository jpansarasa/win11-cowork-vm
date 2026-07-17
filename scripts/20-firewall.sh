#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/../lib/common.sh"
# shellcheck source=lib/generators.sh
source "${HERE}/../lib/generators.sh"
load_config

ensure_include() {
  local conf="$1" line="$2"
  grep -qF "$line" "$conf" 2>/dev/null || printf '%s\n' "$line" >> "$conf"
}

apply_firewall() {
  local nft_dir="${1:-/etc/nftables.d}" conf="${2:-/etc/nftables.conf}"
  need_cmd nft
  mkdir -p "$nft_dir"
  gen_nft_rules > "${nft_dir}/cowork.nft"
  nft -f "${nft_dir}/cowork.nft"
  ensure_include "$conf" "include \"${nft_dir}/cowork.nft\""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  apply_firewall "$@"
  systemctl enable nftables
  log "firewall applied and persisted"
fi
