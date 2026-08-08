#!/usr/bin/env bash
# guard.sh — hook PreToolUse (Bash)
#
# Contrôle les paquets JS AVANT installation, là où le mal se fait : un hook
# `preinstall` s'exécute avant tout code applicatif.
#
# Trois contrôles :
#   1. mise à jour incrémentale de la base des paquets npm malveillants (GitHub)
#   2. résolution de l'ARBRE COMPLET à installer (transitives incluses) → refus
#   3. cooldown de 3 jours sur les versions fraîches des paquets nommés
#
# Pourquoi l'arbre complet : le worm du 2026-08-04 est entré par `keyv`, une
# dépendance TRANSITIVE. Personne ne tape `npm i keyv` — mais `npm i eslint` la
# tire (vérifié : `npm i eslint --dry-run` fait apparaître `keyv 4.5.4`).
# Ne contrôler que les paquets nommés laisserait passer le vecteur réel.
#
# Principe de conception : ne JAMAIS bloquer sur une incertitude technique
# (réseau coupé, jq/python3 absent, gh non authentifié) — un garde-fou qui casse
# le travail hors ligne finit désactivé. On échoue en laissant passer ; seul un
# paquet prouvé malveillant (nom ET version dans la plage) bloque.

set -uo pipefail

# ⚠️ `-f` (noglob) est indispensable, pas une précaution de style. Ce script
# découpe une commande utilisateur avec des expansions volontairement NON
# quotées (`set -- $commande`, puis les paquets passés à `--dry-run`) : le
# découpage en mots est voulu, l'expansion des jokers ne l'est pas. Sans lui,
# `npm i key*` lancé dans un dépôt contenant un fichier `keyv` devient
# `npm i keyv` — le hook accuse alors un paquet que personne n'a demandé.
# Aucune expansion de chemin n'est nécessaire ailleurs dans ce fichier.
set -f

# Désactivation complète — première chose lue, pour qu'un utilisateur bloqué
# puisse toujours reprendre la main sans désinstaller le plugin.
[ -n "${NPM_GUARD_DISABLE:-}" ] && exit 0

COOLDOWN_JOURS="${NPM_GUARD_COOLDOWN_DAYS:-3}"
TIMEOUT_RESEAU=8
FENETRE_AMORCAGE=7          # jours, si aucun cache local n'existe encore
PEREMPTION_CACHE=30         # jours, au-delà on repart d'un amorçage

CACHE_DIR="${NPM_GUARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/npm-bun-guard}"
CACHE_MALWARE="${NPM_GUARD_CACHE:-$CACHE_DIR/npm-malware.tsv}"
CACHE_STAMP="$CACHE_DIR/npm-malware.stamp"

# --- sorties normalisées -----------------------------------------------------

refuser() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

demander() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0

# ⚠️ macOS ne fournit PAS `timeout` (binaire GNU coreutils) : un
# `timeout … gh api` y échoue en « command not found », la sortie est vide, et
# le garde-fou laisse tout passer en silence. Repli explicite.
if command -v timeout >/dev/null 2>&1; then OUTIL_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then OUTIL_TIMEOUT=gtimeout
else OUTIL_TIMEOUT=""; fi

borner() {
  if [ -n "$OUTIL_TIMEOUT" ]; then "$OUTIL_TIMEOUT" "$1" "${@:2}"; else "${@:2}"; fi
}

charge=$(cat)
commande=$(printf '%s' "$charge" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$commande" ] || exit 0
repertoire=$(printf '%s' "$charge" | jq -r '.cwd // empty' 2>/dev/null)
[ -d "${repertoire:-}" ] || repertoire="$PWD"

# --- 1. la commande installe-t-elle quelque chose ? --------------------------

GESTIONNAIRE=""
SOUS=""
FICHIER_PAQUETS=$(mktemp) || exit 0

# ⚠️ NE JAMAIS appeler cette fonction via `$( … )` : une substitution de commande
# s'exécute dans un SOUS-SHELL, où les affectations de GESTIONNAIRE et SOUS sont
# perdues. La condition `[ "$GESTIONNAIRE" = npm ]` devenait alors toujours
# fausse et la résolution d'arbre — le cœur du contrôle — ne tournait jamais,
# sans le moindre message. Les paquets transitent donc par un fichier.
analyser_commande() {
  # shellcheck disable=SC2086
  set -- $commande
  while [ $# -gt 0 ]; do
    case "$1" in
      npm|pnpm|yarn|bun) GESTIONNAIRE="$1"; shift; break ;;
      npx|bunx) GESTIONNAIRE="npx"; shift; break ;;
      *) shift ;;
    esac
  done
  [ -n "$GESTIONNAIRE" ] || return 1

  if [ "$GESTIONNAIRE" != "npx" ]; then
    [ $# -gt 0 ] || return 1
    SOUS="$1"; shift
    case "$SOUS" in
      install|i|ci|add|update|up|dlx) ;;
      *) return 1 ;;
    esac
  fi

  # ⚠️ S'ARRÊTER au premier séparateur de commande. Sans cela, tous les tokens de
  # la ligne sont pris pour des paquets : `npm i foo && printf 'keyv…'` faisait
  # lire `keyv` comme un paquet à installer — faux positif garanti sur toute
  # commande chaînée mentionnant un nom de paquet.
  for arg in "$@"; do
    case "$arg" in
      '&&'|'||'|';'|'|'|'>'|'>>'|'&') break ;;
      -*) continue ;;
      .|./*|/*|../*|file:*|link:*) continue ;;
      git+*|http://*|https://*) continue ;;
      *) printf '%s\n' "$arg" >> "$FICHIER_PAQUETS" ;;
    esac
  done
  return 0
}

analyser_commande || exit 0
paquets_nommes=$(cat "$FICHIER_PAQUETS" 2>/dev/null)

# --- 2. mise à jour incrémentale de la base malveillante ---------------------
# C'est le point qui rend le contrôle utile : un paquet compromis ce matin doit
# être connu cet après-midi. On ne retélécharge jamais tout — seulement ce qui a
# été publié depuis le dernier passage (~600 entrées/jour, ~2 s).

mkdir -p "$CACHE_DIR" 2>/dev/null

jours_depuis() {
  local d="$1" ts
  ts=$(date -u -d "$d" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null) || { echo 9999; return; }
  echo $(( ( $(date -u +%s) - ts ) / 86400 ))
}

rafraichir_base() {
  local URL_BASE="${NPM_GUARD_DB_URL:-https://raw.githubusercontent.com/OnyxynO/plugin-claude-npm-bun-guard/main/data/npm-malware.tsv}"

  # Fraîcheur AVANT le test `command -v gh` : c'est justement le chemin sans
  # `gh` — le public principal du plugin — qui, sinon, ne rafraîchit plus
  # jamais rien après le tout premier amorçage. Base absente OU stamp pas
  # d'aujourd'hui (le dépôt régénère data/npm-malware.tsv quotidiennement,
  # cron 5 h UTC : s'aligner sur ce rythme) → on rejoue l'amorçage complet
  # sans authentification, un seul fichier, pas de rate limit.
  local age_stamp=9999
  [ -s "$CACHE_STAMP" ] && age_stamp=$(jours_depuis "$(cat "$CACHE_STAMP")")

  # Drapeau LOCAL À CE RUN — ne survit pas d'une commande à l'autre. Il
  # distingue les deux situations qui produisent toutes deux `age == 0` plus
  # bas : le curl vient de réussir À L'INSTANT (le stamp sort d'être écrit),
  # contre le stamp déjà à aujourd'hui depuis un run précédent. Sans cette
  # distinction, le garde-fou anti-répétition de `gh` (L. ~180) ne peut pas
  # savoir laquelle des deux il regarde.
  local curl_vient_de_reussir=false
  if [ ! -s "$CACHE_MALWARE" ] || [ "$age_stamp" -gt 0 ]; then
    local tmp2; tmp2=$(mktemp) || return 0
    if curl -sf --compressed --max-time 20 "$URL_BASE" -o "$tmp2" 2>/dev/null \
       && [ "$(wc -l < "$tmp2" | tr -d ' ')" -gt 100 ] \
       && mv "$tmp2" "$CACHE_MALWARE"; then
      date -u +%Y-%m-%d > "$CACHE_STAMP"
      curl_vient_de_reussir=true
    fi
    rm -f "$tmp2" 2>/dev/null
  fi

  # L'incrémental `gh` COMPLÈTE le curl, il ne le remplace pas : quand le
  # curl vient de réussir DANS CE RUN, `gh` enchaîne pour couvrir les
  # advisories du jour même (le curl amène jusqu'à ~24 h de retard — le dépôt
  # ne régénère `data/npm-malware.tsv` qu'à 5 h UTC — `gh` donne le temps
  # réel). Sans `gh`, l'amorçage ci-dessus reste le seul mécanisme, ce qui
  # suffit à ne jamais rester figé plus d'un jour.
  command -v gh >/dev/null 2>&1 || return 0

  local depuis age
  if [ -s "$CACHE_MALWARE" ] && [ -s "$CACHE_STAMP" ]; then
    age=$(jours_depuis "$(cat "$CACHE_STAMP")")
    if [ "$age" -gt "$PEREMPTION_CACHE" ]; then
      depuis=$(date -u -v-${FENETRE_AMORCAGE}d +%Y-%m-%d 2>/dev/null || date -u -d "-${FENETRE_AMORCAGE} days" +%Y-%m-%d)
      : > "$CACHE_MALWARE"
    else
      depuis=$(cat "$CACHE_STAMP")
      # Déjà à jour aujourd'hui ET pas de curl dans CE run → rien à faire.
      # C'est le garde-fou qui empêche `gh api` de repartir à chaque commande
      # interceptée dans la journée (régression de latence majeure sinon).
      # Si le curl vient de réussir, on laisse passer : `depuis` vaut déjà la
      # date du jour, donc l'appel `gh` ci-dessous ne ramène que les
      # advisories publiées aujourd'hui — quelques entrées, pas 4000.
      [ "$age" -le 0 ] && [ "$curl_vient_de_reussir" != true ] && return 0
    fi
  else
    # Amorçage borné : une fenêtre courte pour rester sous le timeout du hook.
    # L'historique complet se reconstitue au fil des jours par incréments.
    depuis=$(date -u -v-${FENETRE_AMORCAGE}d +%Y-%m-%d 2>/dev/null || date -u -d "-${FENETRE_AMORCAGE} days" +%Y-%m-%d)
  fi

  local tmp; tmp=$(mktemp) || return 0
  # ⚠️ `page=N` est IGNORÉ par /advisories (pagination par curseur) : une boucle
  # `for page in 1 2` relit la même page et plafonne à 100 entrées sur 11 000.
  # `--paginate` est obligatoire ici.
  if GH_PAGER=cat borner 25 gh api --paginate \
      "/advisories?ecosystem=npm&type=malware&per_page=100&published=>=$depuis" \
      -q '.[]?|.vulnerabilities[]?|"\(.package.name)\t\(.vulnerable_version_range // "*")"' \
      >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    # ⚠️ `cat "$CACHE_MALWARE" "$tmp"` échoue (exit 1) si $CACHE_MALWARE n'existe
    # pas encore (tout premier run). Avec `set -o pipefail`, ce 1 se propage au
    # pipeline même si `sort` a réussi — le `&&` court-circuite alors le `mv` et
    # la base n'est JAMAIS écrite, en silence. Le groupement `{ …; }` isole le
    # `cat` de la base (qui peut légitimement échouer si le fichier est absent)
    # du `cat` du delta téléchargé (qui doit, lui, réussir) : seule l'absence de
    # $tmp doit faire échouer la fusion.
    if { cat "$CACHE_MALWARE" 2>/dev/null; cat "$tmp"; } | sort -u > "$tmp.fusion" \
        && mv "$tmp.fusion" "$CACHE_MALWARE"; then
      date -u +%Y-%m-%d > "$CACHE_STAMP"
    fi
  fi
  rm -f "$tmp" "$tmp.fusion" 2>/dev/null
}

rafraichir_base

# Une base périmée en silence donne une fausse assurance — pire que pas d'outil.
# Toute décision porte donc la date de la base, et signale l'ancienneté au-delà
# d'une semaine.
mention_fraicheur() {
  local d age
  d=$(cat "$CACHE_STAMP" 2>/dev/null)
  [ -n "$d" ] || { printf 'Base : date inconnue.'; return; }
  age=$(jours_depuis "$d")
  if [ "$age" -gt 7 ]; then
    printf '⚠️ Base vieille de %s jours (%s) — le rafraîchissement ne fonctionne plus.' "$age" "$d"
  else
    printf 'Base : %s entrées, mise à jour le %s.' "$(cat "$CACHE_MALWARE" 2>/dev/null | wc -l | tr -d ' ')" "$d"
  fi
}

# --- 3. résoudre l'arbre réellement installé ---------------------------------
# `--dry-run` résout les dépendances SANS exécuter le moindre script : c'est le
# seul moyen sûr de voir les transitives avant qu'elles ne touchent le disque.

arbre=$(mktemp) || exit 0
nettoyer() { rm -f "$arbre" "$arbre.res" "$FICHIER_PAQUETS" 2>/dev/null; }
trap nettoyer EXIT

case "$GESTIONNAIRE" in
  npm)
    if command -v npm >/dev/null 2>&1; then
      # npm liste « add <nom> <version> », un par ligne, sur stdout.
      # shellcheck disable=SC2086
      ( cd "$repertoire" 2>/dev/null && borner 25 npm $SOUS $(printf '%s ' $paquets_nommes) --dry-run 2>/dev/null ) \
        | awk '/^add /{print $2"\t"$3}' > "$arbre"
    fi
    ;;
  bun)
    # bun n'est pas toujours dans le PATH hérité par le hook → repli explicite.
    exe_bun=$(command -v bun 2>/dev/null)
    [ -n "$exe_bun" ] || exe_bun="$HOME/.bun/bin/bun"
    if [ -x "$exe_bun" ]; then
      # ⚠️ Deux différences avec npm : bun écrit l'arbre sur stderr autant que
      # stdout (`2>&1` obligatoire), et son format est « <nom>@<version> »
      # précédé d'une espace — donc le séparateur est le DERNIER `@`, celui de
      # tête appartenant au scope (`@eslint/core@0.17.0`).
      # shellcheck disable=SC2086
      ( cd "$repertoire" 2>/dev/null && NO_COLOR=1 borner 25 "$exe_bun" $SOUS $(printf '%s ' $paquets_nommes) --dry-run 2>&1 ) \
        | awk 'sub(/^ +/,"") && /@/ {
                 i = match($0, /@[^@]*$/)
                 if (i > 1) printf "%s\t%s\n", substr($0, 1, i-1), substr($0, i+1)
               }' > "$arbre"
    fi
    ;;
esac

# Repli (autre gestionnaire, npm absent, dry-run muet) : au moins les paquets
# nommés, dont la version reste inconnue à ce stade.
if [ ! -s "$arbre" ]; then
  for spec in $paquets_nommes; do
    if [ "${spec:0:1}" = "@" ]; then
      reste="${spec:1}"; nom="@${reste%%@*}"
      case "$reste" in *@*) ver="${reste#*@}" ;; *) ver="" ;; esac
    else
      nom="${spec%%@*}"
      case "$spec" in *@*) ver="${spec#*@}" ;; *) ver="" ;; esac
    fi
    [ -n "$nom" ] && printf '%s\t%s\n' "$nom" "$ver" >> "$arbre"
  done
fi

[ -s "$arbre" ] || exit 0

# --- 4. croisement nom + version contre les plages ---------------------------
# Le nom seul ne suffit pas : `keyv`, `flat-cache` et `file-entry-cache` sont
# présents dans le parc en versions saines alors que leurs homonymes piégés
# (6.0.0, 6.1.24, 11.1.6) figurent dans la base. Matcher sur le nom donnerait
# trois faux positifs permanents.

if [ -s "$CACHE_MALWARE" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$CACHE_MALWARE" "$arbre" > "$arbre.res" 2>/dev/null <<'PY'
import sys

def tuple_version(v):
    base = v.split("-")[0].split("+")[0]
    out = []
    for part in base.split(".")[:3]:
        try: out.append(int(part))
        except ValueError: out.append(0)
    while len(out) < 3: out.append(0)
    return tuple(out)

def satisfait(version, plage):
    plage = plage.strip()
    if plage in ("*", ""): return True
    for cond in plage.split(","):
        cond = cond.strip()
        if not cond: continue
        for op in (">=", "<=", "=", ">", "<"):
            if cond.startswith(op):
                cible = cond[len(op):].strip()
                if op == "=":
                    if version != cible and tuple_version(version) != tuple_version(cible): return False
                elif op == ">=":
                    if not tuple_version(version) >= tuple_version(cible): return False
                elif op == "<=":
                    if not tuple_version(version) <= tuple_version(cible): return False
                elif op == ">":
                    if not tuple_version(version) > tuple_version(cible): return False
                elif op == "<":
                    if not tuple_version(version) < tuple_version(cible): return False
                break
        else:
            return False
    return True

base = {}
with open(sys.argv[1]) as f:
    for ligne in f:
        nom, _, plage = ligne.rstrip("\n").partition("\t")
        if nom: base.setdefault(nom, []).append(plage)

with open(sys.argv[2]) as f:
    for ligne in f:
        nom, _, version = ligne.rstrip("\n").partition("\t")
        if nom not in base: continue
        for plage in base[nom]:
            if version and satisfait(version, plage):
                print(f"CERTAIN\t{nom}\t{version}\t{plage}")
                break
        else:
            # Version inconnue (repli sans résolution d'arbre) : on ne peut PAS
            # conclure — `keyv` est légitime en 4.5.4 et piégé en 6.0.0. Refuser
            # ici produirait un faux positif sur un paquet parfaitement sain.
            if not version:
                print(f"DOUTE\t{nom}\t?\t{'; '.join(base[nom][:3])}")
PY

  # ⚠️ Pas de `|| echo 0` ici : `grep -c` affiche DÉJÀ « 0 » quand il ne trouve
  # rien (tout en sortant en 1). Le repli ajoutait un second « 0 », donnant la
  # chaîne « 0\n0 » — `[ … -gt 0 ]` échouait alors en erreur de syntaxe et la
  # détection était purement et simplement sautée.
  certains=$(grep -c '^CERTAIN' "$arbre.res" 2>/dev/null)
  doutes=$(grep -c '^DOUTE' "$arbre.res" 2>/dev/null)

  if [ "${certains:-0}" -eq 0 ] && [ "${doutes:-0}" -gt 0 ]; then
    detail=$(grep '^DOUTE' "$arbre.res" | head -5 | awk -F'\t' '{printf "  • %s (versions piégées connues : %s)\n", $2, $4}')
    demander "⚠️  Impossible de vérifier la version de $doutes paquet(s) dont le NOM figure dans la base des malwares npm.

$detail
La résolution de l'arbre n'a pas abouti (gestionnaire autre que npm, ou projet
sans manifeste), donc la version installée reste inconnue. Or le nom seul ne
prouve rien : \`keyv\` est parfaitement sain en 4.5.4 et piégé en 6.0.0.

À vérifier avant de confirmer : quelle version sera réellement installée.

$(mention_fraicheur)"
  fi

  if [ "${certains:-0}" -gt 0 ]; then
    detail=$(grep '^CERTAIN' "$arbre.res" | head -5 | awk -F'\t' '{printf "  • %s@%s  (plage piégée : %s)\n", $2, $3, $4}')
    total=$certains
    refuser "⛔ PAQUET MALVEILLANT dans ce qui allait être installé ($total correspondance(s)).

$detail
Ces paquets figurent dans la base des malwares npm de GitHub, à la version que
la résolution de dépendances a retenue. Ce n'est pas une vulnérabilité à corriger
par une montée de version : le code est piégé, et son script preinstall
s'exécuterait avant tout le reste (vol de jetons GitHub/npm, clés cloud,
secrets CI, détournement des hooks Claude Code).

⚠️ La détection porte sur l'ARBRE COMPLET : le paquet en cause peut être une
dépendance transitive que tu n'as jamais demandée — c'est le mode opératoire du
worm keyv du 2026-08-04.

À faire : identifier qui tire ce paquet (\`npm why <paquet>\`), puis épingler une
version saine via \`overrides\` (bornée à la lignée, jamais en \`>=\`).

$(mention_fraicheur)"
  fi
fi

# --- 5. cooldown sur les paquets explicitement demandés ----------------------

for spec in $paquets_nommes; do
  if [ "${spec:0:1}" = "@" ]; then
    reste="${spec:1}"; nom="@${reste%%@*}"
    case "$reste" in *@*) version="${reste#*@}" ;; *) version="" ;; esac
  else
    nom="${spec%%@*}"
    case "$spec" in *@*) version="${spec#*@}" ;; *) version="" ;; esac
  fi
  [ -n "$nom" ] || continue

  # Source de la date, après deux impasses mesurées : le packument complet pèse
  # 38 Mo pour `vite` (transfert tronqué → jq échoue → contrôle mort sur les gros
  # paquets), et le `.modified` de l'abrégé date n'importe quelle version (react
  # publie des canary quotidiens → fausse alerte à chaque install). L'API search
  # renvoie le couple exact (latest, date de publication de latest).
  nom_enc=$(printf '%s' "$nom" | sed 's|/|%2F|g; s|@|%40|g')
  meta=$(curl -sf --compressed --max-time "$TIMEOUT_RESEAU" \
    "https://registry.npmjs.org/-/v1/search?text=$nom_enc&size=20" 2>/dev/null) || continue
  [ -n "$meta" ] || continue

  ligne=$(printf '%s' "$meta" | jq -r --arg n "$nom" \
    '.objects[]? | select(.package.name == $n) | "\(.package.version)\t\(.package.date)"' 2>/dev/null | head -1)
  [ -n "$ligne" ] || continue

  latest=${ligne%%$'\t'*}
  publie=${ligne#*$'\t'}
  [ -n "$latest" ] && [ -n "$publie" ] || continue
  [ -n "$version" ] && [ "$version" != "$latest" ] && continue
  version="$latest"

  ts_publie=$(date -u -d "$publie" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${publie%.*}" +%s 2>/dev/null) || continue
  age=$(( ( $(date -u +%s) - ts_publie ) / 86400 ))

  if [ "$COOLDOWN_JOURS" -gt 0 ] 2>/dev/null && [ "$age" -lt "$COOLDOWN_JOURS" ]; then
    demander "⚠️  « $nom@$version » a été publiée il y a ${age} jour(s) — moins que le délai de sécurité de ${COOLDOWN_JOURS} jours.

Une version très fraîche est le seul signal disponible AVANT qu'une compromission
ne soit détectée et qu'un advisory n'existe. Le 2026-08-04, keyv@6.0.0 a contaminé
400+ paquets en 30 minutes depuis un compte de mainteneur compromis.

Rien n'indique un problème ici — c'est un délai, pas une accusation. Options :
  • attendre $(( COOLDOWN_JOURS - age )) jour(s) de plus ;
  • installer une version antérieure déjà éprouvée ;
  • confirmer si cette version est réellement nécessaire maintenant.

Publiée le : $publie
$(mention_fraicheur)"
  fi
done

exit 0
