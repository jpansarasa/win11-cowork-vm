setup() {
  load "test_helper"
  source "${REPO_ROOT}/lib/generators.sh"
  export MOCKLOG="$BATS_TMPDIR/mock.log"; : > "$MOCKLOG"
}

@test "preflight_check_virt fails when cpuinfo lacks vmx/svm" {
  echo "flags: fpu vme lm" > "$BATS_TMPDIR/cpuinfo"
  CPUINFO_FILE="$BATS_TMPDIR/cpuinfo" run bash -c \
    'source lib/common.sh; source scripts/00-preflight.sh; preflight_check_virt'
  [ "$status" -ne 0 ]
}

@test "preflight_check_virt passes with vmx and /dev/kvm" {
  echo "flags: fpu vmx lm" > "$BATS_TMPDIR/cpuinfo"
  CPUINFO_FILE="$BATS_TMPDIR/cpuinfo" KVM_DEV=/dev/null run bash -c \
    'source lib/common.sh; source scripts/00-preflight.sh; preflight_check_virt'
  [ "$status" -eq 0 ]
}

@test "apply_network defines the net when absent" {
  VIRSH_NET_EXISTS=0 run bash -c \
    'source lib/common.sh; source lib/generators.sh; source scripts/10-network.sh; apply_network'
  [ "$status" -eq 0 ]
  grep -q "virsh net-define" "$MOCKLOG"
  grep -q "virsh net-autostart" "$MOCKLOG"
}

@test "apply_network refreshes (no define-clobber error) when present" {
  VIRSH_NET_EXISTS=1 run bash -c \
    'source lib/common.sh; source lib/generators.sh; source scripts/10-network.sh; apply_network'
  [ "$status" -eq 0 ]
  grep -q "virsh net-destroy" "$MOCKLOG"
}

@test "ensure_include is idempotent" {
  conf="$BATS_TMPDIR/nftables.conf"; : > "$conf"
  bash -c 'source lib/common.sh; source scripts/20-firewall.sh;
           ensure_include "'"$conf"'" "include \"/etc/nftables.d/cowork.nft\""'
  bash -c 'source lib/common.sh; source scripts/20-firewall.sh;
           ensure_include "'"$conf"'" "include \"/etc/nftables.d/cowork.nft\""'
  [ "$(grep -c 'cowork.nft' "$conf")" -eq 1 ]
}

@test "apply_firewall writes rule file and loads it" {
  d="$BATS_TMPDIR/nftd"; mkdir -p "$d"; conf="$BATS_TMPDIR/nftables.conf"; : > "$conf"
  MOCKLOG="$MOCKLOG" run bash -c 'source lib/common.sh; source lib/generators.sh; source scripts/20-firewall.sh;
           apply_firewall "'"$d"'" "'"$conf"'"'
  [ "$status" -eq 0 ]
  [ -f "$d/cowork.nft" ]
  grep -q 'nft -f' "$MOCKLOG"
  grep -q '10.0.0.0/8' "$d/cowork.nft"
}
