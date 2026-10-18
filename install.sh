#!/bin/sh
# Instaluje plugin limit-alert do OpenCode v2 + banner z listą zadań (macOS)
# + hooki dla Claude Code i Codex (wykrywanie limitów/błędów).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OC="$HOME/.config/opencode"
APP="$HOME/bin/opencode-alerts"

mkdir -p "$OC/plugins" "$APP"
cp "$DIR/limit-alert.js" "$OC/plugins/limit-alert.js"
cp "$DIR/alerts.py" "$APP/alerts.py"
cp "$DIR/agent-hook.py" "$APP/agent-hook.py"
chmod +x "$APP/alerts.py" "$APP/agent-hook.py"

if [ ! -f "$OC/limit-alert.json" ]; then
  cp "$DIR/limit-alert.example.json" "$OC/limit-alert.json"
  chmod 600 "$OC/limit-alert.json"
  echo "Utworzono $OC/limit-alert.json — wpisz tam klucz ElevenLabs (opcjonalnie)."
fi

# ---------- Claude Code ----------
if [ -d "$HOME/.claude" ]; then
  python3 "$DIR/install-claude.py"
  echo "Zainstalowano hook Claude Code (StopFailure)."
fi

# ---------- Codex ----------
if [ -d "$HOME/.codex" ]; then
  sh "$DIR/install-codex.sh"
  echo "Zainstalowano hook Codex (przez wrapper herdr-agent-state.sh)."
fi

# ---------- Aplikacja menu bar ----------
if command -v swift >/dev/null 2>&1; then
  sh "$DIR/build-app.sh" >/dev/null 2>&1 || echo "Budowa aplikacji nie powiodła się (sprawdź swift)."
fi

echo "Zainstalowano plugin ($OC/plugins), banner ($APP)."
echo "Test bannera:  $APP/alerts.py add 'Testowe zadanie' && $APP/alerts.py show"
