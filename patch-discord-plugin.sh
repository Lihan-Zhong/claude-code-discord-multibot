#!/usr/bin/env bash
# Patch the Discord plugin's messageCreate handler so it no longer drops
# messages from other bots. We still drop messages from OURSELVES (by
# comparing author.id to client.user.id) to prevent self-trigger loops.
#
# Idempotent: re-running on already-patched files is a no-op.
# Run after every Discord plugin upgrade.
# Safe to run from many shells at once: runs are serialized by a lock (see "One run at a time").
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

# What each of the three patches leaves behind (for patch 1, the replacement line itself).
MARKERS=("$NEW" "const BOT_NODE" "MD-SAFE CHUNKER")
all_marked() { local m; for m in "${MARKERS[@]}"; do grep -qF -- "$m" "$1" || return 1; done; }
# Markers alone are not proof: the old unserialized runs could leave every marker in place AND a
# duplicate or a missing declaration (reproduced). So a fully patched file is trusted only if it is
# the exact file that last passed the full check (parse + declarations) — its size and mtime are
# recorded in "<file>.verified".
stamp_of() { stat -c '%s %Y' "$1" 2>/dev/null; }
verified() { [ -f "$1.verified" ] && [ "$(stamp_of "$1")" = "$(cat "$1.verified" 2>/dev/null)" ]; }

# Fast path — the common case on every shell start: everything is already patched and verified.
# Read-only: no lock, no syntax check, so opening a shell costs no more than it did before.
if [ "$QUIET" -eq 1 ]; then
  fast=1
  for pattern in "${TARGETS[@]}"; do
    for f in $pattern; do
      [ -f "$f" ] || continue
      if [ ! -s "$f" ] || ! all_marked "$f" || ! verified "$f"; then fast=0; fi
    done
  done
  if [ "$fast" -eq 1 ]; then exit 0; fi
fi

# --- One run at a time (2026-10-06) ---
# Every shell start runs this script, and several shells often start together (tmux restoring
# windows, a burst of srun shells, bot sessions building their shell snapshot). Unserialized, each
# run saw "not patched yet", they shared one .bak path, and one run's revert clobbered another's
# work. Once (2026-10-06, after a plugin refresh) that left the marketplace copy with FENCE_RE
# declared twice — a file that no longer parses, so every later patch "did not parse" on top of it.
# Reproduced: 8 concurrent runs on a fresh server.ts left patches missing in 6 of 6 trials.
# flock serializes runs across processes, and across nodes when $HOME is on a cluster filesystem
# that supports it — Lustre needs the cluster-coherent `flock` mount option (check: findmnt -no
# OPTIONS -T ~/.claude | tr , '\n' | grep -x flock; `localflock` covers one node only). The kernel
# drops the lock the moment its holder dies, even on kill -9, so there is no stale lock to judge.
# (The first version used mkdir + an mtime check; review showed that breaking a "stale" lock is not
# atomic and that a run could release another run's lock.) The wait is short on purpose: a run takes
# under a second, Claude Code allows a session's whole shell-startup snapshot 10 s, and a waiter that
# gives up loses nothing — the holder is doing the same idempotent work. Never delete the lock file:
# deleting a flock file while others hold it reopens the race.
[ -d "$HOME/.claude" ] || exit 0
LOCKF="$HOME/.claude/.patch-discord-plugin.flock"
if ! { exec 9>>"$LOCKF"; } 2>/dev/null; then
  echo "[discord-patch] cannot open $LOCKF (home full or read-only?) — patches not applied" >&2
  exit 0
fi
lock_rc=0; flock -E 75 -w 3 9 2>/dev/null || lock_rc=$?
if [ "$lock_rc" -eq 75 ]; then           # another run holds it — and is doing this same work
  [ "$QUIET" -eq 1 ] || echo "[warn] another patch run holds $LOCKF — skipped this run" >&2
  exit 0
elif [ "$lock_rc" -ne 0 ]; then          # this filesystem cannot flock at all: run unserialized
  [ "$QUIET" -eq 1 ] || echo "[warn] cannot flock $LOCKF on this filesystem — running unserialized" >&2
fi
rmdir "$HOME/.claude/.patch-discord-plugin.lock" 2>/dev/null || true   # leftover of the mkdir version

# Transpile-only syntax check (no import resolution, ~20 ms). parse_err prints the first line of
# the parse error, and fails, when "$1" does not parse.
SYNGATE='const s=await Bun.file(Bun.env.SYNCHK_FILE).text(); try{ new Bun.Transpiler({loader:"ts"}).transformSync(s) }catch(e){ console.error(String(e).split("\n")[0]); process.exit(1) }'
# Run from / so the shell's cwd cannot matter (a stray bunfig.toml there makes bun itself fail).
parse_err() { (cd / && SYNCHK_FILE="$1" bun -e "$SYNGATE" 2>&1 >/dev/null); }
# bun must actually RUN, not merely be on PATH — otherwise every file would look broken. Probe it.
HAVE_BUN=0
if command -v bun >/dev/null 2>&1 && parse_err /dev/null >/dev/null; then HAVE_BUN=1; fi

# Parsing is not enough: a file can parse and still die at load. The old race could leave
# presenceLabel() calling BOT_NODE with no `const BOT_NODE` left ("ReferenceError: BOT_NODE is not
# defined" the moment the plugin starts). The names our patches introduce must each be declared
# exactly once wherever they are used. decl_err prints what is wrong and fails.
DECLCHK='
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
names = {"BOT_BASE": "const", "BOT_NODE": "const", "SLURM_JOB_ID": "const", "FENCE_RE": "const",
         "slurmTimeLeft": "function", "presenceLabel": "function"}
bad = []
for n, kind in names.items():
    d = len(re.findall(r"^\s*%s\s+%s\b" % (kind, n), s, flags=re.M))
    u = len(re.findall(r"\b%s\b" % n, s)) - d
    if d > 1:
        bad.append("%s declared %d times" % (n, d))
    elif d == 0 and u > 0:
        bad.append("%s used but never declared" % n)
if bad:
    print("; ".join(bad))
    sys.exit(1)
'
decl_err() { python3 -c "$DECLCHK" "$1"; }
# file_err: why "$1" is unusable (a parse error or a broken declaration); fails if it is.
file_err() {
  local e
  if [ "$HAVE_BUN" -eq 1 ] && ! e=$(parse_err "$1"); then echo "$e"; return 1; fi
  if ! e=$(decl_err "$1"); then echo "$e"; return 1; fi
  return 0
}

# --- Pre-flight: never stack patches on a file that is already unusable (2026-10-06) ---
# A file that is broken BEFORE we touch it makes every later patch look broken — that is how the
# duplicate FENCE_RE above surfaced as later patches that "did not parse". Repair such a file from the
# pristine upstream copy patch 1 saved (it must parse and carry none of our markers), then patch
# from scratch. With no clean copy, leave the file alone, say so, and skip it. A fully patched file
# whose .verified stamp still matches is skipped: it is the very file that passed last time.
declare -A BROKEN=()
if [ "$HAVE_BUN" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
  echo "[warn] bun not usable here — cannot syntax-check, so patch 3 is skipped this run" >&2
fi
for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    [ -s "$f" ] || continue
    if all_marked "$f" && verified "$f"; then continue; fi
    if err=$(file_err "$f"); then continue; fi
    clean="$f.bak.predisco-botbot"
    if [ -s "$clean" ] && file_err "$clean" >/dev/null \
       && ! grep -qF -e "$NEW" -e "const BOT_NODE" -e "MD-SAFE CHUNKER" "$clean"; then
      cp "$f" "$f.bak.unusable"            # the latest broken copy, for diagnosis (one file, not one per run)
      cp "$clean" "$f.tmp.$$"
      mv -f "$f.tmp.$$" "$f"
      echo "[fix]  server.ts was unusable ($err) — restored the pristine upstream copy, re-patching: $f" >&2
    else
      BROKEN["$f"]=1
      echo "[ERR]  server.ts is unusable even before patching ($err), and there is no clean copy to restore — left untouched: $f" >&2
    fi
  done
done

patched=0
already=0
missing=0

for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    if [ ! -f "$f" ]; then
      continue
    fi
    if [ -n "${BROKEN[$f]:-}" ]; then continue; fi
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
    # In-place edit with backup. The backup is the pre-flight's restore source, so only a truly
    # pristine file (none of our markers) may overwrite it.
    if ! grep -qF -e "const BOT_NODE" -e "MD-SAFE CHUNKER" "$f"; then
      cp "$f" "$f.bak.predisco-botbot"
    fi
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
    if [ -n "${BROKEN[$f]:-}" ]; then continue; fi
    if grep -qF "const BOT_NODE" "$f"; then
      [ "$QUIET" -eq 1 ] || echo "[skip] presence+countdown already patched: $f"
      continue
    fi
    cp "$f" "$f.bak.prepresence"
    python3 - "$f" <<'PYEOF'
import sys, re
f=sys.argv[1]
s=open(f,encoding='utf-8').read()
# Idempotent on what we actually read. On an already patched file the legacy-strip regex below
# matches the head of OUR block and deletes BOT_BASE/BOT_NODE (seen in review) — never run it there.
if "const BOT_NODE" in s:
    raise SystemExit(0)
if "function slurmTimeLeft" in s:
    print("[warn] presence block only partly present — left for the pre-flight to restore:", f)
    raise SystemExit(0)

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
    # Same gate as patch 3: revert if the edit left the file unusable.
    if ! cmp -s "$f" "$f.bak.prepresence"; then
      if err=$(file_err "$f"); then
        pres_patched=$((pres_patched + 1))
      else
        mv -f "$f.bak.prepresence" "$f"
        echo "[ERR]  presence+countdown patch left the file unusable ($err) — REVERTED: $f" >&2
      fi
    fi
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
# (SYNGATE / parse_err are defined at the top of the script.)
for pattern in "${TARGETS[@]}"; do
  for f in $pattern; do
    [ -f "$f" ] || continue
    if [ ! -s "$f" ]; then continue; fi          # empty file already reported by patch 1
    if [ "$HAVE_BUN" -eq 0 ] || [ -n "${BROKEN[$f]:-}" ]; then continue; fi
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
if "MD-SAFE CHUNKER" in s:          # idempotent on what we actually read
    raise SystemExit(0)

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
      if err=$(file_err "$f"); then
        chunk_patched=$((chunk_patched + 1))
      else
        mv -f "$f.bak.prechunk" "$f"
        echo "[ERR]  md-safe chunker patch did not parse ($err) — REVERTED: $f" >&2
      fi
    fi
  done
done

# Stamp every fully patched file that parses, so the fast path can trust it next time.
if [ "$HAVE_BUN" -eq 1 ]; then
  for pattern in "${TARGETS[@]}"; do
    for f in $pattern; do
      [ -s "$f" ] || continue
      if all_marked "$f" && ! verified "$f" && [ "$HAVE_BUN" -eq 1 ] && file_err "$f" >/dev/null; then
        { stamp_of "$f" > "$f.verified"; } 2>/dev/null || true    # best-effort: no stamp only costs the fast path
      fi
    done
  done
fi

if [ "$QUIET" -eq 0 ]; then
  echo
  echo "summary: patched=$patched already=$already missing=$missing presence_patched=$pres_patched chunk_patched=$chunk_patched"
  echo "remember to /exit and relaunch any running Discord bots for the patch to take effect"
elif [ "$patched" -gt 0 ]; then
  echo "[discord-patch] $patched file(s) re-patched — /exit and relaunch any running Discord bots." >&2
fi
