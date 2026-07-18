setup() { load "test_helper"; source "${REPO_ROOT}/lib/generators.sh"; }

@test "gen_nft_rules uses dedicated table at priority -10" {
  run gen_nft_rules
  [[ "$output" == *"table inet cowork"* ]]
  [[ "$output" == *"hook forward priority -10"* ]]
}

@test "gen_nft_rules drops all four private ranges" {
  run gen_nft_rules
  for r in "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16"; do
    [[ "$output" == *"$r"* ]]
  done
}

@test "gen_nft_rules LAN-drop is scoped to the guest bridge on one line" {
  run gen_nft_rules
  [[ "$output" == *'iifname "'"${BRIDGE}"'" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop'* ]]
}

@test "gen_nft_rules: DNS/web accepts precede the final catch-all drop" {
  gen_nft_rules > "$BATS_TMPDIR/r.nft"
  web=$(grep -n 'tcp dport { 80, 443 }' "$BATS_TMPDIR/r.nft" | cut -d: -f1)
  catchall=$(grep -n "iifname \"${BRIDGE}\" counter drop" "$BATS_TMPDIR/r.nft" | tail -1 | cut -d: -f1)
  [ "$web" -lt "$catchall" ]
}

@test "gen_nft_rules allows DNS and web, drops the rest" {
  run gen_nft_rules
  [[ "$output" == *"udp dport 53 accept"* ]]
  [[ "$output" == *"tcp dport 53 accept"* ]]
  [[ "$output" == *"tcp dport { 80, 443 } accept"* ]]
  [[ "$output" == *"iifname \"${BRIDGE}\" counter drop"* ]]
}

@test "gen_nft_rules is re-appliable (atomic delete+recreate idiom)" {
  run gen_nft_rules
  [[ "$output" == *"delete table inet cowork"* ]]
}

@test "gen_nft_rules blocks guest->host via the input hook (allow only DNS/DHCP)" {
  # Traffic to the host's OWN addresses is delivered via the INPUT hook, not
  # FORWARD, so the forward chain can't protect the host's services (SSH, NFS,
  # ZFS shares). An input chain must drop guest->host except the host resolver.
  run gen_nft_rules
  [[ "$output" == *"hook input priority -10"* ]]
  [[ "$output" == *'iifname "'"${BRIDGE}"'" udp dport { 53, 67 } accept'* ]]
  # a catch-all guest->host drop must exist (2 bridge drops total: forward + input)
  [ "$(printf '%s\n' "$output" | grep -c "iifname \"${BRIDGE}\" counter drop")" -ge 2 ]
}

@test "gen_net_xml sets name, bridge, and NAT" {
  run gen_net_xml
  [[ "$output" == *"<name>${NET_NAME}</name>"* ]]
  [[ "$output" == *"<bridge name='${BRIDGE}'"* ]]
  [[ "$output" == *"<forward mode='nat'/>"* ]]
}

@test "gen_net_xml enables dnsmasq query logging to DNS_LOG" {
  run gen_net_xml
  [[ "$output" == *"log-queries"* ]]
  [[ "$output" == *"log-facility=${DNS_LOG}"* ]]
}

@test "gen_net_xml carries the DHCP range" {
  run gen_net_xml
  [[ "$output" == *"start='${DHCP_START}' end='${DHCP_END}'"* ]]
}

@test "gen_sni_unit captures timestamped SNI and restarts always" {
  run gen_sni_unit
  [[ "$output" == *"-i ${BRIDGE}"* ]]
  [[ "$output" == *"frame.time_epoch"* ]]
  [[ "$output" == *"tls.handshake.extensions_server_name"* ]]
  [[ "$output" == *"append:${SNI_LOG}"* ]]
  [[ "$output" == *"Restart=always"* ]]
  [[ "$output" == *"WantedBy=multi-user.target"* ]]
}

@test "gen_logrotate rotates both logs on a rolling window" {
  run gen_logrotate
  [[ "$output" == *"${SNI_LOG}"* ]]
  [[ "$output" == *"${DNS_LOG}"* ]]
  [[ "$output" == *"rotate ${LOG_RETAIN_DAYS}"* ]]
  [[ "$output" == *"daily"* ]]
  [[ "$output" == *"copytruncate"* ]]
}

@test "detect_ovmf finds secboot firmware in a fixture dir" {
  mkdir -p "$BATS_TMPDIR/ovmf"
  touch "$BATS_TMPDIR/ovmf/OVMF_CODE_4M.secboot.fd" "$BATS_TMPDIR/ovmf/OVMF_VARS_4M.fd"
  run detect_ovmf "$BATS_TMPDIR/ovmf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OVMF_CODE_4M.secboot.fd|"* ]]
  [[ "$output" == *"OVMF_VARS_4M.fd"* ]]
}

@test "detect_ovmf fails when no firmware present" {
  mkdir -p "$BATS_TMPDIR/empty"
  run detect_ovmf "$BATS_TMPDIR/empty"
  [ "$status" -ne 0 ]
}

@test "virt_install_args requests TPM2, secure boot, virtio, spice, both ISOs" {
  mkdir -p "$BATS_TMPDIR/ovmf"
  touch "$BATS_TMPDIR/ovmf/OVMF_CODE_4M.secboot.fd" "$BATS_TMPDIR/ovmf/OVMF_VARS_4M.fd"
  OVMF_DIR="$BATS_TMPDIR/ovmf" run virt_install_args
  [[ "$output" == *"backend.version=2.0"* ]]
  [[ "$output" == *"loader.secure=yes"* ]]
  [[ "$output" == *"bus=virtio"* ]]
  [[ "$output" == *"--graphics"* ]]
  [[ "$output" == *"spice"* ]]
  [[ "$output" == *"${WIN_ISO}"* ]]
  [[ "$output" == *"${VIRTIO_ISO}"* ]]
}

@test "virt_install_args wires the qemu-guest-agent channel (freeze/thaw for ZFS snapshots)" {
  # The golden snapshot is VSS-quiesced via `virsh domfsfreeze`, which needs the
  # guest agent. A fresh build must include the virtio-serial channel so the live
  # box matches what 90-snapshot.sh assumes.
  mkdir -p "$BATS_TMPDIR/ovmf"
  touch "$BATS_TMPDIR/ovmf/OVMF_CODE_4M.secboot.fd" "$BATS_TMPDIR/ovmf/OVMF_VARS_4M.fd"
  OVMF_DIR="$BATS_TMPDIR/ovmf" run virt_install_args
  printf '%s\n' "$output" | grep -qx -- '--channel'
  [[ "$output" == *"target.name=org.qemu.guest_agent.0"* ]]
}

@test "virt_install_args specifies an install method and a bootable order" {
  # Regression: virt-install rejects args with no install method
  # (--cdrom/--location/--pxe/--import/--boot <dev>). A firmware-only --boot
  # loader=... is NOT an install method. Guard that one is always present.
  mkdir -p "$BATS_TMPDIR/ovmf"
  touch "$BATS_TMPDIR/ovmf/OVMF_CODE_4M.secboot.fd" "$BATS_TMPDIR/ovmf/OVMF_VARS_4M.fd"
  OVMF_DIR="$BATS_TMPDIR/ovmf" run virt_install_args
  # --import is emitted as its own token (own line)
  printf '%s\n' "$output" | grep -qx -- '--import'
  # the Win11 installer CD boots first, the OS disk is in the boot chain
  [[ "$output" == *"path=${WIN_ISO},device=cdrom,boot.order=1"* ]]
  [[ "$output" == *"format=qcow2,bus=virtio,boot.order=3"* ]]
}

@test "virt_install_args emits one token per line (flag and value never share an element)" {
  mkdir -p "$BATS_TMPDIR/ovmf"
  touch "$BATS_TMPDIR/ovmf/OVMF_CODE_4M.secboot.fd" "$BATS_TMPDIR/ovmf/OVMF_VARS_4M.fd"
  local a
  OVMF_DIR="$BATS_TMPDIR/ovmf"
  mapfile -t a < <(virt_install_args)
  printf '%s\n' "${a[@]}" | grep -qx -- '--memory'
  printf '%s\n' "${a[@]}" | grep -qx -- '--graphics'
  printf '%s\n' "${a[@]}" | grep -qx -- "${RAM_MB}"
  # No element may contain a space (each would otherwise be rejected by virt-install).
  for x in "${a[@]}"; do [[ "$x" != *" "* ]]; done
}
