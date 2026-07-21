#Requires -Version 5.1
<#
  notify.ps1 - queue a notification for the operator.

  The guest holds NO credential and makes NO network call. It writes a request
  file into a spool directory; the HOST drains that spool over qemu-guest-agent
  and publishes to ntfy from there, where ntfy is reachable. The guest cannot
  reach ntfy (the cage drops guest->LAN by design) and does not need to.

  Deliberately one-way: the guest queues outbound notifications and has no way to
  read anything back. Do NOT add a fetch/poll path - that would be a command
  channel INTO the guest.

  Usage:
    .\notify.ps1 -Title 'Blocked' -Message 'Need approval on step 3'
    .\notify.ps1 -Title 'Draft ready' -Message 'Review attached' -File C:\out\draft.txt
    .\notify.ps1 -Title t -Message m -DryRun     # show the request, queue nothing
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
$Outbox = Join-Path $env:ProgramData 'cowork\outbox'

# Attachments ride inline (base64) through the agent channel, which is not a bulk
# transport. Keep them small; the SPICE shared folder exists for real file moves.
$MaxAttachmentBytes = 2MB

$req = [ordered]@{
  title    = $Title
  message  = $Message
  priority = $Priority
  tags     = @($Tags | Where-Object { $_ })
  created  = (Get-Date).ToUniversalTime().ToString('o')
}

$fi = $null
if ($File) {
  if (-not (Test-Path -LiteralPath $File)) { throw "Attachment not found: $File" }
  $fi = Get-Item -LiteralPath $File
  if ($fi.Length -gt $MaxAttachmentBytes) {
    throw ("Attachment is {0:N0} bytes; the relay limit is {1:N0}. Move large files with the SPICE shared folder (buildspec 5a) instead." -f $fi.Length, $MaxAttachmentBytes)
  }
  $req.filename = $fi.Name
  $req.file_b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fi.FullName))
}

if ($DryRun) {
  Write-Host 'DRY RUN - nothing queued'
  if ($fi) {
    $shown = [ordered]@{}
    foreach ($k in $req.Keys) { if ($k -ne 'file_b64') { $shown[$k] = $req[$k] } }
    Write-Host ($shown | ConvertTo-Json -Depth 4 -Compress)
    Write-Host ("  <attachment {0}: {1:N0} bytes>" -f $req.filename, $fi.Length)
  } else {
    Write-Host ($req | ConvertTo-Json -Depth 4 -Compress)
  }
  return
}

New-Item -ItemType Directory -Force -Path $Outbox | Out-Null

# Write .tmp then rename: the host lists only *.json, so it can never read a
# half-written request.
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
$base  = '{0}-{1}' -f $stamp, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$tmp   = Join-Path $Outbox ($base + '.tmp')
$final = Join-Path $Outbox ($base + '.json')

[IO.File]::WriteAllText($tmp, ($req | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $final

Write-Host "queued: $final"
