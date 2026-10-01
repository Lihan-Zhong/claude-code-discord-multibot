#!/usr/bin/env python3
"""Pick the session a given Discord bot should resume — by ground truth, not by guessing.

Install as ~/.claude/claude-dc-pick-session.py. Used by `claude-dc-resume`, `claude-dc-alt-resume N`
and the `-c` reroute in claude-dc.bash.

Why this exists
---------------
Claude Code keys sessions on the working directory alone; nothing binds a session to the bot
(DISCORD_STATE_DIR) that was driving it. In a directory shared by a primary and an alt, the v2.0
resume helpers had to *infer* ownership from transcript text:

  * claude-dc-alt-resume counted `variant_N` across the whole transcript (>= 3 = "alt's").
  * claude-dc-resume scored only the session opening (0 hits = "primary's").

Both are heuristics, and the first one failed for real: a primary bot had discussed its alt so
often that its own transcript held 104 mentions of `variant_2`. Every session in that directory
scored >= 3, the helper picked the newest — the primary's — and the alt resumed the primary's
conversation. The check had passed when it was written (the primary then had 0 mentions); the
signal decayed as the conversation grew. Opening-only scoring has a related weakness: the opening
says who STARTED a session, not who drives it now, and a session can change hands. Text about a
bot is not evidence of which bot it was.

Ground truth
------------
Every inbound Discord message is recorded in the transcript as `<channel chat_id="..." ...>`, and
each bot talks to its owner through ITS OWN private DM channel. So the bot that is driving a
session is whichever bot's DM channel the session most recently received a message on. That is
not inferred from what was discussed; it is the channel the harness actually delivered through.

A bot's DM channel id is obtained once with the idempotent `POST /users/@me/channels` (it returns
the existing DM and sends nothing) and cached in `<state dir>/dm_channel`, so later launches make
no network call. (`GET /users/@me/channels` does not work for this: it returns [] for bot accounts.)

The owner — the Discord user on the other end of that DM — is `$CLAUDE_DC_OWNER_ID` if set,
otherwise the first entry of `allowFrom` in the bot's own `<state dir>/access.json`. Set the env
var if a bot has more than one paired user. Delete `dm_channel` to force a re-lookup.

Rules
-----
* A transcript belongs to bot B if, among inbound messages on the DM channels of the bots sharing
  this directory, the LAST one arrived on B's channel. A session that changed hands belongs to
  whoever drove it last.
* Only deliveries count. Assistant records (the agent's own text and tool calls) and tool results
  are skipped, so a session that merely talks about another bot's DM id — while debugging, say —
  is not attributed to that bot.
* Transcripts with no inbound DM message from any of these bots are not attributable and are skipped.
* Never guess. If B's DM channel cannot be determined, print nothing and exit 2 — the caller then
  starts a fresh session instead of resuming the wrong one.

Usage:  claude-dc-pick-session.py <cwd> <state-dir>      -> prints a session id, or nothing
        claude-dc-pick-session.py <cwd> <state-dir> -v   -> also explains every transcript on stderr
"""
import glob
import json
import os
import re
import sys
import urllib.request

OWNER_ENV = "CLAUDE_DC_OWNER_ID"
INBOUND = re.compile(r'chat_id=\\?"(\d+)\\?"')


def owner_id(state_dir):
    """The Discord user whose DM with this bot identifies it."""
    v = os.environ.get(OWNER_ENV, "").strip()
    if v.isdigit():
        return v
    try:
        with open(os.path.join(state_dir, "access.json")) as fh:
            allow = json.load(fh).get("allowFrom") or []
        if allow and str(allow[0]).isdigit():
            return str(allow[0])
    except (OSError, ValueError, AttributeError):
        pass
    return None


def dm_channel(state_dir):
    """This bot's DM channel with its owner, cached in <state_dir>/dm_channel."""
    cache = os.path.join(state_dir, "dm_channel")
    try:
        with open(cache) as fh:
            v = fh.read().strip()
        if v.isdigit():
            return v
    except OSError:
        pass
    try:
        owner = owner_id(state_dir)
        token = None
        with open(os.path.join(state_dir, ".env")) as fh:
            for line in fh:
                if line.startswith("DISCORD_BOT_TOKEN="):
                    token = line.split("=", 1)[1].strip().strip("'\"")
        if not token or not owner:
            return None
        req = urllib.request.Request(
            "https://discord.com/api/v10/users/@me/channels",
            data=json.dumps({"recipient_id": owner}).encode(),
            headers={"Authorization": f"Bot {token}", "Content-Type": "application/json",
                     "User-Agent": "claude-dc-pick-session (local helper)"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            cid = json.load(r).get("id")
        if cid and str(cid).isdigit():
            try:
                with open(cache, "w") as fh:
                    fh.write(str(cid) + "\n")
                os.chmod(cache, 0o600)
            except OSError:
                pass
            return str(cid)
    except Exception:
        return None
    return None


def delivered_text(line):
    """The part of a transcript line that can carry a delivered message.

    Skips what the agent itself wrote (assistant records) and what its tools returned
    (tool_result blocks); everything else is scanned as-is, so a delivery record type this
    script has never seen is still counted rather than silently dropped.
    """
    try:
        rec = json.loads(line)
    except ValueError:
        return line
    if not isinstance(rec, dict):
        return line
    if rec.get("type") == "assistant":
        return ""
    msg = rec.get("message")
    if rec.get("type") == "user" and isinstance(msg, dict) and isinstance(msg.get("content"), list):
        kept = [b for b in msg["content"]
                if not (isinstance(b, dict) and b.get("type") == "tool_result")]
        return json.dumps(kept)
    return line


def last_owner(path, known):
    """The DM channel (among `known`) that this transcript most recently received a message on."""
    last = None
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if "chat_id=" not in line:
                    continue
                for m in INBOUND.finditer(delivered_text(line)):
                    if m.group(1) in known:
                        last = m.group(1)
    except OSError:
        return None
    return last


def transcript_dir(cwd):
    """Claude Code's bucket for `cwd`: the (physical) path with every non-alphanumeric -> '-'."""
    root = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    cands = [re.sub(r"[^A-Za-z0-9]", "-", p)
             for p in (os.path.realpath(cwd), os.path.abspath(cwd))]
    for enc in cands:
        if os.path.isdir(os.path.join(root, enc)):
            return os.path.join(root, enc)
    return os.path.join(root, cands[0])


def main():
    if len(sys.argv) < 3:
        print(__doc__.split("Usage:")[1], file=sys.stderr)
        return 64
    cwd, state = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    verbose = "-v" in sys.argv[3:]

    me = dm_channel(state)
    if not me:
        print(f"claude-dc-pick-session: could not determine this bot's DM channel ({state});"
              f" is the bot paired, or is {OWNER_ENV} set?", file=sys.stderr)
        return 2

    # Every bot sharing this directory: <base> and <base>-N under the same state root, where
    # <base> is basename(cwd) — the same rule claude-dc / claude-dc-alt use to pick a state dir.
    root = os.path.dirname(state)
    base = os.path.basename(cwd)
    if not re.fullmatch(re.escape(base) + r"(-\d+)?", os.path.basename(state)):
        base = re.sub(r"-\d+$", "", os.path.basename(state))
    # Siblings are exactly <base>-<digits>: a bare "<base>-[0-9]*" glob would also catch an
    # unrelated directory that merely starts with "<base>-2…". Any number of alts is fine.
    alt_re = re.compile(re.escape(base) + r"-(\d+)")
    try:
        alts = [n for n in os.listdir(root) if alt_re.fullmatch(n)]
    except OSError:
        alts = []
    siblings = {}
    for n in [base] + sorted(alts, key=lambda n: int(alt_re.fullmatch(n).group(1))):
        d = os.path.join(root, n)
        if os.path.isfile(os.path.join(d, ".env")):
            c = dm_channel(d)
            if c:
                siblings[c] = n
    siblings[me] = os.path.basename(state)

    tdir = transcript_dir(cwd)
    best = None
    for t in glob.glob(os.path.join(tdir, "*.jsonl")):
        owner = last_owner(t, siblings)
        mtime = os.path.getmtime(t)
        if verbose:
            who = siblings.get(owner, "— no inbound DM from these bots")
            print(f"  {os.path.basename(t)[:8]}  last driven by: {who}"
                  f"{'   <- mine' if owner == me else ''}", file=sys.stderr)
        if owner == me and (best is None or mtime > best[0]):
            best = (mtime, os.path.basename(t)[:-len(".jsonl")])

    if best:
        print(best[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
