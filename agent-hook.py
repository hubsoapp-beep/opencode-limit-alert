#!/usr/bin/env python3
"""Hook dla Claude Code i Codex: wykrywa limity/błędy i wywołuje alerts.py."""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ALERTS = Path.home() / "bin/opencode-alerts/alerts.py"
PYTHON = sys.executable


def is_limit_text(text):
    return bool(re.search(r"rate.?limit|quota|usage limit|too many requests|429|insufficient.?(credit|balance|quota)", text or "", re.I))


def run_alert(title, kind, session_id="", detail="", agent=""):
    if not ALERTS.exists():
        return
    cmd = [PYTHON, str(ALERTS), "alert", title or "zadanie",
           "--kind", kind, "--session", session_id or "", "--detail", (detail or "")[:300], "--agent", agent]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def main():
    agent = sys.argv[1] if len(sys.argv) > 1 else "agent"
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    if not isinstance(data, dict):
        return

    event = data.get("hook_event_name") or ""
    session_id = str(data.get("session_id") or "")
    cwd = data.get("cwd") or ""
    title = Path(cwd).name if cwd else agent

    if agent == "claude-code":
        if event == "StopFailure":
            err_text = " ".join(str(data.get(k) or "") for k in
                                ("error", "error_type", "error_details", "message", "last_assistant_message"))
            kind = "limit" if is_limit_text(err_text) else "error"
            run_alert(f"Claude Code · {title}" if title else "Claude Code", kind, session_id, err_text, "claude-code")
        elif event == "SessionEnd":
            try:
                cfg = json.loads((Path.home() / ".config/opencode/limit-alert.json").read_text())
            except Exception:
                cfg = {}
            if cfg.get("announceDone", True) is not False:
                run_alert(f"Claude Code · {title}" if title else "Claude Code", "done", session_id, "", "claude-code")
    elif agent == "codex":
        if event == "Stop":
            msg = data.get("last_assistant_message") or ""
            if is_limit_text(msg):
                run_alert(f"Codex · {title}" if title else "Codex", "limit", session_id, msg[:300], "codex")
            elif re.search(r"\b(error|failed|exception)\b", msg, re.I) and is_limit_text(msg):
                run_alert(f"Codex · {title}" if title else "Codex", "error", session_id, msg[:300], "codex")


if __name__ == "__main__":
    main()
