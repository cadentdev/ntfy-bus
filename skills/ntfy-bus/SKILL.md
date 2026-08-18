---
name: ntfy-bus
description: Send and receive messages on a private ntfy bus shared across agents (LifeOS or vanilla Claude Code). Uses Title-based routing (SENDER→RECIPIENT) for deterministic multi-agent communication. Workflows cover checking the inbox, sending a message, watching for new traffic, and one-time setup of the per-host config file.
when_to_use: bus, ntfy, agent-bus, fleet messaging, check inbox, send to Alice, send to Bob, broadcast to all agents, watch bus, relay message, agent-to-agent message
---

# ntfy-bus

Cross-agent messaging over a private ntfy server, with a locked Title-based routing convention. Works identically on LifeOS hosts (reads from the existing inbox JSONL written by the systemd watcher) and on vanilla Claude Code installs (live HTTP poll).

## USE WHEN

- The user asks to check the bus, ntfy inbox, or the bus topic (default `agent-bus`)
- The user asks to send a message to another agent (Alice, Bob, ALL)
- The user asks to relay or forward a bus message
- The user asks to watch for new bus traffic
- The user is setting up the bus on a new host

## Routing Convention (locked)

Every message uses the Title field as the sole routing carrier. Shape:

```
SENDER→RECIPIENT: subject
```

Examples:

- `Alice→Bob: Phase 0 results`
- `Bob→Alice: ack — proceed`
- `Dana→ALL: project scope change`
- `Carol→Alice: status update`

**The body is pure payload.** Never prefix the body with `[FROM→TO]` or a signature line — the title already carries both ends.

### Pointer character (the arrow)

`→` (U+2192) is the canonical pointer, but it's awkward to type on many keyboards. **Senders may use any of `→`, `➡️`, `👉`, ASCII `->`, or the plain word ` to ` (space-delimited, case-insensitive — `Alice to Bob:`, `Alice TO ALL:`)** — whichever is easiest on their device. All recipient **matchers normalize these to `→` before routing**, so no message is dropped for using a substitute. Programmatic sends (Send/Setup) still **emit the canonical `→`**. The spaces around ` to ` are required (`Aliceto Bob:` does not route; a sender named `Toby` is never split), and one false positive is accepted by design: plain-English headers like `reply to Bob: draft` route to Bob with sender `reply` — the bus is private and the Title convention is the contract, so don't "fix" this. **Don't hand-roll a matcher — source the shared one.** `lib/routing.sh` is the single source of truth: `. "$HOME/.claude/skills/ntfy-bus/lib/routing.sh"` then put `$BUS_ROUTING_DEFS` at the front of your jq program and call `addressed_to($filters)` (pipe-joined recipients, e.g. `"Bob|ALL"`) and/or `msg_sender`. It already (1) scopes to the routing **header** (`split(":")[0]`) so a `->` in the *subject* can't false-match, (2) folds `→ ➡️ ➡ 👉 ->` (VS16 form before bare `➡`), and (3) matches the recipient as a `\b`-token so **group** titles like `Dana→Alice & Bob:` / `Dana→Bob, Alice:` match. Change the matcher there once and every consumer (CheckInbox, Watch, the wakers) inherits it.

## Body Size Limit

ntfy rejects bodies over ~4096 bytes with `40014 invalid request: attachments not allowed`. For long payloads, split across multiple messages titled `... (1/N)`, `... (2/N)`, etc.

**Two curl footguns when sending bodies:** (1) `-d @file` strips newlines — use `--data-binary @file` instead. (2) `-d` and `--data-binary` treat a leading `@` in the value as a filename and will read the file, posting its contents (local-file exfiltration risk) — prefer `--data-raw "${BODY}"` for inline bodies. Send.md uses `--data-raw` (inline) and `--data-binary @file` (file form). The BridgeBodyGuard companion hook guards the byte cap but does NOT guard either curl footgun.

## Workflows

- **CheckInbox** — pull recent messages addressed to this agent (or `ALL`)
- **Send** — emit a message with proper Title routing
- **Watch** — long-poll for new traffic in background
- **Setup** — write `~/.claude/ntfy-bus.config.json` on first use per host

## Per-Host Config

All workflows resolve the config path through the shared guard
`lib/resolve-config.sh`, which sets `$NTFY_CONFIG`. Resolution has two classes:

- **Host-locked (LifeOS)** — `~/.claude/PAI/` exists (the LifeOS marker
  directory, named for its former brand), or the host-global config does
  not set `per_repo_identity_allowed: true`. Always uses the host-global
  `~/.claude/ntfy-bus.config.json`; any repo-local identity config is ignored.
  This is default-safe: a fresh host is locked.
- **Vanilla opt-in** — the host-global config sets `per_repo_identity_allowed: true`
  and no `~/.claude/PAI/`. Inside a repo, the repo-local
  `<repo>/.claude/ntfy-bus.config.json` (untracked, per-contributor) IS the
  identity; a repo without one resolves to NOTHING (source `none`, empty
  `$NTFY_CONFIG`) and every workflow refuses to act — there is no host-global
  fallback inside a repo. Host-global applies only outside any repo, in
  explicit daemon context (`NTFY_DAEMON_CONTEXT=1`, set by the shipped unit
  templates). Lets one host carry per-repo identities (e.g. one identity per
  repo).

Secrets (NTFY_USERNAME/NTFY_PASSWORD) live in `~/.env` or `~/.claude/.env` and are
referenced by name in the config — never the values. See `config.example.json`
(host-global) and `config.repo-local.example.json` (untracked, per-repo, per-contributor) for the
schemas.

## Hybrid Inbox Read Strategy

CheckInbox prefers the JSONL inbox file when present:

1. If `~/.claude/ntfy-inbox.jsonl` exists → tail and filter by recipient (fast, no HTTP)
2. Else → live HTTP poll against the ntfy endpoint with `?poll=1&since=...`

LifeOS hosts have a systemd watcher writing the JSONL. Vanilla hosts don't — they fall through to HTTP.
