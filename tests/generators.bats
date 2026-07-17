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
