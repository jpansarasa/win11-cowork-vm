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

@test "gen_nft_rules accepts gateway BEFORE the LAN drop" {
  gen_nft_rules > "$BATS_TMPDIR/rules.nft"
  local gw drop
  gw=$(grep -n "ip daddr ${GATEWAY} accept" "$BATS_TMPDIR/rules.nft" | head -1 | cut -d: -f1)
  drop=$(grep -n '10.0.0.0/8' "$BATS_TMPDIR/rules.nft" | head -1 | cut -d: -f1)
  [ -n "$gw" ] && [ -n "$drop" ] && [ "$gw" -lt "$drop" ]
}

@test "gen_nft_rules allows DNS and web, drops the rest" {
  run gen_nft_rules
  [[ "$output" == *"udp dport 53 accept"* ]]
  [[ "$output" == *"tcp dport 53 accept"* ]]
  [[ "$output" == *"tcp dport { 80, 443 } accept"* ]]
  [[ "$output" == *"iifname \"${BRIDGE}\" counter drop"* ]]
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
