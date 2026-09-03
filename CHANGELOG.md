# Changelog

## v2.0

v1 shipped a set of conventions and a skill that taught an agent to follow them. Three months of
daily use across a few dozen bots showed where conventions are not enough — so v2 moves the
important ones down into the harness, and writes down the failures that were expensive to find.

### Added — mechanisms

- **`hooks/enforce-discord-reply.py`** (`Stop` hook). A turn triggered from Discord cannot end
  without a `reply` / `react` / `edit_message`. Terminal output reaches nobody, and a prompt rule
  never fixed the "finished a long tool chain, forgot to reply" slip — because it fails exactly
  when it is needed. Fail-open on every error path.
- **`hooks/guard-variant-memory.py`** (`PreToolUse` hook). An alt bot cannot write into any memory
  namespace but its own `memory/variant_N/`. Same UNIX uid and ordinary permissions mean file modes
  cannot express this; a hook can. Covers `Write`/`Edit`/`NotebookEdit` and shell redirects,
  `tee`, `cp`, `mv`, `rsync`, `install`.
- **`patch-discord-plugin.sh` patch #3 — markdown-safe message splitting.** Upstream's `chunk()`
  does a blind `slice(0, 2000)`, which cuts fenced code blocks in half; the tail message loses its
  opening fence and renders as prose. The replacement prefers a cut outside any fence, and closes
  and re-opens the fence (keeping the language tag) when a single block exceeds the limit.
  Switching `chunkMode` to `'newline'` does **not** fix this on its own.

### Added — launcher

- **`claude-dc-resume`** — resume the primary bot's own session in a directory that has alt
  variants, instead of letting `-c` pick whichever transcript is newest.
- **`claude-dc-alt-resume N`** — the same for alt N.
- A non-blocking warning when `-c` / `-r` is used in a directory with more than one bot.

### Changed

- `patch-discord-plugin.sh` is now anchored by **regex** on `function chunk(` rather than a full
  signature, so an upstream parameter rename still patches — and every patched file passes a
  transpile-only syntax gate, reverting itself from its `.bak` if the result no longer parses.
- The patch script refuses to touch a 0-byte `server.ts`, and refuses to write back a file whose
  anchors were not found, instead of reporting success on a broken edit.
- The presence label falls back to `CLAUDE_BOT_LABEL` (or `Claude Code`) rather than a hard-coded
  name.

### Documented

The parts of `SKILL.md` that cost the most time to learn:

- **Hooks only load from `~/.claude/settings.json`.** `~/.claude/settings.local.json` is not on the
  settings chain and its `hooks` block is silently ignored — no error, no warning. This hid for two
  weeks because it was verified from a bot whose project directory *is* `$HOME`, the one session
  where that file happens to be the project-level one.
- **The plugin must be installed at user scope** from Claude Code 2.1.181; project scope no longer
  inherits into subdirectories.
- **An empty `.git` in `$HOME` silently redirects every bot's memory.** A `.git` that `git` itself
  rejects is still enough to stop the harness's project-root walk. Transcripts keep keying on the
  working directory, which is exactly what makes it invisible. Includes how to attribute a drifted
  memory to its real author — and why matching on its filename alone is not evidence.
- **Attributing a transcript to an agent: score what the harness injected, not what the
  conversation discussed.** Scoring a whole transcript cannot separate two bots that share a
  directory; scoring the session opening separates them cleanly.
- **Do not raise `MCP_TIMEOUT` to fix a connection that never succeeds.** It converts a fast
  failure into a slow one.
- **Test every guard with a known-good input as well as a known-bad one.** Several checks written
  during this work reported failure on perfectly good files; each looked like it worked when only
  the broken input was tried.

### Note on the SLURM parts

The presence countdown reads `SLURM_JOB_ID` / `SLURMD_NODENAME` and shells out to `squeue`. It was
built and tested on one cluster (Rockefeller University HPC, interactive `srun` sessions) and other
SLURM sites configure these differently. Everything degrades gracefully — with no `SLURM_JOB_ID`
the presence falls back to the plain label — so it is safe to leave enabled anywhere, but do not
expect the countdown itself to work elsewhere without checking.

## v1.0

Initial release: per-project Discord bot setup for Claude Code.

- `claude-dc.bash` — `claude-dc`, `claude-dc-init`, `claude-dc-alt`, `claude-dc-pair`.
- `SKILL.md` — the architecture, as a skill an agent can follow to add and pair a new bot.
- The core trick: the official plugin honours `DISCORD_STATE_DIR`, so pointing it at a
  per-project directory gives each project its own token, pairing and bot server.
