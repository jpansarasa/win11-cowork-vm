# Design — Remote Notification (file optional) via ntfy

**Date:** 2026-07-19
**Status:** Approved (brainstorming)
**Companion doc:** `win11-cowork-vm-buildspec.md` (adds a "Reaching the operator remotely" subsection)

---

## REVISED 2026-07-20 — direct post replaced by a host-mediated relay

Everything below this line describes the **original** design, in which the guest
POSTed to ntfy itself. That design was implemented, taken to a live guest, and
**failed**: the self-hosted ntfy resolves to a LAN address (a reverse proxy on the
router), and the cage correctly drops guest→LAN as lateral movement. The premise
"the guest already has 443 egress, so it can post directly" is true in general and
false for a self-hosted endpoint.

The workarounds were worse than the problem — punching a hole to the router, or
pinning a public address and maintaining it against a dynamic IP. The shipped
design instead **spools in the guest and publishes from the host**:

```
guest: notify.ps1 -> %ProgramData%\cowork\outbox\*.json
                          | (qemu-guest-agent; host pulls)
host:  cowork-notify-relay -> https://<ntfy-host>/<topic> -> phone
```

What changed, and why it is better than what this spec originally proposed:

- **The guest holds no credential.** The token is root-only on the host. This
  *removes* the "one sanctioned secret in the guest" exception that section 3
  below had to argue for — the exception is simply gone.
- **The one-way property is structural.** The guest has no token, no URL, and no
  network path to ntfy. It cannot subscribe even if its code were altered; the
  original design relied on us not writing a subscribe path.
- **Nothing to maintain.** No DNS override, no pinned address, no router or
  firewall change.
- **Delivery is durable.** A failed publish leaves the request queued and retries;
  a malformed one is quarantined rather than retried forever.

Costs accepted: notifications arrive on a poll interval (default 1 min) rather
than instantly, and attachments are capped at 2 MB because they ride inline
through the agent channel. Large files use the SPICE share (Problem 1).

Retained from the original design and verified live: RFC 2047 encoding for
non-ASCII headers (ntfy decodes it — confirmed in ntfy's own message store),
`-DryRun`, fail-loud behaviour, and the publish-only single-topic token, whose
scoping was proven by test (publish 200 / read 403 / other-topic 403) and whose
revocation was proven to fail loud (HTTP 401) and then rotate cleanly.

---

## Purpose

Let **Cowork / the guest reach the operator when they're away** (phone), to **notify** — and optionally **hand over a file** (a draft it produced) as an attachment on the same channel. This is **Problem 2** in the decomposition: outbound, remote, guest-originated. It is entirely separate from local file transfer (Problem 1, SPICE — its own spec). The optional attachment is a bonus on the notification channel, **not** a second mechanism.

This is the natural complement to the capability gate: unattended runs can't take irreversible **actions**, but they *can* reach the operator to say "I'm blocked" or "here's a draft for review" — which is what makes unattended runs actually useful.

## The setup that makes this cheap

The pattern assumes a **publicly-reachable ntfy instance on 443** (self-hosted or ntfy.sh). The guest already has **unrestricted 443 egress** (that's how it browses and reaches Claude). So a POST to `https://<ntfy-host>/<topic>` adds **no new network capability** and needs **no cage change and no host courier** — the guest posts directly. (Host-mediation was considered and dropped: the trigger originates *in* the guest, so mediation would force the host to *poll* a guest outbox — laggy and clunky, for no security gain given the guest already owns 443.)

## Three load-bearing design decisions

1. **Outbound-only. The guest never *subscribes*.** This is the security of the whole thing. If the guest subscribed to the topic for "commands," the design would have a **C2 channel *into* the guest** — anyone with the topic could push instructions to Cowork. ntfy stays a one-way pipe **out**. This is a hard constraint, not a default.

2. **Publish-only token, single topic.** The credential in the guest can *only publish to this one topic* — cannot read, cannot subscribe, cannot touch other topics. Blast radius if the disposable guest is compromised = someone can spam that one topic to the operator's phone. Revoke/rotate in seconds from ntfy. The token lives in a **guest-local config file created by the operator, never in the repo**, with locked-down perms.

3. **This is the one sanctioned secret in the guest.** It nudges against "no secrets in the guest" (buildspec constraint #3), so it is documented as a **conscious, scoped exception** — publish-only + revocable + single-topic is the justification — rather than allowed to become silent drift. Connector sessions already live in the guest, so one publish-only token is consistent with the existing trust model.

## Honest residual risk

A prompt-injected Cowork could use notification bodies/attachments as an exfil channel. But the guest **already has full 443 egress to the internet**, so this adds *convenience*, not a *new* capability. Documented, not pretended away. Mitigations that keep it bounded: publish-only scope, a hard-to-guess topic name (defense in depth even with a token), and the token being trivially revocable.

## Architecture

```
Guest
  └─ guest/notify.ps1   ── HTTPS POST (443) ──►  https://<ntfy-host>/<topic>  ──►  operator's phone (ntfy app)
       reads guest-local config:                    (public, TLS)
         - topic URL
         - publish-only token
       args: title, message, priority, tags, [-File <path>]
```

**Direction:** guest → operator only. No inbound. No subscription. No host involvement.

## Components

1. **`guest/notify.ps1`** — shipped in the repo like `guest/postboot.ps1` (the operator copies it into the guest). Behavior:
   - Reads topic URL + token from a **local config file** (path documented; example `%ProgramData%\cowork\ntfy.json`); the file itself is **not** in the repo and is git-ignored by pattern.
   - POSTs via `Invoke-RestMethod` with `Authorization: Bearer <token>`, setting ntfy headers for `Title`, `Priority`, `Tags`.
   - `-File <path>` (optional) attaches a file on the same request (ntfy attachment via `PUT`/`Filename`), respecting the server's configured attachment size limit (operator-controlled — noted, not enforced client-side beyond a friendly error).
   - Fails **loudly** on a non-2xx response or missing config — no silent swallow (consistent with the repo's silent-failure stance). Prints the ntfy error body.
   - Idempotent to run; holds no state.

2. **Config file (operator-created, not in repo).** Documents required keys (`url`, `token`) and file permissions. A `.gitignore` entry guards the pattern so a stray copy can't be committed.

3. **Exposure to Cowork.** Wire the helper so Cowork can call it — "notify the operator", "send the operator a file". Exact wiring (a Cowork tool/action vs. a documented command Cowork invokes) is an implementation detail for the plan; the spec's requirement is only that it be callable and that it remain **publish-only/outbound**.

4. **Docs — buildspec "Reaching the operator remotely" subsection.** How to create the publish-only token + topic in ntfy, where the config file goes, the outbound-only/no-subscribe rule stated as a constraint, the sanctioned-secret exception, and the residual-risk note.

## Error handling

- **Missing/invalid config** → helper dies loudly with a clear message; no silent no-op.
- **Non-2xx from ntfy** (bad token, revoked, topic typo, oversize attachment) → surface the HTTP status + ntfy body; do not swallow.
- **Attachment over server limit** → friendly error naming the limit; raise it server-side if needed.
- **No network / DNS** → surfaced as the request exception; expected only if the whole 443 path is down.

## Verification (manual — no bats)

1. Create a publish-only token + topic in ntfy; subscribe on the phone.
2. `notify.ps1 -Title "test" -Message "hello"` → arrives on the phone.
3. `notify.ps1 -Title "draft" -Message "review" -File <somefile>` → attachment arrives on the phone.
4. Revoke the token in ntfy → confirm the helper now fails loudly (token scoping/revocation verified).
5. Confirm the guest **cannot** subscribe (no subscribe path exists in the helper; design check, not a runtime test).

## Relationship to Problem 1

Orthogonal. SPICE (Problem 1) is the **local, attended, both-way** channel for the operator at the console. ntfy (Problem 2) is the **remote, outbound, guest-originated** channel for Cowork to reach the operator. Neither carries the other's traffic; the attachment on ntfy is only for the remote handoff of a small draft, not a substitute for the SPICE share.
