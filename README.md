**🇺🇸English** · [🇨🇳中文](README.zh.md)

# claude-code-discord-multibot

One dedicated Discord bot per Claude Code project · independent state · zero cross-talk · scales to hundreds of bots

> **Sibling project:** [`claude-code-telegram-multibot`](https://github.com/Lihan-Zhong/claude-code-telegram-multibot) — same architecture on Telegram. Pick this Discord version if you've outgrown Telegram's 20-bot @BotFather cap, or want Discord-only features like `fetch_messages` and bidirectional reactions.

> **TL;DR** — pair the official `[discord` plugin](https://github.com/anthropics/claude-plugins-official) with a few shell functions and a Claude Code skill, so each project directory gets its own Discord bot. Switch projects in Discord by switching channels, not terminals. Sister project to `[claude-code-telegram-multibot](https://github.com/Lihan-Zhong/claude-code-telegram-multibot)` — same architecture, different platform.
>
> Use Discord when you've outgrown Telegram's 20-bot hard cap, or want richer features: message history via `fetch_messages`, bidirectional reactions, threads, channel-based organization.

## ✨ Why

The official Discord plugin assumes **one bot per user**. If you want multiple Claude Code projects each bridged to a different Discord channel, the default setup runs into two walls:

- Every `claude` invocation spawns the plugin's MCP server, which uses a singleton state directory by default. Each new session disrupts the previous one.
- The `/discord:access` skill hardcodes the default state directory path, so per-project pairing workflows fail.

The trick: the plugin's `server.ts` honors a `DISCORD_STATE_DIR` environment variable. Point it at a unique directory per project and you get full isolation — separate token, separate pairing, separate bot server, no fighting.

The shell functions in `claude-dc.bash` derive `DISCORD_STATE_DIR` from `basename "$PWD"`, so launching `claude-dc` in any project directory automatically targets that project's own bot. The companion skill (`SKILL.md`) teaches Claude Code agents the architecture, so saying *"add a new Discord bot for this project"* becomes a one-shot operation.

This skill / architecture is also not limited to **Claude Code** — it can be ported to Codex, OpenClaw, or other agent platforms. And the same idea works for any chat platform: Telegram (sibling repo), Slack, IRC, Matrix, iMessage, etc. — wherever you have a per-token-per-channel bot model.

## 🚀 Quick start

> Prereqs: Claude Code installed · official `discord` plugin enabled in `~/.claude/settings.json` · `bun` on `$PATH` · org policy permits the `discord` channel plugin (admin must add it to `allowedChannelPlugins`) · Discord account + a Discord server you control.

```bash
# 1. Install
git clone https://github.com/Lihan-Zhong/claude-code-discord-multibot.git
cd claude-code-discord-multibot

# 2. Load the shell functions
echo "source $PWD/claude-dc.bash" >> ~/.bashrc
source ~/.bashrc

# 3. Install the skill (teaches Claude Code to manage the setup)
mkdir -p ~/.claude/skills/setup-discord-multibot
cp SKILL.md ~/.claude/skills/setup-discord-multibot/SKILL.md
```

Add a bot for a project:

```bash
cd /path/to/my-project           # whatever project

# At https://discord.com/developers/applications:
#   1. New Application → name it
#   2. Bot tab → Reset Token → copy
#   3. Enable Message Content Intent
#   4. OAuth2 → URL Generator → scope: bot + permissions → invite to your server

claude-dc-init                   # paste the token; writes a .env
claude-dc                        # launch Claude Code with this bot attached

# In Discord: DM your new bot any plain message (e.g. "hi")
# Bot replies with a 6-char pair code
claude-dc-pair <6-char-code>     # if jq is installed
# Or in the Claude Code session: "I got the pair code, please pair me."
```

Done. Future `cd /path/to/my-project && claude-dc` re-attaches to the same bot.

## 🚀 Much easier quick start

```bash
# 1. Install
git clone https://github.com/Lihan-Zhong/claude-code-discord-multibot.git
cd claude-code-discord-multibot
```

Then, ask your Claude Code session to read this whole repo and follow `SKILL.md`. The agent will walk you through every step 🔥

## ‼️ Recommended usage

- Step 1: deploy your **first Discord bot** for your `$HOME` directory — connect your "manager" Claude Code terminal here.
- Step 2: use that "manager" bot to help you deploy subsequent project-specific bots (the manager handles state dir / .env / pairing for you).
- Then: you have an army of project-specific Discord bots, each in its own channel or DM, easy to switch between.

## 📁 What's in this repo

- `**claude-dc.bash`** — four shell functions: `claude-dc`, `claude-dc-init`, `claude-dc-alt`, `claude-dc-pair`. Source from `~/.bashrc`.
- `**SKILL.md**` — Claude Code skill that teaches an agent the architecture. Drop into `~/.claude/skills/setup-discord-multibot/SKILL.md`.
- `**README.md**` / `**README.zh.md**` — this file (English / 中文).
- `**LICENSE**` — MIT.
- `**.gitignore**` — keeps tokens and state dirs out of git by default.

## 🧩 Two bots in the same project (alt mode)

Want two independent Claude Code sessions on the same project — a "primary" run and a "what if I tried it this way" experiment? Use `claude-dc-alt`:

```bash
cd /path/to/my-project

# After setting up the primary bot:
mkdir -p ~/.claude-discord/$(basename "$PWD")-2
$EDITOR ~/.claude-discord/$(basename "$PWD")-2/.env   # paste a second bot's token

claude-dc-alt        # variant 2 by default
claude-dc-alt 3      # variant 3, if you want a third
```

`claude-dc-alt` also exports `CLAUDE_BOT_VARIANT=N`, so your project rules can pick a variant-specific sandbox directory:

```bash
# in your CLAUDE.md or project rules
SANDBOX="Intermediate_data/for_claude${CLAUDE_BOT_VARIANT:+_${CLAUDE_BOT_VARIANT}}"
```

Bot A writes to `Intermediate_data/for_claude/`, bot A-alt writes to `Intermediate_data/for_claude_2/`. No collisions.

## 🤖 Multi-bot collaboration (Discord-specific)

Unlike Telegram, Discord lets multiple bots share a channel and see each other's messages. This enables a "team of agents in one room" workflow — e.g. `@planner_bot`, `@coder_bot`, `@reviewer_bot` all in one channel coordinating via @mentions.

Trade-off: bots in shared channels see all channel messages as `<channel>` events even when they don't act, which inflates each bot's session context. Recommended pattern: keep bots in isolated channels for daily work; create **temporary "war-room" channels** when you need real cross-bot collaboration, then archive when done.

See `SKILL.md` "Multi-bot collaboration via shared channels" for details.

## 🗂️ State directory layout

```
~/.claude-discord/
├── <project-A-basename>/
│   ├── .env                   # DISCORD_BOT_TOKEN=...   (chmod 600)
│   ├── access.json            # dmPolicy / allowFrom / pending (chmod 600)
│   ├── approved/<senderId>    # pairing-confirm signal file (contents: chatId)
│   └── inbox/                 # received attachments (photos etc.)
├── <project-A-basename>-2/    # alt bot for project A
└── <project-B-basename>/
    └── ...
```

## 🐛 Known issues

> See `[SKILL.md](SKILL.md)` for the full troubleshooting catalogue.

- **Inbound messages aren't reaching the agent (one-way).** Most common cause: org policy doesn't include `discord` in `allowedChannelPlugins`. Admin must enable via Claude.ai Admin Console → Claude Code → Channels. Editing `~/.claude/remote-settings.json` locally is futile — the server overwrites within an hour.
- `**/discord:access pair` reports "code not found".** The official skill hardcodes the default state dir path. Use `claude-dc-pair` from this repo, or follow the manual file-edit path in SKILL.md.
- **MCP "failed — Skipping connection" cached.** Run `/doctor` then `/mcp` inside Claude Code. `/mcp` offers a manual retry.
- **Discord bot doesn't see message text.** Enable "Message Content Intent" in Developer Portal → Bot → Privileged Gateway Intents.
- `**stop_reason: refusal` mid-session.** Anthropic's safety classifier can false-positive on bloated sessions. Recovery: `/exit` then `claude-dc` (**no `-c`/`-r`** — those resume the poisoned session). Rebuild context from project files. Mitigation: keep tool outputs small, write big results to files instead of pasting them through the agent.

## 🔒 Security notes

- Bot tokens grant full control of the bot. `.env` files are `chmod 600` inside `chmod 700` directories. Don't commit them, don't share OAuth invite URLs widely. The included `.gitignore` excludes `.env`, `*.env`, `.claude-discord/`, `.claude/channels/`.
- `allowFrom` is the only gate to a Claude Code session behind a bot. Anyone whose Discord snowflake ID is listed can effectively type into the paired session. Treat the list as carefully as shell access.
- The plugin sends outbound traffic only to `discord.com/api/v10` and `gateway.discord.gg`. No third-party endpoints.
- Be cautious with "Public Bot" toggle — if Public, anyone with the OAuth URL can install the bot into their own server. Keep the URL private.

## 🆚 vs the Telegram sibling


| Dimension                    | [Telegram sibling](https://github.com/Lihan-Zhong/claude-code-telegram-multibot) | This (Discord)                                  |
| ---------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------- |
| Hard bot count limit         | 20 per @BotFather account                                                        | Effectively unlimited                           |
| New-bot setup                | 3 steps in @BotFather chat (~2 min)                                              | ~~6 steps in Developer Portal browser (~~5 min) |
| Markdown formatting          | MarkdownV2 with full escape                                                      | Discord Markdown, almost no escape              |
| Headers (`# H1`)             | Not supported                                                                    | Supported                                       |
| Message history API          | Not available (bot API limit)                                                    | `fetch_messages` tool                           |
| Reactions                    | Bot → user only                                                                  | Bidirectional (user reactions visible to bot)   |
| Multi-bot collab in one room | Not supported (private DMs only)                                                 | Supported via shared channels                   |
| Mobile notifications         | Fastest                                                                          | Slightly slower                                 |


The Telegram sibling repo is recommended if you have <20 bots and prefer @BotFather's simpler in-app flow; this Discord repo is recommended for scale (50+ bots) or advanced collaboration patterns.

## 🤝 Contributing

PRs welcome, especially:

- Variant-aware `claude-dc-pair` (currently only handles the primary bot's state dir).
- A reference implementation of multi-bot orchestrator on top of this skill (planner / coder / reviewer / tester pattern).
- Adaptations for Slack (no official plugin yet, requires a Slack bridge).

## 📜 License

MIT — see `[LICENSE](LICENSE)`.