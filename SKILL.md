---
name: setup-discord-multibot
description: Configure or extend a multi-bot Discord setup for Claude Code, where each project directory is bridged to its own dedicated Discord bot. Use when the user wants to (a) add a new Discord bot for a new project, (b) initially set up the per-project Discord architecture, (c) pair a bot when the official /discord:access skill misbehaves, (d) debug why a project's Discord bot isn't responding, or (e) migrate an existing Telegram-bot project to Discord. Triggers include "new Discord bot", "add a Discord bot for project X", "Discord plugin", "set up Discord multi-bot", "pair this Discord bot", "migrate to Discord", "DISCORD_STATE_DIR", "claude-dc". Parallel to setup-telegram-multibot — same architecture, different platform.
---

# Discord Multi-Bot Setup for Claude Code

This skill handles **one Discord bot per Claude Code project**, the Discord analogue of the Telegram multi-bot setup. Each project directory has its own bot token, its own pairing state, and its own bot server process — they don't compete with each other, and switching projects in Discord is just switching channels (or DMs).

Discord is the preferred platform when the user is past Telegram's 20-bot limit (BotFather enforces a hard cap), or wants richer features: message history via `fetch_messages`, bidirectional reactions, threads, channel-based organization.

## Critical architecture insight

Identical to the Telegram trick. The official `claude-plugins-official/discord` plugin's `server.ts` honors a `DISCORD_STATE_DIR` environment variable that overrides the default state directory (`~/.claude/channels/discord/`). Every state file (`.env`, `access.json`, `approved/`, `inbox/`) lives under whatever path is set.

By giving each project a unique `DISCORD_STATE_DIR`, you get full isolation: separate token, separate pairing, separate bot server, no fighting. Combined with a per-project bot token (one Discord Developer Portal application per project), you get the "one channel per project" UX in Discord.

## Prerequisites

Before doing any of this, verify:

1. **Org policy allows the Discord channel plugin.** Check `~/.claude/remote-settings.json` for both:
   - `"channelsEnabled": true`
   - An entry for `plugin: discord` in `allowedChannelPlugins`

   If `discord` is not in the allowlist, the channel registration is blocked by org policy. Outbound (reply tool) may still work, but inbound channel events do NOT reach Claude — symptom is "I send Discord messages but the agent doesn't see them." The admin must enable it via Claude.ai Admin Console → Claude Code → Channels → Allowed Channel Plugins. **Editing the local file is futile** — the server overwrites it within an hour.

2. **Plugin is enabled.** Check `~/.claude/settings.json` has `"discord@claude-plugins-official": true` under `enabledPlugins`.

3. **`bun` is installed.** Check `which bun`.

4. **Optional but recommended: `jq`** for the `claude-dc-pair` helper.

5. **Discord account + a Discord server.** The user needs at least one Discord server they own/admin so they can invite their bots into it. Servers are free and instant to create.

## One-time setup

Check if the baseline is already done:

- `~/.bashrc` contains `claude-dc()` function (NOT just an alias)
- `~/.claude-discord/` directory exists

If those are missing, source the `claude-dc.bash` file from this repo in your `~/.bashrc` (or paste the four function definitions directly). The file defines `claude-dc`, `claude-dc-init`, `claude-dc-alt`, and `claude-dc-pair`.

**Important**: Use **functions**, not aliases. Bash expands aliases before parsing function definitions, so re-sourcing `.bashrc` while an old `claude-dc` alias is in memory triggers `syntax error near unexpected token '('`. The leading `unalias claude-dc 2>/dev/null` (included in `claude-dc.bash`) neutralizes any leftover alias.

## Multiple bots in the same project directory (advanced)

Same convention as Telegram: `claude-dc-alt N` uses state dir `~/.claude-discord/<basename>-N/` and injects `CLAUDE_BOT_VARIANT=N`. Project rules can pick a variant-specific sandbox dir via:

```bash
SANDBOX="Intermediate_data/for_claude${CLAUDE_BOT_VARIANT:+_${CLAUDE_BOT_VARIANT}}"
```

Note: `claude-dc-pair` only handles the primary state dir. For alt bots, do the manual file edit (Option B in Step 5 below).

## Adding a new bot (the recurring task)

Each new project gets a new bot. Walk the user through these steps:

### Step 1: Create a bot via Discord Developer Portal

The user opens https://discord.com/developers/applications in a browser:

1. Click **"New Application"**, give it a name (e.g. "project-X-bot")
2. Left menu → **"Bot"** tab
3. Find **"Token"** section → click **"Reset Token"** → **copy the token** (it's shown only once)
4. **Optionally disable** "Public Bot" — if Discord errors with "Private application cannot have a default authorization link", skip this; it's not a deal-breaker (Public Bot ON is fine as long as you don't share the OAuth invite URL publicly)
5. In **"Privileged Gateway Intents"** section:
   - ✅ Enable **"Message Content Intent"** (required — without it the bot can't see message text)
   - Presence Intent and Server Members Intent can stay off for our use case

### Step 2: Invite the bot to the user's Discord server

In the same Application:

1. Left menu → **"OAuth2"** → **"URL Generator"** sub-tab
2. **Scopes** → ✅ check **"bot"**
3. **Bot Permissions** → check at minimum:
   - ✅ View Channels
   - ✅ Send Messages
   - ✅ Send Messages in Threads
   - ✅ Read Message History
   - ✅ Add Reactions (for `react` tool)
   - ✅ Attach Files (for `reply` with `files`)
   - ✅ Embed Links
4. **DO NOT check "Administrator"** — never needed for self-use bots and gives way too much power
5. Scroll to bottom, copy **"Generated URL"**
6. Paste URL in browser, select the user's Discord server, click **Authorize**

### Step 3: Create the state dir + `.env`

Once you have the token from the user:

```bash
PROJ_BASENAME="$(basename "/full/project/path")"
STATE="$HOME/.claude-discord/$PROJ_BASENAME"
mkdir -p "$STATE"
chmod 700 "$STATE"
```

Write the token to `$STATE/.env` using the Write tool (avoid echoing tokens into shell history):

```
DISCORD_BOT_TOKEN=MTUxMzYz...
```

Then `chmod 600 "$STATE/.env"`.

### Step 4: User starts Claude in the project directory

```bash
cd /full/project/path
claude-dc          # fresh conversation
# or
claude-dc -c       # resume most recent session in this directory
```

### Step 5: User DMs the bot

Have the user DM the bot in Discord (find it in their server's member list → click → Send Message → send "hi"). The bot replies with a 6-character pairing code.

**Discord quirk**: Discord bots cannot DM a user unless they share a server. Since the user just invited the bot into their server in Step 2, DM is available now.

### Step 6: Pair the user

The official `/discord:access pair <code>` skill (parallel to `/telegram:access pair`) hardcodes the default state dir path and does NOT respect `DISCORD_STATE_DIR`. For per-project state dirs, use one of the following:

**Option A: `claude-dc-pair` helper** — user runs `claude-dc-pair <6-char-code>` from the project directory (requires `jq`).

**Option B: Direct filesystem edit** — preferred when the user says "I got the code, please pair me":

1. Read `~/.claude-discord/<basename>/access.json`:
   ```json
   {
     "dmPolicy": "pairing",
     "allowFrom": [],
     "groups": {},
     "pending": {
       "ab1234": {
         "senderId": "<user's Discord snowflake ID>",
         "chatId": "<DM channel snowflake ID>",
         "createdAt": 0,
         "expiresAt": 0
       }
     }
   }
   ```

2. Write a new version (move sender to allowFrom, clear pending):
   ```json
   {
     "dmPolicy": "pairing",
     "allowFrom": ["<senderId>"],
     "groups": {},
     "pending": {}
   }
   ```
   `chmod 600` afterwards.

3. Create the approved-signal file. **Critical: senderId and chatId differ in Discord (unlike Telegram).** Use senderId as the filename and chatId as the contents:
   ```bash
   mkdir -p ~/.claude-discord/<basename>/approved
   printf '<chatId>' > ~/.claude-discord/<basename>/approved/<senderId>
   ```

### Step 7: Test

User sends a normal message (e.g., `test`) to the new bot in Discord. It should appear in the project's Claude session as a `<channel source="plugin:discord:discord" ...>` event. Confirm receipt and you're done.

## Multi-bot collaboration via shared channels (Discord-specific advantage)

Unlike Telegram (where each bot lives in its own private DM and bots cannot see each other), Discord supports **multiple bots in the same channel**, with each bot seeing all messages in that channel. This enables a "team of agents in one room" pattern:

- Create a channel (e.g. `#sciNOMe-pilot`)
- Invite multiple bots into it (each bot's `access.json` must have the channel/server allowed)
- User addresses specific bots via `@mention`
- Each bot's Claude session sees the full channel history but acts independently

**Important gotchas:**

1. **Echo loops.** If a bot is configured to respond to ANY message, it would respond to other bots' replies, causing infinite loops. The default `requireMention: true` (configured per-channel in `access.json`) prevents this — bots only respond when explicitly @-mentioned.

2. **Shared file system, not shared session state.** Both bots see each other's channel messages, but their Claude session jsonl files are independent. If they edit the same file, last writer wins. Coordinate via the user, or assign clear roles (planner vs coder vs reviewer).

3. **Context pollution from shared channels.** Even with `requireMention: true`, bots still **receive** all channel messages as `<channel>` events. Their session jsonl grows with chatter they don't act on. For low-noise routine work, prefer **per-project isolated channels**; only put bots together in shared channels when you genuinely need cross-bot collaboration.

4. **Different `CLAUDE_BOT_VARIANT` for collisions in same project.** If two bots share a project directory (alt mode), they need distinct variant sandboxes (`Intermediate_data/for_claude/`, `Intermediate_data/for_claude_2/`).

## Common issues and how to handle them

### `claude-dc` started but messages don't reach the session (one-way)

- **Most common cause: org policy blocks the channel.** Check `~/.claude/remote-settings.json` for `discord` in `allowedChannelPlugins`. If missing, admin must add it via Claude.ai Admin Console → Claude Code → Channels. The local file is overwritten by the server within an hour.
- **Second cause: MCP IPC link failed.** Run `/mcp` in Claude Code, find discord row, retry. Usually fixes a transient startup race. If unsuccessful, `/exit` and `claude-dc -c`.

### Discord token invalid

Test with `curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot <TOKEN>"`. Should return bot's user object. If `{"message": "401: Unauthorized", "code": 0}`, the token is wrong — go back to Developer Portal → Bot → Reset Token.

### Discord bot doesn't see message text

Most likely: **Message Content Intent** is OFF in the Discord Developer Portal → Bot → Privileged Gateway Intents. Turn it on, save. The bot may need to reconnect.

### Bot in server but not appearing online / not responding

- Confirm the bot was added to the server via the OAuth URL (visible in server's Members list)
- Confirm `claude-dc` is running in a terminal somewhere with the matching `DISCORD_STATE_DIR`
- Test gateway connectivity: `curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot <TOKEN>"`

### `stop_reason: refusal` mid-session

Same as Telegram: Anthropic's safety classifier can false-positive on bloated sessions. Recovery: `/exit` then `claude-dc` (**no `-c`/`-r`** — those resume the poisoned session), then rebuild context from project files.

Mitigation: keep individual tool outputs small (use `head -5` not `cat`), write big results to files and reference by path, don't paste massive content back through the agent.

## File layout reference

```
~/.claude-discord/
├── <project-A-basename>/
│   ├── .env                       # DISCORD_BOT_TOKEN=...      (chmod 600)
│   ├── access.json                # dmPolicy / allowFrom / pending (chmod 600)
│   ├── approved/<senderId>        # pairing-confirm signal file (contents: chatId)
│   └── inbox/                     # received attachments
├── <project-A-basename>-2/        # alt variant 2
└── <project-B-basename>/
    └── ...
```

`access.json` schema is the same as Telegram (`dmPolicy`, `allowFrom`, `pending`, `groups`). For Discord groups (server channels), `groupId` is the channel's Snowflake ID.

## Security notes

- Bot tokens grant full control of the bot. `.env` files are `chmod 600` inside `chmod 700` directories. Never commit them, never share OAuth invite URLs widely.
- `allowFrom` is the only gate to a Claude Code session behind a bot. Discord Snowflake IDs are stable — treat the list as carefully as shell access.
- The Discord plugin sends outbound traffic only to `discord.com/api/v10` and `gateway.discord.gg`.
- Be cautious with "Public Bot" toggle in Developer Portal — if Public, anyone with the OAuth URL can install the bot into their own server. Keep the URL private.

## Cross-reference

For the Telegram-side counterpart with identical architecture, see the `setup-telegram-multibot` skill. Translation table:

| Concept | Telegram | Discord |
| --- | --- | --- |
| Plugin name | `telegram@claude-plugins-official` | `discord@claude-plugins-official` |
| Launch flag | `--channels plugin:telegram@...` | `--channels plugin:discord@...` |
| Env var (token) | `TELEGRAM_BOT_TOKEN` | `DISCORD_BOT_TOKEN` |
| Env var (state dir) | `TELEGRAM_STATE_DIR` | `DISCORD_STATE_DIR` |
| State dir base | `~/.claude-telegram/` | `~/.claude-discord/` |
| Shell functions | `claude-tg{,-init,-alt,-pair}` | `claude-dc{,-init,-alt,-pair}` |
| Bot creation | @BotFather `/newbot` (in-app) | discord.com/developers (browser) |
| Pairing skill | `/telegram:access pair <code>` | `/discord:access pair <code>` |
| `senderId == chatId` for DMs? | Yes | **No** (different Snowflakes) |
| Message history API | Not available | `fetch_messages` tool |
| Bot-to-bot visibility | Hidden | Visible in same channel |
| Reactions visible to bot | Outbound only | Bidirectional |
| Hard bot count limit | 20 per @BotFather / account | Effectively unlimited |
