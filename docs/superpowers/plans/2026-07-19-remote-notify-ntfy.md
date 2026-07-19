# Remote Notification (ntfy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Cowork/the guest reach the operator when they're away — an outbound-only ntfy notification (optionally with a file attachment) posted directly from the guest over its existing 443 egress.

**Architecture:** A single guest-side helper `guest/notify.ps1` reads a topic URL + publish-only token from `%ProgramData%\cowork\ntfy.json` and POSTs (or PUTs, for an attachment) to the public ntfy topic. No cage change (the guest already has 443 egress), no host courier, and **the guest never subscribes** (no command channel in). Config carries the one sanctioned guest secret and is kept out of the repo. Design spec: `docs/superpowers/specs/2026-07-19-remote-notify-ntfy-design.md`.

**Tech Stack:** Windows PowerShell 5.1 (guest), ntfy HTTP publish API, `Invoke-RestMethod`. JSON config. Markdown for docs.

## Global Constraints

- **Outbound-only. Never subscribe/poll.** The helper only publishes. Do not add any read/subscribe path — that would build a C2 channel into the guest.
- **Publish-only token, single topic.** The token in the guest can only publish to one topic. It is the one sanctioned guest secret (buildspec constraint #3), documented as a conscious exception.
- **Config never in the repo.** Real config lives at `%ProgramData%\cowork\ntfy.json`; the repo ships only `ntfy.json.example` and a `.gitignore` guard.
- **Fail loud.** Missing/invalid config or any non-2xx from ntfy raises a clear error with the HTTP status + ntfy body — no silent swallow.
- **Not in the bats suite.** Guest PowerShell; verify via `-DryRun` artifact inspection + a real send to the phone.
- **PowerShell target:** 5.1 (`#Requires -Version 5.1`).
- **De-personalized voice** (public repo): "the operator", not a personal name.

---

### Task 1: `guest/notify.ps1` — the outbound helper

**Files:**
- Create: `guest/notify.ps1`

**Interfaces:**
- Consumes: config file `%ProgramData%\cowork\ntfy.json` with keys `url` (string, full topic URL) and `token` (string, publish-only).
- Produces: CLI `notify.ps1 -Title <s> -Message <s> [-Priority min|low|default|high|urgent] [-Tags a,b] [-File <path>] [-DryRun]`. On success prints `ntfy: delivered (id ...)`; on failure throws.

- [ ] **Step 1: Write `guest/notify.ps1`**

```powershell
#Requires -Version 5.1
<#
  notify.ps1 - one-way Cowork -> operator notification via ntfy.

  OUTBOUND ONLY. This helper never subscribes and never reads from ntfy; it only
  PUBLISHES to a single topic with a publish-only token. Do NOT add a subscribe/poll
  path - that would create a command channel INTO the guest.

  Config (operator-created, NOT in the repo):
    %ProgramData%\cowork\ntfy.json
    { "url": "https://<ntfy-host>/<topic>", "token": "tk_publishonly" }

  Usage:
    .\notify.ps1 -Title 'Blocked' -Message 'Need approval on step 3'
    .\notify.ps1 -Title 'Draft ready' -Message 'Review attached' -File C:\out\draft.pdf
    .\notify.ps1 -Title t -Message m -DryRun     # print the request, send nothing
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Title,
  [Parameter(Mandatory = $true)][string]$Message,
  [ValidateSet('min','low','default','high','urgent')][string]$Priority = 'default',
  [string[]]$Tags,
  [string]$File,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ConfigPath = Join-Path $env:ProgramData 'cowork\ntfy.json'

function Get-NtfyConfig([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "ntfy config not found at $Path. Create it: { `"url`": `"https://<ntfy-host>/<topic>`", `"token`": `"tk_...`" } (publish-only token)."
  }
  $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  foreach ($k in 'url', 'token') {
    if (-not $cfg.$k) { throw "ntfy config $Path is missing '$k'." }
  }
  return $cfg
}

$cfg = Get-NtfyConfig $ConfigPath

$headers = @{
  'Authorization' = "Bearer $($cfg.token)"
  'Title'         = $Title
  'Priority'      = $Priority
}
if ($Tags) { $headers['Tags'] = ($Tags -join ',') }

$usePut = [bool]$File
if ($usePut) {
  if (-not (Test-Path -LiteralPath $File)) { throw "Attachment not found: $File" }
  $headers['Filename'] = [System.IO.Path]::GetFileName($File)
  # With an attachment the body IS the file, so the text rides in the Message header.
  $headers['Message']  = $Message
}

if ($DryRun) {
  Write-Host "DRY RUN - no request sent"
  Write-Host ("  {0} {1}" -f $(if ($usePut) { 'PUT' } else { 'POST' }), $cfg.url)
  $shown = $headers.Clone()
  $shown['Authorization'] = 'Bearer <redacted>'
  $shown.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Value) }
  if ($usePut) { Write-Host "  <body: file $File>" } else { Write-Host "  <body: $Message>" }
  return
}

try {
  if ($usePut) {
    $resp = Invoke-RestMethod -Uri $cfg.url -Method Put -Headers $headers -InFile $File -ContentType 'application/octet-stream'
  } else {
    $resp = Invoke-RestMethod -Uri $cfg.url -Method Post -Headers $headers -Body $Message
  }
  Write-Host "ntfy: delivered (id $($resp.id))"
}
catch {
  $status = $null
  if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch {} }
  $body = $_.ErrorDetails.Message
  if (-not $body -and $_.Exception.Response) {
    try {
      $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $body = $sr.ReadToEnd()
    } catch {}
  }
  throw "ntfy notify FAILED (HTTP $status): $body"
}
```

- [ ] **Step 2: Syntax check parses**

```powershell
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('guest/notify.ps1',[ref]$null,[ref]$null) | Out-Null; 'parse-ok'"
```

Expected: `parse-ok`, no parser errors. (If no PowerShell on the host, defer to Step 4 in the guest.)

- [ ] **Step 3: Verify the composed request via `-DryRun` (no config, no network)**

The DryRun path still requires config to exist (it reads `url`). To test the request-composition artifact without a real topic, create a throwaway config first:

```powershell
New-Item -ItemType Directory -Force -Path (Join-Path $env:ProgramData 'cowork') | Out-Null
'{ "url": "https://ntfy.example/testtopic", "token": "tk_dummy" }' |
  Set-Content -LiteralPath (Join-Path $env:ProgramData 'cowork\ntfy.json')

.\notify.ps1 -Title 'hi' -Message 'body text' -Priority high -Tags warning,robot -DryRun
```

Expected output (token redacted, POST since no file):

```
DRY RUN - no request sent
  POST https://ntfy.example/testtopic
  Authorization: Bearer <redacted>
  Priority: high
  Tags: warning,robot
  Title: hi
  <body: body text>
```

Then the attachment path:

```powershell
.\notify.ps1 -Title 'draft' -Message 'review' -File $env:WINDIR\notepad.exe -DryRun
```

Expected: method `PUT`, a `Filename: notepad.exe` header, a `Message: review` header, and `<body: file ...>`.

- [ ] **Step 4: Verify failure modes fail loud**

```powershell
# Missing config:
Remove-Item -LiteralPath (Join-Path $env:ProgramData 'cowork\ntfy.json')
.\notify.ps1 -Title x -Message y     # Expected: throws "ntfy config not found at ..."

# Missing key:
'{ "url": "https://ntfy.example/t" }' | Set-Content (Join-Path $env:ProgramData 'cowork\ntfy.json')
.\notify.ps1 -Title x -Message y     # Expected: throws "... is missing 'token'."
```

- [ ] **Step 5: Commit**

```bash
git add guest/notify.ps1
git commit -m "feat(guest): notify.ps1 - outbound-only ntfy notifier (file optional)

Publishes a single-topic ntfy notification (optionally with an attachment)
using a publish-only token from %ProgramData%\\cowork\\ntfy.json. Never
subscribes. Fails loud on missing config or non-2xx. -DryRun prints the
composed request with the token redacted.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Config example + `.gitignore` guard

**Files:**
- Create: `guest/ntfy.json.example`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the config schema from Task 1 (`url`, `token`).
- Produces: a committed template; a guard so a real `ntfy.json` can never be committed.

- [ ] **Step 1: Create `guest/ntfy.json.example`**

```json
{
  "url": "https://ntfy.example.net/cowork-REPLACE-with-a-hard-to-guess-topic",
  "token": "tk_REPLACE_with_a_PUBLISH_ONLY_token_scoped_to_this_one_topic"
}
```

- [ ] **Step 2: Add the `.gitignore` guard**

Append to `.gitignore`:

```
# ntfy publish-only token config — the REAL file lives in the guest at
# %ProgramData%\cowork\ntfy.json and must never be committed. Ship only the example.
ntfy.json
!ntfy.json.example
```

- [ ] **Step 3: Verify the guard works**

```bash
# A stray real config anywhere in the repo must be ignored; the example must be tracked.
touch guest/ntfy.json
git check-ignore guest/ntfy.json            # Expected: prints "guest/ntfy.json" (ignored)
git check-ignore guest/ntfy.json.example || echo "example NOT ignored (correct)"
rm guest/ntfy.json
git add guest/ntfy.json.example && git status --short   # Expected: only the .example staged
```

Expected: `guest/ntfy.json` is ignored; `guest/ntfy.json.example` is trackable.

- [ ] **Step 4: Commit**

```bash
git add guest/ntfy.json.example .gitignore
git commit -m "chore(guest): ntfy.json.example + gitignore guard for the real token file

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Buildspec — "Reaching the operator remotely" + Cowork wiring

**Files:**
- Modify: `win11-cowork-vm-buildspec.md` (add a subsection near §6/§7 — Cowork setup — titled "Reaching the operator remotely")

**Interfaces:**
- Consumes: `guest/notify.ps1` (Task 1) and the config path (Task 2).
- Produces: operator setup steps (token/topic creation, config placement) + the "documented command" wiring that lets Cowork call the helper through its normal shell.

- [ ] **Step 1: Add the subsection**

````markdown
### Reaching the operator remotely (ntfy — outbound only)

When Cowork needs the operator while they're away, it sends a **one-way** ntfy
notification (optionally with a file attachment) straight from the guest over its
existing 443 egress. This is the natural complement to the capability gate:
unattended runs can't *act* irreversibly, but they *can* say "I'm blocked" or
"here's a draft."

**Hard rule — outbound only.** The guest publishes; it **never subscribes**. A
subscribe path would be a command channel *into* the guest. `guest/notify.ps1`
has no read/poll path; keep it that way.

**One-time setup:**
1. In ntfy, pick a **hard-to-guess topic** (e.g. `cowork-7f3a…`) and create a
   **publish-only access token** scoped to just that topic (ntfy: *Account →
   Access tokens*, then a topic ACL granting write-only). This token is the one
   sanctioned secret in the guest (buildspec principle #1 exception): publish-only,
   single-topic, revocable in seconds.
2. In the guest, write `%ProgramData%\cowork\ntfy.json` (see
   `guest/ntfy.json.example`) with the topic URL + token. Lock it down:
   ```powershell
   New-Item -ItemType Directory -Force -Path "$env:ProgramData\cowork" | Out-Null
   # paste url+token into $env:ProgramData\cowork\ntfy.json, then restrict to admins+SYSTEM:
   icacls "$env:ProgramData\cowork\ntfy.json" /inheritance:r /grant:r "Administrators:R" "SYSTEM:R"
   ```
3. Subscribe to the topic on your phone (ntfy app) and send a test:
   ```powershell
   .\notify.ps1 -Title 'test' -Message 'hello from the guest'
   ```

**Wiring Cowork to it (documented command).** Cowork invokes the helper through its
normal command execution — no MCP, no extension API. Give Cowork a standing
instruction, e.g.:

> To notify the operator, run:
> `powershell -ExecutionPolicy Bypass -File C:\path\to\notify.ps1 -Title "<short>" -Message "<detail>" [-Priority high] [-File "<path>"]`
> Use it when blocked awaiting approval, or to hand over a finished draft (`-File`).
> Never attempt to read or subscribe to ntfy — this channel is outbound only.

**Residual risk (documented, not hidden):** a prompt-injected Cowork could use the
notification body/attachment as an exfil channel — but the guest already has full
443 egress, so this adds convenience, not a new capability. Bounded by: publish-only
scope, a hard-to-guess topic, and instant token revocation.

> This is the *remote* channel. Local, attended file moves use the SPICE shared
> folder — see §5a.
````

- [ ] **Step 2: Verify cross-references + no secret leaked into docs**

```bash
grep -n "Reaching the operator remotely" win11-cowork-vm-buildspec.md
grep -rniE 'tk_[a-z0-9]{6,}' win11-cowork-vm-buildspec.md guest/ntfy.json.example
```

Expected: the subsection exists; the only `tk_...` matches are the obvious placeholders (`tk_REPLACE...`), never a real token.

- [ ] **Step 3: Commit**

```bash
git add win11-cowork-vm-buildspec.md
git commit -m "docs(buildspec): Reaching the operator remotely (ntfy, outbound-only)

Token/topic setup, config placement + ACL lockdown, the documented-command
wiring for Cowork, and the residual-risk note. Cross-references §5a (SPICE).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** outbound-only helper + never-subscribe (Task 1, enforced by having no read path + documented rule) ✓; publish-only single-topic token as sanctioned secret (Tasks 2–3) ✓; config at `%ProgramData%\cowork\ntfy.json`, not in repo, gitignore-guarded (Task 2) ✓; optional attachment via PUT (Task 1) ✓; fail-loud on missing config / non-2xx (Task 1 + Step 4) ✓; `-DryRun` artifact (Task 1 + Step 3) ✓; documented-command Cowork wiring (Task 3, per operator decision) ✓; residual-risk note (Task 3) ✓; buildspec subsection titled to match Plan A's cross-reference ✓.
- **Placeholders:** none — full PowerShell, JSON, `.gitignore`, and Markdown provided.
- **Consistency:** config keys `url`/`token`, path `%ProgramData%\cowork\ntfy.json`, and param names `-Title/-Message/-Priority/-Tags/-File/-DryRun` are identical across Tasks 1–3; subsection title "Reaching the operator remotely" matches the reference in Plan A's §5a.
