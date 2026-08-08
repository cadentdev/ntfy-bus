#!/usr/bin/env bun
/**
 * BridgeBodyGuard.hook.ts — PreToolUse warner for oversized bus POSTs
 *
 * Fires WARN (stderr only, never blocks) when a Bash curl POST to the
 * bus endpoint exceeds either:
 *   - body bytes > 4000     (ntfy ~4096-byte body cap → 40014 attachment reject)
 *   - Title header > 80 chars (locked bus title convention)
 *
 * See README § Body size for the documented N/of-N
 * split pattern that recovers from the cap.
 *
 * TRIGGER: PreToolUse (matcher: Bash)
 * EXIT CODES: always 0. WARN-only discipline — never block.
 */

interface HookInput {
  session_id: string;
  tool_name: string;
  tool_input: { command?: string } | string;
}

const BODY_BYTE_LIMIT = 4000;
const TITLE_CHAR_LIMIT = 80;

// Match on the bus topic path, not a specific host/scheme, so the guard fires
// for every endpoint form in use across a fleet (raw IP, LAN name, HTTPS
// overlay) — a scheme/host-specific match silently stops guarding the moment
// a node migrates endpoints. The topic itself comes from the host config
// — a hardcoded topic is the same trap one level up — a host on any
// other topic silently loses the guard. Fail-open per hooks doctrine:
// missing/unreadable config or no .topic → null → the hook matches nothing.
async function busTopicPath(): Promise<string | null> {
  try {
    const { readFileSync } = await import('fs');
    const { homedir } = await import('os');
    const home = process.env.NTFY_HOME || homedir();
    const raw = readFileSync(`${home}/.claude/ntfy-bus.config.json`, 'utf-8');
    const topic = JSON.parse(raw)?.topic;
    return typeof topic === 'string' && topic.length > 0 ? `/${topic}` : null;
  } catch {
    return null;
  }
}

function extractDataArg(command: string): string | null {
  const flagAlt = '(?:-d|--data|--data-raw|--data-binary|--data-urlencode)';
  const patterns = [
    new RegExp(`(?:^|\\s)${flagAlt}\\s+'([^']*)'`),
    new RegExp(`(?:^|\\s)${flagAlt}\\s+"((?:\\\\.|[^"\\\\])*)"`),
    new RegExp(`(?:^|\\s)${flagAlt}\\s+(\\S+)`),
  ];
  for (const re of patterns) {
    const m = command.match(re);
    if (m) return m[1];
  }
  return null;
}

function extractTitleHeader(command: string): string | null {
  const patterns = [
    /(?:^|\s)-H\s+"Title:\s*([^"]*)"/i,
    /(?:^|\s)-H\s+'Title:\s*([^']*)'/i,
  ];
  for (const re of patterns) {
    const m = command.match(re);
    if (m) return m[1];
  }
  return null;
}

async function main(): Promise<void> {
  let input: HookInput;
  try {
    const { readFileSync } = await import('fs');
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) return;
    input = JSON.parse(raw);
  } catch {
    return;
  }

  if (input.tool_name !== 'Bash') return;

  const command =
    typeof input.tool_input === 'object' && input.tool_input !== null
      ? input.tool_input.command ?? ''
      : '';
  if (!command) return;

  if (!command.includes('curl')) return;
  const topicPath = await busTopicPath();
  if (topicPath === null) return;
  if (!command.includes(topicPath)) return;

  const warnings: string[] = [];
  const infos: string[] = [];

  // Heuristic: if the matched value contains shell interpolation, a file
  // reference (curl `@file`), or heredoc tokens, the regex measured the
  // command text — NOT the actual bytes curl will send. Emit INFO so the
  // caller knows the byte guard cannot speak to the real payload size.
  const unmeasurable = (v: string) => /[\$`]|^@|<<\s*\S+/.test(v);

  const body = extractDataArg(command);
  if (body !== null) {
    if (unmeasurable(body)) {
      infos.push(
        'body is shell-interpolated or @file — byte guard cannot measure; verify split manually',
      );
    } else {
      const bytes = new TextEncoder().encode(body).byteLength;
      if (bytes > BODY_BYTE_LIMIT) {
        warnings.push(
          `body=${bytes} bytes (cap ~${BODY_BYTE_LIMIT}; ntfy rejects ~4096 with 40014)`,
        );
      }
    }
  }

  const title = extractTitleHeader(command);
  if (title !== null) {
    if (unmeasurable(title)) {
      infos.push('title is shell-interpolated — char guard cannot measure');
    } else if (title.length > TITLE_CHAR_LIMIT) {
      warnings.push(`title=${title.length} chars (convention ≤${TITLE_CHAR_LIMIT})`);
    }
  }

  if (warnings.length > 0) {
    console.error(
      `[bus-body-guard] WARN — ${warnings.join('; ')}. ` +
        `Split into N/of-N parts per README § Body size. Allowing.`,
    );
  }
  if (infos.length > 0) {
    console.error(
      `[bus-body-guard] INFO — ${infos.join('; ')}. ` +
        `See README § Body size.`,
    );
  }
}

main().catch(() => {});
