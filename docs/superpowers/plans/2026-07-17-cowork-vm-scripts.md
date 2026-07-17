# Win11 Cowork VM Script Collateral — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build idempotent bash collateral that stands up and recovers the isolated Windows 11 / libvirt-KVM host that runs Claude Cowork.

**Architecture:** Two thin entrypoints (`install.sh`, `recover.sh`) call numbered, idempotent stage scripts. All host-config artifacts (nftables rules, libvirt network XML, the SNI systemd unit, logrotate config, virt-install args) are produced by **pure generator functions** in `lib/generators.sh` so they can be unit-tested without a live host; the stage scripts are thin wrappers that apply those artifacts. Automates the Linux host only — Windows OOBE and connector logins stay manual.

**Tech Stack:** Bash (`set -euo pipefail`), libvirt/virsh, virt-install, nftables, dnsmasq (via libvirt), tshark, systemd, logrotate. Tests: `bats`. Lint: `shellcheck`. Targets Ubuntu/Debian (`apt`) only.

## Global Constraints

- **Distro:** Ubuntu/Debian only. Package manager is `apt-get`. No RHEL/dnf paths.
- **Idempotency:** every stage is check-then-act and safe to re-run. Re-running finishes a half-built host; it never errors on "already exists" and never duplicates rules/lines.
- **Security invariant (load-bearing):** the nftables `forward` rules MUST drop guest→`{10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16}`, and MUST place `ip daddr ${GATEWAY} accept` **above** that drop (the resolver 10.77.0.1 lives inside 10.0.0.0/8). Dedicated `inet cowork` table, `forward` hook priority `-10`.
- **Console:** VM uses SPICE graphics, never RDP.
- **Windows 11 firmware:** UEFI + Secure Boot + emulated TPM 2.0 are required; detect the OVMF secure-boot firmware path at runtime, never hardcode.
- **No secrets in the repo.** Connector logins and Windows setup are out of scope.
- **Config lives in one place:** `config.env`, sourced by every script. Exact defaults: `VM_NAME=win11-cowork`, `RAM_MB=16384`, `VCPUS=4`, `DISK_GB=100`, `NET_NAME=cowork-net`, `BRIDGE=virbr-cowork`, `SUBNET=10.77.0.0/24`, `NETMASK=255.255.255.0`, `GATEWAY=10.77.0.1`, `DHCP_START=10.77.0.10`, `DHCP_END=10.77.0.100`, `IMAGE_DIR=/var/lib/libvirt/images`, `DISK_PATH=${IMAGE_DIR}/win11-cowork.qcow2`, `WIN_ISO=${IMAGE_DIR}/Win11.iso`, `VIRTIO_ISO=${IMAGE_DIR}/virtio-win.iso`, `DNS_LOG=/var/log/libvirt/cowork-dns.log`, `SNI_LOG=/var/log/libvirt/cowork-sni.log`, `LOG_RETAIN_DAYS=14`, `ZFS_EXPORT_DIR=/var/lib/libvirt/images/cowork-state`, `HOST_ADDR=you@your-host`.
- **Host reachability is out of scope for automation.** The operator drives the guest console with `virt-viewer --connect qemu+ssh://${HOST_ADDR}/system ${VM_NAME}`, which tunnels SPICE over the operator's **existing** SSH access to the host. No avahi/mDNS, no DNS records, no SPICE ports exposed, no new firewall rule (reuses the SSH path already open). `HOST_ADDR` exists only to print a copy-pasteable connect string.
- **Stage order:** install = `00→10→20→30→40→50`; recover = `00→10→20→30→(re-import XML + reattach disk)→50`. `90-snapshot.sh` is run manually after a clean auth.

---

## File Structure

```
config.env                       # all tunables (sourced)
lib/common.sh                    # log/warn/die, need_cmd, require_root, confirm, cpu_has_virt, repo-root resolution
lib/generators.sh                # PURE functions: gen_nft_rules, gen_net_xml, gen_sni_unit, gen_logrotate, detect_ovmf, virt_install_args
scripts/00-preflight.sh          # virt/kvm asserts + apt install + enable libvirtd
scripts/10-network.sh            # define+start cowork-net (idempotent) from gen_net_xml
scripts/20-firewall.sh           # write/load nft from gen_nft_rules; persist include (idempotent)
scripts/30-observe.sh            # install SNI unit + logrotate from generators; enable service
scripts/40-create-vm.sh          # virt-install from virt_install_args; guard if domain exists
scripts/50-verify.sh             # host-side read-only assertions
scripts/90-snapshot.sh           # virsh snapshot + export domain/net XML to ZFS_EXPORT_DIR
install.sh                       # fresh-build orchestrator
recover.sh                       # rebuild-from-ZFS orchestrator
Makefile                         # `make lint` (shellcheck), `make test` (bats)
tests/test_helper.bash           # sources libs, sets up PATH mocks
tests/mocks/                     # stub virsh/nft/systemctl/apt-get for wrapper tests
tests/generators.bats            # unit tests for lib/generators.sh (incl. nft ordering)
tests/common.bats                # unit tests for lib/common.sh
tests/wrappers.bats              # idempotency/guard tests for stage scripts via mocks
```

---

### Task 1: Scaffolding — config, common lib, test harness

**Files:**
- Create: `config.env`, `lib/common.sh`, `Makefile`, `tests/test_helper.bash`, `tests/common.bats`
- Create: `tests/mocks/.keep`

**Interfaces:**
- Produces: `config.env` (all Global-Constraints vars). `lib/common.sh` exporting `REPO_ROOT`, and functions `log(msg)`, `warn(msg)`, `die(msg)` (prints to stderr, exits 1), `need_cmd(cmd)` (die if absent), `require_root()` (die unless EUID 0), `confirm(prompt)` (return 0 on y/Y), `cpu_has_virt(text)` (return 0 if `text` contains `vmx` or `svm`).

- [ ] **Step 1: Write the failing test**

`tests/common.bats`:
```bash
setup() { load "test_helper"; }

@test "cpu_has_virt detects vmx" {
  run cpu_has_virt "flags: fpu vme vmx lm"
  [ "$status" -eq 0 ]
}

@test "cpu_has_virt detects svm" {
  run cpu_has_virt "flags: fpu svm lm"
  [ "$status" -eq 0 ]
}

@test "cpu_has_virt fails when absent" {
  run cpu_has_virt "flags: fpu vme lm"
  [ "$status" -ne 0 ]
}

@test "need_cmd dies on missing command" {
  run need_cmd definitely-not-a-real-binary-xyz
  [ "$status" -ne 0 ]
}
```

`tests/test_helper.bash`:
```bash
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PATH="${REPO_ROOT}/tests/mocks:${PATH}"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/config.env"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `lib/common.sh` does not exist / functions undefined.

- [ ] **Step 3: Write minimal implementation**

`config.env`:
```bash
# Single source of tunables for the Cowork VM host scaffolding.
VM_NAME=win11-cowork
RAM_MB=16384
VCPUS=4
DISK_GB=100
NET_NAME=cowork-net
BRIDGE=virbr-cowork
SUBNET=10.77.0.0/24
NETMASK=255.255.255.0
GATEWAY=10.77.0.1
DHCP_START=10.77.0.10
DHCP_END=10.77.0.100
IMAGE_DIR=/var/lib/libvirt/images
DISK_PATH=${IMAGE_DIR}/win11-cowork.qcow2
WIN_ISO=${IMAGE_DIR}/Win11.iso
VIRTIO_ISO=${IMAGE_DIR}/virtio-win.iso
DNS_LOG=/var/log/libvirt/cowork-dns.log
SNI_LOG=/var/log/libvirt/cowork-sni.log
LOG_RETAIN_DAYS=14
ZFS_EXPORT_DIR=${IMAGE_DIR}/cowork-state
# Address you already SSH to for this host — only used to print the virt-viewer connect string.
HOST_ADDR=you@your-host
```

`lib/common.sh`:
```bash
# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log()  { printf '[cowork] %s\n' "$*"; }
warn() { printf '[cowork] WARN: %s\n' "$*" >&2; }
die()  { printf '[cowork] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"; }
confirm() { local a; read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
cpu_has_virt() { printf '%s' "$1" | grep -Eq '(vmx|svm)'; }

load_config() { source "${REPO_ROOT}/config.env"; }
```

`Makefile`:
```make
SHELL := /bin/bash
SCRIPTS := $(wildcard scripts/*.sh) install.sh recover.sh lib/common.sh lib/generators.sh

.PHONY: lint test
lint:
	shellcheck -x $(SCRIPTS)
test:
	bats tests/
```

`tests/mocks/.keep`: empty file.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add config.env lib/common.sh Makefile tests/
git commit -m "feat: scaffolding — config.env, common lib, bats harness"
```

---

### Task 2: nftables rule generator (security-critical)

**Files:**
- Create: `lib/generators.sh`
- Test: `tests/generators.bats`

**Interfaces:**
- Consumes: `BRIDGE`, `GATEWAY` from config.
- Produces: `gen_nft_rules()` — prints the full `table inet cowork { ... }` to stdout.

- [ ] **Step 1: Write the failing test**

`tests/generators.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/generators.bats`
Expected: FAIL — `gen_nft_rules` undefined.

- [ ] **Step 3: Write minimal implementation**

`lib/generators.sh`:
```bash
# shellcheck shell=bash
# Pure generators — read config vars from the environment, print artifacts to stdout.

gen_nft_rules() {
  cat <<EOF
table inet cowork {
  chain forward {
    type filter hook forward priority -10; policy accept;

    ct state established,related accept

    # Resolver must stay reachable (10.77.0.1 is inside 10.0.0.0/8) — keep ABOVE the LAN drop
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/generators.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/generators.sh tests/generators.bats
git commit -m "feat: nftables rule generator with LAN-block and DNS-survival ordering"
```

---

### Task 3: libvirt network XML generator

**Files:**
- Modify: `lib/generators.sh`
- Test: `tests/generators.bats`

**Interfaces:**
- Consumes: `NET_NAME`, `BRIDGE`, `GATEWAY`, `NETMASK`, `DHCP_START`, `DHCP_END`, `DNS_LOG`.
- Produces: `gen_net_xml()` — prints the `cowork-net` network XML including dnsmasq query-logging options.

- [ ] **Step 1: Write the failing test**

Append to `tests/generators.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/generators.bats`
Expected: FAIL — `gen_net_xml` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/generators.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/generators.bats`
Expected: PASS (all generator tests).

- [ ] **Step 5: Commit**

```bash
git add lib/generators.sh tests/generators.bats
git commit -m "feat: libvirt network XML generator with dnsmasq query logging"
```

---

### Task 4: SNI service + logrotate generators

**Files:**
- Modify: `lib/generators.sh`
- Test: `tests/generators.bats`

**Interfaces:**
- Consumes: `BRIDGE`, `SNI_LOG`, `DNS_LOG`, `LOG_RETAIN_DAYS`.
- Produces: `gen_sni_unit()` — prints the `cowork-sni.service` systemd unit. `gen_logrotate()` — prints the logrotate stanza covering both logs.

- [ ] **Step 1: Write the failing test**

Append to `tests/generators.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/generators.bats`
Expected: FAIL — `gen_sni_unit` / `gen_logrotate` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/generators.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/generators.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/generators.sh tests/generators.bats
git commit -m "feat: SNI capture unit and logrotate generators"
```

---

### Task 5: OVMF detection + virt-install argument builder

**Files:**
- Modify: `lib/generators.sh`
- Test: `tests/generators.bats`

**Interfaces:**
- Consumes: `VM_NAME`, `RAM_MB`, `VCPUS`, `DISK_PATH`, `DISK_GB`, `WIN_ISO`, `VIRTIO_ISO`, `NET_NAME`.
- Produces: `detect_ovmf(search_dir)` — echoes `CODE_PATH|VARS_PATH` for the first secure-boot firmware found (default dir `/usr/share/OVMF`), returns 1 if none. `virt_install_args()` — prints the virt-install args, one per line (TPM 2.0, Secure Boot, virtio, SPICE, both ISOs).

- [ ] **Step 1: Write the failing test**

Append to `tests/generators.bats`:
```bash
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
  [[ "$output" == *"--graphics spice"* ]]
  [[ "$output" == *"${WIN_ISO}"* ]]
  [[ "$output" == *"${VIRTIO_ISO}"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/generators.bats`
Expected: FAIL — `detect_ovmf` / `virt_install_args` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/generators.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/generators.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/generators.sh tests/generators.bats
git commit -m "feat: OVMF detection and virt-install argument builder"
```

---

### Task 6: 00-preflight.sh

**Files:**
- Create: `scripts/00-preflight.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: `cpu_has_virt`, `need_cmd`, `die` from common.
- Produces: `preflight_check_virt()` — reads `/proc/cpuinfo` (or `$CPUINFO_FILE` if set) and `/dev/kvm`, dies if virtualization/KVM absent. The script also installs packages and enables libvirtd.

- [ ] **Step 1: Write the failing test**

`tests/wrappers.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/00-preflight.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

`scripts/00-preflight.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
load_config

PACKAGES=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
          virtinst virt-viewer ovmf swtpm swtpm-tools nftables tshark)

preflight_check_virt() {
  local cpuinfo="${CPUINFO_FILE:-/proc/cpuinfo}" kvm="${KVM_DEV:-/dev/kvm}"
  cpu_has_virt "$(cat "$cpuinfo")" || die "no CPU virtualization (vmx/svm) present"
  [ -e "$kvm" ] || die "KVM device $kvm missing — is virtualization enabled in BIOS?"
}

install_packages() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  # Preseed wireshark-common so tshark installs without the dumpcap prompt.
  echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
  apt-get update
  apt-get install -y "${PACKAGES[@]}"
  systemctl enable --now libvirtd
  virt-host-validate qemu || warn "virt-host-validate reported issues (review above)"
}

# Only run side effects when executed directly, not when sourced by tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  preflight_check_virt
  install_packages
  log "preflight complete"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/00-preflight.sh tests/wrappers.bats
git commit -m "feat: 00-preflight — virtualization/KVM checks and package install"
```

---

### Task 7: 10-network.sh (idempotent)

**Files:**
- Create: `scripts/10-network.sh`, `tests/mocks/virsh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: `gen_net_xml`, `need_cmd`, `log`.
- Produces: `apply_network()` — defines/starts/autostarts `${NET_NAME}` from `gen_net_xml`; if it already exists, refreshes its definition (destroy+start) without erroring.

- [ ] **Step 1: Write the failing test**

Create `tests/mocks/virsh` (shared stub; records args, simulates existence via `$VIRSH_NET_EXISTS`):
```bash
#!/usr/bin/env bash
echo "virsh $*" >> "${MOCKLOG:-/dev/null}"
case "$1" in
  net-info)   [ "${VIRSH_NET_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;
  dominfo)    [ "${VIRSH_DOM_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;
  net-dumpxml)  echo "<network><name>$2</name></network>" ;;
  dumpxml)      echo "<domain><name>$2</name></domain>" ;;
  *) : ;;
esac
exit 0
```
Make it executable: `chmod +x tests/mocks/virsh`.

Append to `tests/wrappers.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/10-network.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/10-network.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
source "${HERE}/../lib/generators.sh"
load_config

apply_network() {
  need_cmd virsh
  local tmp; tmp="$(mktemp)"; gen_net_xml > "$tmp"
  if virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
    log "network ${NET_NAME} exists — refreshing definition"
    virsh net-define "$tmp"
    virsh net-destroy "${NET_NAME}" >/dev/null 2>&1 || true
    virsh net-start "${NET_NAME}"
  else
    log "defining network ${NET_NAME}"
    virsh net-define "$tmp"
    virsh net-start "${NET_NAME}"
  fi
  virsh net-autostart "${NET_NAME}"
  rm -f "$tmp"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then apply_network; log "network ready"; fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/10-network.sh tests/mocks/virsh tests/wrappers.bats
git commit -m "feat: 10-network — idempotent cowork-net definition"
```

---

### Task 8: 20-firewall.sh (idempotent persist)

**Files:**
- Create: `scripts/20-firewall.sh`, `tests/mocks/nft`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: `gen_nft_rules`.
- Produces: `ensure_include(conf_file, include_line)` — appends `include_line` to `conf_file` only if absent (idempotent). `apply_firewall(nft_dir, conf_file)` — writes `${nft_dir}/cowork.nft`, loads it, ensures the include in `conf_file`.

- [ ] **Step 1: Write the failing test**

Create `tests/mocks/nft`:
```bash
#!/usr/bin/env bash
echo "nft $*" >> "${MOCKLOG:-/dev/null}"
exit 0
```
`chmod +x tests/mocks/nft`.

Append to `tests/wrappers.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/20-firewall.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/20-firewall.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
source "${HERE}/../lib/generators.sh"
load_config

ensure_include() {
  local conf="$1" line="$2"
  grep -qF "$line" "$conf" 2>/dev/null || printf '%s\n' "$line" >> "$conf"
}

apply_firewall() {
  local nft_dir="${1:-/etc/nftables.d}" conf="${2:-/etc/nftables.conf}"
  need_cmd nft
  mkdir -p "$nft_dir"
  gen_nft_rules > "${nft_dir}/cowork.nft"
  nft -f "${nft_dir}/cowork.nft"
  ensure_include "$conf" "include \"${nft_dir}/cowork.nft\""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  apply_firewall
  systemctl enable nftables
  log "firewall applied and persisted"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/20-firewall.sh tests/mocks/nft tests/wrappers.bats
git commit -m "feat: 20-firewall — idempotent nft rules with persistent include"
```

---

### Task 9: 30-observe.sh

**Files:**
- Create: `scripts/30-observe.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: `gen_sni_unit`, `gen_logrotate`.
- Produces: `install_observability(unit_path, logrotate_path)` — writes the systemd unit and logrotate config from the generators (defaults `/etc/systemd/system/cowork-sni.service`, `/etc/logrotate.d/cowork`).

- [ ] **Step 1: Write the failing test**

Append to `tests/wrappers.bats`:
```bash
@test "install_observability writes unit and logrotate files" {
  unit="$BATS_TMPDIR/cowork-sni.service"; lr="$BATS_TMPDIR/cowork.logrotate"
  run bash -c 'source lib/common.sh; source lib/generators.sh; source scripts/30-observe.sh;
           install_observability "'"$unit"'" "'"$lr"'"'
  [ "$status" -eq 0 ]
  grep -q "Restart=always" "$unit"
  grep -q "copytruncate" "$lr"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/30-observe.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/30-observe.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
source "${HERE}/../lib/generators.sh"
load_config

install_observability() {
  local unit="${1:-/etc/systemd/system/cowork-sni.service}" lr="${2:-/etc/logrotate.d/cowork}"
  gen_sni_unit > "$unit"
  gen_logrotate > "$lr"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  need_cmd tshark
  install_observability
  systemctl daemon-reload
  systemctl enable --now cowork-sni.service
  log "SNI capture service + logrotate installed"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/30-observe.sh tests/wrappers.bats
git commit -m "feat: 30-observe — persistent SNI capture service and logrotate"
```

---

### Task 10: 40-create-vm.sh (guarded)

**Files:**
- Create: `scripts/40-create-vm.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: `virt_install_args` (via `mapfile`), mock `virsh` for the existence guard.
- Produces: `create_vm()` — refuses (returns non-zero, no virt-install) if a domain named `${VM_NAME}` already exists; otherwise runs `virt-install` with the generated args.

- [ ] **Step 1: Write the failing test**

Create `tests/mocks/virt-install`:
```bash
#!/usr/bin/env bash
echo "virt-install $*" >> "${MOCKLOG:-/dev/null}"
exit 0
```
`chmod +x tests/mocks/virt-install`.

Append to `tests/wrappers.bats`:
```bash
@test "create_vm refuses when domain already exists" {
  VIRSH_DOM_EXISTS=1 OVMF_DIR="$BATS_TMPDIR/ovmf" run bash -c \
    'mkdir -p "$OVMF_DIR"; touch "$OVMF_DIR/OVMF_CODE_4M.secboot.fd" "$OVMF_DIR/OVMF_VARS_4M.fd";
     source lib/common.sh; source lib/generators.sh; source scripts/40-create-vm.sh; create_vm'
  [ "$status" -ne 0 ]
  ! grep -q "virt-install" "$MOCKLOG"
}

@test "create_vm runs virt-install when domain absent" {
  VIRSH_DOM_EXISTS=0 OVMF_DIR="$BATS_TMPDIR/ovmf" run bash -c \
    'mkdir -p "$OVMF_DIR"; touch "$OVMF_DIR/OVMF_CODE_4M.secboot.fd" "$OVMF_DIR/OVMF_VARS_4M.fd";
     source lib/common.sh; source lib/generators.sh; source scripts/40-create-vm.sh; create_vm'
  [ "$status" -eq 0 ]
  grep -q "virt-install" "$MOCKLOG"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/40-create-vm.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/40-create-vm.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
source "${HERE}/../lib/generators.sh"
load_config

create_vm() {
  need_cmd virt-install
  if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    warn "domain ${VM_NAME} already exists — refusing to recreate (use recover.sh to re-import)"
    return 1
  fi
  local args; mapfile -t args < <(virt_install_args)
  virt-install "${args[@]}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then create_vm && log "VM created — attach with: virt-viewer --connect qemu:///system ${VM_NAME}"; fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/40-create-vm.sh tests/mocks/virt-install tests/wrappers.bats
git commit -m "feat: 40-create-vm — guarded virt-install"
```

---

### Task 11: 50-verify.sh

**Files:**
- Create: `scripts/50-verify.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: mock `virsh`, mock `nft`, mock `systemctl`.
- Produces: `verify_all()` — runs each host-side assertion, prints PASS/FAIL per check, returns non-zero if any failed. Checks: net active, nft `cowork` table present, domain defined with TPM/secure-boot, `cowork-sni.service` active, log paths writable.

- [ ] **Step 1: Write the failing test**

Create `tests/mocks/systemctl`:
```bash
#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCKLOG:-/dev/null}"
# is-active returns based on $SYSTEMCTL_ACTIVE (default active)
[ "$1" = "is-active" ] && { [ "${SYSTEMCTL_ACTIVE:-1}" = "1" ] && { echo active; exit 0; } || { echo inactive; exit 3; }; }
exit 0
```
`chmod +x tests/mocks/systemctl`. Extend `tests/mocks/nft` to answer `list table`:
```bash
#!/usr/bin/env bash
echo "nft $*" >> "${MOCKLOG:-/dev/null}"
if [ "$1" = "list" ] && [ "$2" = "table" ]; then
  [ "${NFT_TABLE_EXISTS:-1}" = "1" ] && exit 0 || exit 1
fi
exit 0
```
Extend the `virsh` mock `dumpxml` branch to include TPM + secure-boot markers so the verify check can match:
```bash
  dumpxml) echo "<domain><name>$2</name><tpm model='tpm-crb'><backend version='2.0'/></tpm><loader secure='yes'/></domain>" ;;
```

Append to `tests/wrappers.bats`:
```bash
@test "verify_all passes when everything is healthy" {
  VIRSH_NET_EXISTS=1 VIRSH_DOM_EXISTS=1 NFT_TABLE_EXISTS=1 SYSTEMCTL_ACTIVE=1 \
  DNS_LOG="$BATS_TMPDIR/dns.log" SNI_LOG="$BATS_TMPDIR/sni.log" \
  run bash -c 'source lib/common.sh; load_config;
    DNS_LOG="'"$BATS_TMPDIR"'/dns.log"; SNI_LOG="'"$BATS_TMPDIR"'/sni.log";
    source scripts/50-verify.sh; verify_all'
  [ "$status" -eq 0 ]
}

@test "verify_all fails when the nft table is missing" {
  VIRSH_NET_EXISTS=1 VIRSH_DOM_EXISTS=1 NFT_TABLE_EXISTS=0 SYSTEMCTL_ACTIVE=1 \
  run bash -c 'source lib/common.sh; load_config;
    DNS_LOG="'"$BATS_TMPDIR"'/dns.log"; SNI_LOG="'"$BATS_TMPDIR"'/sni.log";
    source scripts/50-verify.sh; verify_all'
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/50-verify.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/50-verify.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
load_config

_fails=0
_check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$name"
  else printf 'FAIL  %s\n' "$name"; _fails=$((_fails+1)); fi
}

verify_all() {
  _fails=0
  _check "network ${NET_NAME} active"     virsh net-info "${NET_NAME}"
  _check "nft cowork table loaded"        nft list table inet cowork
  _check "domain ${VM_NAME} defined"      virsh dominfo "${VM_NAME}"
  _check "domain has TPM 2.0"             bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"version='2.0'\""
  _check "domain has secure boot"         bash -c "virsh dumpxml '${VM_NAME}' | grep -q \"secure='yes'\""
  _check "cowork-sni.service active"      systemctl is-active cowork-sni.service
  _check "DNS_LOG dir writable"           bash -c "touch '${DNS_LOG}' 2>/dev/null || [ -w \"\$(dirname '${DNS_LOG}')\" ]"
  _check "SNI_LOG dir writable"           bash -c "touch '${SNI_LOG}' 2>/dev/null || [ -w \"\$(dirname '${SNI_LOG}')\" ]"
  [ "$_fails" -eq 0 ] || return 1
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  verify_all
  rc=$?
  echo
  echo "Manual guest-side checks (run inside Windows):"
  echo "  - Test-NetConnection <a LAN host IP>  -> should FAIL (unreachable)"
  echo "  - internet reachable; Get-Tpm / Confirm-SecureBootUEFI -> True"
  echo "  - Cowork launches in the console session after reboot; scheduled run yields drafts only"
  exit $rc
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/50-verify.sh tests/mocks/systemctl tests/mocks/nft tests/mocks/virsh tests/wrappers.bats
git commit -m "feat: 50-verify — host-side assertions with manual guest checklist"
```

---

### Task 12: 90-snapshot.sh

**Files:**
- Create: `scripts/90-snapshot.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: mock `virsh`.
- Produces: `export_definitions(dest_dir)` — writes `virsh net-dumpxml ${NET_NAME}` and `virsh dumpxml ${VM_NAME}` into `dest_dir` (for ZFS to sweep). `snapshot_vm()` — creates the `clean-authed` disk snapshot.

- [ ] **Step 1: Write the failing test**

Append to `tests/wrappers.bats`:
```bash
@test "export_definitions writes both XML files to dest" {
  dest="$BATS_TMPDIR/state"
  run bash -c 'source lib/common.sh; load_config; source scripts/90-snapshot.sh; export_definitions "'"$dest"'"'
  [ "$status" -eq 0 ]
  [ -s "$dest/${NET_NAME}.net.xml" ] || [ -s "$dest/cowork-net.net.xml" ]
  [ -s "$dest/${VM_NAME}.domain.xml" ] || [ -s "$dest/win11-cowork.domain.xml" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `scripts/90-snapshot.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`scripts/90-snapshot.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../lib/common.sh"
load_config

export_definitions() {
  local dest="${1:-$ZFS_EXPORT_DIR}"
  need_cmd virsh
  mkdir -p "$dest"
  virsh net-dumpxml "${NET_NAME}" > "${dest}/${NET_NAME}.net.xml"
  virsh dumpxml "${VM_NAME}"      > "${dest}/${VM_NAME}.domain.xml"
  log "exported net + domain XML to ${dest}"
}

snapshot_vm() {
  need_cmd virsh
  virsh snapshot-create-as "${VM_NAME}" clean-authed "post-setup, connectors authed" --disk-only --atomic
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  export_definitions
  snapshot_vm
  log "snapshot + export complete — ensure ${ZFS_EXPORT_DIR} and the qcow2 are in the ZFS dataset"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/90-snapshot.sh tests/wrappers.bats
git commit -m "feat: 90-snapshot — disk snapshot and XML export for ZFS"
```

---

### Task 13: install.sh + recover.sh orchestrators

**Files:**
- Create: `install.sh`, `recover.sh`
- Test: `tests/wrappers.bats`

**Interfaces:**
- Consumes: all stage scripts; mock `virsh`.
- Produces: `install.sh` runs `00→10→20→30→40→50`. `recover.sh` runs `00→10→20→30`, re-imports XML from `${ZFS_EXPORT_DIR}`, **aborts if `${DISK_PATH}` is missing**, defines the domain, starts it, runs `50`. Expose `recover_check_disk()` for testing the abort guard.

- [ ] **Step 1: Write the failing test**

Append to `tests/wrappers.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/wrappers.bats`
Expected: FAIL — `recover.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib/common.sh"; load_config
require_root
for stage in 00-preflight 10-network 20-firewall 30-observe 40-create-vm 50-verify; do
  log "=== ${stage} ==="
  bash "${HERE}/scripts/${stage}.sh"
done
log "install complete — now do the manual Windows/Cowork/connector steps, then run scripts/90-snapshot.sh"
```

`recover.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib/common.sh"; load_config

recover_check_disk() {
  [ -f "${DISK_PATH}" ] || die "restored disk not found at ${DISK_PATH} — restore it from ZFS before recovering"
}

recover_import() {
  need_cmd virsh
  local net="${ZFS_EXPORT_DIR}/${NET_NAME}.net.xml" dom="${ZFS_EXPORT_DIR}/${VM_NAME}.domain.xml"
  [ -f "$net" ] && virsh net-define "$net" || warn "no exported net XML; network already rebuilt by stage 10"
  [ -f "$dom" ] || die "no exported domain XML at ${dom} — cannot re-import the VM"
  virsh define "$dom"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_root
  for stage in 00-preflight 10-network 20-firewall 30-observe; do
    log "=== ${stage} ==="; bash "${HERE}/scripts/${stage}.sh"
  done
  recover_check_disk
  recover_import
  virsh start "${VM_NAME}" || warn "domain start failed — inspect with virsh dominfo ${VM_NAME}"
  bash "${HERE}/scripts/50-verify.sh"
  log "recovery complete"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/wrappers.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add install.sh recover.sh tests/wrappers.bats
git commit -m "feat: install and recover orchestrators with disk-presence guard"
```

---

### Task 14: README Scripts section + green lint/test gate

**Files:**
- Modify: `README.md`
- Verify: all scripts

**Interfaces:** none (docs + final gate).

- [ ] **Step 1: Make scripts executable and run the full lint + test gate**

Run:
```bash
chmod +x scripts/*.sh install.sh recover.sh tests/mocks/*
make lint
make test
```
Expected: `shellcheck` clean (fix any warnings inline), all `bats` tests PASS.

- [ ] **Step 2: Add a "Scripts" section to README.md**

Insert before the "Disclaimer" section in `README.md`:
```markdown
## Scripts

Idempotent bash collateral automates the **Linux host** side of the buildspec
(the Windows install and connector logins stay manual). Tunables live in
`config.env`.

```bash
sudo ./install.sh     # fresh build: preflight → network → firewall → observe → create VM → verify
# ... do the manual Windows + Cowork + connector steps ...
sudo ./scripts/90-snapshot.sh   # snapshot the clean authed state + export XML for ZFS

sudo ./recover.sh     # after a server death: rebuild host scaffolding, re-import XML,
                      # reattach the ZFS-restored qcow2, verify
```

Recovery assumes ZFS has already restored the qcow2 to `DISK_PATH` and the
exported XML to `ZFS_EXPORT_DIR`. Dev: `make lint` (shellcheck), `make test` (bats).

**Reaching the console from a workstation** (no new services or firewall rules —
it reuses the SSH access you already have to the host; SPICE tunnels inside it):

```bash
virt-viewer --connect qemu+ssh://${HOST_ADDR}/system win11-cowork
```

**Console client (security):** run distro-packaged `virt-viewer` on a Linux
machine (current, CVE-patched spice-gtk/GTK/GStreamer). Avoid the Windows MSI
(11.0, 2021) — its bundled parsing stack is frozen and carries years of
unpatched memory-safety CVEs. SPICE stays bound to the host's loopback and is
reached only through the SSH tunnel.

The guest lives on a host-internal NAT network; it is never visible on the LAN.

Egress visibility is always-on: dnsmasq query logging plus a persistent
`cowork-sni.service` TLS-SNI capture, both rotated over a rolling ~14-day
window (`LOG_RETAIN_DAYS`).
```

- [ ] **Step 3: Verify the docs render and links are correct**

Run: `grep -n "install.sh\|recover.sh\|config.env" README.md`
Expected: the new Scripts section references all three.

- [ ] **Step 4: Commit**

```bash
git add README.md scripts/ install.sh recover.sh tests/
git commit -m "docs: add Scripts section; make collateral executable and green"
```

---

## Self-Review

**Spec coverage:**
- config.env (all tunables) → Task 1 ✓
- lib/common.sh helpers → Task 1 ✓
- 00-preflight (virt checks, apt, libvirtd) → Task 6 ✓
- 10-network (net + dnsmasq logging, idempotent) → Tasks 3 (gen) + 7 (apply) ✓
- 20-firewall (nft table, DNS-survival ordering, persist) → Tasks 2 (gen) + 8 (apply) ✓
- 30-observe (persistent SNI service + logrotate for both logs, in install AND recover) → Tasks 4 (gen) + 9 (apply); wired into both orchestrators in Task 13 ✓
- 40-create-vm (UEFI+SecureBoot+TPM, SPICE, guard) → Tasks 5 (gen) + 10 (apply) ✓
- 50-verify (host-side assertions + manual guest checklist) → Task 11 ✓
- 90-snapshot (disk snapshot + XML export to ZFS) → Task 12 ✓
- install.sh / recover.sh (recover disk-abort, XML re-import) → Task 13 ✓
- Ubuntu/Debian only → apt in Task 6, no dnf anywhere ✓
- README Scripts section → Task 14 ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code. ✓

**Type/name consistency:** function names used across tasks match — `gen_nft_rules`, `gen_net_xml`, `gen_sni_unit`, `gen_logrotate`, `detect_ovmf`, `virt_install_args`, `apply_network`, `apply_firewall`/`ensure_include`, `install_observability`, `create_vm`, `verify_all`, `export_definitions`/`snapshot_vm`, `recover_check_disk`/`recover_import`. The `virsh`/`nft`/`systemctl`/`virt-install` mocks are introduced when first needed and extended (not renamed) in later tasks. ✓
