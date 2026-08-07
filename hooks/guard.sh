#!/usr/bin/env bash
# Témoin d'installation — remplacé par le garde-fou réel en tâche 2.
set -uo pipefail
charge=$(cat)
commande=$(printf '%s' "$charge" | jq -r '.tool_input.command // empty' 2>/dev/null)
printf '%s\t%s\n' "$(date -u +%FT%TZ)" "${commande:-<vide>}" >> /tmp/preuve-plugin-guard.log
exit 0
