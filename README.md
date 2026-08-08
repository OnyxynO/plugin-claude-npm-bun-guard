# plugin-claude-npm-bun-guard

Garde-fou qui contrôle les paquets JS **avant** installation, dans Claude Code.

## ⚠️ Lisez ceci d'abord

**C'est un modèle, pas un produit maintenu.**

- **Couvre npm et bun uniquement.** Pour `pnpm`/`yarn` : couverture partielle — pas de
  résolution de l'arbre transitif, seuls les paquets nommés explicitement sont contrôlés.
  Voir « Adapter à votre gestionnaire ».
- **Vous en devenez mainteneur.** Les formats de sortie de `npm`/`bun` changent avec
  leurs versions, l'API GitHub des advisories peut évoluer. Quand quelque chose casse,
  ouvrez `hooks/guard.sh` avec Claude Code et adaptez-le : c'est le mode d'emploi prévu.
- **Aucune garantie de couverture.** Cet outil réduit un risque, il ne l'annule pas.

## Le problème

Le 4 août 2026, le compte du mainteneur de `keyv` (127 M téléchargements/semaine) a été
compromis. La version piégée a propagé un voleur d'identifiants à plus de 400 paquets en
une trentaine de minutes, via un script `preinstall` exécuté avant tout code applicatif —
jetons GitHub et npm, identifiants cloud, secrets de CI, et détournement des hooks de
Claude Code.

Le vecteur d'entrée était une dépendance **transitive** : personne ne tape `npm i keyv`.

`npm audit` regarde après coup. Dependabot regarde le dépôt, pas la commande. Ce plugin
intercepte l'instant où le script `preinstall` va s'exécuter.

## Ce qu'il fait

| Situation | Décision |
|---|---|
| Un paquet de l'arbre à installer est un malware connu (nom **et** version) | Refus |
| Une version demandée a moins de 3 jours | Demande de confirmation |
| Le reste | Silence — quelques millisecondes hors gestionnaire de paquets (`ls`, `npm run build`…) ; de l'ordre de 300 ms pour une installation, le temps du `--dry-run` et du contrôle de quarantaine ; quelques secondes une fois par jour, lorsque la base est rafraîchie |

L'arbre est résolu par `--dry-run`, qui calcule les dépendances **sans exécuter aucun
script** et sans rien écrire sur le disque.

## Installation

    /plugin marketplace add OnyxynO/plugin-claude-npm-bun-guard
    /plugin install plugin-claude-npm-bun-guard@plugin-claude-npm-bun-guard

Aucune configuration requise. `gh` n'est pas nécessaire — la base est téléchargée depuis
ce dépôt. S'il est présent et authentifié, elle est complétée de façon incrémentale.

## Réglages

| Variable | Défaut | Effet |
|---|---|---|
| `NPM_GUARD_COOLDOWN_DAYS` | `3` | Délai de quarantaine ; `0` le désactive |
| `NPM_GUARD_DISABLE` | — | Toute valeur non vide désactive entièrement le hook |
| `NPM_GUARD_DB_URL` | ce dépôt | Pointer votre propre base |

## Adapter à votre gestionnaire

Le point d'extension est unique : le `case "$GESTIONNAIRE"` de `hooks/guard.sh`. Chaque
gestionnaire y fournit sa commande de résolution et son parsing. Deux différences piègent :

| | npm | bun |
|---|---|---|
| Flux de sortie | stdout | stdout **et** stderr (`2>&1`) |
| Format | `add <nom> <version>` | ` <nom>@<version>` |
| Séparateur | espaces | **dernier** `@` (celui de tête appartient au scope) |

Ajouter `pnpm` revient à ajouter une branche à ce `case`. Lancez ensuite
`bash tests/test-guard.sh`.

## La base de données

`data/npm-malware.tsv` est régénérée quotidiennement par GitHub Actions depuis la base
d'advisories GitHub. **C'est une commodité d'amorçage, pas un service garanti** : pour
maîtriser votre chaîne, forkez ce dépôt et activez l'Action chez vous, ou pointez
`NPM_GUARD_DB_URL` vers votre propre base.

Le hook affiche la date de sa base à chaque décision, et avertit au-delà de 7 jours.

## Limites connues

- Un paquet compromis dont l'advisory n'existe pas encore n'est pas détecté par le
  contrôle malware — c'est le rôle de la quarantaine de 3 jours, qui ne couvre pas une
  version piégée publiée il y a plus longtemps sans avoir été détectée.
- `pnpm` et `yarn` : pas de résolution d'arbre.
- Si le téléchargement de `data/npm-malware.tsv` échoue et que seul `gh` est disponible,
  l'amorçage ne couvre que les **7 derniers jours** (de l'ordre de 4 000 entrées contre
  11 000), et les jours suivants avancent par incréments sans jamais remonter cet
  historique. Le repli protège donc moins que le chemin nominal.
- Réseau coupé, `jq` ou `python3` absents : le hook laisse passer. Un garde-fou qui casse
  le travail hors ligne finit désactivé.

## Tests

    bash tests/test-guard.sh

⚠️ Lancez-la ainsi, sans coller les commandes dans un terminal où le plugin est actif : il
intercepterait la commande de test elle-même.

La batterie comprend des **mutations** — on déclare une version saine malveillante et on
vérifie que l'installation qui la tire en transitif est bien refusée. Huit défauts ont été
trouvés à l'écriture de ce hook, tous silencieux : les tests « la commande passe » restaient
verts pour chacun, parce qu'un garde-fou qui ne fait *rien* les passe aussi.

Le huitième n'a été trouvé ni par les tests ni par la relecture, mais au premier run réel :
à cache vide, la base n'était jamais écrite alors que la date du jour l'était — le hook
annonçait donc « base à jour » avec zéro entrée. Aucun des dix-sept cas de la batterie ne
partait d'un cache vide.

## Licence

MIT.
