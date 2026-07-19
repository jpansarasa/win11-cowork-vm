# Design — Remote Notification (file optional) via ntfy

**Date:** 2026-07-19
**Status:** Approved (brainstorming)
**Repo:** github.com/jpansarasa/win11-cowork-vm
**Companion doc:** `win11-cowork-vm-buildspec.md` (adds a "Reaching James remotely" subsection)

## Purpose

Let **Cowork / the guest reach James when he's away** (phone), to **notify** — and optionally **hand him a file** (a draft it produced) as an attachment on the same channel. This is **Problem 2** in the decomposition: outbound, remote, guest-originated. It is entirely separate from local file transfer (Problem 1, SPICE — its own spec). The optional attachment is a bonus on the notification channel, **not** a second mechanism.

This is the natural complement to the capability gate: unattended runs can't take irreversible **actions**, but they *can* reach James to say "I'm blocked" or "here's a draft for review" — which is what makes unattended runs actually useful.

## The setup that makes this cheap

James's ntfy instance is **publicly reachable on 443**. The guest already has **unrestricted 443 egress** (that's how it browses and reaches Claude). So a POST to `https://ntfy.<host>/<topic>` adds **no new network capability** and needs **no cage change and no host courier** — the guest posts directly. (Host-mediation was considered and dropped: the trigger originates *in* the guest, so mediation would force the host to *poll* a guest outbox — laggy and clunky, for no security gain given the guest already owns 443.)

## Three load-bearing design decisions

1. **Outbound-only. The guest never *subscribes*.** This is the security of the whole thing. If the guest subscribed to the topic for "commands," we'd have built a **C2 channel *into* the guest** — anyone with the topic could push instructions to Cowork. ntfy stays a one-way pipe **out**. This is a hard constraint, not a default.

2. **Publish-only token, single topic.** The credential in the guest can *only publish to this one topic* — cannot read, cannot subscribe, cannot touch other topics. Blast radius if the disposable guest is compromised = someone can spam that one topic to James's phone. Revoke/rotate in seconds from ntfy. The token lives in a **guest-local config file created by James, never in the repo**, with locked-down perms.

3. **This is the one sanctioned secret in the guest.** It nudges against "no secrets in the guest" (buildspec constraint #3), so it is documented as a **conscious, scoped exception** — publish-only + revocable + single-topic is the justification — rather than allowed to become silent drift. Connector sessions already live in the guest, so one publish-only token is consistent with the existing trust model.

## Honest residual risk

A prompt-injected Cowork could use notification bodies/attachments as an exfil channel. But the guest **already has full 443 egress to the internet**, so this adds *convenience*, not a *new* capability. Documented, not pretended away. Mitigations that keep it bounded: publish-only scope, a hard-to-guess topic name (defense in depth even with a token), and the token being trivially revocable.

## Architecture

```
Guest (win11-cowork)
  └─ guest/notify-james.ps1   ── HTTPS POST (443) ──►  https://ntfy.<host>/<topic>  ──►  James's phone (ntfy app)
       reads guest-local config:                         (public, TLS)
         - topic URL
         - publish-only token
       args: title, message, priority, tags, [-File <path>]
```

**Direction:** guest → James only. No inbound. No subscription. No host involvement.

## Components

1. **`guest/notify-james.ps1`** — shipped in the repo like `guest/postboot.ps1` (James copies it into the guest). Behavior:
   - Reads topic URL + token from a **local config file** (e.g. `%ProgramData%\cowork\ntfy.json` or similar), path documented; the file itself is **not** in the repo and is git-ignored by pattern.
   - POSTs via `Invoke-RestMethod` with `Authorization: Bearer <token>`, setting ntfy headers for `Title`, `Priority`, `Tags`.
   - `-File <path>` (optional) attaches a file on the same request (ntfy attachment via `PUT`/`Filename`), respecting the server's configured attachment size limit (James controls it — noted, not enforced client-side beyond a friendly error).
   - Fails **loudly** on a non-2xx response or missing config — no silent swallow (consistent with the repo's silent-failure stance). Prints the ntfy error body.
   - Idempotent to run; holds no state.

2. **Config file (operator-created, not in repo).** Documents required keys (`url`, `token`) and file permissions. A `.gitignore` entry guards the pattern so a stray copy can't be committed.

3. **Exposure to Cowork.** Wire the helper so Cowork can call it — "notify James", "send James this file". Exact wiring (a Cowork tool/action vs. a documented command Cowork invokes) is an implementation detail for the plan; the spec's requirement is only that it be callable and that it remain **publish-only/outbound**.

4. **Docs — buildspec "Reaching James remotely" subsection.** How to create the publish-only token + topic in ntfy, where the config file goes, the outbound-only/no-subscribe rule stated as a constraint, the sanctioned-secret exception, and the residual-risk note.

## Error handling

- **Missing/invalid config** → helper dies loudly with a clear message; no silent no-op.
- **Non-2xx from ntfy** (bad token, revoked, topic typo, oversize attachment) → surface the HTTP status + ntfy body; do not swallow.
- **Attachment over server limit** → friendly error naming the limit; James raises it server-side if needed.
- **No network / DNS** → surfaced as the request exception; expected only if the whole 443 path is down.

## Verification (manual — no bats)

1. Create a publish-only token + topic in ntfy; subscribe on the phone.
2. `notify-james.ps1 -Title "test" -Message "hello"` → arrives on the phone.
3. `notify-james.ps1 -Title "draft" -Message "review" -File <somefile>` → attachment arrives on the phone.
4. Revoke the token in ntfy → confirm the helper now fails loudly (token scoping/revocation verified).
5. Confirm the guest **cannot** subscribe (no subscribe path exists in the helper; design check, not a runtime test).

## Relationship to Problem 1

Orthogonal. SPICE (Problem 1) is the **local, attended, both-way** channel for James at the console. ntfy (Problem 2) is the **remote, outbound, guest-originated** channel for Cowork to reach James. Neither carries the other's traffic; the attachment on ntfy is only for the remote handoff of a small draft, not a substitute for the SPICE share.
