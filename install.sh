#!/bin/sh
# Instaluje plugin limit-alert do OpenCode v2 + banner z listą zadań (macOS).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OC="$HOME/.config/opencode"
APP="$HOME/bin/opencode-alerts"

mkdir -p "$OC/plugins" "$APP"
cp "$DIR/limit-alert.js" "$OC/plugins/limit-alert.js"
cp "$DIR/alerts.py" "$APP/alerts.py"
chmod +x "$APP/alerts.py"

if [ ! -f "$OC/limit-alert.json" ]; then
  cp "$DIR/limit-alert.example.json" "$OC/limit-alert.json"
  chmod 600 "$OC/limit-alert.json"
  echo "Utworzono $OC/limit-alert.json — wpisz tam klucz ElevenLabs (opcjonalnie)."
fi
echo "Zainstalowano plugin ($OC/plugins) i banner ($APP)."
echo "Test bannera:  $APP/alerts.py add 'Testowe zadanie' && $APP/alerts.py show"
