---
name: setup-discord-multibot
description: Configure or extend a multi-bot Discord setup for Claude Code, where each project directory is bridged to its own dedicated Discord bot. Use when the user wants to (a) add a new Discord bot for a new project, (b) initially set up the per-project Discord architecture, (c) pair a bot when the official /discord:access skill misbehaves, (d) debug why a project's Discord bot isn't responding, or (e) migrate an existing Telegram-bot project to Discord. Triggers include "new Discord bot", "add a Discord bot for project X", "Discord plugin", "set up Discord multi-bot", "pair this Discord bot", "migrate to Discord", "DISCORD_STATE_DIR", "claude-dc". Parallel to setup-telegram-multibot — same architecture, different platform.
---

# Discord Multi-Bot Setup for Claude Code

This skill handles **one Discord bot per Claude Code project**, the Discord analogue of the Telegram multi-bot setup. Each project directory has its own bot token, its own pairing state, and its own bot server process — they don't compete with each other, and switching projects in Discord is just switching channels (or DMs).

Discord is the preferred platform when the user is past Telegram's 20-bot limit, or wants richer features: message history via `fetch_messages`, bidirectional reactions, threads, channel-based organization.

## Critical architecture insight

Identical to the Telegram trick. The official `claude-plugins-official/discord` plugin's `server.ts` reads:

```js
const STATE_DIR = process.env.DISCORD_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'discord')
```

**The `DISCORD_STATE_DIR` environment variable overrides the default.** Every state file (`.env`, `access.json`, `approved/`, `inbox/`) lives under that dir. By giving each project a unique `DISCORD_STATE_DIR`, you get full isolation: separate token, separate pairing, separate bot server, no fighting.

Combined with a per-project bot token (one Discord Developer Portal application per project), you get the "one channel per project" UX in Discord.

## Prerequisites

Before doing any of this, verify:

1. **Org policy allows the Discord channel plugin.** Check `~/.claude/remote-settings.json` for both:
   - `"channelsEnabled": true`
   - An entry for `plugin: discord` in `allowedChannelPlugins` (alongside `plugin: telegram` if both are needed)

   If `discord` is not in the allowlist, the channel registration is blocked by org policy. Outbound (reply tool) may still work, but inbound channel events do NOT reach Claude — symptom is "I send Discord messages but the agent doesn't see them." The admin must enable it via Claude.ai Admin Console → Claude Code → Channels → Allowed Channel Plugins.

2. **Plugin is enabled at USER scope (CRITICAL).** Verify with:
   ```bash
   claude plugin list | grep -A2 discord
   ```
   The `Scope:` line MUST say `user`. If it says `project`, the plugin won't load when `claude-dc` runs from any per-project subdirectory (Claude Code 2.1.181+ no longer inherits project scope to subdirectories). Fix:
   ```bash
   # Back up first
   cp ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.bak
   # Edit installed_plugins.json: change "scope": "project" → "scope": "user", remove "projectPath"
   ```
   Symptom if not fixed: `claude-dc` starts and banner shows "Channels (experimental) ... inject directly in this session" but `/mcp` shows no discord under "Built-in MCPs". The plugin subprocess is silently never spawned.

3. **Plugin is enabled.** Check `~/.claude/settings.json` has `"discord@claude-plugins-official": true` under `enabledPlugins`.

4. **`bun` is installed.** Check `which bun`.

5. **Optional but recommended: `jq`** for the `claude-dc-pair` helper.

6. **Discord account + a Discord server.** The user needs at least one Discord server they own/admin so they can invite their bots into it. Servers are free and instant to create.

## One-time setup

Check if the baseline is already done:

- `~/.bashrc` contains `claude-dc()` function (NOT just an alias)
- `~/.claude-discord/` directory exists

If those are missing, install `claude-dc.bash`-style functions in `~/.bashrc`:

```bash
claude-dc() {
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  mkdir -p "$state"
  chmod 700 "$state"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found" >&2
    echo "   Create a Discord app+bot at https://discord.com/developers/applications," >&2
    echo "   then run: claude-dc-init" >&2
    return 1
  fi
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
}

claude-dc-alt() {
  local variant
  if [[ "$1" =~ ^[0-9]+$ ]]; then variant="$1"; shift; else variant="2"; fi
  local state="$HOME/.claude-discord/$(basename "$PWD")-${variant}"
  mkdir -p "$state"; chmod 700 "$state"
  if [ ! -f "$state/.env" ]; then
    echo "⚠️  $state/.env not found for variant ${variant}" >&2
    return 1
  fi
  DISCORD_STATE_DIR="$state" CLAUDE_BOT_VARIANT="$variant" command claude --channels plugin:discord@claude-plugins-official "$@"
}

claude-dc-pair() {
  if [ -z "$1" ]; then echo "Usage: claude-dc-pair <6-char-code>" >&2; return 1; fi
  if ! command -v jq >/dev/null 2>&1; then echo "⚠️  jq required" >&2; return 1; fi
  local state="$HOME/.claude-discord/$(basename "$PWD")"
  local acc="$state/access.json"
  local code="$1"
  [ ! -f "$acc" ] && { echo "⚠️  No access.json at $acc" >&2; return 1; }
  local sender chat
  sender=$(jq -r --arg c "$code" '.pending[$c].senderId // empty' "$acc")
  chat=$(jq -r --arg c "$code" '.pending[$c].chatId // empty' "$acc")
  [ -z "$sender" ] && { echo "⚠️  Code '$code' not in pending" >&2; jq '.pending | keys' "$acc"; return 1; }
  local tmp; tmp=$(mktemp)
  jq --arg s "$sender" --arg c "$code" '.allowFrom = (.allowFrom + [$s] | unique) | del(.pending[$c])' "$acc" > "$tmp" && mv "$tmp" "$acc" && chmod 600 "$acc"
  mkdir -p "$state/approved"
  printf '%s' "$chat" > "$state/approved/$sender"
  echo "✅ Paired sender $sender in $(basename "$state")"
}
```

**Important Discord/Telegram pairing schema difference:** In Telegram, `senderId == chatId` for DMs. In Discord, `senderId` is the user's Snowflake ID and `chatId` is the DM channel's Snowflake ID — they are **different numbers**. The pair function above already handles this correctly (it reads both separately from the pending entry).

## Multiple bots in the same project directory (advanced)

Same convention as Telegram: `claude-dc-alt N` uses state dir `~/.claude-discord/<basename>-N/` and injects `CLAUDE_BOT_VARIANT=N`. Project rules can pick a variant-specific sandbox dir via:

```bash
SANDBOX="Intermediate_data/for_claude${CLAUDE_BOT_VARIANT:+_${CLAUDE_BOT_VARIANT}}"
```

Note: `claude-dc-pair` only handles the primary state dir. For alt bots, do the manual file edit (Step 5 Option B below).

**Three collision points, and how each is handled** (hardened 2026-08-18):

| Collision | Isolation | Enforced by |
|---|---|---|
| token / pairing | `~/.claude-discord/<base>-N/` | `claude-dc-alt` (automatic, structural) |
| sandbox + notebook + new scripts | `for_claude_N/`, `For_claude_N.ipynb`, `_N` suffix | your project rules (convention) |
| auto-memory | `memory/variant_N/` | your project rules (convention) |
| **sessions / `-c`** | **none — genuinely shared** | launcher warns only |

Only the first is structural; the rest rely on the bot obeying the rules. Two consequences worth knowing before you add an alt:

1. **The alt bot's built-in memory instructions point at `memory/` root** and know nothing about variants — your project rules must explicitly say they override that. Without that, an alt can overwrite a primary's `MEMORY.md` (real projects here hold ~50 memory files / 12 KB indexes that no transcript can rebuild). Real-world check on a two-bot project showed the split *did* hold in practice (6 root + 4 variant_2 files, no cross-contamination) — the convention works, but it is still a convention.
2. **`-c` can resume the sibling's session.** Claude Code keys sessions on cwd alone; nothing binds a session to `DISCORD_STATE_DIR`. Verified on a two-bot project: 3 transcripts shared one bucket with no bot binding. `claude-dc`/`claude-dc-alt` now print a non-blocking warning when `-c`/`-r` is used in a directory that has multiple variants. To resume exactly, use `claude --resume <session-id>`.

**Discord-reply enforcement is now GLOBAL (2026-08-30).** `~/.claude/hooks/enforce-discord-reply.py` (a `Stop` hook) blocks a bot from ending a turn that was triggered by a Discord message but never called `reply`/`react`/`edit_message` — terminal output reaches nobody, and prompt rules alone never fixed the "finished a long tool chain, forgot to reply" slip. Its `ENFORCE_FOR` list lets you stage the rollout — put one or more `DISCORD_STATE_DIR` basenames in it to enforce for those bots only, or `["*"]` for every bot. Tested: Discord-triggered turn with no reply → **block**; reply / react / terminal-triggered turn / `stop_hook_active` / malformed input / missing transcript → **allow** (fail-open everywhere; a guard that wedges sessions is worse than the slip). Takes effect per bot on its next session start.

**⚠️ HOOKS MUST LIVE IN `~/.claude/settings.json` — never `~/.claude/settings.local.json`** (learned the hard way 2026-08-30). Claude Code's settings chain is:

```
<project>/.claude/settings.local.json → <project>/.claude/settings.json → ~/.claude/settings.json
```

`~/.claude/settings.local.json` is **not on that chain** — its entire `hooks` block is silently ignored. No error, no warning; the hook simply never runs.

**The trap that hid this for two weeks:** testing it from the **$HOME bot**. That bot's cwd *is* `$HOME`, so for it `~/.claude/settings.local.json` happens to be the *project-level* local settings — first on the chain. It fires there and nowhere else. **Never validate a scope/settings question from the $HOME bot — it is the one session where every path coincides.** Test from a real project bot, or check both.

Cost of the mistake: the `Stop` discord-reply hook sat in that file from 2026-08-17 and **never once ran for any project bot**; we believed we had a mechanism layer when we only had the prompt rule. Verified fixed 2026-08-30 — after moving both hooks to `~/.claude/settings.json`, an alt bot's probe write to another bot's memory was correctly denied.

**Resuming an alt safely — `claude-dc-alt-resume N`** (added 2026-08-29). Neither `-c` nor `-r` is safe in a multi-variant directory: `-c` silently continues *the newest session in the cwd* regardless of which bot wrote it, and `-r`'s interactive picker lists both siblings **without saying which is which**. `claude-dc-alt-resume <N>` (in `~/.bashrc.d/claude-discord.bash`) scans the cwd's transcripts, scores each by how many times it references `memory/variant_<N>/`, and resumes the **newest one scoring ≥3** — the primary's sessions essentially never write that path. Falls back to a fresh `claude-dc-alt N` when nothing matches (never guesses). Verified against the live kidney project: picked the alt's session (score 21) over the primary's (score 0); variant 3 → correctly matched nothing.

Two traps found while building it: (a) the primary's transcript *does* contain the string `CLAUDE_BOT_VARIANT` (it reads the rules), so keyword presence alone cannot attribute a session — score on the `variant_N/` **path** instead; (b) `grep -c` can emit multi-line output, which broke the numeric test with "integer expression expected" — pipe through `head -1 | tr -dc '0-9'`.

**Resuming the primary — `claude-dc-resume`.** The mirror image, and it needs a *different* signal. You cannot simply invert the alt's test: the primary's transcript mentions `variant_2` plenty, because you discuss the alt bot inside it. What separates them is **where in the transcript the mention comes from**. Score only the **session opening** (the first ~30 records) — that is what the harness injected: the auto-loaded `MEMORY.md`, the `CLAUDE.md`/rules render. An alt's opening carries its own `variant_<N>/` and `for_claude_<N>` namespace; the primary's carries neither.

Measured on a real five-session directory: whole-file scoring could not separate the two bots at all, while opening-only scoring gave **0 for the primary and 3-4 for each alt** — no overlap. `claude-dc-resume` picks the newest session scoring 0, prints which one it chose, and takes an explicit session id as an escape hatch. In a directory with only one bot every session scores 0, so it just resumes the newest — which is the right behaviour there anyway.

The general lesson is worth more than the function: **when attributing a transcript to an agent, score what the harness injected, not what the conversation discussed.**

**MECHANISM (not just convention) — `guard-variant-memory.py`, added 2026-08-29.** Everything above about memory separation is a *convention*: the alt bot has Write/Bash and the same UNIX uid, so nothing structural stops it writing an absolute path into the primary's `memory/` — or into the `$HOME` bot's. So there is now a **`PreToolUse` hook** (`~/.claude/hooks/guard-variant-memory.py`, registered in **`~/.claude/settings.json`** (NOT `settings.local.json` — see below), matcher `Write|Edit|NotebookEdit|Bash`) that **denies** the call outright.

Rule: active **only** when `CLAUDE_BOT_VARIANT` is set; resolves the write target; denies if it lands in any `.claude/projects/*/memory/` tree that is not this bot's own `memory/variant_<N>/`. Fail-open on every error (bad JSON, unknown tool, no variant) — a guard that wedges sessions is worse than the risk. Tested both directions: writing the $HOME bot's memory / the primary's root / `echo >` / `cp` / `mv` into them → **DENY**; writing own `variant_N/`, ordinary project files, primary bots (no variant), and *reading* memory (`cat`, or memory as the `cp` **source**) → **ALLOW**. Note the `cp`/`mv` target is the LAST operand — a first-draft regex missed that and let `cp a.md <primary>` through; fixed and re-tested.

**Bootstrap BOTH namespaces, not just the alt's** (learned 2026-08-29). When adding an alt to a project whose primary has never written a memory yet, `memory/` contains *only* `variant_N/` — there is no root `MEMORY.md` for the alt to read as "the parent index". The alt then goes looking further up and can land on another project's bucket entirely — for instance that of a bot whose project directory is your `$HOME` — and report (or worse, act on) "my memory path resolves to the other bot's". So always also create a **primary `memory/MEMORY.md` placeholder** stating who owns the root, a who-writes-where table, and an explicit "if your memory path resolves to a bucket with no project suffix in its name, that is another bot's private memory — never write there, stop and ask". Cheap, and it removes the ambiguity that makes an alt guess.

(Real incident: an alt bot correctly *stopped and reported* instead of writing — the `variant_2/MEMORY.md` boundary text did its job. Verified afterwards: its cwd and transcript bucket were correct all along and the other bucket was untouched. The same class of bug later bit for real, from a different cause — see **An empty `.git` silently redirects every bot's memory** below.)

**Also required when adding an alt-N to an existing project**: bootstrap the variant memory subdir so the alt has its own namespace and won't clobber the primary's `MEMORY.md`:

```bash
PROJ_PATH="/full/project/path"
ENC=$(echo "$PROJ_PATH" | sed 's|/|-|g; s|_|-|g')   # rough; verify against ~/.claude/projects/
MEMDIR="$HOME/.claude/projects/$ENC/memory"
mkdir -p "$MEMDIR/variant_${N}"
# Write a stub MEMORY.md inside variant_N/ naming who owns which namespace
# Then add a "## Sibling variants" section to $MEMDIR/MEMORY.md pointing at variant_N/MEMORY.md.
```

## Adding a new bot (the recurring task)

Each new project gets a new bot. Walk the user through these steps:

### Step 1: Create a bot via Discord Developer Portal

The user opens https://discord.com/developers/applications in a browser:

1. Click **"New Application"**, give it a name (e.g. "myproject agent 1")
2. Left menu → **"Bot"** tab
3. Find **"Token"** section → click **"Reset Token"** → **copy the token** (it's shown only once)
4. **Disable** "Public Bot" if Discord lets you — but if you get a "Private application cannot have a default authorization link" error, skip this; it's not a deal-breaker (Public Bot ON is fine as long as you don't share the OAuth invite URL publicly)
5. In **"Privileged Gateway Intents"** section:
   - ✅ Enable **"Message Content Intent"** (required — without it the bot can't see message text)
   - You can leave Presence Intent and Server Members Intent off for our use case

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
4. **DO NOT check "Administrator"** — never needed for self-use bots
5. Scroll to bottom, copy **"Generated URL"**
6. Paste URL in browser, select the user's Discord server, click **Authorize**

### Step 3: Create the state dir + `.env`

Once you have the token from the user (they paste it in the chat):

```bash
PROJ_BASENAME="$(basename "/full/project/path")"
STATE="$HOME/.claude-discord/$PROJ_BASENAME"
mkdir -p "$STATE"
chmod 700 "$STATE"
```

Write the token to `$STATE/.env` using the Write tool (avoid echoing tokens into shell history):

```
DISCORD_BOT_TOKEN=MTIzNDU2Nzg5MDEyMzQ1Njc4.EXAMPLE.this-is-not-a-real-token
```

Then `chmod 600 "$STATE/.env"`.

**Also set the split-mode floor** — after the bot pairs and `access.json` exists, add
`"chunkMode": "newline"` to it (a first-class field: `readAccessFile()` carries it through, so the
plugin's own rewrites preserve it). While Patch 3 is in place this changes nothing — the patched
chunker ignores the mode. It matters only when the patch is *absent* (upstream refactored
`chunk()`, or a fresh install before the next shell): the reply then degrades to clean line
breaks instead of upstream's hard `slice(0, 2000)`. Cheap insurance; set it on every bot.

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
         "createdAt": ...,
         "expiresAt": ...
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

### Step 8: Wire the project to the shared rules (default ON)

This step assumes the user keeps one shared rules file — folder layout, prohibitions, code style, job-submission templates, environment policy, and the Discord-output conventions every bot must follow. This repo does not ship one; it is yours to write, and it is where the reply discipline and the bot-to-bot etiquette belong. The examples below call it `~/.claude/PROJECT_RULES.md`.

**If such a file exists, wire every new project to it by default** — don't skip this step unless the user says otherwise.

Mechanism: drop a `CLAUDE.md` in the project root containing `@~/.claude/PROJECT_RULES.md` so any future Claude session in that directory auto-loads the rules. (`@path` is an application-level include, evaluated when the session starts — not a symlink, and not re-read mid-session.)

```bash
PROJ=/full/project/path
if [ ! -f "$PROJ/CLAUDE.md" ]; then
  printf '@~/.claude/PROJECT_RULES.md\n' > "$PROJ/CLAUDE.md"
fi
```

If `CLAUDE.md` already exists, **append** the line (don't clobber project-specific notes already there). If the user has a project-specific addendum, the file should look like:

```
@~/.claude/PROJECT_RULES.md

# Project-specific notes
- ...
```

**Exceptions** (do NOT auto-wire; ask if unsure):
- A conversational bot whose project directory is your `$HOME` — not an analysis project.
- Paper-reading / notification / data-repository bots — no `Scripts/`, no batch jobs, no analysis.
- Anything the user explicitly tags as "just a sandbox" or "skip the rules for this one".

For those, a much lighter rules file works better: the Discord reply discipline, "reply promptly",
and the no-foreground-`sleep` rule, and nothing else.

If the project path looks ambiguous (e.g., not under `projects/`), ask once: "Should this project follow `~/.claude/PROJECT_RULES.md`?" Default to yes when unclear.

### Step 9: Update `~/bots-overview.md`

Keeping a one-row-per-bot index (say `~/bots-overview.md`) pays for itself once you pass ~5 bots: it is the only place that maps a Discord display name back to a state dir, a launch command and a project path. If the user maintains one, append a new row. To fetch the display name and username after the bot is created:

```bash
TOKEN=$(grep -o 'DISCORD_BOT_TOKEN=[^[:space:]]*' ~/.claude-discord/<suffix>/.env | cut -d= -f2)
curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot $TOKEN"
```

Returns JSON with `username` (the bot's username) and `id` (the bot's Snowflake ID).

**Only ever edit the roster itself** — never a backup copy. Backups are one-way and self-updating (below), so a new row propagates on its own; nothing to sync by hand.

### Back up the hand-built knowledge

Worth setting up a daily cron once the setup is real. Snapshot only what is hand-built and NOT regenerable: the roster, your rules file, `patch-discord-plugin.sh`, the hooks, all of `~/.claude/skills/`, plus **`~/.bashrc` and all of `~/.bashrc.d/`** (where the `claude-dc*` functions and the patch hook live). Keep the last ~10 dated tarballs in two destinations:

```
~/.claude/bot-knowledge-backups/          roster (chmod 444) · knowledge-YYYY-MM-DD.tar.gz
<somewhere off your $HOME>/claude-bot-knowledge/    the same, on different storage
```

Anti-confusion design: the plain copy carries a "this is an automatic backup — do not edit" banner **and** is `chmod 444`, so editing the wrong file fails loudly instead of silently diverging. Note it lives in `bot-knowledge-backups/`, NOT `~/.claude/backups/` — that dir belongs to Claude Code's own `.claude.json` backups.

**Where the shell helpers live:** it is worth putting `claude-dc`/`claude-dc-alt`/`claude-dc-pair`/`claude-dc-resume` and the `patch-discord-plugin.sh --quiet` hook in their own file rather than inline in `.bashrc` — they were moved into `~/.bashrc.d/{claude-discord,claude-telegram,codex-discord}.bash`, sourced by a guarded loop at the end of `.bashrc`. When looking for these functions, check `~/.bashrc.d/` first. (Lesson: the backup script used to `sed`-slice the functions out of `.bashrc` and silently produced a 0-byte file for a week after the move — it now copies `.bashrc` + the whole `.bashrc.d/` and warns loudly if it captures nothing. Prefer copying whole files over pattern-slicing.)

**Not backed up on purpose:** `~/.claude-discord/**` (bot tokens + pairing state) — secrets stay put at chmod 600. And if both destinations sit on the same filesystem, this protects against a stray `rm` or a bad edit, *not* against storage loss — a private git remote is the fix for that.

## Multi-bot collaboration via shared channels (Discord-specific advantage)

Unlike Telegram (where each bot lives in its own private DM and bots cannot see each other), Discord supports **multiple bots in the same channel**, with each bot seeing all messages in that channel. This enables a true "team of agents in one room" pattern:

- Create a channel (e.g. `#sciNOMe-pilot`)
- Invite multiple bots into it (each bot's `access.json` must have the channel/server allowed)
- User addresses specific bots via `@mention`
- Each bot's Claude session sees the full channel history but acts independently

### Plugin patch — allow bot-to-bot inbound

The stock Discord plugin drops every message whose author is a bot (`if (msg.author.bot) return` in `server.ts`). This prevents bot-to-bot collaboration entirely. We patch it to only drop self-echoes, so each bot sees other bots' messages.

The patch lives at `~/.claude/patch-discord-plugin.sh` (idempotent — safe to re-run). After every plugin upgrade, run:

```bash
~/.claude/patch-discord-plugin.sh
```

Then `/exit` and relaunch every running Discord bot for the patch to take effect.

What changes in `server.ts`:
```js
// before:  if (msg.author.bot) return
// after:   if (msg.author.id === client.user?.id) return
```

If you ever need to revert (e.g., bots are looping uncontrollably), comment out / restore the original line and restart bots.

**Failure mode seen 2026-08-12 — a `server.ts` got truncated to 0 bytes.** The *marketplace* copy was emptied (the cache copy, which is what actually runs, stayed intact — so no bot broke). Symptom in the `.bashrc` hook output: `[warn] expected line not found in: …/marketplaces/…/server.ts`. Fix = restore from the good copy:
```bash
cp ~/.claude/plugins/cache/claude-plugins-official/discord/*/server.ts \
   ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/discord/server.ts
~/.claude/patch-discord-plugin.sh          # confirm both copies report "already patched"
```
The patch script is now hardened against this: it **refuses to touch a 0-byte file** (prints `[ERR] server.ts is EMPTY` with the restore command) and **refuses to write back** a file where the patch anchors weren't found — previously it would have happily written the empty string back and reported `[ok]`, masking the breakage. When diagnosing, remember the two copies serve different roles: **cache = what runs now**, **marketplace = the source future installs copy from**; check both.

### Plugin patch #2 — explicit online presence (green dot = real connection)

`patch-discord-plugin.sh` also injects an **online presence** into the `new Client({...})` options (added 2026-07-30), so a connected bot reliably shows the green "online" dot and — because the presence label is derived from `DISCORD_STATE_DIR` — displays its own project name (e.g. "Playing myproject"). The stock plugin never sets a presence, so bots showed no reliable online state.

```js
// injected before `const client = new Client({`:
const BOT_LABEL = (() => {
  const base = (process.env.DISCORD_STATE_DIR || '').split('/').filter(Boolean).pop() || ''
  return base || (process.env.CLAUDE_BOT_LABEL || 'Claude Code')
})()
// injected into the Client options (after `partials: [Partials.Channel],`):
presence: { status: 'online', activities: [{ name: BOT_LABEL, type: 0 }] },
```

Why it matters: when a bot's process dies (the terminal is closed, the machine reboots, or on a cluster the interactive allocation expires), the gateway heartbeat stops and **Discord greys the bot out within ~1 min** — so the member-list dot becomes a live health signal (green = connected, grey = down). The patch is idempotent and bun-transpile-verified. **Running bots must be relaunched to pick it up.** For a *proactive* down-alert (a push, not just the grey dot), add a cron watchdog that polls each bot via the Discord API.

#### Optional: SLURM walltime countdown in the presence

> ⚠️ **HPC-specific, and developed against one cluster.** This part was built and tested on the
> Rockefeller University HPC (SLURM, interactive `srun` sessions). It assumes `SLURM_JOB_ID` /
> `SLURMD_NODENAME` are exported into the bot's environment and that `squeue -h -j <id> -o %L`
> returns TimeLeft in the usual format. Other SLURM sites configure these differently, and non-SLURM
> setups have no equivalent at all. **Everything degrades gracefully** — with no `SLURM_JOB_ID` the
> presence silently falls back to the plain label — so it is safe to leave enabled anywhere, but do
> not expect the countdown itself to work off this cluster without checking.

The bot process runs *inside* the interactive `srun` job, so `process.env.SLURM_JOB_ID` identifies it; `squeue -h -j <id> -o %L` returns TimeLeft. `slurmTimeLeft()` formats it compactly (`6-19:57:49`→`6d19h`, `7:45:21`→`7h45m`, `12:34`→`12m`; `INVALID`/empty→`''`). `presenceLabel()` renders **`node · ⏳time-left · project`** (e.g. `node177 · ⏳6d19h · myproject`) — the node comes from `SLURMD_NODENAME`/`HOSTNAME`/`os.hostname()` (short form, domain stripped), and any missing piece is simply dropped, so off-SLURM it degrades to `node · project`. A `setInterval` in the `ready` handler refreshes it **every 15 min** (`.unref()`d so it never holds the process open) — without that the countdown would freeze at its startup value. Off-SLURM (no `SLURM_JOB_ID`) it silently degrades to the plain label. Net effect: the member list shows, per bot, *which project* and *how long until SLURM kills it* — so you can renew before it dies instead of discovering a grey dot afterwards. All patches are re-applied together by `patch-discord-plugin.sh` (verified end-to-end: patching a pristine `server.ts` reproduces every marker).

### Plugin patch #3 — markdown-safe message splitting

Discord hard-caps one message at 2000 characters, so the plugin splits longer replies. Upstream's `chunk()` defaults to `chunkMode: 'length'`, which is a blind `rest.slice(0, limit)`: it cuts mid-word, mid-`inline span`, and mid-fenced-block. The fenced-block case is the ugly one — the tail message has no opening fence, so Discord renders the rest of your code as prose and the orphaned closing ``` opens an empty block.

**Switching to `'newline'` mode does not fix this**, and it is worth understanding why before you try it: `'newline'` prefers `\n\n`, then `\n`, then a space — and a code block is nothing but newlines, so it still cuts cleanly *inside* the block. Fixing the boundary is not the same as fixing the markup.

Patch 3 replaces `chunk()` (sentinel `MD-SAFE CHUNKER`) and flips the default to `'newline'`. The replacement tracks fence state per line and:

1. prefers a cut **outside** any fence, so a whole code block moves to the next message intact;
2. enters the fence only when staying out would waste more than half the budget (otherwise you get 6-character messages), and then closes with ``` and re-opens with the same ```lang;
3. keeps inline-backtick parity even, backing off to before the unmatched tick;
4. reserves 4 characters of budget for the fence it may have to inject.

Two things make this patch safe to carry across upstream changes. The anchor is a **regex** on `function chunk(` rather than the full signature, so a renamed or re-typed parameter — or a signature split across lines — still patches. And every patched file then goes through a **transpile-only syntax gate** (`Bun.Transpiler`, ~20 ms, no import resolution) and is **reverted from its `.bak`** if it no longer parses. If the declaration is gone entirely, the script prints `[warn]` and leaves the file alone: degradation, not breakage.

**Verify by running the shipped code, not the draft.** After patching, extract the function back out of `server.ts` and run it against cases that actually stress it — prose only, a small block that should move whole, one block bigger than the limit, alternating blocks, backticks landing on the boundary. Assert on each chunk: within the limit, even fence count, even inline-tick count, and non-fence lines identical to the input.

> A wrong-shaped check cost an hour here: the first verifier stripped a leading/trailing fence from *every* chunk before comparing, which also strips fences that were genuinely part of the input — so four passing cases falsely reported "content lost". Compare **non-fence lines** instead. Likewise `bun build --no-bundle` reports failure on a perfectly good file (it is an output-path error, not a syntax one), and `bun -e` cannot see `Bun.argv[2]` — both look like working gates if you only ever test the broken input. **Test every gate with a known-good input as well as a known-bad one.**

### Collaboration etiquette (must read)

Once the patch is in place, nothing in the plugin stops two bots talking forever — the discipline has to live in your own rules file (the one your projects' `CLAUDE.md` imports). The etiquette that has worked in practice:

- **Default silent to other bots.** A bot answers a sibling only when the human opened the discussion.
- **The human opens it explicitly** (e.g. "@A @B, discuss X") and **closes it explicitly** ("stop").
- **No chitchat, and a hard length cap** (~200 characters per bot-to-bot turn).
- **Auto-pause after ~5 bot-to-bot turns with no human message** — a backstop, not the main defence.

Write these into your rules file before enabling the patch, not after.

### Important gotchas

1. **Echo loops.** With the patch active, infinite-loop risk shifts from plugin-level to bot-behaviour level. The etiquette above is what prevents loops; the auto-pause after ~5 turns with no human input is only a backstop.

2. **`requireMention: true`** (configured per-channel in `access.json`) is still the gate — bots only respond when explicitly @-mentioned. Without this, even disciplined bots get triggered by every message in busy channels.

3. **Shared file system, not shared session state.** Both bots see each other's channel messages, but their Claude session jsonl files are independent. If they edit the same file, last writer wins. Coordinate via the user, or assign clear roles (planner vs coder vs reviewer). For auto-memory specifically, the `variant_N/` subdir rule avoids clobbers when bots share a cwd — and `hooks/guard-variant-memory.py` enforces it rather than trusting it.

4. **Different `CLAUDE_BOT_VARIANT` for collisions.** If two bots share a project directory, they need distinct variant sandboxes (`Intermediate_data/for_claude/`, `Intermediate_data/for_claude_2/`, etc.) AND distinct memory subdirs (`memory/`, `memory/variant_2/`, etc.).

## Common issues and how to handle them

### `claude-dc` started but messages don't reach the session (one-way)

- **Most common cause: org policy blocks the channel.** Check `~/.claude/remote-settings.json` for `discord` in `allowedChannelPlugins`. If missing, admin must add it via Claude.ai Admin Console → Claude Code → Channels. Editing the local file is futile — the server overwrites it within an hour.
- **Second cause: MCP IPC link failed.** Run `/mcp` in Claude Code, find discord row, retry. Usually fixes a transient startup race. If unsuccessful, `/exit` and `claude-dc -c`.

### Discord token invalid

Test with `curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot <TOKEN>"`. Should return bot's user object. If `{"message": "401: Unauthorized", "code": 0}`, the token is wrong — go back to Developer Portal → Bot → Reset Token.

### Discord bot doesn't see message text

Most likely: **Message Content Intent** is OFF in the Discord Developer Portal → Bot → Privileged Gateway Intents. Turn it on, save. The bot may need to reconnect.

### Bot in server but not appearing online / not responding

- Confirm the bot was added to the server via the OAuth URL (visible in server's Members list)
- Confirm `claude-dc` is running in a terminal somewhere with the matching `DISCORD_STATE_DIR`
- Test gateway connectivity: `curl -s "https://discord.com/api/v10/users/@me" -H "Authorization: Bot <TOKEN>"`

### An empty `.git` silently redirects every bot's memory

**Symptom.** A bot reports that its auto-memory path resolves to *another* project's bucket — often one whose project directory is your `$HOME`. Or, quieter and worse: one project's `memory/` stays empty for weeks while a different bucket keeps growing knowledge it has no business holding.

**Cause.** To find a project root, the harness walks up from the working directory looking for a `.git`. A **broken or empty** `.git` is enough to stop that walk — even one that `git rev-parse` itself rejects with *"not a git repository"*. If such a directory exists in `$HOME`, then every bot whose own project directory has no `.git` resolves its project root to `$HOME`, reads that bucket's `MEMORY.md` as background context, and writes its new memories there.

**Why it hides.** Transcripts are keyed on the **working directory**, so they keep landing in the right project folder. Only the memory follows the resolved **project root**. That split is exactly what makes the bug invisible: everything looks normal, and the receiving bucket just quietly accumulates other bots' knowledge.

**Check for it:**

```bash
ls -d "$HOME/.git" 2>/dev/null && echo "SUSPECT: is this a real repo?" && git -C "$HOME" rev-parse --show-toplevel
# and, from a project directory, confirm where its root actually resolves:
git rev-parse --show-toplevel 2>&1   # "not a git repository" here is fine and expected
```

**Attributing memories that already drifted** — two checks, neither of which relies on reading the content:

1. `grep -H originSessionId <bucket>/*.md`, then `find ~/.claude/projects -maxdepth 2 -name "<sid>*"` — the directory holding that transcript names the owner.
2. For files written before that metadata existed:
   `grep -rl --include='*.jsonl' -F -- "<bucket-dirname>/memory/<basename>" ~/.claude/projects` finds the session that actually wrote it.

**A basename-only match is NOT evidence.** Every bot's transcript contains every filename in that bucket, because they were all *reading* the same index. Matching on the name alone will attribute a memory to whichever bot merely read it.

**Fix.** Remove the stray `.git` (a new session then resolves to its own cwd correctly), move the drifted files back to their real owners, and prune the matching lines from the receiving bucket's `MEMORY.md`. Two things to know while cleaning up:

- **A session that was already running keeps the old memory path**, because it is baked into the system prompt at startup. Such a session must write its handoff with an explicit absolute path, or be restarted first.
- **Do not append to a live bot's `MEMORY.md` from outside** — you will race its own writes. Drop an inbox file in its memory directory and let it index that itself.

**Prevent it.** Bootstrap every project's `memory/MEMORY.md` at setup time with a short note naming who owns that root and an explicit "if your memory path resolves to a bucket with no project suffix, that is another bot's memory — never write there, stop and ask". It costs nothing and removes the ambiguity that makes a bot guess.

### `stop_reason: refusal` mid-session

Same as Telegram: Anthropic's safety classifier can false-positive on bloated sessions. Recovery: `/exit` then `claude-dc` (**no `-c`/`-r`**), rebuild context from project files.

## File layout reference

```
~/.claude-discord/
├── <project-A-basename>/
│   ├── .env                       # DISCORD_BOT_TOKEN=...      (chmod 600)
│   ├── access.json                # dmPolicy / allowFrom / pending (chmod 600)
│   ├── bot.pid                    # server.ts PID (Discord plugin may not always write this)
│   ├── approved/<senderId>        # pairing-confirm signal file
│   └── inbox/                     # received attachments
├── <project-A-basename>-2/        # alt variant 2
└── <project-B-basename>/
    └── ...
```

`access.json` schema is the same as Telegram (`dmPolicy`, `allowFrom`, `pending`, `groups`). For Discord groups (server channels), `groupId` is the channel's Snowflake ID. It also carries the optional `chunkMode` / `textChunkLimit` fields described in Step 3.

The pieces that live outside the state dirs:

```
~/.claude/
├── settings.json                  # enabledPlugins + the hooks block — hooks MUST be here,
│                                  #   NOT in settings.local.json (see the warning above)
├── patch-discord-plugin.sh        # the three idempotent server.ts patches
└── hooks/
    ├── enforce-discord-reply.py   # Stop: no Discord reply => the turn does not end
    └── guard-variant-memory.py    # PreToolUse: an alt cannot write another bot's memory
~/.bashrc.d/claude-discord.bash    # claude-dc / -alt / -init / -pair / -resume / -alt-resume
                                   #   plus the shell-start call to patch-discord-plugin.sh
~/.claude/projects/<encoded-cwd>/  # transcripts (keyed on cwd) and memory/ (keyed on project root)
```

## Security notes

- Bot tokens grant full control of the bot. `.env` files are `chmod 600` inside `chmod 700` directories. Never commit them, never share OAuth invite URLs widely.
- `allowFrom` is the only gate to a Claude Code session behind a bot. Discord Snowflake IDs are stable — treat the list as carefully as shell access.
- The Discord plugin sends outbound traffic only to `discord.com/api/v10` and `gateway.discord.gg`.
- Be cautious with "Public Bot" toggle — if Public, anyone with the OAuth URL can install the bot into their own server. Keep the URL private.

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
| Bot creation | @BotFather `/newbot` | discord.com/developers (browser) |
| Pairing skill | `/telegram:access pair <code>` | `/discord:access pair <code>` |
| `senderId == chatId` for DMs? | Yes | **No** (different Snowflakes) |
| Message history API | Not available | `fetch_messages` tool |
| Bot-to-bot visibility | Hidden | Visible in same channel |
| Reactions visible to bot | Outbound only | Bidirectional |
