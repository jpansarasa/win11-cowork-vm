# Design — Local File Transfer via SPICE Shared Folder

**Date:** 2026-07-19
**Status:** Approved (brainstorming)
**Repo:** github.com/jpansarasa/win11-cowork-vm
**Companion doc:** `win11-cowork-vm-buildspec.md` (adds a subsection to §5, Console)

## Purpose

Give James a way to move files **both directions** between his local machines and the caged Windows 11 guest, without bouncing them through Google Drive. Clipboard already handles small text; the gap is **binary blobs** (e.g. a LinkedIn data-archive zip). This is the "I'm local, at the console" problem — **Problem 1** in the decomposition. It is entirely separate from remote notification (Problem 2, ntfy — its own spec).

## The constraint that shapes everything

The guest is **network-isolated by design**. The `inet cowork` nftables table drops guest→host (except DNS/DHCP) and guest→`{10/8, 172.16/12, 192.168/16, 169.254/16}`; the only egress is forwarded DNS + 80/443 to the public internet. There is **no network path** into the guest, and no SSH server in it. So every file-transfer option is a *non-network* host↔guest channel. There are only four: virtiofs/9p, disk/ISO attach, qemu-guest-agent file ops, and the SPICE channels. We pick SPICE.

## Non-goals

- **No SMB/CIFS share.** Rejected after an explicit threat-model review. An SMB mount is not "a folder" — it is a full, stateful protocol channel (DCE/RPC over `IPC$`, NTLM credential material, a standing bidirectional exfil pipe that survives unattended runs, plus the file server's own SMB attack surface). It converts "hostile guest" into "hostile LAN" faster than any other single change and would need a dedicated hardened VLAN'd endpoint to be defensible — enormous standing surface for a rare by-hand zip. See the threat model captured in the buildspec.
- **No virtiofs/9p.** Most capable, but needs a Windows virtio-fs driver + WinFSP **and a domain-XML change**, which disturbs the golden-snapshot / recover contract — the most load-bearing invariant in the repo. Overkill for occasional drops, and its always-on host→guest bridge most erodes the disposable/thin-client posture.
- **No on-demand ISO/disk attach.** Zero guest software, but the file must first reach saturn (scp), and it is essentially host→guest read-only. Trades "upload to Google" for "scp to saturn" — a lateral move, not a win. Kept as a documented fallback only.
- **No qemu-ga file push for this.** Base64 over the agent serial channel is fine for tiny files, painful for tens-of-MB zips.
- **Not in the bats suite.** Guest-side PowerShell/config, like `guest/postboot.ps1` — no shellcheck/mock surface. Verified by exercising it, not by unit test.

## Why SPICE (the properties that decide it)

The guest already rides an authenticated **SPICE-over-SSH** channel every time the console opens (`virt-viewer -c qemu+ssh://…/system win11-cowork`, tunneled over James's existing SSH access). File transfer piggybacks on *that* channel:

- **No firewall change, no new port** — reuses the SSH tunnel already open. Adds nothing to the `cowork` cage.
- **No domain-XML change** — leaves the golden-snapshot / recover contract untouched.
- **Attended-only, self-gating** — the share exists *only while `virt-viewer` is running*. Close the console and the path is gone. It does **not** widen the unattended attack surface, which fits thin-client/disposable exactly.
- **Bidirectional** — drop a file in the client folder → it appears in the guest; Cowork writes a draft there → it lands on the client.

## Architecture

```
Client (Windows box "Jupiter")
  └─ WSL2/WSLg distro
       └─ virt-viewer  ── qemu+ssh://saturn ──►  libvirtd on saturn ──► guest SPICE
            │  (local WebDAV server, folder James picks)                     │
            │                                                                 │
            └─ shares e.g. /mnt/c/Users/<you>/Downloads  ◄── spice-webdavd ──┘
                                                              (guest service,
                                                               maps "Spice client folder" drive)
```

**Data flow.**
- *Host→guest:* put a file in the shared client folder → in the guest, open the "Spice client folder" drive → copy it out.
- *Guest→host:* Cowork (or you) writes into that drive → the file appears in the client folder.

## Components

1. **Guest — `spice-webdavd` present + running.** Part of the Windows SPICE guest tools. `spice-vdagent` is almost certainly already installed (clipboard works), and `spice-webdavd` often ships alongside it. **Step 0 is *verify*, install only if missing.** This is mechanical guest config, so it fits `guest/postboot.ps1`'s charter: add an idempotent check-then-ensure block that
   - checks whether the `spice-webdavd` service exists; if absent, logs a clear "install SPICE guest tools" instruction (the MSI/installer is not something postboot downloads — consistent with how postboot avoids fetching installers),
   - if present, ensures the service is enabled + running (`Set-Service -StartupType Automatic`, `Start-Service`),
   - and ensures the **`WebClient`** service is running + auto-start (Windows needs it to map the WebDAV drive).
   The block is idempotent and safe to re-run, matching every other `postboot.ps1` action.

2. **Client (WSLg) — virt-viewer with a shared folder.** Set once in `virt-viewer` → Preferences → **Share folder** (persisted). The WSLg wrinkle, documented precisely: the folder is a **WSL-side path**, so to share Windows files point it at `/mnt/c/Users/<you>/Downloads` (or copy into WSL first). Note the mild `/mnt/c` performance caveat for large files.

3. **Docs — buildspec §5 addition.** Setup steps, the WSLg path caveat, the `WebClient`/`spice-webdavd` service notes, and a short "how to move a file, both directions" runbook. Cross-reference: this is the local half; remote handoff is the ntfy spec.

## Error handling & gotchas

- **`spice-webdavd` missing** → the guest shows no client folder. `postboot.ps1` surfaces this explicitly rather than silently no-op'ing; the buildspec says which installer provides it.
- **`WebClient` stopped** → the drive won't map even with `spice-webdavd` running. Both are ensured in `postboot.ps1` and called out in the buildspec.
- **WSLg path confusion** → sharing a WSL `$HOME` path hides Windows files; the doc steers to `/mnt/c/...`.
- **Share silently gone** → expected when `virt-viewer` is closed; documented as the intended self-gating behavior, not a bug.

## Verification (manual — no bats)

1. In the guest: `Get-Service spice-webdavd, WebClient` → both `Running`.
2. Host→guest: drop a test file (and a real-size zip) in the shared folder → confirm it opens from the guest's Spice client folder drive.
3. Guest→host: write a file from the guest into the drive → confirm it appears in the client folder.
4. Close `virt-viewer` → confirm the drive/path is gone (self-gating verified).

## Security posture (one line)

No protocol on the LAN, no credentials, no standing channel, no server to patch, alive only while James is watching. This is the whole reason it beats SMB for the stated use case.
