#!/bin/sh
# Instaluje hook Codex przez wrapper na herdr-agent-state.sh (zachowuje trust).
set -e
CODEX_DIR="$HOME/.codex"
STATE="$CODEX_DIR/herdr-agent-state.sh"
ORIG="$CODEX_DIR/herdr-agent-state.sh.limit-alert-original"
HOOK="$CODEX_DIR/limit-alert-hook.sh"

# Backup oryginału (jeśli jeszcze nie zrobiony)
if [ -f "$STATE" ] && [ ! -f "$ORIG" ]; then
  cp "$STATE" "$ORIG"
fi

# Jeśli nie ma oryginału (herdr nie zainstalowany), stwórz pusty
if [ ! -f "$ORIG" ]; then
  printf '#!/bin/sh\nexit 0\n' > "$ORIG"
  chmod +x "$ORIG"
fi

cat > "$STATE" <<'EOF'
#!/bin/sh
# wrapper: opencode-limit-alert + oryginalny hook herdr
input_file="$(mktemp "${TMPDIR:-/tmp}/limit-alert-codex.XXXXXX")" || input_file="/tmp/limit-alert-codex.$$"
trap 'rm -f "$input_file"' EXIT HUP INT TERM
cat >"$input_file" 2>/dev/null || true

# nasz alert
python3 "$HOME/bin/opencode-alerts/agent-hook.py" codex <"$input_file" 2>/dev/null || true

# oryginalny hook herdr
"$HOME/.codex/herdr-agent-state.sh.limit-alert-original" "$@" <"$input_file"
rc=$?
exit $rc
EOF
chmod +x "$STATE"
echo "codex wrapper installed"