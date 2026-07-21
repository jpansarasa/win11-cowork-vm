#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  postboot.ps1 - mechanical post-first-boot config for the Cowork Windows guest.

  Run ONCE in an ELEVATED PowerShell inside the guest. Idempotent - safe to re-run.
  The operator runs this by hand; Claude/host never drives it. It covers only the
  non-interactive, mechanical bits so a rebuild isn't a full re-derivation.

  It deliberately does NOT do (these stay manual - see buildspec "Post-first-boot"):
    - Autologon (stores an LSA credential - use Sysinternals Autologon)
    - virtio-win guest tools install (interactive; also provides qemu-ga + SPICE)
    - Claude: install, sign in, enable Cowork, toggle "Runs at log-in"
    - Connector logins (least privilege, MFA)

  Usage:
    powershell -ExecutionPolicy Bypass -File .\postboot.ps1              # apply
    powershell -ExecutionPolicy Bypass -File .\postboot.ps1 -DryRun      # preview debloat, change nothing
    powershell -ExecutionPolicy Bypass -File .\postboot.ps1 -TimeZone 'Pacific Standard Time'
#>
param(
  [string]$TimeZone = 'Eastern Standard Time',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Note($m) { Write-Host "[postboot] $m" }
function Do-Step($m, [scriptblock]$b) { Note $m; if (-not $DryRun) { & $b } else { Note '  (dry-run: skipped)' } }

# 1) Never sleep / hibernate / blank - this is a 24/7 console session.
Do-Step 'power: no sleep/hibernate/monitor-timeout on AC' {
  powercfg /change standby-timeout-ac 0
  powercfg /change hibernate-timeout-ac 0
  powercfg /change monitor-timeout-ac 0
  powercfg /hibernate off
}

# 2) Don't let the console lock out from under Cowork.
Do-Step 'lock: disable inactivity auto-lock + screensaver' {
  # Machine inactivity limit = 0 (never auto-lock the interactive session).
  reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    /v InactivityTimeoutSecs /t REG_DWORD /d 0 /f | Out-Null
  reg add 'HKCU\Control Panel\Desktop' /v ScreenSaveActive /t REG_SZ /d 0 /f | Out-Null
  reg add 'HKCU\Control Panel\Desktop' /v ScreenSaverIsSecure /t REG_SZ /d 0 /f | Out-Null
}

# 3) Windows Update must not surprise-reboot mid-task (autologon recovers, but still).
Do-Step 'windows update: no auto-reboot while a user is logged on' {
  reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' `
    /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null
}

# 4) Time: the guest can't reach NTP (host firewall drops UDP 123). Disable the
#    Windows Time client so it stops churning on failed time.windows.com syncs.
#    The HOST pushes correct time in via qemu-guest-agent (host stage 35-timesync);
#    that uses `virsh domtime --time`, which works with w32time disabled.
Do-Step 'time: disable Windows Time (host pushes time via qemu-ga)' {
  sc.exe config w32time start= disabled | Out-Null
  sc.exe stop w32time 2>$null | Out-Null
}

# 5) Timezone (host only sets UTC; the guest owns its display TZ).
Do-Step "time: set timezone '$TimeZone'" { tzutil /s $TimeZone }

# 6) Enable the Windows HCS stack Cowork's sandbox needs.
#    Requires host nested-virt (kvm_intel nested=1) or the services won't start
#    (Cowork would report: Missing hcs services: hns, vmcompute, vfpext).
Do-Step 'features: enable Hyper-V, Containers, VirtualMachinePlatform (reboot after)' {
  Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName `
    Microsoft-Hyper-V, Containers, VirtualMachinePlatform | Out-Null
}

# 7) Debloat - remove ONLY explicitly-listed consumer apps (curated allow-to-remove).
#    A hard KEEP guard skips anything critical even if a pattern somehow matched.
#    NOTE: qemu-ga / SPICE tools / Claude are NOT Appx packages, so Remove-AppxPackage
#    can't touch them regardless - the guard is belt-and-suspenders.
$RemovePatterns = @(
  'Microsoft.Xbox*','Microsoft.GamingApp','Microsoft.549981C3F5F10',   # Xbox, Cortana
  'Clipchamp.Clipchamp','Microsoft.BingNews','Microsoft.BingWeather',
  'Microsoft.MicrosoftSolitaireCollection','Microsoft.Todos',
  'Microsoft.PowerAutomateDesktop','Microsoft.WindowsFeedbackHub',
  'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub',
  'Microsoft.SkypeApp','Microsoft.People','Microsoft.windowscommunicationsapps',
  'Microsoft.ZuneMusic','Microsoft.ZuneVideo','MicrosoftTeams','MSTeams',
  'Microsoft.YourPhone','Microsoft.WindowsMaps','Microsoft.MixedReality.Portal',
  'Microsoft.Windows.DevHome','Microsoft.OutlookForWindows'
)
$KeepGuard = 'qemu|spice|virtio|claude|edge|nvidia|vclibs|framework|\.net|store|xaml|runtime|sechealth|defender|terminal|calculator|notepad|photos|snip|screensketch'

Note 'debloat: removing curated consumer apps (KEEP guard active)'
foreach ($pat in $RemovePatterns) {
  Get-AppxPackage -AllUsers $pat -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match $KeepGuard) { Note "  SKIP (keep-guard): $($_.Name)"; return }
    if ($DryRun) { Note "  would remove: $($_.Name)"; return }
    # Per-item try/catch: some inbox/framework packages (e.g. XboxGameCallableUI)
    # are protected and error 0x80070032 on removal. Skip those, never abort.
    try {
      Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
      Note "  removed: $($_.Name)"
    } catch {
      Note "  SKIP (not removable): $($_.Name)"
      return
    }
    Get-AppxProvisionedPackage -Online |
      Where-Object DisplayName -EQ $_.Name |
      ForEach-Object {
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null } catch { }
      }
  }
}

# 8) WebDAV redirector - required for the SPICE shared folder to map as a drive.
#    Ensured UNCONDITIONALLY and BEFORE the spice-webdavd check: WebClient is a stock
#    Windows service, independent of spice-webdavd, and a missing/failed webdavd must
#    never leave it unconfigured (it did, in the first real run - the throw skipped it).
Do-Step 'WebClient: WebDAV redirector Automatic + running' {
  Set-Service -Name 'WebClient' -StartupType Automatic
  if ((Get-Service WebClient).Status -ne 'Running') { Start-Service WebClient }
}

# 9) SPICE WebDAV daemon - the guest half of host<->guest file transfer via
#    virt-viewer "Share folder". Attended-only: the share is live only while a
#    virt-viewer console with a shared folder is connected.
#
#    DETECT AND INSTRUCT - deliberately NOT auto-installed. Verified on a real guest:
#    neither the spice-space.org MSI nor the virtio-win guest tools (nor the installed
#    qemu-ga.exe) carry an embedded Authenticode signature - only the virtio-win
#    *drivers* are catalog-signed. So "download, verify the signature, install" can
#    never succeed here, and auto-fetching an UNSIGNED binary onto this box is exactly
#    the trust this build refuses. The operator installs it once, knowingly.
Do-Step 'spice-webdavd: check (host<->guest file share)' {
  $svc = Get-Service -Name 'spice-webdavd' -ErrorAction SilentlyContinue
  if ($svc) {
    Set-Service -Name 'spice-webdavd' -StartupType Automatic
    if ((Get-Service spice-webdavd).Status -ne 'Running') { Start-Service spice-webdavd }
    Note '  present; Automatic + running'
  } else {
    # Not fatal: the rest of the guest config is valid without it. Warn loudly.
    Note '  NOT INSTALLED - the SPICE shared folder will not work until you install it.'
    Note '  Install once, by hand (buildspec 5a):'
    Note '    https://www.spice-space.org/download/windows/spice-webdavd/spice-webdavd-x64-latest.msi'
    Note '  Upstream ships this MSI UNSIGNED (verified) - install it knowingly, then'
    Note '  re-run this script to have the service set Automatic and started.'
  }
}

Note ''
Note 'DONE (mechanical). Still MANUAL - see buildspec "Post-first-boot":'
Note '  1. virtio-win guest tools (qemu-ga + SPICE) - if not already installed'
Note '  2. Autologon (Sysinternals Autologon)'
Note '  3. Claude: install, sign in, enable Cowork, Advanced options -> Runs at log-in = On'
Note '  4. Connector logins (least privilege, MFA)'
Note '  5. Reboot (applies HCS features), verify self-heal, then re-snapshot on the HOST'
