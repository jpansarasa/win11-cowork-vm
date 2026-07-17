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

@test "install_observability writes unit and logrotate files" {
  unit="$BATS_TMPDIR/cowork-sni.service"; lr="$BATS_TMPDIR/cowork.logrotate"
  run bash -c 'source lib/common.sh; source lib/generators.sh; source scripts/30-observe.sh;
           install_observability "'"$unit"'" "'"$lr"'"'
  [ "$status" -eq 0 ]
  grep -q "Restart=always" "$unit"
  grep -q "copytruncate" "$lr"
}

@test "create_vm skips (success no-op) when domain already exists" {
  VIRSH_DOM_EXISTS=1 OVMF_DIR="$BATS_TMPDIR/ovmf" run bash -c \
    'mkdir -p "$OVMF_DIR"; touch "$OVMF_DIR/OVMF_CODE_4M.secboot.fd" "$OVMF_DIR/OVMF_VARS_4M.fd";
     source lib/common.sh; source lib/generators.sh; source scripts/40-create-vm.sh; create_vm'
  [ "$status" -eq 0 ]
  ! grep -q "virt-install" "$MOCKLOG"
}

@test "create_vm runs virt-install when domain absent" {
  VIRSH_DOM_EXISTS=0 OVMF_DIR="$BATS_TMPDIR/ovmf" run bash -c \
    'mkdir -p "$OVMF_DIR"; touch "$OVMF_DIR/OVMF_CODE_4M.secboot.fd" "$OVMF_DIR/OVMF_VARS_4M.fd";
     source lib/common.sh; source lib/generators.sh; source scripts/40-create-vm.sh; create_vm'
  [ "$status" -eq 0 ]
  grep -q "virt-install" "$MOCKLOG"
}

@test "verify_all passes when everything is healthy" {
  VIRSH_NET_EXISTS=1 VIRSH_DOM_EXISTS=1 NFT_TABLE_EXISTS=1 SYSTEMCTL_ACTIVE=1 \
  DNS_LOG="$BATS_TMPDIR/dns.log" SNI_LOG="$BATS_TMPDIR/sni.log" \
  run bash -c 'source lib/common.sh; load_config;
    DNS_LOG="'"$BATS_TMPDIR"'/dns.log"; SNI_LOG="'"$BATS_TMPDIR"'/sni.log";
    source scripts/50-verify.sh; verify_all'
  [ "$status" -eq 0 ]
}

@test "verify_all fails when the domain is not running" {
  VIRSH_NET_EXISTS=1 VIRSH_DOM_EXISTS=1 NFT_TABLE_EXISTS=1 SYSTEMCTL_ACTIVE=1 VIRSH_DOMSTATE="shut off" \
  run bash -c 'source lib/common.sh; load_config;
    DNS_LOG="'"$BATS_TMPDIR"'/dns.log"; SNI_LOG="'"$BATS_TMPDIR"'/sni.log";
    source scripts/50-verify.sh; verify_all'
  [ "$status" -ne 0 ]
}

@test "verify_all fails when the nft table is missing" {
  VIRSH_NET_EXISTS=1 VIRSH_DOM_EXISTS=1 NFT_TABLE_EXISTS=0 SYSTEMCTL_ACTIVE=1 \
  run bash -c 'source lib/common.sh; load_config;
    DNS_LOG="'"$BATS_TMPDIR"'/dns.log"; SNI_LOG="'"$BATS_TMPDIR"'/sni.log";
    source scripts/50-verify.sh; verify_all'
  [ "$status" -ne 0 ]
}

@test "export_definitions writes both XML files to dest" {
  dest="$BATS_TMPDIR/state"
  run bash -c 'source lib/common.sh; load_config; source scripts/90-snapshot.sh; export_definitions "'"$dest"'"'
  [ "$status" -eq 0 ]
  [ -s "$dest/${NET_NAME}.net.xml" ] || [ -s "$dest/cowork-net.net.xml" ]
  [ -s "$dest/${VM_NAME}.domain.xml" ] || [ -s "$dest/win11-cowork.domain.xml" ]
}

@test "recover_check_disk aborts when the restored qcow2 is missing" {
  DISK_PATH="$BATS_TMPDIR/nope.qcow2" run bash -c \
    'source lib/common.sh; load_config; DISK_PATH="'"$BATS_TMPDIR"'/nope.qcow2";
     source recover.sh; recover_check_disk'
  [ "$status" -ne 0 ]
}

@test "recover_check_disk passes when the disk is present" {
  touch "$BATS_TMPDIR/disk.qcow2"
  DISK_PATH="$BATS_TMPDIR/disk.qcow2" run bash -c \
    'source lib/common.sh; load_config; DISK_PATH="'"$BATS_TMPDIR"'/disk.qcow2";
     source recover.sh; recover_check_disk'
  [ "$status" -eq 0 ]
}

@test "recover_import defines only the domain, not the network" {
  dest="$BATS_TMPDIR/state"; mkdir -p "$dest"
  : > "$dest/win11-cowork.domain.xml"
  MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source recover.sh;
     ZFS_EXPORT_DIR="'"$dest"'"; recover_import'
  [ "$status" -eq 0 ]
  grep -q "virsh define" "$MOCKLOG"
  ! grep -q "net-define" "$MOCKLOG"
}

@test "recover_import dies when exported domain XML is missing" {
  dest="$BATS_TMPDIR/empty"; mkdir -p "$dest"
  run bash -c \
    'source lib/common.sh; load_config; source recover.sh;
     ZFS_EXPORT_DIR="'"$dest"'"; recover_import'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no exported domain XML"* ]]
}

@test "export then recover_import round-trips through the same dir" {
  dest="$BATS_TMPDIR/rt"; mkdir -p "$dest"
  MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh;
     export_definitions "'"$dest"'";
     source recover.sh; ZFS_EXPORT_DIR="'"$dest"'"; recover_import'
  [ "$status" -eq 0 ]
}

@test "snapshot_vm creates an atomic disk-only snapshot" {
  MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -eq 0 ]
  grep -q "snapshot-create-as ${VM_NAME} clean-authed" "$MOCKLOG"
  grep -q -- "--disk-only" "$MOCKLOG"
  grep -q -- "--atomic" "$MOCKLOG"
}
