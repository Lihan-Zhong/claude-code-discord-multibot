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
# saying which is which. These two helpers attribute a session before resuming it — by which bot's
# private DM channel last delivered a message into it (claude-dc-pick-session.py). In such a
# directory, `claude-dc -c` and `claude-dc-alt N -c` are rerouted to the same picker.
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
#   dm_channel       # this bot's DM channel id, cached by claude-dc-pick-session.py (chmod 600)
#
# Requires:
#   - claude (the Claude Code CLI), already in PATH
#   - python3 on PATH and ~/.claude/claude-dc-pick-session.py — only for the resume helpers and
#     the -c reroute; without them those start a fresh session instead of guessing
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
# keys sessions on cwd alone — nothing binds a session to DISCORD_STATE_DIR. `-c` is handled by
# rerouting it (see claude-dc below). `-r` cannot be rerouted — it is an interactive picker — so it
# gets a warning: its list does not say which session is which bot's. Warn, never block.
_claude_dc_resume_warn() {
  local base="$1"; shift
  local a
  for a in "$@"; do
    case "$a" in
      -r|--resume)
        _claude_dc_has_siblings "$base" && {
          echo "⚠️  Several bots share this directory, and ONE session history." >&2
          echo "    The -r list does not say which session is which bot's." >&2
          echo "    Use claude-dc-resume / claude-dc-alt-resume N instead." >&2
        }
        return 0 ;;
    esac
  done
  return 0
}

# Does this project directory host more than one bot, i.e. at least one alt? Any number of alts.
# Only exact <base>-<digits> state dirs count: a bare `<base>-[0-9]*` glob would also match an
# unrelated directory that merely starts with "<base>-2…" (say, `<base>-2025notes`).
_claude_dc_has_siblings() {
  local d
  for d in "$HOME/.claude-discord/$1"-[0-9]*; do
    [ -f "$d/.env" ] && [[ "$(basename "$d")" =~ ^.+-[0-9]+$ ]] && [ "${d%-*}" = "$HOME/.claude-discord/$1" ] && return 0
  done
  return 1
}

# Was -c / --continue among the arguments?
_claude_dc_wants_continue() {
  local a; for a in "$@"; do case "$a" in -c|--continue) return 0;; esac; done; return 1
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
  # In a directory shared by several bots, `-c` would continue whichever transcript is newest,
  # whoever wrote it — which is how an alt can end up driving the primary's conversation. So here
  # -c is not passed through: it is rerouted to the DM-channel picker, which resumes the session
  # this bot's own DM channel last drove (or starts fresh — it never guesses). Other args are kept.
  if _claude_dc_wants_continue "$@" && _claude_dc_has_siblings "$(basename "$PWD")"; then
    local -a rest=(); local a
    for a in "$@"; do case "$a" in -c|--continue) ;; *) rest+=("$a");; esac; done
    echo "ℹ️  Several bots share this directory: -c rerouted to the DM-channel picker (same as claude-dc-resume)." >&2
    _claude_dc_resume_as "$state" "" claude-dc -- "${rest[@]}"
    return
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
  if _claude_dc_wants_continue "$@" && _claude_dc_has_siblings "$(basename "$PWD")"; then
    local -a rest=(); local a
    for a in "$@"; do case "$a" in -c|--continue) ;; *) rest+=("$a");; esac; done
    echo "ℹ️  Several bots share this directory: -c rerouted to the DM-channel picker (same as claude-dc-alt-resume ${variant})." >&2
    _claude_dc_resume_as "$state" "$variant" claude-dc-alt "$variant" -- "${rest[@]}"
    return
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

# Resume the session that belongs to THIS bot — by ground truth, not by guessing.
#
# Sessions are keyed on the working directory alone; nothing binds one to the bot that drove it,
# so in a directory shared by a primary and an alt, `-c` is a coin flip and `-r` lists both
# siblings without saying which is which.
#
# v2.0 guessed ownership from transcript TEXT: the alt helper counted `variant_N` across the whole
# transcript, the primary helper scored only the session opening. The first guess failed for real:
# a primary bot had discussed its alt so often that its own transcript held 104 mentions of
# `variant_2`, every session in the directory looked like the alt's, and the alt resumed the
# primary's conversation. The check had passed when it was written; the signal decayed as the
# conversation grew. The second has a related weakness: the opening says who STARTED a session,
# not who drives it now.
#
# Now: ~/.claude/claude-dc-pick-session.py asks which bot's PRIVATE DM CHANNEL the session last
# received a message on. That is the channel the harness actually delivered through — not inferred
# from anything that was said. Each bot's DM id is fetched once and cached in <state dir>/dm_channel.
# If the bot's DM can't be determined, it picks nothing and we start fresh. It never guesses.
#
# Usage: claude-dc-resume [<sid>]          the primary bot
#        claude-dc-alt-resume [N] [<sid>]  alt N (default 2)
#        an explicit session id always wins over the picker (escape hatch)

# Claude Code's transcript bucket for $PWD: the physical path, every non-alphanumeric -> '-'.
_claude_dc_transcript_dir() {
  local p enc first=""
  for p in "$(pwd -P)" "$PWD"; do
    enc="$(printf '%s' "$p" | sed 's/[^A-Za-z0-9]/-/g')"
    [ -n "$first" ] || first="$enc"
    [ -d "$HOME/.claude/projects/$enc" ] && { printf '%s\n' "$HOME/.claude/projects/$enc"; return; }
  done
  printf '%s\n' "$HOME/.claude/projects/$first"
}

_claude_dc_resume_as() {   # <state-dir> <variant|""> <launcher-for-fresh-start...> -- [args...]
  local state="$1" variant="$2"; shift 2
  local -a fresh=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do fresh+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found — is this the right directory / variant?" >&2
    return 1
  fi
  local dir sid="" rc=0
  local picker="$HOME/.claude/claude-dc-pick-session.py"
  dir="$(_claude_dc_transcript_dir)"
  if [ -n "${1:-}" ] && [ -f "$dir/$1.jsonl" ]; then
    sid="$1"; shift
    echo "▶ resuming ${sid:0:8}… (explicit)" >&2
  else
    # A missing picker must say so. Swallowing the error would report "no session belongs to this
    # bot" — a wrong reason that sends you looking in the wrong place.
    if [ ! -f "$picker" ]; then
      echo "⚠️  $picker is not installed — cannot tell which session belongs to this bot." >&2
      echo "    Starting fresh rather than guessing. To resume: cp claude-dc-pick-session.py ~/.claude/" >&2
      "${fresh[@]}" "$@"; return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "⚠️  python3 is not on PATH — cannot run $picker. Starting fresh rather than guessing." >&2
      "${fresh[@]}" "$@"; return
    fi
    sid="$(python3 "$picker" "$PWD" "$state" 2>/dev/null)" || rc=$?
    if [ -z "$sid" ]; then
      if [ "$rc" -eq 2 ]; then
        echo "ℹ️  could not determine this bot's DM channel — starting fresh instead." >&2
      else
        echo "ℹ️  no session here was last driven by this bot — starting fresh instead." >&2
      fi
      echo "    (to see why: python3 $picker \"\$PWD\" $state -v)" >&2
      "${fresh[@]}" "$@"; return
    fi
    echo "▶ resuming ${sid:0:8}… ($(date -r "$dir/$sid.jsonl" '+%m-%d %H:%M' 2>/dev/null)) — last driven by this bot" >&2
  fi
  if [ -n "$variant" ]; then
    DISCORD_STATE_DIR="$state" CLAUDE_BOT_VARIANT="$variant" \
      command claude --channels plugin:discord@claude-plugins-official --resume "$sid" "$@"
  else
    DISCORD_STATE_DIR="$state" \
      command claude --channels plugin:discord@claude-plugins-official --resume "$sid" "$@"
  fi
}

claude-dc-resume() {
  _claude_dc_resume_as "$HOME/.claude-discord/$(basename "$PWD")" "" claude-dc -- "$@"
}

claude-dc-alt-resume() {
  local variant="2"
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then variant="$1"; shift; fi
  _claude_dc_resume_as "$HOME/.claude-discord/$(basename "$PWD")-${variant}" "$variant" claude-dc-alt "$variant" -- "$@"
}
