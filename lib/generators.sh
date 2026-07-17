# shellcheck shell=bash
# Pure generators — read config vars from the environment, print artifacts to stdout.

gen_nft_rules() {
  cat <<EOF
table inet cowork {
  chain forward {
    type filter hook forward priority -10; policy accept;

    ct state established,related accept

    # Resolver must stay reachable (gateway address falls inside the private range below) — keep ABOVE the LAN drop
    ip daddr ${GATEWAY} accept

    # HARD BLOCK: guest -> private LAN (no lateral movement)
    iifname "${BRIDGE}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop

    # Allow DNS to the libvirt resolver and outbound web
    iifname "${BRIDGE}" udp dport 53 accept
    iifname "${BRIDGE}" tcp dport 53 accept
    iifname "${BRIDGE}" tcp dport { 80, 443 } accept

    # Everything else from the guest: drop
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
  cat <<EOF
--name ${VM_NAME}
--osinfo win11
--memory ${RAM_MB}
--vcpus ${VCPUS}
--cpu host-passthrough
--machine q35
--features smm.state=on
--boot loader=${code},loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=${vars}
--tpm backend.type=emulator,backend.version=2.0,model=tpm-crb
--disk path=${DISK_PATH},size=${DISK_GB},format=qcow2,bus=virtio
--disk path=${WIN_ISO},device=cdrom,boot.order=1
--disk path=${VIRTIO_ISO},device=cdrom
--network network=${NET_NAME},model=virtio
--graphics spice
--video qxl
--controller type=usb,model=qemu-xhci
--sound none
--noautoconsole
EOF
}
