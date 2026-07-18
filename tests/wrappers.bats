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

@test "apply_network rebuilds cleanly when present (undefine BEFORE define, no uuid clobber)" {
  # Regression (found by the real recover.sh E2E test): net-define on an existing
  # network name errors "already exists with uuid ..." — recovery MUST net-undefine
  # the old network before redefining. The exit-0 mocks hid this; assert the order.
  VIRSH_NET_EXISTS=1 run bash -c \
    'source lib/common.sh; source lib/generators.sh; source scripts/10-network.sh; apply_network'
  [ "$status" -eq 0 ]
  grep -q "virsh net-undefine ${NET_NAME}" "$MOCKLOG"
  undef=$(grep -n "net-undefine" "$MOCKLOG" | head -1 | cut -d: -f1)
  def=$(grep -n "net-define"   "$MOCKLOG" | tail -1 | cut -d: -f1)
  [ "$undef" -lt "$def" ]
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

@test "install_timesync writes the service + timer units" {
  svc="$BATS_TMPDIR/cowork-timesync.service"; tmr="$BATS_TMPDIR/cowork-timesync.timer"
  run bash -c 'source lib/common.sh; load_config; source lib/generators.sh; source scripts/35-timesync.sh;
           install_timesync "'"$svc"'" "'"$tmr"'"'
  [ "$status" -eq 0 ]
  grep -q "domtime ${VM_NAME} --time" "$svc"
  grep -q "OnUnitActiveSec=1h" "$tmr"
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

@test "snapshot_vm freezes the guest, zfs-snapshots the dataset, then thaws (in order)" {
  MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -eq 0 ]
  grep -q "virsh domfsfreeze ${VM_NAME}" "$MOCKLOG"
  grep -q "zfs snapshot ${ZFS_DATASET}@clean-authed" "$MOCKLOG"
  grep -q "virsh domfsthaw ${VM_NAME}" "$MOCKLOG"
  # freeze -> snapshot -> thaw ordering
  freeze=$(grep -n "domfsfreeze" "$MOCKLOG" | cut -d: -f1)
  snap=$(grep -n "zfs snapshot"  "$MOCKLOG" | cut -d: -f1)
  thaw=$(grep -n "domfsthaw"   "$MOCKLOG" | cut -d: -f1)
  [ "$freeze" -lt "$snap" ] && [ "$snap" -lt "$thaw" ]
}

@test "snapshot_vm thaws the guest even when the zfs snapshot fails (snapshot before thaw)" {
  # A frozen-and-abandoned guest is worse than a missing snapshot. On failure we
  # must still thaw, and the command must report failure (non-zero). The snapshot
  # must also be ATTEMPTED before the thaw, or the freeze bought us nothing.
  ZFS_FAIL=1 MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -ne 0 ]
  grep -q "virsh domfsthaw ${VM_NAME}" "$MOCKLOG"
  snap=$(grep -n "zfs snapshot" "$MOCKLOG" | cut -d: -f1)
  thaw=$(grep -n "domfsthaw"    "$MOCKLOG" | cut -d: -f1)
  [ "$snap" -lt "$thaw" ]
}

@test "snapshot_vm still thaws and does NOT snapshot when the freeze fails" {
  # A VSS timeout can leave filesystems frozen while domfsfreeze returns non-zero,
  # so the thaw must run even on freeze failure; and no snapshot may be taken.
  VIRSH_FREEZE_FAIL=1 MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -ne 0 ]
  grep -q "virsh domfsthaw ${VM_NAME}" "$MOCKLOG"
  ! grep -q "zfs snapshot" "$MOCKLOG"
}

@test "snapshot_vm reports a frozen-guest emergency (loudly) when the thaw fails" {
  VIRSH_THAW_FAIL=1 MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -ne 0 ]
  [[ "$output" == *"FROZEN"* ]]
}

@test "snapshot_vm refuses to snapshot when the disk is not on the dataset" {
  # If the dataset mounts somewhere other than where DISK_PATH lives, the golden
  # snapshot would capture an empty dataset. Guard must abort before snapshotting.
  ZFS_MOUNTPOINT=/somewhere/else MOCKLOG="$MOCKLOG" run bash -c \
    'source lib/common.sh; load_config; source scripts/90-snapshot.sh; snapshot_vm'
  [ "$status" -ne 0 ]
  ! grep -q "zfs snapshot" "$MOCKLOG"
}

@test "90-snapshot.sh exports the domain XML before taking the zfs snapshot" {
  # The whole dataset-capture contract depends on the XML being written INTO the
  # dataset before the snapshot freezes it. Run the real __main__ block to guard
  # the ordering (not just the two functions in isolation).
  dest="$BATS_TMPDIR/state"
  run env PATH="${REPO_ROOT}/tests/mocks:$PATH" MOCKLOG="$MOCKLOG" \
    DISK_PATH="$BATS_TMPDIR/win11.qcow2" ZFS_EXPORT_DIR="$dest" ZFS_MOUNTPOINT="$BATS_TMPDIR" \
    bash scripts/90-snapshot.sh
  [ "$status" -eq 0 ]
  dump=$(grep -n "virsh dumpxml ${VM_NAME}" "$MOCKLOG" | head -1 | cut -d: -f1)
  snap=$(grep -n "zfs snapshot" "$MOCKLOG" | cut -d: -f1)
  [ -n "$dump" ] && [ -n "$snap" ] && [ "$dump" -lt "$snap" ]
}
