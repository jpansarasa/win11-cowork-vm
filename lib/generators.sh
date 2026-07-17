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
