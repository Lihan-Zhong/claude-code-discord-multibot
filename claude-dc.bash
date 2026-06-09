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
#   - org policy allows the discord channel plugin (Claude.ai Admin Console → Claude Code → Channels
#     → Allowed Channel Plugins must include `discord`)
#
# Defensive: remove any stale alias before defining functions.
unalias claude-dc 2>/dev/null

claude-dc() {
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  mkdir -p "$state"
  chmod 700 "$state"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found" >&2
    echo "   Create a Discord application+bot at https://discord.com/developers/applications," >&2
    echo "   then run:" >&2
    echo "   claude-dc-init" >&2
    return 1
  fi
  DISCORD_STATE_DIR="$state" command claude --channels plugin:discord@claude-plugins-official "$@"
}

claude-dc-init() {
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  mkdir -p "$state" && chmod 700 "$state"
  echo "Paste the bot token from Discord Developer Portal (Bot tab → Reset Token), then press Enter:"
  read -r token
  printf "DISCORD_BOT_TOKEN=%s\n" "$token" > "$state/.env"
  chmod 600 "$state/.env"
  echo "✅ Saved to $state/.env"
  echo "   Now run: claude-dc"
}

claude-dc-alt() {
  # Numeric first arg = variant suffix (e.g. claude-dc-alt 3 -> state dir basename-3).
  # Otherwise default to 2.
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
    echo "   Set up bot #${variant}: write the Discord bot token to $state/.env" >&2
    return 1
  fi
  # CLAUDE_BOT_VARIANT lets project rules (e.g. a CLAUDE.md sandbox section) resolve
  # variant-specific working dirs (Intermediate_data/for_claude_<N>/) so alt bots in
  # the same project dir don't collide with the primary bot.
  DISCORD_STATE_DIR="$state" CLAUDE_BOT_VARIANT="$variant" command claude --channels plugin:discord@claude-plugins-official "$@"
}

claude-dc-pair() {
  if [ -z "$1" ]; then
    echo "Usage: claude-dc-pair <6-char-code>" >&2
    echo "Run from the project directory after DMing the bot." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq not installed. Install with one of:" >&2
    echo "   conda install -c conda-forge jq" >&2
    echo "   sudo apt install jq    # Debian/Ubuntu" >&2
    echo "   brew install jq        # macOS" >&2
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
  jq --arg s "$sender" --arg c "$code" \
    '.allowFrom = (.allowFrom + [$s] | unique) | del(.pending[$c])' \
    "$acc" > "$tmp" && mv "$tmp" "$acc" && chmod 600 "$acc"
  # Discord: senderId and chatId are DIFFERENT snowflakes (unlike Telegram). The
  # approved signal file is named senderId, contents are chatId.
  mkdir -p "$state/approved"
  printf '%s' "$chat" > "$state/approved/$sender"
  echo "✅ Paired sender $sender in $(basename "$state")"
}
