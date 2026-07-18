# Build Spec — Isolated Win11 VM to Host Claude Cowork (libvirt/KVM)

**For:** Claude Code running on the Linux KVM host.
**Operator:** James (does the interactive Windows install, sign-ins, and all connector logins himself).
**Goal:** Stand up a purpose-built, segmented Windows 11 guest whose only value is revocable, MFA-gated sessions — no lateral path to the rest of the network, no imported profiles, least-privilege egress.

---

## 0. Design principles (do not violate)

1. **The VM is a thin client, not a vault.** No personal data, no copied browser profiles, no SSH keys to other hosts. Everything of value (ZFS, other lab hosts) stays unreachable from it.
2. **No lateral movement.** The guest must not be able to reach RFC1918 LAN hosts — only the internet endpoints it needs. This is the load-bearing network control.
3. **The capability gate stays in software.** Network isolation caps crude paths; it does not harden the agent's judgment. Keep the standing rule that unattended/scheduled runs produce drafts and proposals only — never outbound/irreversible actions without James present to approve.
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

L3/L4 rules can't reliably allowlist by hostname (CDN IPs churn). If James wants real domain control (the "diode" on egress), stand up an explicit-allow forward proxy and point the guest at it, then drop direct 80/443 in 3b:

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

## 5. Windows install (James, interactive)

Attach with the console — **use SPICE/virt-viewer, not RDP** (RDP spawns its own session and detaches the console session the app and scheduled tasks must live in):

```bash
# On the host itself:
virt-viewer --connect qemu:///system win11-cowork

# From a workstation — tunnels SPICE inside your existing SSH access, no new ports/rules:
virt-viewer --connect qemu+ssh://<you>@<host>/system win11-cowork
```

**Console client (security):** run **distro-packaged `virt-viewer` on a Linux machine**, where its spice-gtk/GTK/GLib/GStreamer dependencies are current and CVE-patched. **Avoid the Windows MSI (11.0, 2021)** — its bundled parsing stack is frozen at 2021 and carries years of unpatched memory-safety CVEs in exactly the framebuffer/image-decode paths a display client exercises. Keep the SPICE console bound to the host's loopback (the default here) so it is reachable only through the SSH tunnel — nothing but your own qemu can feed the client.

During setup:
1. At disk selection, if no disk appears, **Load driver** → browse the virtio-win CD → `viostor\w11\amd64` (storage), then `NetKVM\w11\amd64` (network) if needed.
2. Choose **local account**, not a Microsoft account — this is a purpose-built box; keep it clean and unlinked. (Use the "no internet / limited setup" path, or `oobe\bypassnro` if the offline option is hidden.)
3. Minimal everything: decline telemetry-heavy options, no OneDrive, no restore-from-backup, **do not sign into any personal accounts yet**.

Post-first-boot, install guest tools from the virtio-win CD: run `virtio-win-guest-tools.exe` (balloon, qemu-ga, NIC).

---

## 6. Windows configuration for 24/7 unattended hosting

Run from an elevated PowerShell / cmd:

```powershell
# Never sleep / hibernate / blank in a way that suspends the session
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off

# Confirm TPM + Secure Boot took
Get-Tpm                      # TpmPresent/TpmReady = True
Confirm-SecureBootUEFI       # True

# Cowork's sandbox is Windows HCS (vmcompute/hns/vfpext) — it needs the guest's
# own virtualization stack. Enable it (reboot when prompted), then confirm.
Enable-WindowsOptionalFeature -Online -All -NoRestart -FeatureName `
  Microsoft-Hyper-V, Containers, VirtualMachinePlatform
# after reboot:
Get-Service vmcompute, hns   # both Running  (vfpext loads on demand)
```

- **Nested virt is a hard dependency here:** if the host didn't enable `kvm_intel nested=1` (§1), these guest features install but the HCS services fail to start and Cowork reports `Missing hcs services: hns, vmcompute, vfpext`. Fix it on the host, not in the guest.

- **Autologon (console session):** James is fine with this on the isolated box. Prefer **Sysinternals Autologon** (stores the credential via LSA rather than plaintext registry) over `netplwiz`. This makes reboots self-healing.
- **Disable the lock screen timeout** so the console session doesn't lock out from under the app.
- **Windows Update:** set active hours and "notify to restart" so it can't surprise-reboot mid-task. With autologon + app-at-startup, a reboot recovers on its own anyway.
- **Launch Cowork at logon:** put a shortcut in `shell:startup`, or a Task Scheduler task "At log on of <user>" (not "at startup" — it must be in the interactive console session).

---

## 7. Install Claude Cowork

1. In the guest browser, download the Claude desktop app from the **official** page only: **https://claude.com/download** (Windows). Do not fetch from third parties.
2. Install, launch, sign in with James's account.
3. Enable/enter **Cowork** (research preview inside the desktop app) — see the getting-started article in Sources. Confirm the account has access to the Cowork preview.
4. If using browser control (Claude in Chrome), install the Chrome extension in the guest's browser — a fresh profile, not an import.

---

## 8. Connector logins (James, least privilege)

- Log into **only** the services actually needed (e.g., Google for Gmail/Drive/Calendar). Start from a clean browser profile — **do not copy or import** the desktop Chrome profile.
- Scope connectors minimally (draft/label over full-send where the option exists; read-only Drive if write isn't required). Drive is optional given the ZFS store — skip it if not needed.
- MFA on every account. Note that these sessions are the only asset on the box and are revocable in seconds from outside if anything looks off.

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

- **Cowork preview availability** on James's account/plan — confirm in the app; the desktop app installs regardless but the Cowork feature may be gated.
- **Exact egress endpoint list** for the app + connectors — I did not hardcode hostnames beyond the obvious (`anthropic.com`, `claude.com`, `claude.ai`, Google, Microsoft). Run the VM for a day with §3b permissive on 443, capture destinations (`conntrack`, Squid logs, or `nft` counters + a passive DNS log), then tighten §3c to the observed set.
- **Whether connectors broker server-side** (through claude.ai) vs. call out directly from the guest — this changes how much egress the guest itself needs. Observe before locking down hard, or you'll break connectors and chase ghosts.
- **Firmware paths / virt-install flag dialects** vary by distro version — Claude Code should confirm on the actual host rather than trust the exact strings above.

---

*Sources: [Download Claude](https://claude.com/download) · [Install Claude Desktop](https://support.claude.com/en/articles/10065433-install-claude-desktop) · [Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows) · [Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)*
