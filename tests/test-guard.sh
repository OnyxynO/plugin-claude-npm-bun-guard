#!/usr/bin/env bash
# Batterie du garde-fou.
# ⚠️ Lancer INDIRECTEMENT (`bash tests/test-guard.sh`) : si le plugin est actif,
# il intercepterait la commande de test elle-même, qui contient les chaînes
# « npm i … » / « bun add … » qu'il recherche.
set -uo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
H="$RACINE/hooks/guard.sh"

# Isolation stricte du cache : la batterie ne doit JAMAIS écrire dans le cache
# réel de l'utilisateur (~/.cache/npm-bun-guard/). On EXPORTE les deux
# variables que guard.sh sait lire — CACHE_DIR (dont dérive aussi le fichier
# de tampon CACHE_STAMP) et CACHE — vers un répertoire temporaire dédié, créé
# ici, sans dépendre d'un export préalable fait par l'opérateur.
export NPM_GUARD_CACHE_DIR
NPM_GUARD_CACHE_DIR=$(mktemp -d)
export NPM_GUARD_CACHE="$NPM_GUARD_CACHE_DIR/npm-malware.tsv"
CACHE="$NPM_GUARD_CACHE"
SAUVE=$(mktemp)
DIR=$(mktemp -d)
ECHECS=0

printf '{"name":"t","version":"1.0.0"}\n' > "$DIR/package.json"
mkdir -p "$(dirname "$CACHE")"; touch "$CACHE"; cp "$CACHE" "$SAUVE"
restaurer() { rm -rf "$SAUVE" "$DIR" "$NPM_GUARD_CACHE_DIR"; }
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

# ⚠️ Version d'eslint EPINGLEE (9.9.1, jamais `latest`) : le cooldown de l'étape 5
# de guard.sh déclenche `ask` pour toute version publiée il y a moins de 3 jours.
# Sans épingle, le cas casse dès qu'eslint publie une release fraîche — flakiness
# calendaire sans rapport avec le code testé. 9.9.1 tire toujours `keyv@4.5.4` en
# transitif (vérifié pour npm et bun), donc la résolution d'arbre et les mutations
# ci-dessous restent exercées à l'identique.
echo "--- doivent passer ---"
verif "ls -la"                        "commande hors gestionnaire"   "-"
verif "npm run build"                 "npm run"                      "-"
verif "npm ci"                        "npm ci (arbre sain)"          "-"
verif "npm i left-pad"                "paquet ancien sain"           "-"
verif "npm i eslint@9.9.1"            "npm : arbre transitif sain"   "-"
verif "bun add eslint@9.9.1"          "bun : arbre transitif sain"   "-"
verif "bun install"                   "bun install (sans paquet)"    "-"
verif "npm i left-pad && echo keyv"   "nom apres && (ne compte pas)" "-"

echo "--- mutation : keyv 4.5.4 declare malveillant ---"
printf 'keyv\t= 4.5.4\n' >> "$CACHE"
verif "npm i eslint@9.9.1"            "npm : transitif piege"        "deny"
verif "bun add eslint@9.9.1"          "bun : transitif piege"        "deny"
cp "$SAUVE" "$CACHE"

echo "--- apres restauration ---"
verif "npm i eslint@9.9.1"            "npm : de nouveau sain"        "-"
verif "bun add eslint@9.9.1"          "bun : de nouveau sain"        "-"

echo "--- amorcage sans gh (PATH neutralise) ---"
# ⚠️ Ce cas ne prouve PAS le téléchargement : le cache est déjà rempli.
# Il exerce le repli sur paquets nommés quand PATH est neutralisé (ni gh, ni npm, ni bun).
# La preuve du téléchargement est le cas suivant, sur cache vide.
CACHE_VIDE=$(mktemp -d)
printf 'keyv\t= 4.5.4\n' > "$CACHE_VIDE/npm-malware.tsv"
r=$(printf '{"cwd":"%s","tool_input":{"command":"npm i keyv@4.5.4"}}' "$DIR" \
  | env PATH="/usr/bin:/bin:/usr/sbin:/sbin" NPM_GUARD_CACHE="$CACHE_VIDE/npm-malware.tsv" \
    bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null)
printf '%-46s %-6s ' "sans gh : le controle mord quand meme" "${r:--}"
if [ "${r:--}" = "deny" ]; then echo "OK"; else echo "ECHEC (attendu deny)"; ECHECS=$((ECHECS+1)); fi
rm -rf "$CACHE_VIDE"

echo "--- amorcage par telechargement direct (cache vide, PATH neutralise) ---"
# Contrairement au cas précédent (cache déjà rempli), celui-ci part d'un cache
# VIDE et pointe NPM_GUARD_DB_URL vers une source locale : seul un vrai
# téléchargement peut le faire passer au vert. C'est la preuve par mutation
# exigée par le principe 21 — sans `rafraichir_base` sachant télécharger, ce
# cas échoue nécessairement.
CACHE_TELECHARGE_DIR=$(mktemp -d)
SOURCE_DISTANTE=$(mktemp)
# Le contrôle `> 100 lignes` de rafraichir_base rejette une source trop
# courte (page d'erreur HTML) : il faut donc plus de 100 lignes ici aussi.
{ printf 'keyv\t= 4.5.4\n'; i=0; while [ "$i" -lt 150 ]; do printf 'paquet-bidon-%d\t*\n' "$i"; i=$((i+1)); done; } > "$SOURCE_DISTANTE"
r=$(printf '{"cwd":"%s","tool_input":{"command":"npm i keyv@4.5.4"}}' "$DIR" \
  | env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        NPM_GUARD_CACHE="$CACHE_TELECHARGE_DIR/npm-malware.tsv" \
        NPM_GUARD_DB_URL="file://$SOURCE_DISTANTE" \
    bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null)
printf '%-46s %-6s ' "sans gh : amorcage via telechargement" "${r:--}"
if [ "${r:--}" = "deny" ]; then echo "OK"; else echo "ECHEC (attendu deny)"; ECHECS=$((ECHECS+1)); fi
rm -rf "$CACHE_TELECHARGE_DIR" "$SOURCE_DISTANTE"

echo
if [ "$ECHECS" -eq 0 ]; then echo "TOUS LES CAS PASSENT"; else echo "$ECHECS ECHEC(S)"; fi
exit "$ECHECS"
