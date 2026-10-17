#!/bin/sh
# Instaluje plugin limit-alert do OpenCode v2 (macOS).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OC="$HOME/.config/opencode"
mkdir -p "$OC/plugins"
cp "$DIR/limit-alert.js" "$OC/plugins/limit-alert.js"
if [ ! -f "$OC/limit-alert.json" ]; then
  cp "$DIR/limit-alert.example.json" "$OC/limit-alert.json"
  chmod 600 "$OC/limit-alert.json"
  echo "Utworzono $OC/limit-alert.json — wpisz tam klucz ElevenLabs (opcjonalnie)."
fi
echo "Zainstalowano. Zrestartuj opencode (także 'opencode serve --service', jeśli działa)."
