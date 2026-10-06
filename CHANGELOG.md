# Changelog

## v2.2

### Fixed

- **`patch-discord-plugin.sh` raced itself.** It runs at every shell start, and shells often start
  together — tmux restoring its windows, a burst of `srun` shells, bot sessions building their shell
  snapshot. Concurrent runs each saw "not patched yet", applied their edits on top of one another and
  shared one `.bak` path, so one run's revert clobbered another's work. In practice this left
  `chunk()`'s `FENCE_RE` declared twice: the file no longer parses, and every later patch then
  reported "did not parse". In testing it could also leave a file that parses but dies the moment the
  plugin loads (`ReferenceError: BOT_NODE is not defined`). Reproduced with 6–8 concurrent runs on a
  fresh `server.ts`. Runs are now serialized with `flock`, which the kernel releases when a holder dies
  (even on `kill -9`), so there is no stale lock to detect. On Lustre, `$HOME` needs the
  cluster-coherent `flock` mount option for this to hold across nodes; where flock is not supported
  at all, the script warns and runs unserialized as before.
- Patch #2 (presence) was not idempotent on what it read: run on an already patched file, its
  legacy-cleanup regex removed our own `BOT_BASE` / `BOT_NODE`. It now checks the content first, and
  it is gated and reverted like patch #3.

### Added

- **Self-repair.** Before patching, a target that is already unusable — it fails the transpile check,
  or a name our patches add is used but never declared, or declared twice — is restored from the
  pristine upstream copy that patch #1 saved, then patched from scratch. With no clean copy it is left
  alone, with one clear error. Patch #1 only ever saves a file that carries none of our patches.
- **A declaration check next to the syntax check.** A transpile only proves a file parses; it cannot
  see a `const` the rest of the file depends on going missing. Every write is now checked for both
  and reverted if either fails.
- **A fast path.** A target that carries every patch and still matches its `<file>.verified` stamp
  (size and mtime of the file that last passed both checks) is trusted without running bun, so a
  normal shell start stays at a few milliseconds and takes no lock.

### Changed

- bun is probed before it is relied on and runs from `/`, so a stray `bunfig.toml` in the current
  directory cannot make every file look broken. Without a working bun, patch #3 is skipped for that
  run instead of files being reported as unusable.
- A failed `.verified` write is ignored (it only costs the fast path), and error messages now quote
  the actual parse or declaration error.

## v2.1

### Fixed

- **`claude-dc-alt-resume` could resume the primary's session.** It decided "is this session the
  alt's?" by counting `variant_N` across the whole transcript (>= 3 = the alt's). In production a
  primary bot had discussed its alt so often that its own transcript held 104 mentions of
  `variant_2`; every session in the directory scored >= 3, the helper picked the newest — the
  primary's — and the alt resumed the primary's conversation. The check had passed when it was
  written; the signal decayed as the conversation grew. `claude-dc-resume`'s opening-only score
  had a related weakness: the opening says who *started* a session, not who drives it now.
  Both helpers now attribute a session to the bot whose **private DM channel last delivered a
  message into it** — the channel the harness actually used, not anything that was said. A
  session that changed hands belongs to whoever drives it now; if a bot's DM channel cannot be
  determined, the helper starts fresh instead of guessing.
- v2.0's README and `SKILL.md` said whole-transcript scoring was reliable for the alt, and the
  v2.0 changelog presented opening-only scoring as the answer. Both are corrected: attribute by
  the delivery channel, not by what was discussed.
- Sibling bots are matched exactly as `<base>-<digits>`; a bare `<base>-[0-9]*` glob also caught
  unrelated state dirs such as `<base>-2025notes`. Any number of alts is supported.
- The transcript bucket is found the way Claude Code names it — the physical path, every
  non-alphanumeric character turned into `-` — so directories with a `.` in their name, and
  projects reached through a symlink, resume correctly.
- A project whose own name ends in `-<digits>` is no longer mistaken for an alt when resuming
  (`CLAUDE_BOT_VARIANT` was derived from the state-dir name).
- If the picker is not installed, the resume helpers say so instead of reporting that no
  session belongs to this bot.
- **The picker refuses rather than guesses when a sibling cannot be identified.** If any configured
  bot in the directory has no determinable DM channel, or two state dirs report the same one, every
  bot there starts fresh. Silently dropping the unknown sibling made its deliveries invisible, so a
  session it had taken over was still attributed to whoever drove it before — the original failure.
- `guard-variant-memory.py` allowed too much: its "own namespace" test was a substring match, so
  alt 1 could write `variant_10/`, and any alt could write `variant_N/` of any other project. The
  own namespace is now exactly this project's `memory/variant_N/`, compared as real paths, with
  relative paths resolved against the session's working directory.
- An empty `<base>-N` directory without a `.env` no longer makes a single-bot directory look
  multi-bot (which rerouted its `-c`).
- A corrupt `dm_channel` cache no longer crashes the picker with a traceback.

### Changed

- **`-c` is rerouted in multi-bot directories.** `claude-dc -c` and `claude-dc-alt N -c` no longer
  pass `-c` through when the directory has more than one bot; they resume through the same
  DM-channel picker, keeping every other argument. Single-bot directories keep plain `-c`.
  `-r` still passes through, with a warning.
- Both resume helpers share one implementation, `_claude_dc_resume_as`.

### Added

- **`claude-dc-pick-session.py`** — install to `~/.claude/`. Prints the session a given bot should
  resume, or nothing; `-v` explains every transcript. Each bot's DM channel id is looked up once
  with the idempotent `POST /users/@me/channels` (`GET` returns `[]` for bot accounts) and cached
  in `<state dir>/dm_channel`. The DM partner is `$CLAUDE_DC_OWNER_ID`, else the first `allowFrom`
  entry of the bot's `access.json`. Only deliveries count: the agent's own text, tool calls and
  tool output are ignored, so a session that merely discusses another bot's DM id is not
  attributed to it.

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
