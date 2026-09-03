#!/usr/bin/env python3
"""Stop hook: refuse to end a turn that was triggered from Discord but never replied there.

Why this exists
---------------
Prompt-level rules (PROJECT_RULES.md's "EVERY reply must go through the reply tool",
the end-of-turn self-check, per-bot memories) all still rely on the model *remembering*
at the end of a long tool chain — and it demonstrably does not, every so often. This hook
is the deterministic backstop: the harness checks, not the model.

Logic
-----
* Read the transcript, isolate THIS turn = everything after the last user message.
* Only enforce when that user message actually came from Discord (`<channel source=
  "plugin:discord:...">`). Terminal-driven turns are none of our business, so a plain
  `claude` session is never affected.
* If the turn contains no `mcp__plugin_discord_discord__{reply,react,edit_message}`
  tool call → block, telling the model to send it.
* `stop_hook_active` guard: if we already blocked once and it stopped again, let it go —
  never trap the session in a loop.

Exit contract: print JSON on stdout, exit 0.
"""
import json
import os
import sys

# Rollout gate. Hooks registered in ~/.claude/settings.json apply to EVERY session, and there is
# no settings path that means "only this one bot" — a bot whose project dir is your $HOME has the
# same project-level .claude/ as the user-level one. So scoping lives here instead: list the
# DISCORD_STATE_DIR basenames to enforce for, e.g. ["my-project", "other-project"], which is handy
# for a staged rollout. ["*"] enables it everywhere.
ENFORCE_FOR = ["*"]

DISCORD_OUTBOUND = (
    "mcp__plugin_discord_discord__reply",
    "mcp__plugin_discord_discord__react",
    "mcp__plugin_discord_discord__edit_message",
)


def allow():
    print(json.dumps({}))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        allow()  # malformed input must never wedge a session

    # Already blocked once this turn — don't loop.
    if payload.get("stop_hook_active"):
        allow()

    # Staged rollout: is this bot in scope?
    if "*" not in ENFORCE_FOR:
        bot = os.path.basename((os.environ.get("DISCORD_STATE_DIR") or "").rstrip("/"))
        if bot not in ENFORCE_FOR:
            allow()

    path = payload.get("transcript_path")
    if not path:
        allow()

    try:
        with open(path, errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        allow()

    # Walk backwards to the last user message: that's where this turn began.
    turn = []
    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except Exception:
            continue
        turn.append(rec)
        if rec.get("type") == "user":
            break
    turn.reverse()
    if not turn:
        allow()

    # Was this turn triggered from Discord? Only then is a Discord reply owed.
    opener = turn[0]
    if opener.get("type") != "user":
        allow()
    blob = json.dumps(opener.get("message", ""), ensure_ascii=False)
    if 'source=\\"plugin:discord' not in blob and "source=\"plugin:discord" not in blob:
        allow()

    # Did anything in this turn actually send to Discord?
    for rec in turn:
        msg = rec.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                if block.get("name") in DISCORD_OUTBOUND:
                    allow()

    print(json.dumps({
        "decision": "block",
        "reason": (
            "This turn came from Discord but you never called "
            "mcp__plugin_discord_discord__reply. Terminal output does NOT reach the user. "
            "Send your reply now via the reply tool (pass the inbound chat_id). "
            "If you genuinely have nothing to say, call react instead."
        ),
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
