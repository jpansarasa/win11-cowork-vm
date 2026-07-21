# Design — Local File Transfer via SPICE Shared Folder

**Date:** 2026-07-19
**Status:** Approved (brainstorming)
**Companion doc:** `win11-cowork-vm-buildspec.md` (adds a subsection to §5, Console)

## Purpose

Move files **both directions** between the operator's local machines and the caged Windows 11 guest, without routing them through a third-party cloud drive. Clipboard already handles small text; the gap is **binary blobs** (e.g. a large data-archive zip). This is the "operator is local, at the console" problem — **Problem 1** in the decomposition. It is entirely separate from remote notification (Problem 2, ntfy — its own spec).

## The constraint that shapes everything

The guest is **network-isolated by design**. The `inet cowork` nftables table drops guest→host (except DNS/DHCP) and guest→`{10/8, 172.16/12, 192.168/16, 169.254/16}`; the only egress is forwarded DNS + 80/443 to the public internet. There is **no network path** into the guest, and no SSH server in it. So every file-transfer option is a *non-network* host↔guest channel. There are only four: virtiofs/9p, disk/ISO attach, qemu-guest-agent file ops, and the SPICE channels. This design picks SPICE.

## Non-goals

- **No SMB/CIFS share.** Rejected after an explicit threat-model review. An SMB mount is not "a folder" — it is a full, stateful protocol channel (DCE/RPC over `IPC$`, NTLM credential material, a standing bidirectional exfil pipe that survives unattended runs, plus the file server's own SMB attack surface). It converts "hostile guest" into "hostile LAN" faster than any other single change, and would need a dedicated hardened VLAN'd endpoint to be defensible — enormous standing surface for a rare, by-hand file drop. See the threat model captured in the buildspec.
- **No virtiofs/9p.** Most capable, but needs a Windows virtio-fs driver + WinFSP **and a domain-XML change**, which disturbs the golden-snapshot / recover contract — the most load-bearing invariant in the repo. Overkill for occasional drops, and its always-on host→guest bridge most erodes the disposable/thin-client posture.
- **No on-demand ISO/disk attach.** Zero guest software, but the file must first reach the host (scp), and it is essentially host→guest read-only. Trades "upload to a cloud drive" for "scp to the host" — a lateral move, not a win. Kept as a documented fallback only.
- **No qemu-ga file push for this.** Base64 over the agent serial channel is fine for tiny files, painful for tens-of-MB payloads.
- **Not in the bats suite.** Guest-side PowerShell/config, like `guest/postboot.ps1` — no shellcheck/mock surface. Verified by exercising it, not by unit test.

## Why SPICE (the properties that decide it)

The guest already rides an authenticated **SPICE-over-SSH** channel every time the console opens (`virt-viewer -c qemu+ssh://${HOST_ADDR}/system ${VM_NAME}`, tunneled over the operator's existing SSH access to the host). File transfer piggybacks on *that* channel:

- **No firewall change, no new port** — reuses the SSH tunnel already open. Adds nothing to the `cowork` cage.
- **No domain-XML change** — leaves the golden-snapshot / recover contract untouched.
- **Attended-only, self-gating** — the share exists *only while `virt-viewer` is running*. Close the console and the path is gone. It does **not** widen the unattended attack surface, which fits thin-client/disposable exactly.
- **Bidirectional** — a file dropped in the client folder appears in the guest; a draft the guest writes there lands back on the client.

## Architecture

```
Client workstation
  └─ WSL2/WSLg distro
       └─ virt-viewer  ── qemu+ssh://<host> ──►  libvirtd on host ──► guest SPICE
            │  (local WebDAV server, operator-chosen folder)              │
            │                                                             │
            └─ shares e.g. /mnt/c/Users/<user>/Downloads  ◄─ spice-webdavd ┘
                                                             (guest service,
                                                              maps "Spice client folder" drive)
```

**Data flow.**
- *Host→guest:* place a file in the shared client folder → in the guest, open the "Spice client folder" drive → copy it out.
- *Guest→host:* the guest (or Cowork) writes into that drive → the file appears in the client folder.

## Components

1. **Guest — `spice-webdavd` present + running.** Part of the Windows SPICE guest tools. `spice-vdagent` is almost certainly already installed (clipboard works), and `spice-webdavd` often ships alongside it. **Step 0 is *verify*, install only if missing.** This is mechanical guest config, so it fits `guest/postboot.ps1`'s charter: add an idempotent check-then-ensure block that
   - ensures the **`WebClient`** service is Automatic + running **first and unconditionally** — it is a stock Windows service, independent of `spice-webdavd`, and must never be left unconfigured because the webdavd step failed,
   - then checks whether the `spice-webdavd` service exists; if present, ensures it is enabled + running (`Set-Service -StartupType Automatic`, `Start-Service`),
   - if absent, **logs the install URL and stops — it does not download or install anything** (non-fatal; the rest of the guest config is valid without it).

   **Why detect-and-instruct, not auto-install** (revised after the first real run): auto-install with an Authenticode gate was tried and *cannot work*. Verified on a live guest — the spice-space.org MSI, both virtio-win guest-tools installers, and the already-installed `qemu-ga.exe` all report `NotSigned`; only the virtio-win *drivers* are catalog-signed. `Get-AuthenticodeSignature` itself was proven functional (`Valid` for `notepad.exe`/`kernel32.dll`/`explorer.exe`), so the gate was correct and the assumption about upstream artifacts was wrong. The remaining options were to auto-fetch an unsigned binary behind a pinned hash — a hash proves "the same bytes as last time", not "trustworthy" — or to have the operator install it once, knowingly. For a rarely-run setup step on a deliberately hardened guest, the latter is right.
   The block is idempotent and safe to re-run, matching every other `postboot.ps1` action.

2. **Client (WSLg) — virt-viewer with a shared folder.** Set once in `virt-viewer` → Preferences → **Share folder** (persisted). The WSLg wrinkle, documented precisely: the folder is a **WSL-side path**, so to share Windows files point it at `/mnt/c/Users/<user>/Downloads` (or copy into WSL first). Note the mild `/mnt/c` performance caveat for large files.

3. **Docs — buildspec §5 addition.** Setup steps, the WSLg path caveat, the `WebClient`/`spice-webdavd` service notes, and a short "how to move a file, both directions" runbook. Cross-reference: this is the local half; remote handoff is the ntfy spec.

## Error handling & gotchas

- **`spice-webdavd` missing** → the guest shows no client folder. `postboot.ps1` self-heals this: it downloads the signed MSI, verifies the Authenticode signature, and installs — failing loud (never silently no-op'ing) if the download or signature check fails.
- **`WebClient` stopped** → the drive won't map even with `spice-webdavd` running. Both are ensured in `postboot.ps1` and called out in the buildspec.
- **WSLg path confusion** → sharing a WSL `$HOME` path hides Windows files; the doc steers to `/mnt/c/...`.
- **Share silently gone** → expected when `virt-viewer` is closed; documented as the intended self-gating behavior, not a bug.

## Verification (manual — no bats)

1. In the guest: `Get-Service spice-webdavd, WebClient` → both `Running`.
2. Host→guest: drop a test file (and a real-size payload) in the shared folder → confirm it opens from the guest's Spice client folder drive.
3. Guest→host: write a file from the guest into the drive → confirm it appears in the client folder.
4. Close `virt-viewer` → confirm the drive/path is gone (self-gating verified).

## Security posture (one line)

No protocol on the LAN, no credentials, no standing channel, no server to patch, alive only while the operator is at the console. This is the whole reason it beats SMB for the stated use case.

**Caveat.** Pinning `WebClient` (the WebDAV redirector) to Automatic+Running is a real, if small, posture change: it's the classic NTLM-coercion primitive, and `postboot.ps1` keeps it Automatic so the drive maps reliably, which keeps the WebDAV redirector live at all times, not just while `virt-viewer` is connected. The cage bounds the blast radius — LAN and host targets are unreachable — so the residual is an NTLM-over-HTTP leak to an internet host, and only from an already-compromised guest on a disposable local account.
