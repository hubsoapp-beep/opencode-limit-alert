#!/usr/bin/env python3
"""Dodaje hook StopFailure (i SessionEnd) do ~/.claude/settings.json."""
import json
from pathlib import Path

settings_path = Path.home() / ".claude/settings.json"
hook_cmd = 'python3 "$HOME/bin/opencode-alerts/agent-hook.py" claude-code'

data = json.loads(settings_path.read_text())
hooks = data.setdefault("hooks", {})

def has_hook(event, needle):
    for group in hooks.get(event, []):
        for h in group.get("hooks", []):
            if needle in (h.get("command") or ""):
                return True
    return False

for event in ("StopFailure", "SessionEnd"):
    if not has_hook(event, "agent-hook.py"):
        hooks.setdefault(event, []).append({"hooks": [{"type": "command", "command": hook_cmd, "timeout": 10}]})

settings_path.write_text(json.dumps(data, indent=2) + "\n")
print("claude hooks updated")