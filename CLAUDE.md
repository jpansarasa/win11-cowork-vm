# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not a software project** — it has no build, lint, or test tooling. It is a single ops runbook, `win11-cowork-vm-buildspec.md`, describing how to stand up an isolated Windows 11 guest on a Linux libvirt/KVM host to run Claude Cowork under revocable, MFA-gated sessions. Work here means executing the buildspec on the host, or revising the buildspec itself.

## Roles (who does what)

Two actors, and the split is deliberate:
- **Claude Code** runs on the Linux KVM host and does the non-interactive setup: host package install, network/firewall definition, `virt-install`, verification, snapshotting.
- **James (operator)** does everything interactive inside the guest: the Windows install, all account sign-ins, and every connector login. Never assume you can drive the Windows OOBE or authenticate connectors — those are James's steps.

## Load-bearing constraints (do not violate)

These are the reason the box exists; treat them as invariants, not suggestions:
1. **No lateral movement.** The guest must not reach RFC1918 LAN hosts (protects ZFS and other lab machines). The host egress firewall dropping `virbr-cowork → {10/8, 172.16/12, 192.168/16, 169.254/16}` is the single highest-value control. Verify from the guest that a known LAN host is unreachable while the internet works.
2. **Capability gate stays in software.** Network isolation caps crude paths but does not harden agent judgment. Unattended/scheduled Cowork runs produce **drafts and proposals only** — never outbound or irreversible actions without James present to approve.
3. **The VM is a thin client, not a vault.** No personal data, no imported/copied browser profiles, no SSH keys to other hosts. Connector sessions are the only asset, and they're revocable in seconds from outside.
4. **Disposable.** Snapshot the clean, authed state so re-auth/corruption is a rollback, not a rebuild.

## Sequencing that matters

The buildspec's order is not cosmetic — steps depend on earlier ones:
- **Network segmentation (§3) before VM creation (§4).** Define the dedicated NAT network `cowork-net` (`10.77.0.0/24`, bridge `virbr-cowork`) and load the nftables rules first, so the guest is fenced from its first boot.
- **Observe-then-tighten for egress (§3d).** Never start with a restrictive domain allowlist — a broken connector mid-run is exactly the false-positive fatigue to avoid. Run permissive on 443 with dnsmasq query logging + TLS SNI capture → collect a day or two → build a candidate allowlist → shadow-enforce in Squid (still allow all, log misses) → only hard-enforce once the miss list is empty for a stable period. The human should only ever see a hard block *after* the list is proven complete.

## Non-obvious gotchas

- **DNS resolver sits inside the LAN-drop range.** The bridge gateway/resolver `10.77.0.1` is within `10.0.0.0/8`, so the lateral-movement drop would also kill DNS. The `dport 53` accepts save it today; if you tighten, add `ip daddr 10.77.0.1 accept` *above* the LAN drop, or exclude `10.77.0.0/24` from the drop set.
- **libvirt uses its own nft chains.** The `cowork` table hooks `forward` at priority `-10` to run ahead of them; don't assume libvirt's default rules will enforce the isolation.
- **Console must be SPICE/virt-viewer, not RDP.** Cowork and its scheduled tasks must live in the interactive console session; RDP spawns its own session and detaches the console. For the same reason, launch Cowork "at log on" (interactive), not "at startup".
- **Windows 11 requires UEFI + Secure Boot + emulated TPM 2.0**, and virtio disk/NIC have no in-box Windows drivers — the `virtio-win.iso` must be mounted so drivers can be loaded during install.
- **Distro-specific strings are not to be trusted verbatim.** OVMF secure-boot firmware filenames (`OVMF_CODE.secboot.fd` vs `OVMF_CODE_4M.secboot.fd`, etc.) and `virt-install` flag dialects (`--osinfo` vs `--os-variant`) vary by distro/version. Confirm on the actual host (`ls /usr/share/OVMF/`, `virt-host-validate`) rather than copying the buildspec literally.
- **Downloads from official sources only.** Windows 11 ISO from microsoft.com, virtio-win from fedorapeople.org, Claude desktop from claude.com/download. Verify checksums.

## Open items the buildspec flags (verify, don't assume)

Cowork preview availability on James's plan; the real egress endpoint list (only the obvious hosts are named — anthropic.com, claude.com, claude.ai, Google, Microsoft); and whether connectors broker server-side through claude.ai vs. call out directly from the guest (this changes how much egress the guest needs — observe before locking down).
