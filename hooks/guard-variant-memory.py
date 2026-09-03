#!/usr/bin/env python3
"""PreToolUse hook: stop an alt-N bot from writing outside its own memory namespace.

Why this exists
---------------
Same-cwd alt bots (`claude-dc-alt N`, `CLAUDE_BOT_VARIANT=N`) are supposed to write only to
`memory/variant_N/`. That rule lives in PROJECT_RULES §1b and in each variant's own MEMORY.md —
but it is a *convention*: nothing stops an alt from writing an absolute path into the primary's
`memory/` root, or into another project's memory entirely. Same UNIX user, ordinary 0755 dirs,
so file permissions cannot help. One careless write destroys an index built over months
(one project here: ~50 memory files, 12 KB MEMORY.md, unrecoverable from transcripts).

This hook makes the harness enforce it instead of the model remembering it.

Rule
----
Only active when `CLAUDE_BOT_VARIANT` is set (i.e. we ARE an alt bot). For a write-ish tool
(Write/Edit/NotebookEdit, or a shell command that redirects/moves into such a path), resolve the
target and DENY if it lands inside any `.claude/projects/*/memory/` tree that is NOT this bot's
own `memory/variant_<N>/`.

Fail-open by design: unparseable input, unknown tool, no variant set, or any internal error →
allow. A guard that wedges every session is worse than the risk it prevents.
"""
import json
import os
import re
import sys

MEM_RE = re.compile(r"\.claude/projects/[^/]+/memory(/|$)")


def allow():
    print(json.dumps({}))
    sys.exit(0)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def candidate_paths(tool, ti):
    """Paths this tool call would write to. Conservative: only obvious write targets."""
    out = []
    if tool in ("Write", "Edit", "NotebookEdit"):
        for k in ("file_path", "notebook_path", "path"):
            v = ti.get(k)
            if isinstance(v, str):
                out.append(v)
    elif tool == "Bash":
        cmd = ti.get("command")
        if isinstance(cmd, str) and "memory" in cmd:
            # Redirections and tee/rm/mkdir: the token right after is the target.
            for m in re.finditer(r"(?:>>?|\btee\b|\brm\b|\bmkdir\b)\s+(?:-\S+\s+)*([^\s;|&]+)", cmd):
                out.append(m.group(1).strip("'\""))
            # cp/mv/rsync/install: the TARGET is the LAST operand, not the first.
            for m in re.finditer(r"\b(?:cp|mv|rsync|install)\b((?:\s+(?:-\S+|[^\s;|&]+))+)", cmd):
                ops = [o for o in m.group(1).split() if not o.startswith("-")]
                if ops:
                    out.append(ops[-1].strip("'\""))
    return out


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        allow()

    variant = (os.environ.get("CLAUDE_BOT_VARIANT") or "").strip()
    if not variant:
        allow()                      # primary bot or plain session — not our business

    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()

    try:
        mine = f"/memory/variant_{variant}"
        for raw in candidate_paths(tool, ti):
            p = os.path.expanduser(os.path.expandvars(raw))
            if not os.path.isabs(p):
                p = os.path.abspath(p)
            p = os.path.normpath(p)
            if not MEM_RE.search(p):
                continue             # not a memory path at all
            if mine in p:
                continue             # our own namespace — fine
            deny(
                f"BLOCKED: you are alt-{variant} (CLAUDE_BOT_VARIANT={variant}), so the only memory "
                f"directory you may write to is memory/variant_{variant}/. The path you tried "
                f"({raw}) is another bot's memory namespace — writing there would overwrite an index "
                f"built up over months that no transcript can rebuild. Put this in "
                f"memory/variant_{variant}/ instead (that is YOUR MEMORY.md and your index). "
                f"If you genuinely believe the write belongs elsewhere, stop and ask the user."
            )
    except Exception:
        allow()                      # never let a bug in this guard block real work

    allow()


if __name__ == "__main__":
    main()
