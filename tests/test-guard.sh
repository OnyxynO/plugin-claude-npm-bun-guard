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

echo "--- amorcage gh api sur cache VIDE (regression task-7) ---"
# Preuve du défaut corrigé : quand $CACHE_MALWARE n'existe pas encore (premier
# run), `cat "$CACHE_MALWARE" "$tmp"` échouait (exit 1) et `set -o pipefail`
# propageait ce statut au pipeline — le `&&` court-circuitait alors le `mv`,
# la base n'était JAMAIS écrite, alors que le stamp du jour l'était quand même
# (ligne non chaînée). On neutralise le réseau (curl d'amorçage pointé vers un
# chemin local inexistant, donc toujours en échec, indépendamment de l'état de
# publication du dépôt) et on remplace `gh` par un faux binaire déterministe :
# ni la fraîcheur du registre npm ni la disponibilité réseau réelle de `gh`
# n'entrent en jeu, comme l'exige le principe de déterminisme des tests ici.
CACHE_AMORCAGE_DIR=$(mktemp -d)
FAUX_GH_DIR=$(mktemp -d)
cat > "$FAUX_GH_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mime `gh api --paginate .../advisories...` avec deux entrées fixes.
case "$1" in
  api) printf 'malware-test-pkg\t*\n'; printf 'malware-test-autre\t*\n'; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAUX_GH_DIR/gh"

printf '{"cwd":"%s","tool_input":{"command":"npm i left-pad"}}' "$DIR" \
  | PATH="$FAUX_GH_DIR:$PATH" \
    NPM_GUARD_CACHE_DIR="$CACHE_AMORCAGE_DIR" \
    NPM_GUARD_CACHE="$CACHE_AMORCAGE_DIR/npm-malware.tsv" \
    NPM_GUARD_DB_URL="file:///chemin-inexistant-guard-test-task-7" \
    bash "$H" >/dev/null 2>&1

base_ecrite=false
[ -s "$CACHE_AMORCAGE_DIR/npm-malware.tsv" ] && base_ecrite=true
stamp_present=false
[ -s "$CACHE_AMORCAGE_DIR/npm-malware.stamp" ] && stamp_present=true

printf '%-46s %-6s ' "cache vide : base ecrite au 1er run" "$([ "$base_ecrite" = true ] && echo oui || echo non)"
if [ "$base_ecrite" = true ]; then echo "OK"; else echo "ECHEC (base absente ou vide)"; ECHECS=$((ECHECS+1)); fi

printf '%-46s %-6s ' "stamp coherent avec la base ecrite" "-"
if [ "$base_ecrite" = true ] && [ "$stamp_present" = true ]; then
  echo "OK"
elif [ "$base_ecrite" = false ] && [ "$stamp_present" = false ]; then
  echo "OK"
else
  echo "ECHEC (stamp present=$stamp_present, base ecrite=$base_ecrite : invariant rompu)"
  ECHECS=$((ECHECS+1))
fi

rm -rf "$CACHE_AMORCAGE_DIR" "$FAUX_GH_DIR"

echo "--- rafraichissement quand le stamp est perime, sans gh (task-9) ---"
# Public principal du plugin : quelqu'un qui a Claude Code mais pas `gh`.
# PATH restreint = liens symboliques vers les seuls binaires dont guard.sh a
# besoin, SAUF `gh` (méthode qui a permis d'établir la preuve du défaut :
# gh installé et authentifié sur cette machine, il faut donc le retirer
# explicitement plutôt que compter sur son absence du système).
FAUX_PATH_DIR=$(mktemp -d)
for bin in bash jq curl mktemp sort mv rm wc date cat awk grep sed tr head; do
  chemin=$(command -v "$bin" 2>/dev/null) || continue
  ln -s "$chemin" "$FAUX_PATH_DIR/$bin"
done

# Serveur HTTP local déterministe. Pas de file:// : curl sur macOS refuse ce
# schéma (code 3, vérifié) — ne pas y bâtir un test dessus. Plus de 100
# lignes pour passer le contrôle anti-page-d'erreur de rafraichir_base.
SERVEUR_DIR=$(mktemp -d)
{ printf 'guard-test-sentinelle\t*\n'; i=0; while [ "$i" -lt 150 ]; do printf 'paquet-bidon-%d\t*\n' "$i"; i=$((i+1)); done; } > "$SERVEUR_DIR/npm-malware.tsv"
python3 -u -m http.server 0 --directory "$SERVEUR_DIR" --bind 127.0.0.1 > "$SERVEUR_DIR/serveur.log" 2>&1 &
SERVEUR_PID=$!
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PORT=$(grep -oE 'port [0-9]+' "$SERVEUR_DIR/serveur.log" 2>/dev/null | grep -oE '[0-9]+')
  [ -n "$PORT" ] && break
  sleep 0.2
done
arreter_serveur() { kill "$SERVEUR_PID" 2>/dev/null; wait "$SERVEUR_PID" 2>/dev/null; }

if [ -z "$PORT" ]; then
  echo "ECHEC (serveur HTTP local n'a pas démarré)"; ECHECS=$((ECHECS+1))
else
  URL_LOCALE="http://127.0.0.1:$PORT/npm-malware.tsv"

  # Cas A : base présente mais stamp périmé (hier) → re-téléchargement.
  CACHE_PERIME_DIR=$(mktemp -d)
  printf 'ancien-paquet\t*\n' > "$CACHE_PERIME_DIR/npm-malware.tsv"
  date -u -v-2d +%Y-%m-%d 2>/dev/null > "$CACHE_PERIME_DIR/npm-malware.stamp" \
    || date -u -d "-2 days" +%Y-%m-%d > "$CACHE_PERIME_DIR/npm-malware.stamp"

  T0=$(date +%s.%N 2>/dev/null || date +%s)
  printf '{"cwd":"%s","tool_input":{"command":"npm i left-pad"}}' "$DIR" \
    | env -i PATH="$FAUX_PATH_DIR" HOME="$HOME" \
          NPM_GUARD_CACHE_DIR="$CACHE_PERIME_DIR" \
          NPM_GUARD_CACHE="$CACHE_PERIME_DIR/npm-malware.tsv" \
          NPM_GUARD_DB_URL="$URL_LOCALE" \
      bash "$H" >/dev/null 2>&1
  T1=$(date +%s.%N 2>/dev/null || date +%s)

  telechargee=false
  grep -q '^guard-test-sentinelle' "$CACHE_PERIME_DIR/npm-malware.tsv" 2>/dev/null && telechargee=true
  stamp_jour=false
  [ "$(cat "$CACHE_PERIME_DIR/npm-malware.stamp" 2>/dev/null)" = "$(date -u +%Y-%m-%d)" ] && stamp_jour=true

  printf '%-46s %-6s ' "sans gh, stamp perime : base retelechargee" "$([ "$telechargee" = true ] && echo oui || echo non)"
  if [ "$telechargee" = true ] && [ "$stamp_jour" = true ]; then echo "OK"; else echo "ECHEC (telechargee=$telechargee, stamp_jour=$stamp_jour)"; ECHECS=$((ECHECS+1)); fi
  echo "  latence mesurée (curl 64 Ko simulé) : $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f s", b-a}' 2>/dev/null)"
  rm -rf "$CACHE_PERIME_DIR"

  # Cas B : stamp du jour → aucun téléchargement (pas de coût réseau à
  # chaque commande). On coupe le serveur juste avant : si guard.sh tentait
  # quand même le curl, il échouerait proprement (réseau KO, on laisse
  # passer) — mais la base ne doit alors PAS contenir la sentinelle.
  CACHE_FRAIS_DIR=$(mktemp -d)
  printf 'ancien-paquet\t*\n' > "$CACHE_FRAIS_DIR/npm-malware.tsv"
  date -u +%Y-%m-%d > "$CACHE_FRAIS_DIR/npm-malware.stamp"
  arreter_serveur

  printf '{"cwd":"%s","tool_input":{"command":"npm i left-pad"}}' "$DIR" \
    | env -i PATH="$FAUX_PATH_DIR" HOME="$HOME" \
          NPM_GUARD_CACHE_DIR="$CACHE_FRAIS_DIR" \
          NPM_GUARD_CACHE="$CACHE_FRAIS_DIR/npm-malware.tsv" \
          NPM_GUARD_DB_URL="$URL_LOCALE" \
      bash "$H" >/dev/null 2>&1

  pas_touchee=true
  grep -q '^guard-test-sentinelle' "$CACHE_FRAIS_DIR/npm-malware.tsv" 2>/dev/null && pas_touchee=false

  printf '%-46s %-6s ' "stamp du jour : aucun telechargement" "$([ "$pas_touchee" = true ] && echo oui || echo non)"
  if [ "$pas_touchee" = true ]; then echo "OK"; else echo "ECHEC (la base a ete retelechargee alors que le stamp etait du jour)"; ECHECS=$((ECHECS+1)); fi
  rm -rf "$CACHE_FRAIS_DIR"
fi

arreter_serveur 2>/dev/null
rm -rf "$FAUX_PATH_DIR" "$SERVEUR_DIR"

echo "--- configuration ---"
printf 'keyv\t= 4.5.4\n' >> "$CACHE"
r=$(printf '{"cwd":"%s","tool_input":{"command":"npm i eslint"}}' "$DIR" \
  | NPM_GUARD_DISABLE=1 bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null)
printf '%-46s %-6s ' "NPM_GUARD_DISABLE=1 desactive tout" "${r:--}"
if [ "${r:--}" = "-" ]; then echo "OK"; else echo "ECHEC (attendu -)"; ECHECS=$((ECHECS+1)); fi
cp "$SAUVE" "$CACHE"

# ⚠️ Cas déterministe, indépendant du calendrier de publication npm — le miroir
# du piège documenté plus haut sur eslint@9.9.1. Un paquet non épinglé dont le
# cooldown se déclencherait « par chance » (parce qu'il a été publié il y a
# moins de N jours à la date du run) redeviendrait vert dès que le calendrier
# change, sans rien prouver. On force donc le déclenchement de façon
# structurelle : `is-number` est un paquet ancien (publié en 2018), stable et
# jamais retiré du registre — son âge en jours dépasse 3 mais reste toujours
# inférieur à 99999, quelle que soit la date du run. La paire ci-dessous prouve
# deux choses indépendamment du calendrier : que la quarantaine sait se
# déclencher (99999 jours ⇒ ask), et que 0 la désactive (0 jour ⇒ -).
CACHE_COOLDOWN=$(mktemp -d)
r=$(printf '{"cwd":"%s","tool_input":{"command":"npm i is-number"}}' "$DIR" \
  | NPM_GUARD_CACHE_DIR="$CACHE_COOLDOWN" NPM_GUARD_CACHE="$CACHE_COOLDOWN/npm-malware.tsv" \
    NPM_GUARD_COOLDOWN_DAYS=99999 bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null)
printf '%-46s %-6s ' "COOLDOWN_DAYS=99999 declenche toujours" "${r:--}"
if [ "${r:--}" = "ask" ]; then echo "OK"; else echo "ECHEC (attendu ask)"; ECHECS=$((ECHECS+1)); fi

r=$(printf '{"cwd":"%s","tool_input":{"command":"npm i is-number"}}' "$DIR" \
  | NPM_GUARD_CACHE_DIR="$CACHE_COOLDOWN" NPM_GUARD_CACHE="$CACHE_COOLDOWN/npm-malware.tsv" \
    NPM_GUARD_COOLDOWN_DAYS=0 bash "$H" | jq -r '.hookSpecificOutput.permissionDecision // "-"' 2>/dev/null)
printf '%-46s %-6s ' "COOLDOWN_DAYS=0 desactive la quarantaine" "${r:--}"
if [ "${r:--}" = "-" ]; then echo "OK"; else echo "ECHEC (attendu -)"; ECHECS=$((ECHECS+1)); fi
rm -rf "$CACHE_COOLDOWN"

echo
if [ "$ECHECS" -eq 0 ]; then echo "TOUS LES CAS PASSENT"; else echo "$ECHECS ECHEC(S)"; fi
exit "$ECHECS"
