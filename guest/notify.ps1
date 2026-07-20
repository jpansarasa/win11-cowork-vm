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

# HTTP header values cannot contain CR/LF - flatten anything that becomes a header.
function Flatten([string]$s) { ($s -replace "`r`n|`r|`n", ' ').Trim() }

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
  'Title'         = (Flatten $Title)
  'Priority'      = $Priority
}
if ($Tags) { $headers['Tags'] = (Flatten ($Tags -join ',')) }

$usePut = [bool]$File
if ($usePut) {
  if (-not (Test-Path -LiteralPath $File)) { throw "Attachment not found: $File" }
  $headers['Filename'] = [System.IO.Path]::GetFileName($File)
  # With an attachment the body IS the file, so the text rides in the Message header.
  $headers['Message']  = (Flatten $Message)
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
    $resp = Invoke-RestMethod -Uri $cfg.url -Method Post -Headers $headers -Body $Message -ContentType 'text/plain; charset=utf-8'
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
  if (-not $body) { $body = $_.Exception.Message }
  throw "ntfy notify FAILED (HTTP $status): $body"
}
