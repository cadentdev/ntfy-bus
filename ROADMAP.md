# Roadmap

**Position: ntfy-bus complements Claude Code's built-in messaging. It does not compete with it.**

Claude Code shipped native cross-session messaging (`ListAgents` / `SendMessage`, plus Remote
Control and push notifications). That covers a job ntfy-bus was built to do, and covers it
better. This document records what changed, what is left that only this project does, and how
the codebase should be reshaped around that division of labour.

## What changed

Measured on a live host, 2026-08-09, Claude Code 2.1.226. A message was sent from one local
session to a second session that had been **idle at an empty prompt for roughly four hours**:

| | |
|---|---|
| Delivery latency | under 3 s |
| Woke the idle model | yes, unprompted |
| Human interaction required | none — the receiving session confirmed its invocation carried no user text |
| Transport (same machine) | Unix domain socket; never leaves the host |
| Setup required | none — no config, no daemon, no pidfile, no ledger |

That is precisely the problem `daemons/ntfy-bus-waker.sh` and `hooks/arm-bus-waker.sh` exist
to solve: waking an idle local agent when a message arrives. **For local Claude-to-Claude
wakes, the built-in supersedes them.** It has no identity to resolve, and therefore none of
the identity-substitution bug class this repo has now hit three times (PR #7, #8, #9).

We should say that plainly rather than defend the surface.

## What the built-in does not give us

Four things, in rough order of how durable each advantage looks.

**1. Non-Claude participants.** `SendMessage` is a tool only a Claude session can call. A cron
job, a CI hook, a monitoring gate, a phone, or **another agentic harness entirely** — OpenCode
or similar, potentially running a non-Anthropic model — cannot invoke it. All of them can POST
to ntfy. The `SENDER→RECIPIENT:` Title convention is harness-neutral and model-neutral by
construction. This is the moat: a rival harness running a rival model will never be a
first-class citizen of Anthropic's fleet tooling, and interoperability there is a permanent
gap only a neutral transport fills.

**2. Naming.** Claude Code gave us transport and wake. It did **not** give us stable identity.
Sessions are addressed by auto-generated title plus an ephemeral ref; the same session
observed during the test above reported one name to `ListAgents`, a different name in its own
replies, and an address that is a socket path which dies with the process. There is no way to
say "deliver this to whoever is responsible for X." `lib/resolve-config.sh` has answered
exactly that since day one. Naming is this project's most under-recognised asset — and, not
coincidentally, the part that keeps producing security bugs, because it is the part actually
doing load-bearing work.

**3. Durability.** `SendMessage` requires both peers to exist right now. ntfy retains
server-side, and the JSONL inbox plus poll-state means a message sent to an agent that is down
is waiting when it returns. Store-and-forward is not on the built-in's roadmap as far as we
can observe.

**4. Self-hosted transport for the cross-host case.** Same-machine built-in delivery is local
IPC and private. Cross-machine delivery goes through Anthropic. For hosts where that is not
acceptable, a self-hosted ntfy instance over a private network is the alternative.

Broadcast (`→ALL:` with `recipient_filters`) is a fifth, smaller advantage — the built-in is
point-to-point.

## Target architecture: gateway, not second bus

The failure mode to avoid is two parallel message buses, each with its own identity handling,
each accumulating its own bugs. The shape that avoids it:

```
  cron · CI · phone · other hosts · OpenCode / non-Claude harnesses
                         │
                         │  HTTP  (SENDER→RECIPIENT: Title routing)
                         ▼
                    [ ntfy topic ]
                         │
                         ▼
              ntfy-bus bridge daemon          ← exactly ONE per host
              (durable capture + naming)         resolves recipient → live session
                         │
                         │  SendMessage
                         ▼
                 Claude Code sessions
                 (intra-Claude fabric, built-in)
```

- **ntfy-bus owns ingress, egress, durability, and naming.** Anything that speaks HTTP joins
  the fleet. Identity is resolved once, in one place.
- **Claude Code owns intra-Claude delivery and wake.** We stop reimplementing it.
- **One bridge daemon per host** joins the two, mapping a bus recipient to a live session.

This pays twice. It retires the per-session armed waker — the arm hook, the pidfile, the wake
ledger, the poll-and-exit machinery — for local peers. And it makes host-global identity
**genuinely daemon-only**, which is exactly the fix issue #9 calls for: after this change,
precisely one process per host resolves host-global identity, and it is the bridge. The
security fix and the architecture converge on the same answer.

## Non-goals

- **Do not compete with `SendMessage` for local Claude-to-Claude delivery.** It is faster,
  needs no setup, and cannot be hijacked because it has no identity layer to attack.
- **Do not add configuration surface to the in-session waker.** A proposed
  `waker.autoarm: always|repo-local|off` knob was rejected: its `always` value restores the
  host-global fallback that PR #7 removed, and it invests in a component whose scope is
  deliberately shrinking.
- **Do not build a second config file.** The host-global config remains the only per-host
  surface, per `CLAUDE.md`.

## Sequencing

Identity is fixed **before** anything is built on top of it. A bridge daemon inherits every
defect in `lib/resolve-config.sh`, and three have surfaced in two days.

### Phase 1 — close the identity layer (blocking)

- **#9** — host-global identity is reachable from any live session outside a git worktree
  (`CLAUDE_PROJECT_DIR` is unset in workflow shells, so resolution falls to `git rev-parse` of
  the cwd). Introduce an explicit daemon-context marker. Highest severity; the same hijack
  class PR #7 was meant to close.
- **#8** — `Send`/`CheckInbox`/`Watch` do not enforce the unresolved-identity contract. Add
  `ntfy_require_config()` and gate the pairing in `bin/check.sh`.
- **#10** — README and `SKILL.md` still teach the pre-#7 model and recommend committing the
  repo identity config, which `check.sh` §7 now fails on.

Exit criterion: `bin/check.sh` and `tests/run.sh` green, with the daemon boundary asserted by
test rather than by comment.

### Phase 2 — design the bridge

Open questions to resolve before writing code:

- **Recipient → session mapping.** The hard part. Sessions are ephemeral and auto-titled; bus
  identities are stable. Where does the binding live, who writes it, and what happens when the
  named agent has no live session (queue? notify only? spawn?).
- **Loop prevention.** A bridge that relays bus → session must not relay a bus message the
  session then echoes back.
- **Failure mode.** If the bridge is down, does durable capture still land in the inbox for
  later `CheckInbox`? (It should — that is the existing behavior and it should not regress.)
- **Reach.** `ListAgents` sees Remote Control sessions on other machines. Determine whether
  the bridge should target those directly, which would overlap the cross-host case.

### Phase 3 — retire what the built-in replaces

Only after Phase 2 proves the bridge in practice. Candidates, in order of confidence:
`hooks/arm-bus-waker.sh`, `daemons/ntfy-bus-waker.sh`, the wake-seen ledger, and the
statusline waker indicator. `daemons/bus-waker-daemon.sh` (durable notify to a phone) is
**not** a candidate — push to a human is a different job from waking a model.

Deprecate loudly and in a release, not silently. Hosts carry their own installed unit copies.

## Risks

- **The ingress niche narrows.** Anthropic will keep extending this — webhooks or a public
  ingress endpoint would take the cron/CI case directly. The non-Claude-harness case is the
  part least likely to be absorbed, and Phase 2 should lean on it.
- **Two transports double the identity surface** unless Phase 3 actually happens. Keeping both
  paths alive indefinitely is the worst outcome.
- **The bridge is a new single point of failure** per host. Durable capture must survive it
  being down.

## Provenance

The measurements and the architectural read above came out of a live test on 2026-08-09
between two Claude Code sessions on one host, and an adversarial review of PR #7 by the second
session — which produced findings #9 and #10 and corrected a factual error in #8. Recording
that here because the review model (independent session, told to refute rather than confirm)
worked well enough to repeat.
