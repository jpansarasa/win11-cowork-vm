# Local File Transfer (SPICE Shared Folder) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the operator a bidirectional, non-network file channel between local machines and the caged Windows 11 guest, using SPICE's built-in folder sharing over the existing SPICE-over-SSH console tunnel.

**Architecture:** Two changes only — (1) an idempotent block in `guest/postboot.ps1` that ensures `spice-webdavd` + the `WebClient` redirector are installed and running in the guest, and (2) a buildspec §5 subsection documenting the client-side `virt-viewer` "Share folder" setup and the WSLg path caveat. No host firewall change, no libvirt domain-XML change. Design spec: `docs/superpowers/specs/2026-07-19-local-file-transfer-spice-design.md`.

**Tech Stack:** Windows PowerShell 5.1 (guest, elevated), `spice-webdavd` (SPICE WebDAV daemon), Windows `WebClient` service, `virt-viewer`/`remote-viewer` (client, WSLg on Windows). Markdown for docs.

## Global Constraints

- **No firewall/cage change, no libvirt domain-XML change.** This channel rides the existing SPICE-over-SSH tunnel only.
- **Attended-only by design.** The share exists solely while `virt-viewer` is running; do not add anything that makes it persist unattended.
- **Idempotent.** The `postboot.ps1` block is check-then-act and safe to re-run, matching every other step in that file (`Do-Step` pattern).
- **Auto-install is permitted here** (operator decision) but the downloaded MSI **MUST** pass Authenticode signature verification (`Get-AuthenticodeSignature` → `Valid`) before install — it is fetched onto a hardened box.
- **Not in the bats suite.** Guest PowerShell; verify by exercising it in the guest.
- **PowerShell target:** 5.1 (`#Requires -Version 5.1`, already declared in `postboot.ps1`).
- **De-personalized voice** (public repo): no personal names; use "the operator".

---

### Task 1: `postboot.ps1` — ensure `spice-webdavd` + `WebClient`

**Files:**
- Modify: `guest/postboot.ps1` (insert a new `Do-Step` after the debloat loop that ends at line ~110, before the closing `Note ''` block at line ~112; also de-personalize the header comment at line 7)

**Interfaces:**
- Consumes: the file's existing helpers `Note($m)` and `Do-Step($m, [scriptblock]$b)` (which already honors `-DryRun` by skipping the body).
- Produces: after a real (non-DryRun) run, services `spice-webdavd` and `WebClient` are `StartupType=Automatic` and `Running`.

- [ ] **Step 1: De-personalize the header comment**

In `guest/postboot.ps1` line 7, replace:

```
  Run ONCE in an ELEVATED PowerShell inside the guest. Idempotent - safe to re-run.
  James runs this by hand; Claude/host never drives it. It covers only the
```

with:

```
  Run ONCE in an ELEVATED PowerShell inside the guest. Idempotent - safe to re-run.
  The operator runs this by hand; Claude/host never drives it. It covers only the
```

- [ ] **Step 2: Insert the spice-webdavd Do-Step**

Insert immediately after the debloat `foreach` loop (after the line `}` that closes the loop, before `Note ''`):

```powershell
# 8) SPICE WebDAV - enables host<->guest file transfer via virt-viewer "Share folder".
#    Auto-installs the SIGNED spice-webdavd MSI if absent (verified before install),
#    then ensures it + the WebClient (WebDAV redirector) run so the guest can map the
#    "Spice client folder" as a drive. Attended-only: the share is live only while a
#    virt-viewer console with a shared folder is connected.
Do-Step 'spice-webdavd: ensure installed + running (host<->guest file share)' {
  $svc = Get-Service -Name 'spice-webdavd' -ErrorAction SilentlyContinue
  if (-not $svc) {
    Note '  spice-webdavd absent; downloading signed MSI from spice-space.org'
    $url = 'https://www.spice-space.org/download/windows/spice-webdavd/spice-webdavd-x64-latest.msi'
    $msi = Join-Path $env:TEMP 'spice-webdavd-x64.msi'
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    $sig = Get-AuthenticodeSignature -FilePath $msi
    if ($sig.Status -ne 'Valid') {
      throw "spice-webdavd MSI signature not Valid (status: $($sig.Status)); refusing to install."
    }
    Note "  MSI signed by: $($sig.SignerCertificate.Subject)"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart'
    if ($p.ExitCode -ne 0) { throw "spice-webdavd install failed (msiexec exit $($p.ExitCode))." }
    Remove-Item -LiteralPath $msi -ErrorAction SilentlyContinue
    $svc = Get-Service -Name 'spice-webdavd' -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'spice-webdavd still absent after install.' }
    Note '  installed spice-webdavd'
  }
  Set-Service -Name 'spice-webdavd' -StartupType Automatic
  if ((Get-Service spice-webdavd).Status -ne 'Running') { Start-Service spice-webdavd }
  # WebClient = the WebDAV redirector; without it the Spice client folder won't map.
  Set-Service -Name 'WebClient' -StartupType Automatic
  if ((Get-Service WebClient).Status -ne 'Running') { Start-Service WebClient }
}
```

- [ ] **Step 3: Add the step to the final "still MANUAL" notes if relevant — no change needed**

The closing `Note` block lists manual steps; this step is automated, so it does not belong there. Confirm no edit is needed. (No action.)

- [ ] **Step 4: Lint the PowerShell parses (syntax check)**

Run in the repo (any box with PowerShell; or skip to Step 5 if none):

```powershell
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('guest/postboot.ps1',[ref]$null,[ref]$null) | Out-Null; 'parse-ok'"
```

Expected: prints `parse-ok` with no parser errors. If PowerShell is unavailable on the host, note that and defer syntax validation to Step 5 in the guest.

- [ ] **Step 5: Verify in the guest — DryRun skips, real run is idempotent**

In an **elevated** PowerShell inside the guest:

```powershell
# a) DryRun must NOT install or touch services:
powershell -ExecutionPolicy Bypass -File .\postboot.ps1 -DryRun
#    Expected: line "[postboot] spice-webdavd: ensure installed + running ..." followed by
#              "[postboot]   (dry-run: skipped)"

# b) Real run:
powershell -ExecutionPolicy Bypass -File .\postboot.ps1
Get-Service spice-webdavd, WebClient | Format-Table Name, Status, StartType
#    Expected: both Running, both Automatic.

# c) Re-run (idempotency): must not re-download; just re-ensures services:
powershell -ExecutionPolicy Bypass -File .\postboot.ps1
#    Expected: no "downloading signed MSI" line the second time; ends cleanly.
```

- [ ] **Step 6: Commit**

```bash
git add guest/postboot.ps1
git commit -m "feat(guest): postboot ensures spice-webdavd + WebClient for SPICE file share

Adds an idempotent step that auto-installs the signed spice-webdavd MSI
(Authenticode-verified before install) if absent, then keeps it and the
WebClient redirector Automatic+Running so virt-viewer's Share folder maps
a drive in the guest. Also de-personalizes the header comment.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Buildspec §5 — client-side shared-folder runbook

**Files:**
- Modify: `win11-cowork-vm-buildspec.md` (add a subsection at the end of §5, "Windows install (operator, interactive)", after the guest-tools line ~282)

**Interfaces:**
- Consumes: Task 1's guarantee that `spice-webdavd` + `WebClient` run in the guest.
- Produces: operator-facing steps to set the client shared folder and move files both ways.

- [ ] **Step 1: Add the subsection**

Append to §5 (after the "install guest tools" paragraph):

````markdown
### 5a. File transfer — SPICE shared folder (local, both directions)

Move files between a local machine and the guest over the **same** SPICE-over-SSH
console tunnel — no firewall change, no extra ports. The share is live **only while
`virt-viewer` is connected**, so it never widens the unattended attack surface.

**Guest side:** handled by `guest/postboot.ps1` — it ensures `spice-webdavd` and the
`WebClient` redirector are installed and running. Confirm once:

```powershell
Get-Service spice-webdavd, WebClient   # both Running
```

**Client side (the machine running `virt-viewer`):** pick a folder to share.

- In `virt-viewer`: **Preferences → Share folder** → tick *Share folder*, choose the folder.
- Reconnect the console. In the guest, the folder appears as the **"Spice client folder"**
  drive (a WebDAV mount under `\\localhost@…`/a mapped drive).

**WSLg caveat (Windows client via WSL2):** `virt-viewer` runs inside WSL, so the shared
folder is a **WSL-side path**. To share Windows files, point it at the Windows mount,
e.g. `/mnt/c/Users/<user>/Downloads`, or copy files into WSL first. (`/mnt/c` is a bit
slow for very large files — for those, copy into the WSL home first.)

**Move a file:**
- *Into the guest:* drop it in the shared folder → open the "Spice client folder" drive in the guest → copy it out.
- *Out of the guest:* write/copy it into that drive in the guest → it appears in the shared folder on the client.

**Gotchas:**
- No "Spice client folder" drive? Check `Get-Service spice-webdavd, WebClient` are both
  Running (re-run `postboot.ps1`), and that the `virt-viewer` shared-folder box is ticked.
- The drive vanishing when you close `virt-viewer` is **expected** — the share is attended-only.

> Remote hand-off (when you're away from the console) is a different channel — see
> "Reaching the operator remotely" (ntfy). SPICE is the local, attended path only.
````

- [ ] **Step 2: Verify docs render + cross-reference is correct**

Run:

```bash
grep -n "Spice client folder" win11-cowork-vm-buildspec.md
grep -n "Reaching the operator remotely" win11-cowork-vm-buildspec.md docs/superpowers/specs/2026-07-19-remote-notify-ntfy-design.md
```

Expected: the §5a text is present; the ntfy cross-reference name matches the ntfy spec/plan's subsection title. (If the ntfy plan hasn't landed yet, this reference is forward-looking — acceptable.)

- [ ] **Step 3: Commit**

```bash
git add win11-cowork-vm-buildspec.md
git commit -m "docs(buildspec): §5a SPICE shared-folder file transfer runbook

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Guest `spice-webdavd`+`WebClient` ensure (Task 1) ✓; client shared-folder setup + WSLg caveat + both-directions runbook + gotchas (Task 2) ✓; attended-only property documented (Task 2) ✓; auto-install with signature verification (Task 1, per operator decision) ✓; not-in-bats / manual verify (Task 1 Step 5) ✓.
- **Placeholders:** none — full PowerShell and Markdown provided.
- **Consistency:** service names `spice-webdavd` / `WebClient` used identically across tasks; the §5a cross-reference matches the ntfy subsection title used in Plan B.
