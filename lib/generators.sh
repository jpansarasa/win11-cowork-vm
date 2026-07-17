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
