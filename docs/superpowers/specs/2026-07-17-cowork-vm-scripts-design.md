# Design — Script Collateral for the Win11 Cowork VM

**Date:** 2026-07-17
**Status:** Approved (brainstorming)
**Repo:** github.com/jpansarasa/win11-cowork-vm
**Companion doc:** `win11-cowork-vm-buildspec.md` (the human-facing runbook this automates)

## Purpose

Turn the buildspec runbook into idempotent bash collateral that can **build** the isolated Windows 11 / libvirt-KVM host from scratch and, more importantly, **recover** it after a server death — given that the guest qcow2 disk and the libvirt XML definitions are backed up in ZFS.

The scripts automate only the **Linux host scaffolding** (packages, libvirt network, host firewall, VM definition, verification, snapshot/export). The Windows install, Windows 24/7 configuration, Claude Cowork install, and connector logins stay **manual** — documented in the buildspec, never scripted, no secrets in the repo.

## Non-goals

- No Squid egress proxy / allowlist-enforcement subsystem (buildspec §3c and the enforcement half of §3d remain documented-but-manual). We build the nftables LAN-block plus DNS/SNI **observability**, not proxy enforcement.
- No RHEL/Fedora support. Ubuntu/Debian (`apt`) only. The buildspec keeps the RHEL notes as prose.
- No Windows-side automation (OOBE, autologon, Cowork launch). Host-side only.
- No config-management framework (Ansible/Puppet/Chef) and no Terraform. See "Tooling decision" below.

## Tooling decision (why bash)

Single host, built rarely, frozen by a snapshot — this is not a fleet-convergence problem. The decisive constraint is the **recovery base**: the fewer things that must be installed and correct on a fresh box before recovery can run, the better. `bash` + `libvirt-clients` + coreutils is the floor and is always present.

- **Chef/Puppet** — built for fleets under continuous convergence; agent/runtime overhead for one frozen box. Rejected.
- **Terraform (libvirt provider)** — owns a `.tfstate` and wants to manage the disk lifecycle, which collides with a qcow2 that arrives pre-made from ZFS (reads as drift / triggers recreate). Rejected for the recovery path specifically.
- **Ansible** — the only real contender. Buys free idempotency on `apt`/`file`/`systemd` and Jinja templating. But the two hard parts have no good native modules: `virt-install` (UEFI+SecureBoot+TPM) becomes `command:` + `creates:`, and nftables becomes `template:` + `command: nft -f` — bash-in-YAML for the 60% that's actually hard, while adding a dependency that must be bootstrapped before recovery. Not worth it today. Revisit if this grows past one host, needs ongoing drift-correction, or the rest of the lab standardizes on Ansible.

## Architecture

Two thin entrypoints over a set of idempotent, numbered stage scripts. The only difference between first-install and disaster-recovery is **which stages run**.

```
config.env              # every tunable; sourced by all scripts
lib/common.sh           # log/warn/die, require_root, need_cmd, confirm, distro guard
scripts/00-preflight.sh # assert vmx/svm + /dev/kvm; apt-install the stack; virt-host-validate
scripts/10-network.sh   # define+start cowork-net WITH dnsmasq query-logging baked in
scripts/20-firewall.sh  # write /etc/nftables.d/cowork.nft, load it, persist across reboot
scripts/30-observe.sh   # on-demand TLS-SNI capture (tshark) — a helper you run, not a service
scripts/40-create-vm.sh # virt-install: UEFI + Secure Boot + TPM 2.0; FIRST BUILD ONLY
scripts/50-verify.sh    # host-side read-only assertions; nonzero exit on any failure
scripts/90-snapshot.sh  # virsh disk snapshot + export domain/net XML to the ZFS path
install.sh              # ordered calls for a fresh build (00→10→20→40→50)
recover.sh              # ordered calls for rebuild-from-ZFS (00→10→20→re-import XML→50)
```

Each stage maps 1:1 to a buildspec section so the doc and the code stay legible together.

### Idempotency rule (the property that makes install == recover)

Every stage is **check-then-act** and safe to re-run:

- `00` — skips packages already installed; aborts hard if virtualization/KVM is absent.
- `10` — skips if `cowork-net` is already defined and active; otherwise defines/starts/autostarts it.
- `20` — (re)loads the `cowork` nft table without duplicating rules (dedicated table is flushed and re-added atomically).
- `40` — refuses to clobber an existing domain of the same name (this is what makes it "first build only" — on a recovered host the domain is re-imported by `recover.sh` instead).

Re-running `install.sh` on a half-built host finishes the job rather than erroring.

## config.env (single source of tunables)

```
VM_NAME=win11-cowork
RAM_MB=16384
VCPUS=4
DISK_GB=100
NET_NAME=cowork-net
BRIDGE=virbr-cowork
SUBNET=10.77.0.0/24
GATEWAY=10.77.0.1
DHCP_START=10.77.0.10
DHCP_END=10.77.0.100
IMAGE_DIR=/var/lib/libvirt/images
DISK_PATH=${IMAGE_DIR}/win11-cowork.qcow2
WIN_ISO=${IMAGE_DIR}/Win11.iso
VIRTIO_ISO=${IMAGE_DIR}/virtio-win.iso
DNS_LOG=/var/log/libvirt/cowork-dns.log
SNI_LOG=/var/log/libvirt/cowork-sni.txt
ZFS_EXPORT_DIR=/var/lib/libvirt/images/cowork-state   # 90 drops XML here; ZFS sweeps it with the qcow2
```

## Stage detail & the gotchas the scripts must encode

### 00-preflight.sh
- Assert `egrep -c '(vmx|svm)' /proc/cpuinfo` > 0 and `/dev/kvm` present; **die** if not (never half-build).
- `apt-get install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virt-viewer ovmf swtpm swtpm-tools nftables` (+ `tshark` for `30`, prompted/optional).
- `systemctl enable --now libvirtd`; run `virt-host-validate` and surface failures.

### 10-network.sh
- Generate the `cowork-net` XML **including** the dnsmasq namespace options (`log-queries`, `log-facility=${DNS_LOG}`) from the start, so DNS observability is on from first boot.
- `virsh net-define / net-start / net-autostart`, guarded by existence checks. On change, `net-destroy && net-start` to apply (documented: brief guest network blip).

### 20-firewall.sh (two encoded gotchas)
- Emit `/etc/nftables.d/cowork.nft` with a **dedicated `inet cowork` table**, `forward` hook at priority `-10` (independent of libvirt's own chains).
- **DNS-survival ordering:** an explicit `ip daddr ${GATEWAY} accept` placed **above** the LAN-drop set, because `${GATEWAY}` (10.77.0.1) lives inside `10.0.0.0/8` and would otherwise be caught by the lateral-movement drop. This makes future tightening safe by construction.
- Rule order: established/related accept → gateway accept → **drop guest→{10/8,172.16/12,192.168/16,169.254/16}** → accept DNS 53 udp/tcp → accept tcp 80/443 → drop everything else from the bridge.
- **Persist across reboot:** ensure `/etc/nftables.conf` contains `include "/etc/nftables.d/cowork.nft"` and `systemctl enable nftables`. Rules match `iifname "virbr-cowork"` by name, so they load cleanly even before libvirt brings the bridge up.

### 30-observe.sh
- On-demand helper (not a service): runs `tshark -i ${BRIDGE} -f 'tcp port 443' -Y 'tls.handshake.type==1' -T fields -e tls.handshake.extensions_server_name`, de-dupes to `${SNI_LOG}`. Catches destinations that resolve via hardcoded IP/DoH and never hit dnsmasq. You run it for a while when you want to see egress; Ctrl-C to stop.

### 40-create-vm.sh (first build only)
- Detect the Ubuntu OVMF secure-boot firmware path at runtime (`OVMF_CODE_4M.secboot.fd` vs `OVMF_CODE.secboot.fd`, etc.) rather than hardcoding.
- `virt-install` with `--boot uefi` (fallback to explicit `loader=...secboot...` + `--features smm.state=on`), `--tpm backend.type=emulator,backend.version=2.0,model=tpm-crb`, virtio disk/NIC, both ISOs mounted, `--graphics spice` (never RDP — the console session is where Cowork and its scheduled tasks must live), `--noautoconsole`.
- Guard: refuse if a domain named `${VM_NAME}` already exists.

### 50-verify.sh (host-side test suite)
Read-only assertions, nonzero exit listing failures:
- `cowork-net` defined + active + autostart.
- nft `cowork` table loaded; LAN-drop rule present (and ideally its counter exists).
- domain `${VM_NAME}` defined; its XML contains TPM 2.0, Secure Boot / `smm`, and UEFI loader.
- `${DNS_LOG}` path writable.
- **Documented manual guest-side checklist** (cannot run from host): from Windows, a known LAN host is unreachable (`Test-NetConnection`), the internet works, `Get-Tpm` / `Confirm-SecureBootUEFI` both good, Cowork launches in the console session after reboot, a test scheduled run produces drafts/reports only.

### 90-snapshot.sh
- `virsh snapshot-create-as ${VM_NAME} clean-authed ...` for the clean, authed disk state.
- Export `virsh dumpxml ${VM_NAME}` and `virsh net-dumpxml ${NET_NAME}` into `${ZFS_EXPORT_DIR}` so the XML rides to ZFS alongside the qcow2 — this is precisely what `recover.sh` re-imports.

## Recovery flow (concrete)

`recover.sh` assumes ZFS has already restored the qcow2 to `${DISK_PATH}` and the exported XML to `${ZFS_EXPORT_DIR}`. It:

1. `00-preflight.sh` — reinstall host packages, enable libvirtd.
2. `10-network.sh` + `20-firewall.sh` — rebuild network and firewall.
3. Re-import definitions: `virsh net-define` the saved net XML (fallback: regenerate via `10` if the export is missing), `virsh define` the saved domain XML.
4. Confirm `${DISK_PATH}` exists (the restored disk); **abort with a clear message if not** — recovery cannot proceed without it.
5. `virsh start ${VM_NAME}`.
6. `50-verify.sh`.

No Windows reinstall, no re-auth — that state rode in on the disk image.

## Error handling

- Every script: `set -euo pipefail`; `require_root` where mutating host state; `lib/common.sh` provides `log/warn/die`, `need_cmd`, `confirm`.
- Preflight aborts on missing virtualization/KVM — the one place a hard stop matters most.
- Destructive-ish actions (`net-destroy` to re-apply, snapshot) print what they will do; `install.sh`/`recover.sh` run stages in order and stop on first failure.

## Testing / lint

- `50-verify.sh` is the executable check of a good host-side build.
- `shellcheck` over all scripts as the lint pass (documented one-liner; optional `make lint`).
- Manual guest-side checklist lives in buildspec §9 (unchanged).

## Deliverables

- The scripts, `config.env`, `lib/common.sh`, `install.sh`, `recover.sh` as laid out above.
- README updated with a "Scripts" section: what `install.sh` vs `recover.sh` do, the manual steps that sit between them, and the ZFS assumption for recovery.
- Buildspec cross-references the scripts at the relevant sections (the manual steps stay authoritative there).
