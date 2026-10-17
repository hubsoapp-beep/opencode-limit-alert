#!/bin/sh
# Usuwa plugin i banner. Konfiguracja (~/.config/opencode/limit-alert.json) zostaje.
pkill -f "opencode-alerts/alerts.py show" 2>/dev/null || true
rm -f "$HOME/.config/opencode/plugins/limit-alert.js"
rm -rf "$HOME/bin/opencode-alerts" "$HOME/.opencode-alerts"
echo "Usunięto. Konfigurację usuń ręcznie: rm ~/.config/opencode/limit-alert.json"
