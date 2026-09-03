# claude-dc.bash — Shell functions for the Claude Code multi-bot Discord setup.
#
# Source this file from your ~/.bashrc (or paste these functions in directly).
#
# Provides:
#   claude-dc              — launch Claude Code with the primary Discord bot for the current project dir
#   claude-dc-alt [N]      — launch Claude Code with the Nth alt bot (default N=2) in the SAME project dir
#                            (lets you run two independent agents in one project, each with its own bot)
#   claude-dc-init         — interactive: paste a fresh bot token from Discord Developer Portal to seed a new project's .env
#   claude-dc-pair <code>  — manually approve a pairing code (alternative to /discord:access pair).
#                            Requires `jq`. Useful when /discord:access misroutes because of a custom state dir.
#   claude-dc-resume       — resume the PRIMARY bot's own session in a directory that has alt variants
#   claude-dc-alt-resume N — resume alt N's own session in that same directory
#
# Why the two resume helpers exist: Claude Code keys sessions on the working directory alone, and
# nothing binds a session to DISCORD_STATE_DIR. In a directory with two bots, `-c` continues the
# newest transcript regardless of which bot wrote it, and `-r`'s picker lists both siblings without
# saying which is which. These two helpers attribute a session before resuming it.
#
# State layout per project (created on first use):
#   ~/.claude-discord/<basename-of-cwd>/         # primary bot, claude-dc
#   ~/.claude-discord/<basename-of-cwd>-2/       # alt bot 2, claude-dc-alt
#   ~/.claude-discord/<basename-of-cwd>-N/       # alt bot N, claude-dc-alt N
#
# Each state dir holds:
#   .env             # DISCORD_BOT_TOKEN=...  (chmod 600)
#   access.json      # dmPolicy, allowFrom, pending, groups
#   approved/<id>    # one-shot pairing-confirm signals
#
# Requires:
#   - claude (the Claude Code CLI), already in PATH
#   - the `discord` plugin from anthropics/claude-plugins-official, enabled in ~/.claude/settings.json
#     ("enabledPlugins": { "discord@claude-plugins-official": true })
#     and installed at USER scope — see README, "Plugin must be installed at user scope"
#   - org policy allows the discord channel plugin (Claude.ai Admin Console → Claude Code → Channels
#     → Allowed Channel Plugins must include `discord`)

# Optional: re-apply the local plugin patches on every shell start. patch-discord-plugin.sh is
# idempotent, so this is a no-op once the patches are in place, and it silently repairs them after
# a plugin upgrade overwrites server.ts. Drop this block if you do not use the patches.
if [ -x "$HOME/.claude/patch-discord-plugin.sh" ]; then
  "$HOME/.claude/patch-discord-plugin.sh" --quiet
fi

# Defensive: remove any stale alias before defining functions.
unalias claude-dc 2>/dev/null

# Same-cwd bots (claude-dc + claude-dc-alt N) share ONE transcript bucket, because Claude Code
# keys sessions on cwd alone — nothing binds a session to DISCORD_STATE_DIR. So `-c` resumes the
# most RECENT session in this directory, which may belong to the OTHER bot: you would end up with
# bot A's Discord channel driving bot B's conversation. Warn, never block.
_claude_dc_resume_warn() {
  local base="$1"; shift
  local wants_resume=0 a
  for a in "$@"; do
    case "$a" in -c|--continue|-r|--resume) wants_resume=1 ;; esac
  done
  [ "$wants_resume" -eq 1 ] || return 0
  local siblings
  siblings=$(ls -d "$HOME/.claude-discord/${base}" "$HOME/.claude-discord/${base}"-[0-9]* 2>/dev/null | wc -l)
  [ "${siblings:-0}" -gt 1 ] && {
    echo "⚠️  This directory has $siblings bot variants sharing ONE session history." >&2
    echo "    -c/--continue picks the most recent session, which may be the OTHER bot's." >&2
    echo "    Use claude-dc-resume / claude-dc-alt-resume N instead, or omit -c to start fresh." >&2
  }
  return 0
}

claude-dc() {
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  mkdir -p "$state"
  chmod 700 "$state"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found!" >&2
    echo "   Create a Discord app+bot at https://discord.com/developers/applications," >&2
    echo "   then run:" >&2
    echo "   claude-dc-init" >&2
    return 1
  fi
  _claude_dc_resume_warn "$(basename "$PWD")" "$@"
  DISCORD_STATE_DIR="$state" command claude --channels plugin:discord@claude-plugins-official "$@"
}

claude-dc-init() {
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  mkdir -p "$state" && chmod 700 "$state"
  echo "Paste the bot token from Discord Developer Portal, then press Enter:"
  read -r token
  printf "DISCORD_BOT_TOKEN=%s\n" "$token" > "$state/.env"
  chmod 600 "$state/.env"
  echo "✅ Saved to $state/.env"
  echo "   Now you can run claude-dc to start!"
}

claude-dc-alt() {
  local variant
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    variant="$1"
    shift
  else
    variant="2"
  fi
  local state="$HOME/.claude-discord/$(basename "$PWD")-${variant}"
  mkdir -p "$state"
  chmod 700 "$state"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found" >&2
    echo "   Set up Discord bot #${variant}: write token to $state/.env" >&2
    return 1
  fi
  _claude_dc_resume_warn "$(basename "$PWD")" "$@"
  DISCORD_STATE_DIR="$state" CLAUDE_BOT_VARIANT="$variant" command claude --channels plugin:discord@claude-plugins-official "$@"
}

claude-dc-pair() {
  if [ -z "$1" ]; then
    echo "Usage: claude-dc-pair <6-char-code>" >&2
    echo "Run from the project directory after DMing the bot." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq not installed. Install it with your package manager, e.g.:" >&2
    echo "   apt install jq   |   brew install jq   |   conda install -c conda-forge jq" >&2
    return 1
  fi
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  local acc="$state/access.json"
  local code="$1"
  if [ ! -f "$acc" ]; then
    echo "⚠️  No access.json at $acc" >&2
    echo "   Start claude-dc in this directory first, then DM the bot." >&2
    return 1
  fi
  local sender chat
  sender=$(jq -r --arg c "$code" '.pending[$c].senderId // empty' "$acc")
  chat=$(jq -r --arg c "$code" '.pending[$c].chatId // empty' "$acc")
  if [ -z "$sender" ]; then
    echo "⚠️  Code '$code' not found in pending. Current pending entries:" >&2
    jq '.pending | keys' "$acc" >&2
    return 1
  fi
  local tmp
  tmp=$(mktemp)
  # NOTE: in Discord, senderId (the user) and chatId (the DM channel) are DIFFERENT snowflakes,
  # unlike Telegram where they coincide for DMs. Keep them apart.
  jq --arg s "$sender" --arg c "$code" \
    '.allowFrom = (.allowFrom + [$s] | unique) | del(.pending[$c])' \
    "$acc" > "$tmp" && mv "$tmp" "$acc" && chmod 600 "$acc"
  mkdir -p "$state/approved"
  printf '%s' "$chat" > "$state/approved/$sender"
  echo "✅ Paired sender $sender in $(basename "$state")"
}

# Resume the PRIMARY bot's own session in a directory that has alt variants.
#
# How it attributes a session: score ONLY the session opening (the first 30 records) — that is what
# the harness injected (the auto-loaded MEMORY.md, the CLAUDE.md/rules render), not what the
# conversation later happened to discuss. An alt's opening carries its own `variant_<N>/` and
# `for_claude_<N>` namespace; the primary's carries neither.
#
# Scoring the WHOLE transcript does NOT work, and this is worth knowing before you "improve" it:
# the primary's transcript mentions `variant_2` plenty (you discuss the alt in it), and every
# session contains the literal string `CLAUDE_BOT_VARIANT` because the rules text names it. On one
# real five-session directory, whole-file scoring could not separate them at all; opening-only
# scoring gave 0 for the primary and 3-4 for each alt.
#
# Usage: claude-dc-resume            → newest session that looks like the primary's
#        claude-dc-resume <sid>      → resume exactly that session id (escape hatch)
claude-dc-resume() {
  local base state enc dir pick sid
  base="$(basename "$PWD")"
  state="$HOME/.claude-discord/${base}"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found — is this the right directory?" >&2
    return 1
  fi
  enc="$(printf '%s' "$PWD" | sed 's|[/_]|-|g')"
  dir="$HOME/.claude/projects/$enc"

  # Escape hatch: an explicit session id wins over any guessing.
  if [ -n "$1" ] && [ -f "$dir/$1.jsonl" ]; then
    sid="$1"; shift
    echo "▶ resuming primary session ${sid:0:8}… (explicit)" >&2
    DISCORD_STATE_DIR="$state" command claude --channels plugin:discord@claude-plugins-official --resume "$sid" "$@"
    return
  fi

  if [ ! -d "$dir" ]; then
    echo "ℹ️  no transcripts yet for this directory — starting fresh." >&2
    claude-dc "$@"; return
  fi
  pick="$(
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      # `grep -c` can emit multiple lines; squeeze to digits or the numeric test below explodes
      # with "integer expression expected".
      n=$(head -30 "$f" | grep -cE 'variant_[0-9]|for_claude_[0-9]' 2>/dev/null | head -1 | tr -dc '0-9')
      [ "${n:-0}" -eq 0 ] 2>/dev/null && printf '%s\t%s\n' "$(stat -c %Y "$f")" "$f"
    done | sort -rn | head -1 | cut -f2
  )"
  if [ -z "$pick" ]; then
    echo "ℹ️  no session looks like the primary's — starting fresh instead." >&2
    echo "    (to force one: claude-dc-resume <session-id>; list them with" >&2
    echo "     ls -t $dir/*.jsonl)" >&2
    claude-dc "$@"; return
  fi
  sid="$(basename "$pick" .jsonl)"
  echo "▶ resuming primary session ${sid:0:8}… ($(date -r "$pick" '+%m-%d %H:%M'))" >&2
  DISCORD_STATE_DIR="$state" command claude --channels plugin:discord@claude-plugins-official --resume "$sid" "$@"
}

# Resume the session that belongs to THIS variant, never the sibling's. Mirror of the above: score
# each transcript by how often it references `memory/variant_<N>/` — the alt's own namespace, which
# the primary's sessions essentially never write — and resume the newest one scoring >= 3. Falls
# back to a fresh start rather than guessing.
claude-dc-alt-resume() {
  local variant="${1:-2}"; shift 2>/dev/null || true
  local base state enc dir pick
  base="$(basename "$PWD")"
  state="$HOME/.claude-discord/${base}-${variant}"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found — is variant ${variant} set up?" >&2
    return 1
  fi
  enc="$(printf '%s' "$PWD" | sed 's|[/_]|-|g')"
  dir="$HOME/.claude/projects/$enc"
  if [ ! -d "$dir" ]; then
    echo "ℹ️  no transcripts yet for this directory — starting fresh." >&2
    claude-dc-alt "$variant" "$@"; return
  fi
  pick="$(
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] || continue
      n=$(grep -c "variant_${variant}" "$f" 2>/dev/null | head -1 | tr -dc '0-9')
      [ -n "$n" ] && [ "$n" -ge 3 ] 2>/dev/null && printf '%s\t%s\n' "$(stat -c %Y "$f")" "$f"
    done | sort -rn | head -1 | cut -f2
  )"
  if [ -z "$pick" ]; then
    echo "ℹ️  no session clearly belongs to variant ${variant} — starting fresh instead." >&2
    claude-dc-alt "$variant" "$@"; return
  fi
  local sid; sid="$(basename "$pick" .jsonl)"
  echo "▶ resuming variant-${variant} session ${sid:0:8}… ($(date -r "$pick" '+%m-%d %H:%M'))" >&2
  DISCORD_STATE_DIR="$state" CLAUDE_BOT_VARIANT="$variant" \
    command claude --channels plugin:discord@claude-plugins-official --resume "$sid" "$@"
}
