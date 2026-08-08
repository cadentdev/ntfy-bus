# Send

Send a message on the bus using the locked Title routing convention.

## Step 1: Load Config + Auth

```bash
set -a; . "$HOME/.env" 2>/dev/null; . "$HOME/.claude/.env" 2>/dev/null; set +a
# Resolve identity via the shared guard (host-locked LifeOS vs vanilla per-repo).
. "$HOME/.claude/skills/ntfy-bus/lib/resolve-config.sh"
CONFIG="$NTFY_CONFIG"
AGENT_ID=$(jq -r '.agent_id' "$CONFIG")
ENDPOINT=$(jq -r '.endpoint' "$CONFIG")
TOPIC=$(jq -r '.topic' "$CONFIG")
USER_VAR=$(jq -r '.auth_env.username' "$CONFIG")
PASS_VAR=$(jq -r '.auth_env.password' "$CONFIG")
# Resolve the env-var NAMES to their values portably. bash's ${!VAR} indirect
# expansion is a parse error in zsh ("bad substitution"), so use eval, which
# works in bash, zsh, and POSIX sh. The names come from the trusted config.
NTFY_USER=$(eval "printf '%s' \"\${$USER_VAR}\"")
NTFY_PASS=$(eval "printf '%s' \"\${$PASS_VAR}\"")
```

## Step 2: Validate Recipient

Recipient must be a known agent ID or `ALL`. Known set is configurable per fleet — current canonical set:

- `Alice`, `Bob`, `Carol`, `Dana`, `ALL`

Reject unknown recipients with a clear error rather than guessing.

Send always emits the canonical `→` pointer in the Title. Inbound matchers also tolerate `➡️`, `➡`, `👉`, `->`, and the space-delimited word ` to ` (case-insensitive) — those are receive-side conveniences only; never emit them from here.

## Step 3: Validate Body Size

ntfy's hard limit is ~4096 bytes. Check before sending:

```bash
if [ "$(echo -n "$BODY" | wc -c)" -gt 4000 ]; then
  echo "Body exceeds 4000 bytes. Split into (1/N), (2/N), ... and resend." >&2
  exit 1
fi
```

For long payloads, split and send sequentially with titles `... (1/N)`, `... (2/N)`.

## Step 4: Send

### Populating the body safely (read this first)

The most common send failure is **not** in the curl flag below — it's in how `${BODY}` gets set. A single-quoted shell assignment containing an **apostrophe** silently self-destructs:

```bash
BODY='Bob — today's gate is GREEN'   # WRONG: the ' in today's closes the quote.
```

The shell mis-parses the tail as commands (`command not found: own`), `${BODY}` ends up **empty**, and `--data-raw "${BODY}"` then faithfully sends an empty body — while the Title still posts, so it *looks* like it worked. Same trap with `it's`, `won't`, `we'll`, quotes, backticks, and `$`.

**Rule:** for any body with apostrophes, quotes, `$`, backticks, or multiple lines, do NOT build it as an inline shell string. Instead **write the body to a file** (the Write tool is ideal — it never passes through shell quoting) and send it with the `--data-binary @file` form below. Reserve inline `--data-raw` for short, single-line, punctuation-free bodies.

**Always verify the send.** After sending, confirm the response JSON has a non-zero body — or echo `Body bytes: $(wc -c < "${BODY_FILE}")` before sending and confirm it's not 0. A title-only post with an empty body is the signature of this bug.

Two curl forms cover the common cases. Both preserve newlines and both avoid the leading-`@` pitfall where `-d` or `--data-binary` would read a file if `${BODY}` happens to start with `@/...` — that pitfall is a real local-file exfiltration risk.

**Inline body — use `--data-raw`:** preserves newlines, treats `@` literally.

```bash
curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  -H "Title: ${AGENT_ID}→${RECIPIENT}: ${SUBJECT}" \
  --data-raw "${BODY}" \
  "${ENDPOINT}/${TOPIC}"
```

**File body — use `--data-binary @file`** (NOT `-d @file`, which silently strips CR/LF):

```bash
curl -s -u "${NTFY_USER}:${NTFY_PASS}" \
  -H "Title: ${AGENT_ID}→${RECIPIENT}: ${SUBJECT}" \
  --data-binary @"${BODY_FILE}" \
  "${ENDPOINT}/${TOPIC}"
```

**Critical:** Body is pure payload. Do NOT prefix with `[FROM→TO]` or sign with `—${AGENT_ID}`. The Title carries both endpoints.

## Step 5: Capture + Report

The response is JSON with `id`, `time`, `topic`. Echo the `id` so the user can reference the message in a later turn.

```
✓ Sent. id=<ntfy-id> | <AGENT_ID>→<RECIPIENT>: <subject>
```
