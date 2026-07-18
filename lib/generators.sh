# shellcheck shell=bash
# Pure generators — read config vars from the environment, print artifacts to stdout.

gen_nft_rules() {
  cat <<EOF
table inet cowork
delete table inet cowork
table inet cowork {
  chain forward {
    type filter hook forward priority -10; policy accept;

    ct state established,related accept

    # HARD BLOCK: all guest IPv6. The guest is IPv4-only by design, so drop every
    # guest-originated v6 packet outright — no v6 lateral movement, no v6 exfil
    # path, and no dependence on knowing the LAN's v6 prefix (a global-unicast
    # neighbour wouldn't be covered by fc00::/7 anyway). Note the dport 80/443
    # accepts below are address-family-agnostic: without this a v6-capable guest
    # could reach a LAN host's v6 address on 443. If v6 egress is ever wanted,
    # allow it explicitly here after observe-then-tighten.
    iifname "${BRIDGE}" meta nfproto ipv6 counter drop

    # HARD BLOCK: guest -> private LAN (no lateral movement). Guest->resolver DNS is destined for the host's own bridge IP and is handled by the INPUT hook (libvirt's own rules), not this forward chain.
    iifname "${BRIDGE}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop

    # Allow forwarded DNS + web egress from the guest bridge
    iifname "${BRIDGE}" udp dport 53 accept
    iifname "${BRIDGE}" tcp dport 53 accept
    iifname "${BRIDGE}" tcp dport { 80, 443 } accept

    # Everything else from the guest: drop
    iifname "${BRIDGE}" counter drop
  }

  chain input {
    type filter hook input priority -10; policy accept;

    # HARD BLOCK: guest -> the HOST itself. Traffic to any of the host's own
    # addresses (its LAN IP, the bridge IP, ...) is delivered via the INPUT hook,
    # not FORWARD, so the forward chain above never sees it. The guest may use
    # ONLY the host's dnsmasq (DNS + DHCP) on the bridge; every other host service
    # (SSH, Webmin, NFS/SMB/ZFS shares, docker, ...) is unreachable from the guest.
    # Drop all guest IPv6 to the host first (v4-only guest — the DNS/DHCP accepts
    # below are family-agnostic, so this keeps the guest off any host v6 service).
    iifname "${BRIDGE}" meta nfproto ipv6 counter drop
    iifname "${BRIDGE}" udp dport { 53, 67 } accept
    iifname "${BRIDGE}" tcp dport 53 accept
    iifname "${BRIDGE}" counter drop
  }
}
EOF
}

gen_net_xml() {
  cat <<EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${GATEWAY}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='log-queries'/>
    <dnsmasq:option value='log-facility=${DNS_LOG}'/>
  </dnsmasq:options>
</network>
EOF
}

gen_sni_unit() {
  cat <<EOF
[Unit]
Description=Cowork VM egress TLS-SNI capture
After=network.target libvirtd.service

[Service]
# Runs as root so it can capture on the bridge without the wireshark group dance.
ExecStart=/usr/bin/tshark -i ${BRIDGE} -l -f 'tcp port 443' -Y 'tls.handshake.type==1' -T fields -e frame.time_epoch -e tls.handshake.extensions_server_name
StandardOutput=append:${SNI_LOG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

gen_logrotate() {
  cat <<EOF
${SNI_LOG} ${DNS_LOG} {
    daily
    rotate ${LOG_RETAIN_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# Guest time-sync: the guest can't reach NTP (UDP 123 is dropped by the cowork
# firewall), so the HOST pushes its own (NTP-correct) time into the guest via
# qemu-guest-agent. No egress hole, host stays the single time authority.
# NOTE: this needs the Windows Time service (w32time) set to Automatic in the
# guest — qemu-ga's guest-set-time only works while w32time is running.
gen_timesync_service() {
  cat <<EOF
[Unit]
Description=Push host time into the Cowork VM via qemu-guest-agent (guest NTP is blocked by design)
After=libvirtd.service
Wants=libvirtd.service

[Service]
Type=oneshot
# Only when the domain is running; set guest UTC to the host's current UTC.
ExecStart=/bin/sh -c 'virsh domstate ${VM_NAME} 2>/dev/null | grep -q "^running\$" && exec virsh domtime ${VM_NAME} --time "\$(date +%%s)" || true'
EOF
}

gen_timesync_timer() {
  cat <<EOF
[Unit]
Description=Periodically sync the Cowork VM clock from the host (guest NTP blocked)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Ordered preference of Ubuntu/Debian secure-boot firmware code files.
detect_ovmf() {
  local dir="${1:-/usr/share/OVMF}" code
  for code in OVMF_CODE_4M.secboot.fd OVMF_CODE.secboot.fd OVMF_CODE_4M.ms.fd; do
    if [ -f "${dir}/${code}" ]; then
      local vars
      for vars in OVMF_VARS_4M.fd OVMF_VARS.fd OVMF_VARS_4M.ms.fd; do
        [ -f "${dir}/${vars}" ] && { echo "${dir}/${code}|${dir}/${vars}"; return 0; }
      done
    fi
  done
  return 1
}

virt_install_args() {
  local pair code vars
  pair="$(detect_ovmf "${OVMF_DIR:-/usr/share/OVMF}")" || die "no OVMF secure-boot firmware found; install the 'ovmf' package"
  code="${pair%%|*}"; vars="${pair##*|}"
  # One token per line: virt-install receives each element as a separate argv
  # slot, so a flag and its value must NOT share a line (values contain no spaces).
  cat <<EOF
--name
${VM_NAME}
--osinfo
win11
--memory
${RAM_MB}
--vcpus
${VCPUS}
--cpu
host-passthrough
--machine
q35
--features
smm.state=on
--boot
loader=${code},loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=${vars}
--tpm
backend.type=emulator,backend.version=2.0,model=tpm-crb
--disk
path=${DISK_PATH},size=${DISK_GB},format=qcow2,bus=virtio,boot.order=3
--disk
path=${WIN_ISO},device=cdrom,boot.order=1
--disk
path=${VIRTIO_ISO},device=cdrom,boot.order=2
--network
network=${NET_NAME},model=virtio
--channel
unix,target.type=virtio,target.name=org.qemu.guest_agent.0
--graphics
spice
--video
qxl
--controller
type=usb,model=qemu-xhci
--sound
none
--import
--noautoconsole
EOF
}
