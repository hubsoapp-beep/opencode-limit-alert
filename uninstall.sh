#!/bin/sh
# Usuwa plugin i banner. Konfiguracja (~/.config/opencode/limit-alert.json) zostaje.
pkill -f "opencode-alerts/alerts.py show" 2>/dev/null || true
pkill -f "LimitAlert.app/Contents/MacOS/LimitAlert" 2>/dev/null || true
rm -f "$HOME/.config/opencode/plugins/limit-alert.js"
rm -rf "$HOME/bin/opencode-alerts" "$HOME/.opencode-alerts" "$HOME/Applications/LimitAlert.app"

# Claude Code: usuń hooki
if [ -f "$HOME/.claude/settings.json" ]; then
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
for ev in ("StopFailure","SessionEnd"):
    groups=d.get("hooks",{}).get(ev,[])
    new=[]
    for g in groups:
        hs=[h for h in g.get("hooks",[]) if "agent-hook.py" not in (h.get("command") or "")]
        if hs:
            g["hooks"]=hs
            new.append(g)
    if new:
        d["hooks"][ev]=new
    else:
        d.get("hooks",{}).pop(ev,None)
json.dump(d,open(p,"w"),indent=2)
PY
fi

# Codex: przywróć oryginalny herdr-agent-state.sh
if [ -f "$HOME/.codex/herdr-agent-state.sh.limit-alert-original" ]; then
  mv "$HOME/.codex/herdr-agent-state.sh.limit-alert-original" "$HOME/.codex/herdr-agent-state.sh"
fi

echo "Usunięto. Konfigurację usuń ręcznie: rm ~/.config/opencode/limit-alert.json"
