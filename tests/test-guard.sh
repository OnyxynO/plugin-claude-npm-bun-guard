#!/usr/bin/env bash
# Batterie du garde-fou.
# ⚠️ Lancer INDIRECTEMENT (`bash tests/test-guard.sh`) : si le plugin est actif,
# il intercepterait la commande de test elle-même, qui contient les chaînes
# « npm i … » / « bun add … » qu'il recherche.
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
H="$RACINE/hooks/guard.sh"
CACHE="${NPM_GUARD_CACHE:-$HOME/.cache/npm-bun-guard/npm-malware.tsv}"
SAUVE=$(mktemp)
DIR=$(mktemp -d)
ECHECS=0

printf '{"name":"t","version":"1.0.0"}\n' > "$DIR/package.json"
mkdir -p "$(dirname "$CACHE")"; touch "$CACHE"; cp "$CACHE" "$SAUVE"
restaurer() { cp "$SAUVE" "$CACHE"; rm -rf "$SAUVE" "$DIR"; }
trap restaurer EXIT

decision() {
  printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$DIR" "$1" \
    | bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null
}

verif() { # commande, libellé, attendu
  local r; r=$(decision "$1")
  printf '%-46s %-6s ' "$2" "${r:--}"
  if [ "${r:--}" = "$3" ]; then echo "OK"; else echo "ECHEC (attendu $3)"; ECHECS=$((ECHECS+1)); fi
}

echo "--- doivent passer ---"
verif "ls -la"                        "commande hors gestionnaire"   "-"
verif "npm run build"                 "npm run"                      "-"
verif "npm ci"                        "npm ci (arbre sain)"          "-"
verif "npm i left-pad"                "paquet ancien sain"           "-"
verif "npm i eslint"                  "npm : arbre transitif sain"   "-"
verif "bun add eslint"                "bun : arbre transitif sain"   "-"
verif "bun install"                   "bun install (sans paquet)"    "-"
verif "npm i left-pad \&\& echo keyv"  "nom apres && (ne compte pas)" "-"

echo "--- mutation : keyv 4.5.4 declare malveillant ---"
printf 'keyv\t= 4.5.4\n' >> "$CACHE"
verif "npm i eslint"                  "npm : transitif piege"        "deny"
verif "bun add eslint"                "bun : transitif piege"        "deny"
cp "$SAUVE" "$CACHE"

echo "--- apres restauration ---"
verif "npm i eslint"                  "npm : de nouveau sain"        "-"
verif "bun add eslint"                "bun : de nouveau sain"        "-"

echo
if [ "$ECHECS" -eq 0 ]; then echo "TOUS LES CAS PASSENT"; else echo "$ECHECS ECHEC(S)"; fi
exit "$ECHECS"
