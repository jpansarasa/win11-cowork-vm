# Build Spec — Isolated Win11 VM to Host Claude Cowork (libvirt/KVM)

**For:** Claude Code running on the Linux KVM host.
**Operator:** the human operator (does the interactive Windows install, sign-ins, and all connector logins themselves).
**Goal:** Stand up a purpose-built, segmented Windows 11 guest whose only value is revocable, MFA-gated sessions — no lateral path to the rest of the network, no imported profiles, least-privilege egress.

---

## 0. Design principles (do not violate)

1. **The VM is a thin client, not a vault.** No personal data, no copied browser profiles, no SSH keys to other hosts. Everything of value (ZFS, other lab hosts) stays unreachable from it.
2. **No lateral movement.** The guest must not be able to reach RFC1918 LAN hosts — only the internet endpoints it needs. This is the load-bearing network control.
3. **The capability gate stays in software.** Network isolation caps crude paths; it does not harden the agent's judgment. Keep the standing rule that unattended/scheduled runs produce drafts and proposals only — never outbound/irreversible actions without the operator present to approve.
4. **Least privilege on connectors.** Log into only what's needed, minimum scopes, MFA everywhere.
5. **Disposable.** Snapshot after a clean auth so re-auth/corruption is a rollback, not a rebuild.

---

## 1. Host prerequisites & verification

Run checks first; only proceed if virtualization is present.

```bash
# CPU virtualization present?
egrep -c '(vmx|svm)' /proc/cpuinfo          # >0 expected (Xeon E-2176G => vmx)
# KVM modules loaded?
lsmod | grep -E 'kvm_intel|kvm'
ls -l /dev/kvm
# NESTED virtualization must be on — Cowork's sandbox runs Windows HCS
# (vmcompute/hns/vfpext) inside the guest, which needs Hyper-V in the guest.
cat /sys/module/kvm_intel/parameters/nested    # Y expected (kvm_amd on AMD)
# If N: echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
#       then reload kvm_intel (or reboot) and re-check.
```

Install the stack (Debian/Ubuntu shown; RHEL-family equivalents in parentheses):

```bash
# Debian/Ubuntu
sudo apt update && sudo apt install -y \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst virt-viewer ovmf swtpm swtpm-tools nftables

# RHEL/Fedora equivalent:
# sudo dnf install -y qemu-kvm libvirt virt-install virt-viewer edk2-ovmf swtpm swtpm-tools nftables

sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"   # re-login for group membership
virt-host-validate                     # should pass QEMU/KVM checks
ls /usr/share/OVMF/                     # note exact OVMF_CODE*/VARS* paths — vary by distro
```

**Firmware note for Claude Code:** confirm the actual OVMF secure-boot firmware filename on this distro (`OVMF_CODE.secboot.fd`, `OVMF_CODE_4M.secboot.fd`, etc.). The `--boot uefi` shortcut usually resolves it, but verify.

---

## 2. ISOs to fetch

- **Windows 11** — from Microsoft's official page only (`microsoft.com/software-download/windows11`). Do not use third-party ISOs.
- **virtio-win** — signed guest drivers (Windows has no virtio drivers at install time). Official Fedora location: `fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`.

Place both under `/var/lib/libvirt/images/` (or wherever the pool lives). Verify checksums.

---

## 3. Network segmentation (do this BEFORE creating the VM)

### 3a. Dedicated NAT network

Define an isolated libvirt network on its own subnet so host firewall rules can target it cleanly.

`cowork-net.xml`:
```xml
<network>
  <name>cowork-net</name>
  <forward mode='nat'/>
  <bridge name='virbr-cowork' stp='on' delay='0'/>
  <ip address='10.77.0.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.77.0.10' end='10.77.0.100'/>
    </dhcp>
  </ip>
</network>
```
```bash
virsh net-define cowork-net.xml
virsh net-start cowork-net
virsh net-autostart cowork-net
```

### 3b. Host egress firewall (the high-value control)

The single most important rule: **block the guest subnet from reaching the LAN**, allow only DNS + outbound 80/443. This protects the ZFS/other hosts even if the guest is fully compromised.

`/etc/nftables.d/cowork.nft` (load after libvirt brings up the bridge; libvirt uses its own chains, so hook these into `forward` with higher priority or use a dedicated table):
```
table inet cowork {
  chain forward {
    type filter hook forward priority -10; policy accept;

    # Allow return traffic
    ct state established,related accept

    # HARD BLOCK: all guest IPv6 (v4-only guest — the web accepts below are
    # family-agnostic, so drop v6 first or the guest could reach a v6 host on 443)
    iifname "virbr-cowork" meta nfproto ipv6 counter drop

    # HARD BLOCK: guest -> private LAN (no lateral movement)
    iifname "virbr-cowork" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } \
      counter drop

    # Allow forwarded DNS + outbound web. (Guest->resolver DNS to 10.77.0.1 does
    # NOT pass through here — see the note below — so these dport-53 accepts only
    # ever apply to DNS the guest tries to route elsewhere.)
    iifname "virbr-cowork" udp dport 53 accept
    iifname "virbr-cowork" tcp dport 53 accept
    iifname "virbr-cowork" tcp dport { 80, 443 } accept

    # Everything else from the guest: drop
    iifname "virbr-cowork" counter drop
  }
}
```
```bash
sudo nft -f /etc/nftables.d/cowork.nft
# Verify after VM is up: from guest, a LAN host must be unreachable; the internet must work.
```

> **DNS is not affected by this forward chain — and that's not luck.** The resolver `10.77.0.1` is the host's *own* bridge IP, so guest→resolver DNS is delivered via the **INPUT** hook (governed by libvirt's own rules), never the `forward` hook. The LAN-drop set here contains `10.0.0.0/8` (which covers `10.77.0.0/24`), but that never blocks resolver DNS because that traffic doesn't traverse `forward` at all — the drop only ever sees genuinely-routed guest→LAN traffic, which is exactly what it must block. For the same reason, do **not** "fix DNS" by adding an `ip daddr 10.77.0.1 accept` to this chain: it's inert (this was tried and removed). Guest→host access — including whether the guest may even use the resolver — is controlled by a **separate `input` chain**, not shown here; the authoritative, complete ruleset (both chains, idempotent) is generated by `gen_nft_rules` in `lib/generators.sh`.

### 3c. Optional — true domain allowlist (egress proxy)

L3/L4 rules can't reliably allowlist by hostname (CDN IPs churn). If real domain control is needed (the "diode" on egress), stand up an explicit-allow forward proxy and point the guest at it, then drop direct 80/443 in 3b:

```bash
# Squid sketch (host or a tiny sidecar):
#   acl allowed dstdomain .anthropic.com .claude.com .claude.ai .google.com .googleapis.com \
#                          .gstatic.com .microsoft.com .windowsupdate.com
#   http_access allow allowed
#   http_access deny all
# Then set the Windows guest's system proxy to the Squid host:port.
```
Refine the domain list by observing real traffic (see §3d), then lock it down.

### 3d. Observe-then-tighten (build the allowlist from real traffic)

**Sequence: run permissive + logging → collect for a day or two → generate candidate allowlist → shadow-enforce → hard-enforce.** Never start restrictive; a broken connector mid-run is exactly the false-positive fatigue you want to avoid.

**Step 1 — turn on domain-level logging at the libvirt resolver.** The guest resolves through dnsmasq on `10.77.0.1`, so its query log is the cleanest source of truth for *what domains the app and connectors actually hit*. Add the dnsmasq namespace + options to the network and restart it:

```xml
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>cowork-net</name>
  <forward mode='nat'/>
  <bridge name='virbr-cowork' stp='on' delay='0'/>
  <ip address='10.77.0.1' netmask='255.255.255.0'>
    <dhcp><range start='10.77.0.10' end='10.77.0.100'/></dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='log-queries'/>
    <dnsmasq:option value='log-facility=/var/log/libvirt/cowork-dns.log'/>
  </dnsmasq:options>
</network>
```
```bash
virsh net-edit cowork-net      # paste the additions
virsh net-destroy cowork-net && virsh net-start cowork-net   # apply (guest briefly loses net)
```

**Step 2 — also capture TLS SNI** (catches anything that resolves via hardcoded IP or DoH and never hits dnsmasq):

```bash
sudo tshark -i virbr-cowork -f 'tcp port 443' -Y 'tls.handshake.type == 1' \
  -T fields -e tls.handshake.extensions_server_name 2>/dev/null \
  | grep . | sort -u | tee /var/log/libvirt/cowork-sni.txt
```

**Step 3 — quantify volume** with an nft counter+log rule (optional, tells you the noisy destinations):

```
# add temporarily to the cowork table's forward chain, ABOVE the dport 443 accept:
iifname "virbr-cowork" tcp dport 443 ct state new log prefix "cowork-egress: " counter accept
```
```bash
journalctl -k | grep cowork-egress            # per-connection destinations
sudo conntrack -L -s 10.77.0.0/24 | grep -oP 'dst=\K[0-9.]+' | sort | uniq -c | sort -rn
```

**Step 4 — generate the candidate allowlist.** Aggregate the observed names and eyeball them into `.domain` wildcards (don't auto-trust the collapse — review it):

```bash
# domains the guest actually queried:
grep -oP 'query\[[A-Z]+\] \K[^ ]+' /var/log/libvirt/cowork-dns.log | sort -u > /tmp/dns-domains.txt
# merge with SNI, review by hand:
cat /tmp/dns-domains.txt /var/log/libvirt/cowork-sni.txt | sort -u
```
Convert reviewed entries to Squid `acl allowed dstdomain` lines (leading-dot wildcards, e.g. `.anthropic.com .claude.com .claude.ai .googleapis.com .gstatic.com .microsoft.com`).

**Step 5 — shadow-enforce before you hard-enforce.** Put Squid in front (guest system proxy → Squid) with the allowlist defined but *still allowing everything*, and log the misses. Only flip to deny once a full day shows no legitimate domain outside the list:

```
# squid.conf — shadow phase
acl allowed dstdomain "/etc/squid/cowork-allow.txt"
http_access allow allowed
http_access allow all            # <-- shadow: still permit, but the line above tags matches
# review: requests whose domain is NOT in the allowlist:
#   awk '{print $7}' /var/log/squid/access.log | ... (extract host) | grep -vf /etc/squid/cowork-allow.txt
```
When the miss list is empty for a stable period, delete `http_access allow all`, add `http_access deny all`, and drop the direct-`443` accept from §3b so all egress must traverse the proxy. Keep the dnsmasq log on for a while as a tripwire.

This ordering means the human only ever sees a hard block *after* you've proven the list is complete — no mid-run surprises, no fatigue.

---

## 4. Create the Windows 11 VM

UEFI + Secure Boot + emulated TPM 2.0 are **required** by Windows 11. virtio disk/NIC for performance, with virtio-win mounted for install-time drivers.

```bash
virt-install \
  --name win11-cowork \
  --osinfo win11 \
  --memory 16384 \
  --vcpus 4 \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi \
  --features smm.state=on \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --disk path=/export/coworkvm/win11-cowork.qcow2,size=100,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/Win11.iso,device=cdrom,boot.order=1 \
  --disk path=/var/lib/libvirt/images/virtio-win.iso,device=cdrom \
  --network network=cowork-net,model=virtio \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --graphics spice \
  --video qxl \
  --controller type=usb,model=qemu-xhci \
  --sound none \
  --noautoconsole
```

Notes:
- Older `virt-install` uses `--os-variant win11` instead of `--osinfo win11`.
- If `--boot uefi` doesn't enable Secure Boot on this distro, set it explicitly with the `.secboot` firmware, e.g. `--boot loader=/usr/share/OVMF/OVMF_CODE.secboot.fd,loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=/usr/share/OVMF/OVMF_VARS.fd` plus `--features smm.state=on`.
- 16 GB / 4 vCPU is generous headroom on 32 GB free; drop to 12 GB if you want more host slack.
- **Disk lives on a ZFS dataset** (`tank/coworkvm`, mounted `/export/coworkvm`), not the NVMe libvirt pool — so the golden baseline snapshots and the whole recovery story are ZFS (§9). The ISOs can stay in the libvirt pool.
- **`--channel …guest_agent.0`** wires qemu-guest-agent. It's required, not cosmetic: `virsh domfsfreeze` (the VSS quiesce for an app-consistent snapshot in §9) only works through it. Install `virtio-win-guest-tools.exe` in the guest so the Windows side of the agent is running.

---

## 5. Windows install (operator, interactive)

Attach with the console — **use SPICE/virt-viewer, not RDP** (RDP spawns its own session and detaches the console session the app and scheduled tasks must live in):

```bash
# On the host itself:
virt-viewer --connect qemu:///system win11-cowork

# From a LINUX client — native, or WSL2/WSLg on a Windows desktop. qemu+ssh
# discovers the loopback SPICE port and tunnels it inside your existing SSH:
# no manual `ssh -L`, no pinned port, no new firewall rules.
virt-viewer --connect qemu+ssh://<you>@<host>/system win11-cowork
```

**Console client — use a Linux `virt-viewer` (incl. WSLg on Windows), never the native Windows MSI.** The newest *official* virt-viewer Windows MSI is **11.0 (2021-11-23)** — nothing newer exists. Two independent reasons to avoid it: (1) its spice-gtk/GTK/image-decode stack is frozen at 2021 with years of unpatched memory-safety CVEs in exactly the framebuffer paths a display client exercises; and (2) **it cannot connect over SSH at all** — libvirt's `unix`/`ssh`/`ext` transports are unsupported on Windows (`transport methods unix, ssh and ext are not supported under Windows`), the MSI ships only `libssh2` (which fails at the SSH banner against a modern OpenSSH host — `Failed sending banner`), and `tls`/`tcp` would require opening a new libvirtd port, which §3 forbids. So `?command=ssh` and friends are dead ends on native Windows. Run a **distro-packaged virt-viewer on Linux** instead: natively, or on a Windows desktop via **WSL2 + WSLg** (Windows 11 renders the Linux GUI automatically) —

```bash
# in WSL2 Ubuntu, one-time:
sudo apt install -y virt-viewer
mkdir -p ~/.ssh && chmod 700 ~/.ssh                      # dir needs its x bit or ssh reads nothing inside
cp /mnt/c/Users/<you>/.ssh/id_* ~/.ssh/ && chmod 600 ~/.ssh/id_*   # /mnt/c copies land 755; ssh refuses keys that open
ssh <you>@<host> hostname        # confirms key auth + stores the host key (no password prompt)
# then the qemu+ssh one-liner above works as designed.
```

Keep the SPICE console bound to the host's loopback (the default here) so it is reachable only through the SSH tunnel — nothing but your own qemu can feed the client.

During setup:
1. At disk selection, if no disk appears, **Load driver** → browse the virtio-win CD → `viostor\w11\amd64` (storage), then `NetKVM\w11\amd64` (network) if needed.
2. Choose **local account**, not a Microsoft account — this is a purpose-built box; keep it clean and unlinked. (Use the "no internet / limited setup" path, or `oobe\bypassnro` if the offline option is hidden.)
3. Minimal everything: decline telemetry-heavy options, no OneDrive, no restore-from-backup, **do not sign into any personal accounts yet**.

Post-first-boot, install guest tools from the virtio-win CD: run `virtio-win-guest-tools.exe` (balloon, qemu-ga, NIC).

### 5a. File transfer — SPICE shared folder (local, both directions)

Move files between a local machine and the guest over the **same** SPICE-over-SSH
console tunnel — no firewall change, no extra ports. The share is live **only while
`virt-viewer` is connected**, so it never widens the unattended attack surface.

**Guest side — two parts.** `guest/postboot.ps1` ensures the stock **`WebClient`**
(WebDAV redirector) is Automatic + running, and *checks* for **`spice-webdavd`**. It
does **not** install `spice-webdavd`: verified on a real guest, neither the
spice-space.org MSI nor the virtio-win guest tools carry an embedded Authenticode
signature (only the virtio-win *drivers* are catalog-signed), so "download and verify"
is impossible — and auto-fetching an unsigned binary onto this box is a trust this
build declines. Install it once, by hand:

```
https://www.spice-space.org/download/windows/spice-webdavd/spice-webdavd-x64-latest.msi
```

**Upstream ships this MSI unsigned** — install it knowingly, then re-run
`postboot.ps1` to have the service set Automatic and started. Confirm:

```powershell
Get-Service spice-webdavd, WebClient   # both Running
```

If `spice-webdavd` is absent, `postboot.ps1` prints the URL and this caveat rather
than failing — the rest of the guest config is valid without it; only the shared
folder is unavailable.

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
> §8a "Reaching the operator remotely" (ntfy). SPICE is the local, attended path only.

---

## 6. Post-first-boot configuration (24/7 unattended hosting)

This is the whole guest-side config, in order. The **mechanical, non-interactive** steps are scripted — run **`guest/postboot.ps1`** once in an **elevated** PowerShell inside the guest (idempotent; `-DryRun` previews the debloat, `-TimeZone '<zone>'` overrides the default). The rest stays manual **by design** — credentials and Cowork/connector auth are never driven by a script (see Design principle: connectors are manual).

**Checklist (in order):**
1. **Guest tools** — install `virtio-win-guest-tools.exe` from the virtio-win CD (qemu-ga + SPICE + NIC/balloon). **qemu-ga is load-bearing**: host snapshots (`domfsfreeze`) and time-sync (`domtime`) go through it.
2. **Mechanical config** — `powershell -ExecutionPolicy Bypass -File .\postboot.ps1` (elevated). It does: no sleep/hibernate/monitor-off, no inactivity auto-lock, no auto-reboot while logged on, disable Windows Time, set timezone, enable the HCS features (Hyper-V / Containers / VirtualMachinePlatform), a curated **debloat**, ensures the `WebClient` WebDAV redirector, and *checks* for `spice-webdavd` (printing install instructions if absent — it never downloads an installer). No outbound fetch.
3. **Confirm firmware:** `Get-Tpm` (TpmReady = True), `Confirm-SecureBootUEFI` (True). After the later reboot, `Get-Service vmcompute, hns` should both be Running (vfpext loads on demand).
4. **Autologon** — **Sysinternals Autologon** (stores the credential via LSA, not plaintext registry; sidesteps the hidden `netplwiz` checkbox on Win11 local accounts). Makes reboots self-healing. *[manual — credential]*
5. **Claude** — install from **https://claude.com/download**, sign in, enable Cowork, then Advanced options → *Runs at log-in* = **On** and *Let this app run in background* = **Always** (see the launch-at-logon note below). *[manual — auth]*
6. **Connectors** — §8, least privilege + MFA. *[manual — auth]*
7. **Reboot** — applies the HCS features; verify the self-heal (autologon → Claude launches in the console session → clock correct), then **re-snapshot on the host** (§9).

**Never uninstall (the debloat's KEEP-list, and don't remove them by other means either):** the **QEMU guest agent / VirtIO guest tools** and **SPICE tools** (removing them silently breaks snapshots, host time-sync, and the console), a **browser** (Edge — Cowork's browser control and connector logins need one), and **Claude**. These aren't Appx packages, so `postboot.ps1`'s debloat can't reach them — the guard is belt-and-suspenders.

**Windows Features (`optionalfeatures.exe`) — nothing to turn off.** On a current Win11 the deprecated/wormable components (SMB 1.0, Telnet, TFTP, WSL1, IIS, NFS, MSMQ, Simple TCPIP…) are already unchecked by default. **Keep on:** Hyper-V, Containers, Virtual Machine Platform (the HCS requirement). *Windows Hypervisor Platform* can stay off — it's for third-party hypervisors, not Cowork.

- **Nested virt is a hard dependency here:** if the host didn't enable `kvm_intel nested=1` (§1), the HCS features install but the services fail to start and Cowork reports `Missing hcs services: hns, vmcompute, vfpext`. Fix it on the host, not in the guest.

- **Autologon (console session):** acceptable on the isolated box. Prefer **Sysinternals Autologon** (stores the credential via LSA rather than plaintext registry) over `netplwiz`. This makes reboots self-healing.
- **Disable the lock screen timeout** so the console session doesn't lock out from under the app.
- **Windows Update:** set active hours and "notify to restart" so it can't surprise-reboot mid-task. With autologon + app-at-startup, a reboot recovers on its own anyway.
- **Launch Cowork at logon:** use Claude's **own "Runs at log-in" toggle** — Settings → Apps → Installed apps → **Claude** → Advanced options → *Runs at log-in* → **On** (and set *Let this app run in background* = **Always**). It registers a per-user logon **startup task**: it fires in the interactive console session (what Cowork needs — a *service* wouldn't be in the session SPICE shows) and survives app updates (unlike a shortcut pinned to a version-stamped `claude.exe`). Fallbacks only if that toggle is ever missing: a shortcut in `shell:startup`, or a Task Scheduler task "At log on of <user>" — **never** "at startup" or "run whether the user is logged on or not", which detach from the console session.
- **Time sync — the guest can't use NTP.** The cowork firewall drops UDP 123, so Windows Time never reaches a server ("Last successful time synchronization: unspecified") and the clock free-runs/drifts. Don't punch an NTP hole; the **host pushes its NTP-correct time into the guest via qemu-guest-agent** (the `35-timesync` stage installs `cowork-timesync.timer` on the host — boot + hourly `virsh domtime … --time`). In fact you can turn the guest's Windows time sync **off entirely** (Date & time → *Set time automatically* Off, or disable the `w32time` service) — cleaner, no failed `time.windows.com` attempts. The host push uses the **explicit `--time` epoch form**, which calls the guest's `SetSystemTime` directly and works **even with w32time stopped/disabled** (verified). Only `virsh domtime --sync` needs w32time running — and it no-ops here anyway (the `<clock offset='localtime'>` interaction), so don't use it. Leave the guest timezone correct; the host only sets UTC.

---

## 7. Install Claude Cowork

1. In the guest browser, download the Claude desktop app from the **official** page only: **https://claude.com/download** (Windows). Do not fetch from third parties.
2. Install, launch, sign in with the operator's account.
3. Enable/enter **Cowork** (research preview inside the desktop app) — see the getting-started article in Sources. Confirm the account has access to the Cowork preview.
4. If using browser control (Claude in Chrome), install the Chrome extension in the guest's browser — a fresh profile, not an import.

---

## 8. Connector logins (operator, least privilege)

- Log into **only** the services actually needed (e.g., Google for Gmail/Drive/Calendar). Start from a clean browser profile — **do not copy or import** the desktop Chrome profile.
- Scope connectors minimally (draft/label over full-send where the option exists; read-only Drive if write isn't required). Drive is optional given the ZFS store — skip it if not needed.
- MFA on every account. Note that these sessions are the only asset on the box and are revocable in seconds from outside if anything looks off.

### 8a. Reaching the operator remotely (ntfy — outbound only)

When Cowork needs the operator while they're away, it sends a **one-way** ntfy
notification (optionally with a file attachment) straight from the guest over its
existing 443 egress. This is the natural complement to the capability gate:
unattended runs can't *act* irreversibly, but they *can* say "I'm blocked" or
"here's a draft."

**Hard rule — outbound only.** The guest publishes; it **never subscribes**. A
subscribe path would be a command channel *into* the guest. `guest/notify.ps1`
has no read/poll path; keep it that way.

**One-time setup:**
> **Gotcha — a self-hosted endpoint the guest cannot reach (split-horizon DNS).**
> If the ntfy host is self-hosted behind the same router, its name very likely
> resolves *internally* to a LAN address (the router/reverse proxy). The guest sits
> inside that LAN, gets the LAN answer, and the cage correctly drops it as lateral
> movement — `notify.ps1` then fails with `Unable to connect to the remote server`.
> Verify first:
>
> ```powershell
> Resolve-DnsName <ntfy-host> -Type A     # RFC1918 answer => the guest cannot reach it
> ```
>
> Fix without weakening the cage: point the guest at the **public** address via
> `DNS_OVERRIDES` in `config.env` (emitted as a libvirt `<dns><host>` entry by
> `gen_net_xml`, so it survives `recover.sh`). This requires **NAT reflection /
> hairpin** enabled on the gateway, or the guest's traffic to the WAN address will
> simply time out. **Do not** instead allow guest→LAN for the ntfy host: on a typical
> setup that address is the router itself, the highest-value target on the network.
>
> **Dynamic WAN address:** a pinned IP goes stale on renumber, and notifications
> then stop **silently** — the guest just resolves a dead address, with no error
> anywhere until you notice the pings stopped. Set `DNS_WAN_HOSTS` in
> `config.local.env` and stage `36-wandns` installs a host-side timer
> (`cowork-wandns`, every 15 min) that re-points those entries at the current
> public IP, updating libvirt `--live --config`. Leave `DNS_WAN_HOSTS` empty and
> the timer is not installed at all.
>
> Site-specific values (your hostname, your WAN IP) belong in **`config.local.env`**
> — gitignored — not in the tracked `config.env`. See `config.local.env.example`.

1. In ntfy, pick a **hard-to-guess topic** (e.g. `cowork-7f3a…`) and create a
   **publish-only access token** scoped to just that topic (ntfy: *Account →
   Access tokens*, then a topic ACL granting write-only). This token is the one
   sanctioned secret in the guest (buildspec principle #1 exception): publish-only,
   single-topic, revocable in seconds.
2. In the guest, write `%ProgramData%\cowork\ntfy.json` (see
   `guest/ntfy.json.example`) with the topic URL + token. Lock it down:
   ```powershell
   New-Item -ItemType Directory -Force -Path "$env:ProgramData\cowork" | Out-Null
   # paste url+token into $env:ProgramData\cowork\ntfy.json, then:
   $agent = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').DefaultUserName
   icacls "$env:ProgramData\cowork\ntfy.json" /inheritance:r `
     /grant:r "${agent}:(R)" "BUILTIN\Administrators:(F)" "SYSTEM:(F)"
   ```
   Two things this gets right, both learned the hard way:
   - The grant **must name the account Cowork actually runs as** (the autologon user).
     Cowork invokes the helper **non-elevated**, so its filtered token has the
     Administrators group deny-only — an Administrators-only ACL silently denies it.
   - The agent account gets **`R`**, but Administrators/SYSTEM get **`F`**. Granting
     `R` to *everyone* (as an earlier version of this doc did) makes the file
     unwritable by anyone, so **token rotation fails** with `Access to the path ... is
     denied` — you then have to fix the DACL before you can replace a revoked token.
     Read-only for the agent is the security intent; full control for admins is what
     makes the credential rotatable.
3. Copy `guest/notify.ps1` into `C:\cowork\` in the guest (the §5a SPICE share is the
   easy way to get it there). Subscribe to the topic on your phone (ntfy app) and send
   a test:
   ```powershell
   C:\cowork\notify.ps1 -Title 'test' -Message 'hello from the guest'
   ```

**Wiring Cowork to it (documented command).** Cowork invokes the helper through its
normal command execution — no MCP, no extension API. Give Cowork a standing
instruction, e.g.:

> To notify the operator, run:
> `powershell -ExecutionPolicy Bypass -File C:\cowork\notify.ps1 -Title "<short>" -Message "<detail>" [-Priority high] [-File "<path>"]`
> Use it when blocked awaiting approval, or to hand over a finished draft (`-File`).
> Never attempt to read or subscribe to ntfy — this channel is outbound only.

**Residual risk (documented, not hidden):** a prompt-injected Cowork could use the
notification body/attachment as an exfil channel — but the guest already has full
443 egress, so this adds convenience, not a new capability. Bounded by: publish-only
scope, a hard-to-guess topic, and instant token revocation.

> This is the *remote* channel. Local, attended file moves use the SPICE shared
> folder — see §5a.

---

## 9. Verify, then snapshot

Checklist:
- `Get-Tpm` / `Confirm-SecureBootUEFI` both good; VM boots UEFI.
- From the guest: a known LAN host (e.g. the ZFS box) is **unreachable** (`Test-NetConnection <lan-ip>` fails); the internet works.
- App launches automatically in the console session after a reboot.
- Connectors authenticate; a test scheduled run produces **drafts/reports only**, no outbound actions.

Then snapshot the clean, authed state — this is the **golden baseline** the whole
"recovery is a rollback" design rests on. The disk and the exported domain XML both
live on the `tank/coworkvm` dataset, so one ZFS snapshot captures them atomically.
`scripts/90-snapshot.sh` does exactly this: export XML → VSS-quiesce → snapshot → thaw.

```bash
sudo ./scripts/90-snapshot.sh
# equivalently, by hand:
#   virsh dumpxml win11-cowork > /export/coworkvm/state/win11-cowork.domain.xml
#   virsh domfsfreeze win11-cowork          # VSS quiesce via qemu-ga -> "Froze N filesystem(s)"
#   zfs snapshot tank/coworkvm@clean-authed
#   virsh domfsthaw  win11-cowork
```

Recovery (`recover.sh`) is the inverse: get the dataset back to the baseline first, then
rebuild scaffolding + re-import the domain.
- Same host, disk intact: `zfs rollback tank/coworkvm@clean-authed` (VM off).
- Dead pool / new host: `zfs send` the snapshot offsite; restore with `zfs recv` before recovering.

---

## 10. Open items to verify (don't assume)

- **Cowork preview availability** on the operator's account/plan — confirm in the app; the desktop app installs regardless but the Cowork feature may be gated.
- **Exact egress endpoint list** for the app + connectors — hostnames aren't hardcoded beyond the obvious (`anthropic.com`, `claude.com`, `claude.ai`, Google, Microsoft). Run the VM for a day with §3b permissive on 443, capture destinations (`conntrack`, Squid logs, or `nft` counters + a passive DNS log), then tighten §3c to the observed set.
- **Whether connectors broker server-side** (through claude.ai) vs. call out directly from the guest — this changes how much egress the guest itself needs. Observe before locking down hard, or you'll break connectors and chase ghosts.
- **Firmware paths / virt-install flag dialects** vary by distro version — Claude Code should confirm on the actual host rather than trust the exact strings above.

---

*Sources: [Download Claude](https://claude.com/download) · [Install Claude Desktop](https://support.claude.com/en/articles/10065433-install-claude-desktop) · [Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows) · [Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)*
