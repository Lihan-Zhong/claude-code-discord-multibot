#!/usr/bin/env bash
# Patch the Discord plugin's messageCreate handler so it no longer drops
# messages from other bots. We still drop messages from OURSELVES (by
# comparing author.id to client.user.id) to prevent self-trigger loops.
#
# Idempotent: re-running on already-patched files is a no-op.
# Run after every Discord plugin upgrade.
#
# Pass --quiet (used from .bashrc) to silence the "already patched" noise;
# the script still speaks when it actually applies a patch or sees an
# unexpected line.

set -euo pipefail

QUIET=0
if [ "${1-}" = "--quiet" ]; then QUIET=1; fi

OLD='if (msg.author.bot) return'
NEW='if (msg.author.id === client.user?.id) return'

# Both copies of server.ts that ship with the plugin
TARGETS=(
  "$HOME/.claude/plugins/cache/claude-plugins-official/discord/"*"/server.ts"
  "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/discord/server.ts"
)

patched=0
already=0
missing=0

for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    if [ ! -f "$f" ]; then
      continue
    fi
    # A 0-byte / truncated server.ts means something clobbered it (seen 2026-08-12: the
    # marketplace copy was emptied). Never patch garbage — say so loudly and skip, so the
    # real file can be restored from the other copy instead of masking the breakage.
    if [ ! -s "$f" ]; then
      echo "[ERR]  server.ts is EMPTY (0 bytes) — restore it, e.g.:" >&2
      echo "       cp ~/.claude/plugins/cache/claude-plugins-official/discord/*/server.ts \"$f\"" >&2
      missing=$((missing + 1))
      continue
    fi
    if grep -qF "$NEW" "$f"; then
      already=$((already + 1))
      [ "$QUIET" -eq 1 ] || echo "[skip] already patched: $f"
      continue
    fi
    if ! grep -qF "$OLD" "$f"; then
      missing=$((missing + 1))
      echo "[warn] expected line not found in: $f" >&2
      continue
    fi
    # In-place edit with backup
    cp "$f" "$f.bak.predisco-botbot"
    sed -i "s|$OLD|$NEW|" "$f"
    patched=$((patched + 1))
    echo "[ok]   patched (re-applied after plugin update?): $f" >&2
  done
done

# --- Patch 2: online presence + srun walltime countdown ---
# Green dot reflects the real gateway connection (process death, e.g. a SLURM walltime expiry, greys it
# out), and the activity text shows the project name + how long before SLURM kills this job.
pres_patched=0
for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    [ -f "$f" ] || continue
    if [ ! -s "$f" ]; then continue; fi          # empty file already reported by patch 1
    if grep -qF "const BOT_NODE" "$f"; then
      [ "$QUIET" -eq 1 ] || echo "[skip] presence+countdown already patched: $f"
      continue
    fi
    python3 - "$f" <<'PYEOF'
import sys, re
f=sys.argv[1]
s=open(f,encoding='utf-8').read()

# Drop any older presence-only patch so we can re-inject the full version.
s=re.sub(r"// Presence label from the per-bot state dir[\s\S]*?\}\)\(\)\n", "", s, count=1)

block = (
 "// Presence label from the per-bot state dir so each bot shows its own project name.\n"
 "const BOT_BASE = (process.env.DISCORD_STATE_DIR || '').split('/').filter(Boolean).pop() || ''\n"
 "// Compute node this bot actually runs on (SLURM sets SLURMD_NODENAME; else the hostname).\n"
 "const BOT_NODE = (() => {\n"
 "  const n = process.env.SLURMD_NODENAME || process.env.HOSTNAME || ''\n"
 "  if (n) return n.split('.')[0]\n"
 "  try { return String(require('os').hostname()).split('.')[0] } catch { return '' }\n"
 "})()\n"
 "// This process runs INSIDE the interactive srun job, so SLURM_JOB_ID identifies it.\n"
 "// `squeue -h -j <id> -o %L` gives TimeLeft, shown as a countdown in the presence.\n"
 "const SLURM_JOB_ID = process.env.SLURM_JOB_ID || process.env.SLURM_JOBID || ''\n"
 "function slurmTimeLeft(): string {\n"
 "  if (!SLURM_JOB_ID) return ''\n"
 "  try {\n"
 "    const { execFileSync } = require('child_process')\n"
 "    const out = String(execFileSync('squeue', ['-h', '-j', SLURM_JOB_ID, '-o', '%L'], {\n"
 "      timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],\n"
 "    })).trim()\n"
 "    if (!out || out === 'INVALID' || out === 'NOT_SET') return ''\n"
 "    const m = out.match(/^(?:(\\d+)-)?(?:(\\d+):)?(\\d+):(\\d+)$/)\n"
 "    if (!m) return out\n"
 "    const [d, h, mi] = [Number(m[1] || 0), Number(m[2] || 0), Number(m[3] || 0)]\n"
 "    if (d) return `${d}d${h}h`\n"
 "    if (h) return `${h}h${String(mi).padStart(2, '0')}m`\n"
 "    return `${mi}m`\n"
 "  } catch { return '' }\n"
 "}\n"
 "// Format: \"node · ⏳time-left · project\"  (pieces missing off-SLURM are simply dropped)\n"
 "function presenceLabel(): string {\n"
 "  const left = slurmTimeLeft()\n"
 "  const parts = [BOT_NODE, left ? `⏳${left}` : '', BOT_BASE].filter(Boolean)\n"
 "  return parts.length ? parts.join(' · ') : (process.env.CLAUDE_BOT_LABEL || 'Claude Code')\n"
 "}\n"
)
anchor="const client = new Client({"
if anchor in s and "function slurmTimeLeft" not in s:
    s=s.replace(anchor, block+anchor, 1)

part="  partials: [Partials.Channel],\n"
pres=("  // Explicit online presence => connected bot shows the green dot; process death greys it out.\n"
      "  presence: { status: 'online', activities: [{ name: presenceLabel(), type: 0 }] },\n")
if "presence: { status: 'online'" in s:
    s=re.sub(r"  presence: \{ status: 'online'.*?\},\n", pres, s, count=1, flags=re.S)
elif part in s:
    s=s.replace(part, part+pres, 1)

# Refresh the countdown periodically so it stays truthful as walltime burns down.
ready_old="client.once('ready', c => {\n  process.stderr.write(`discord channel: gateway connected as ${c.user.tag}`"
if "setActivity(presenceLabel()" not in s:
    m=re.search(r"client\.once\('ready', c => \{\n(.*?)\n\}\)", s, flags=re.S)
    if m:
        body=m.group(1)
        add=(body+"\n  if (SLURM_JOB_ID) {\n"
             "    process.stderr.write(`discord channel: srun job ${SLURM_JOB_ID}, time left ${slurmTimeLeft() || '?'}\\n`)\n"
             "    const tick = setInterval(() => {\n"
             "      try { c.user.setActivity(presenceLabel(), { type: 0 }) } catch {}\n"
             "    }, 15 * 60 * 1000)\n"
             "    if (typeof tick.unref === 'function') tick.unref()\n"
             "  }")
        s=s[:m.start(1)]+add+s[m.end(1):]
# Refuse to write back anything that didn't actually get the patch (empty/renamed anchors) —
# writing an unpatched or truncated file would silently report success.
if "function slurmTimeLeft" not in s or len(s) < 1000:
    print("[warn] presence anchors not found (upstream changed?) — left untouched:", f)
    raise SystemExit(0)
open(f,'w',encoding='utf-8').write(s)
print("[ok]   presence+countdown patched (re-applied after plugin update?):", f)
PYEOF
    pres_patched=$((pres_patched + 1))
  done
done

# --- Patch 3: markdown-safe message splitting (MD-SAFE CHUNKER) ---
# Discord hard-caps a message at 2000 chars. Upstream's chunk() defaults to mode 'length',
# which slices at exactly the limit — mid-word, mid-`inline span`, mid-fenced-block. When a
# ```code block``` gets cut, the tail message loses its opening fence and renders as prose.
# This replaces chunk() with a splitter that (a) prefers a cut OUTSIDE any fence so a whole
# block moves to the next message intact, (b) closes and re-opens the fence (keeping the
# language tag) when a single block is itself longer than the limit, (c) never leaves an odd
# number of inline backticks behind — and flips the default mode to 'newline'.
#
# The anchor is a REGEX on `function chunk(` rather than the full signature, so an upstream
# rename of a parameter still patches. That is only safe because every patched file then goes
# through a transpile-only syntax gate below and is REVERTED if it no longer parses.
chunk_patched=0
SYNGATE='const s=await Bun.file(Bun.env.SYNCHK_FILE).text(); try{ new Bun.Transpiler({loader:"ts"}).transformSync(s) }catch(e){ console.error(String(e).split("\n")[0]); process.exit(1) }'
for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    [ -f "$f" ] || continue
    if [ ! -s "$f" ]; then continue; fi          # empty file already reported by patch 1
    if grep -qF "MD-SAFE CHUNKER" "$f"; then
      [ "$QUIET" -eq 1 ] || echo "[skip] md-safe chunker already patched: $f"
      continue
    fi
    cp "$f" "$f.bak.prechunk"
    python3 - "$f" <<'PYEOF'
import re, sys
f = sys.argv[1]
s = open(f, encoding='utf-8').read()
orig = s

# Loose anchor: any declaration of chunk(), whatever its parameters are called.
m = re.search(r"\bfunction\s+chunk\s*\(", s)
if not m:
    print("[warn] chunk() declaration not found (upstream changed?) — left untouched:", f)
    raise SystemExit(0)

# Walk the parameter list, then take the first '{' after it as the body opener.
i = m.start()
k = s.index("(", m.start())
depth = 0
for n in range(k, len(s)):
    if s[n] == "(": depth += 1
    elif s[n] == ")":
        depth -= 1
        if depth == 0:
            k = n + 1
            break
else:
    print("[warn] chunk() parameter list not balanced — left untouched:", f)
    raise SystemExit(0)
try:
    body = s.index("{", k)
except ValueError:
    print("[warn] chunk() body not found — left untouched:", f)
    raise SystemExit(0)
depth = 0
end = -1
for n in range(body, len(s)):
    if s[n] == "{": depth += 1
    elif s[n] == "}":
        depth -= 1
        if depth == 0:
            end = n + 1
            break
if end < 0:
    print("[warn] chunk() body not brace-balanced — left untouched:", f)
    raise SystemExit(0)

# `_mode` is deliberately typed loose: upstream may narrow or widen its own union, and we
# ignore the argument anyway. Keeping it permissive means a union change cannot break us.
NEW = r"""// MD-SAFE CHUNKER (local patch). Discord caps messages at 2000 chars; splitting blind
// cuts fenced code blocks and inline `code` spans in half, and the tail chunk then renders
// as prose. Prefer a cut outside any fence; if one block is itself over the limit, close the
// fence on the way out and re-open it (same language tag) at the top of the next chunk.
const FENCE_RE = /^\s{0,3}(?:`{3,}|~{3,})/
function chunk(text: string, limit: number, _mode?: unknown): string[] {
  const head = (o: string) => (o ? o + '\n' : '')
  if (text.length <= limit) return [text]
  const out: string[] = []
  let rest = text
  let open = ''                       // opening fence line still in force at the start of `rest`
  let guard = 0
  while (head(open).length + rest.length > limit) {
    if (++guard > 10000) break        // belt-and-braces: never spin on a pathological input
    const prefix = head(open)
    const budget = limit - prefix.length - 4   // 4 = room for a trailing "\n```"
    if (budget <= 0) break

    const lines = rest.split('\n')
    let used = 0
    let inFence = open !== ''
    let opener = open
    let ticks = 0
    let safeCut = -1                  // last line boundary that sits OUTSIDE any fence/span
    let lineCut = -1                  // last line boundary that fits, fence or not
    let openerAtLine = open
    for (let i = 0; i < lines.length; i++) {
      const add = (i === 0 ? 0 : 1) + lines[i].length
      if (used + add > budget) break
      used += add
      if (FENCE_RE.test(lines[i])) {
        if (inFence) { inFence = false; opener = '' }
        else { inFence = true; opener = lines[i].trim() }
      } else if (!inFence) {
        for (const ch of lines[i]) if (ch === '`') ticks++
      }
      lineCut = used
      openerAtLine = opener
      if (!inFence && ticks % 2 === 0) safeCut = used
    }

    let cut: number
    let nextOpen: string
    // Prefer staying outside a fence — but not at the cost of a near-empty message: if that
    // would waste more than half the budget, go into the fence and pay one close/reopen.
    if (safeCut > 0 && (safeCut >= budget * 0.5 || lineCut <= safeCut)) {
      cut = safeCut
      nextOpen = ''
    } else if (lineCut > 0) {
      cut = lineCut
      nextOpen = openerAtLine
    } else {
      // A single line longer than the budget: back off to a space, and never leave an odd
      // number of inline backticks behind.
      cut = Math.min(budget, rest.length)
      const sp = rest.lastIndexOf(' ', cut)
      if (sp > budget / 2) cut = sp
      const probe = rest.slice(0, cut)
      let odd = 0
      for (const ch of probe) if (ch === '`') odd++
      if (odd % 2 === 1) {
        const b = probe.lastIndexOf('`')
        if (b > 0) cut = b
      }
      nextOpen = open
    }
    if (cut <= 0) cut = Math.min(budget, rest.length)

    let body = rest.slice(0, cut)
    if (nextOpen) body += '\n```'
    out.push(prefix + body)
    rest = rest.slice(cut).replace(/^\n+/, '')
    open = nextOpen
  }
  if (rest) out.push(head(open) + rest)
  return out
}"""

s = s[:i] + NEW + s[end:]

# Paragraph-preferring default: upstream ships 'length' (a hard cut) as the default.
s = re.sub(r"access\.chunkMode \?\? '(?:length|newline)'", "access.chunkMode ?? 'newline'", s)

if "MD-SAFE CHUNKER" not in s or len(s) < 1000 or len(s) < len(orig) - 4000:
    print("[warn] md-safe chunker patch looks wrong — left untouched:", f)
    raise SystemExit(0)
open(f, 'w', encoding='utf-8').write(s)
print("[ok]   md-safe chunker patched:", f)
PYEOF
    # Syntax gate: transpile only (no import resolution, ~20 ms). A loose anchor is only safe
    # with this — if the edit produced something that no longer parses, put the file back.
    if grep -qF "MD-SAFE CHUNKER" "$f"; then
      if SYNCHK_FILE="$f" bun -e "$SYNGATE" >/dev/null 2>&1; then
        chunk_patched=$((chunk_patched + 1))
      else
        mv -f "$f.bak.prechunk" "$f"
        echo "[ERR]  md-safe chunker patch did not parse — REVERTED: $f" >&2
      fi
    fi
  done
done

if [ "$QUIET" -eq 0 ]; then
  echo
  echo "summary: patched=$patched already=$already missing=$missing presence_patched=$pres_patched chunk_patched=$chunk_patched"
  echo "remember to /exit and relaunch any running Discord bots for the patch to take effect"
elif [ "$patched" -gt 0 ]; then
  echo "[discord-patch] $patched file(s) re-patched — /exit and relaunch any running Discord bots." >&2
fi
