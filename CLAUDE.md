# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two things that fit together:
1. **`win11-cowork-vm-buildspec.md`** — the human-facing runbook: how to stand up an isolated Windows 11 guest on a Linux libvirt/KVM host to run Claude Cowork under revocable, MFA-gated sessions.
2. **Bash "script collateral"** that automates the **Linux-host side** of that runbook so a rebuild is a rollback, not a re-derivation. This is now a real software project with `make lint` / `make test`.

The scripts automate host scaffolding only. The Windows install, Cowork install, and all connector logins stay **manual** (James does them) — never assume you can drive the Windows OOBE or authenticate connectors.

## Commands

```bash
make lint          # shellcheck -x over all scripts + lib
make test          # run the full bats suite (tests/)
bats tests/generators.bats                          # one file
bats tests/wrappers.bats -f "recover_check_disk"    # one test by name

sudo ./install.sh              # fresh build: 00-preflight → 10-network → 20-firewall → 30-observe → 40-create-vm → 50-verify
sudo ./scripts/90-snapshot.sh  # after manual Windows+Cowork+connector steps: export XML into the dataset, then VSS-quiesce + `zfs snapshot tank/coworkvm@clean-authed`
sudo ./recover.sh              # after a server death: `zfs rollback`/`recv` the dataset to @clean-authed FIRST, then rebuild scaffolding + re-import domain XML + verify
```

Prereqs for the test loop: `bats` and `shellcheck` (`apt install bats shellcheck`). `install.sh` itself apt-installs the VM stack and **mutates the host** — only run it on the real box when ready.

## Architecture (the big picture)

The design that makes bash testable: **separate pure generators from thin host-touching wrappers.**

- **`lib/generators.sh`** — pure functions that read config vars from the environment and print an artifact to stdout: `gen_nft_rules`, `gen_net_xml`, `gen_sni_unit`, `gen_logrotate`, `detect_ovmf`, `virt_install_args`. No side effects → unit-tested directly (`tests/generators.bats`).
- **`scripts/NN-*.sh`** — thin stages that apply a generator's output to the host via `virsh`/`nft`/`systemctl`/`virt-install`. Each exposes a testable function (`apply_network`, `apply_firewall`, `create_vm`, `verify_all`, …) and guards side effects behind `if [ "${BASH_SOURCE[0]}" = "${0}" ]` so tests can source and call the function without touching the host.
- **`install.sh` / `recover.sh`** — the two entrypoints. The ONLY difference is which stages run: install builds a new VM (stage 40); recover skips 40 and instead re-imports the saved domain XML pointing at the ZFS-restored disk. Recover does NOT recreate the disk — you `zfs rollback`/`zfs recv` the dataset back to `@clean-authed` *before* running it (`recover_check_disk` asserts the disk is *present*, not that it's the right vintage). This is the whole recovery story.
- **`config.env`** — the single source of every tunable (VM name, RAM/vCPU/disk, subnet `10.77.0.0/24`, bridge `virbr-cowork`, `LOG_RETAIN_DAYS`, `HOST_ADDR`, and the ZFS layout). The disk and exported XML live **on the ZFS dataset**, not the NVMe libvirt pool: `DISK_PATH=/export/coworkvm/win11-cowork.qcow2`, `ZFS_EXPORT_DIR=/export/coworkvm/state`, `ZFS_DATASET=tank/coworkvm` (mount `/export/coworkvm`). Sourced by everything via `load_config` in `lib/common.sh`.
- **`lib/common.sh`** — `log`/`warn`/`die`, `need_cmd`, `require_root`, `confirm`, `cpu_has_virt`, `load_config`, `REPO_ROOT`.

## Load-bearing constraints (do not violate)

1. **No lateral movement.** The `inet cowork` nftables table has TWO base chains, both priority `-10`: a **`forward`** chain drops guest→`{10/8, 172.16/12, 192.168/16, 169.254/16}` (lateral to *other* LAN machines), and an **`input`** chain drops guest→the *host itself* except the host's DNS/DHCP. Both are required — see the INPUT-vs-FORWARD gotcha below. Only forwarded DNS + 80/443 egress is allowed. Both chains also drop **all guest IPv6** (`meta nfproto ipv6`) as a first rule: the guest is IPv4-only, and the DNS/web accepts are address-family-agnostic, so without the v6 drop a v6-capable guest could reach a LAN/host v6 address on 443/53. This is the highest-value control.
2. **Capability gate stays in software.** Unattended/scheduled Cowork runs produce **drafts and proposals only** — never irreversible actions without James present.
3. **Thin client, not a vault.** No personal data, no imported browser profiles, no SSH keys to other hosts. Connector sessions are the only asset; revocable in seconds.
4. **Disposable.** Snapshot the clean-authed state; recovery is a rollback.
5. **Idempotency.** Every stage is check-then-act and safe to re-run — re-running `install.sh` on a built host must reach verify, not abort. Regressions here are the main defect class.

## Non-obvious things (learned the hard way — read before changing)

- **Tests use mocks that mostly `exit 0`** (`tests/mocks/{virsh,nft,systemctl,virt-install,zfs}`). They validate control flow, **not live tool behavior** — a green suite does NOT mean the scripts work on a real host. Two real bugs (malformed `virt-install` args; `recover.sh` reporting success on a failed start) passed all tests. **The scripts have never been run end-to-end on real hardware.** Where a mock can't model a tool, assert on the *generated artifact* instead.
- **Guest→resolver DNS does NOT traverse the `cowork` forward chain.** The resolver `10.77.0.1` is the host's own bridge IP → traffic to it hits the **INPUT** hook (governed by libvirt's own rules), never `forward`. So do **not** re-add an `ip daddr $GATEWAY accept` rule to `gen_nft_rules` "to keep DNS working" — it's inert (this was tried and removed). The forward-chain LAN-drop only ever sees genuinely-routed guest→LAN traffic, which is exactly what it must block.
- **`gen_nft_rules` must stay idempotent.** It emits the atomic `table inet cowork` / `delete table inet cowork` / `table … {…}` idiom so a second `nft -f` doesn't `EEXIST` on the base chain. Don't drop those two leading lines.
- **`virt_install_args` emits ONE token per line** (each `--flag` and its value on separate lines) so `mapfile -t` splits argv correctly. Never glue `--flag value` onto one line — `virt-install` (argparse) rejects the space-containing token, and the mock won't catch it.
- **install↔recover filename contract:** `90-snapshot.sh` writes `${NET_NAME}.net.xml` + `${VM_NAME}.domain.xml` under `${ZFS_EXPORT_DIR}`; `recover.sh` re-imports the domain XML by that exact name (the network is rebuilt from config by stage 10, not re-imported). A filename mismatch silently breaks recovery. `${ZFS_EXPORT_DIR}` lives *inside* the dataset so the golden snapshot captures disk + XML together — the XML export must therefore run BEFORE the `zfs snapshot`, and because the snapshot is non-recursive, `${ZFS_EXPORT_DIR}` must be a plain directory in the dataset, not a child dataset. `snapshot_vm` guards this with a `zfs list -o mountpoint` containment check (an off-dataset `DISK_PATH`/`ZFS_EXPORT_DIR` would otherwise snapshot an empty dataset).
- **`snapshot_vm` ALWAYS thaws — including on a *freeze* failure.** The ZFS golden snapshot is VSS-quiesced: `virsh domfsfreeze` (needs the **qemu-ga channel** `virt_install_args` now emits) → `zfs snapshot ${ZFS_DATASET}@clean-authed` → `virsh domfsthaw`. Both `virsh` calls are un-`set -e`-guarded on purpose: a `domfsfreeze` that returns non-zero (VSS timeout) can still have frozen filesystems, so the thaw must run even then; and a failed *thaw* is an emergency (Windows I/O hangs) that `die`s loudly with `GUEST MAY BE FROZEN`. The wrapper captures `rc`/`thaw_rc`, thaws unconditionally, surfaces a frozen guest first, then the snapshot failure. Don't collapse it into a bare `set -e` sequence that aborts before the thaw (this was the review bug). Re-baselining fails loud on `@clean-authed` EEXIST by design (protects the golden); `zfs destroy` it first to retake.
- **`50-verify.sh` uses `set -uo pipefail` (no `-e`) deliberately** so every check runs and one failure doesn't abort the sweep; `verify_all` returns non-zero overall. Don't "standardize" it back to `set -euo`.
- **Console: SPICE, never RDP.** Cowork's scheduled tasks must live in the interactive console session; RDP detaches it. Remote console is `virt-viewer --connect qemu+ssh://${HOST_ADDR}/system win11-cowork` — SPICE tunnels over existing SSH (no new ports/rules). Run a **distro-packaged** virt-viewer (patched deps), not the frozen 2021 Windows MSI.
- **OVMF firmware is detected at runtime** (`detect_ovmf`), never hardcoded — Windows 11 requires UEFI + Secure Boot + TPM 2.0, and the `.secboot` filenames vary by distro.
- **Ubuntu/Debian only** (`apt`). No RHEL/dnf paths.

## Git / PR workflow

Commits and PRs go through a separate bot account (`jpansarasa-bot`, token in `.github-pat-bot`, gitignored) so Claude's work is visually distinct from James's; **James reviews and merges**. See project memory `github-bot-identity` / `github-pat-usage` for the credential-helper pattern that keeps tokens out of `.git/config`.
