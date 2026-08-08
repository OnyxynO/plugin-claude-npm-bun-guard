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

## À quoi ressemble une décision

Sorties réelles du hook, pas des reconstitutions. Le refus porte sur une entrée
authentique de la base ; la quarantaine, sur une version fraîche du jour.

**Refus** — `npm i @keyv/redis@6.0.0`

```
⛔ PAQUET MALVEILLANT dans ce qui allait être installé (1 correspondance(s)).

  • @keyv/redis@6.0.0  (plage piégée : = 6.0.0)
Ces paquets figurent dans la base des malwares npm de GitHub, à la version que
la résolution de dépendances a retenue. Ce n'est pas une vulnérabilité à corriger
par une montée de version : le code est piégé, et son script preinstall
s'exécuterait avant tout le reste (vol de jetons GitHub/npm, clés cloud,
secrets CI, détournement des hooks Claude Code).

⚠️ La détection porte sur l'ARBRE COMPLET : le paquet en cause peut être une
dépendance transitive que tu n'as jamais demandée — c'est le mode opératoire du
worm keyv du 2026-08-04.

À faire : identifier qui tire ce paquet (`npm why <paquet>`), puis épingler une
version saine via `overrides` (bornée à la lignée, jamais en `>=`).

Base : 11069 entrées, mise à jour le 2026-08-08.
```

**Quarantaine** — `npm i vite`, un 2026-08-08 où `vite@8.2.1` avait deux jours

```
⚠️  « vite@8.2.1 » a été publiée il y a 2 jour(s) — moins que le délai de sécurité de 3 jours.

Une version très fraîche est le seul signal disponible AVANT qu'une compromission
ne soit détectée et qu'un advisory n'existe. Le 2026-08-04, keyv@6.0.0 a contaminé
400+ paquets en 30 minutes depuis un compte de mainteneur compromis.

Rien n'indique un problème ici — c'est un délai, pas une accusation. Options :
  • attendre 1 jour(s) de plus ;
  • installer une version antérieure déjà éprouvée ;
  • confirmer si cette version est réellement nécessaire maintenant.

Publiée le : 2026-08-06T13:47:48.588Z
Base : 11069 entrées, mise à jour le 2026-08-08.
```

Toute autre commande ne produit **aucune sortie** : le hook se tait et laisse passer.

## Installation

    /plugin marketplace add OnyxynO/plugin-claude-npm-bun-guard
    /plugin install plugin-claude-npm-bun-guard@plugin-claude-npm-bun-guard

Aucune configuration requise. `gh` n'est pas nécessaire — la base est téléchargée depuis
ce dépôt, puis **réactualisée une fois par jour** (64 Ko compressés). S'il est présent et
authentifié, il complète ensuite avec les advisories publiées depuis, dans la journée.

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

## Installer sans me faire confiance

Ce dépôt vous demande d'exécuter un script shell avant chacune de vos commandes, et de
télécharger une base de données depuis un compte GitHub individuel — le mien. C'est la
forme de dépendance qui a produit l'incident dont cet outil est né. Prenez la précaution
au sérieux plutôt que de me croire sur parole.

**Ce que le pire cas peut faire**, selon ce qui est compromis :

| Élément compromis | Conséquence maximale |
|---|---|
| La base `data/npm-malware.tsv` | **Faux négatifs** : le hook se tait là où il devrait bloquer, et vous laisse croire que vous êtes couvert. C'est un fichier de données, lu ligne à ligne — jamais exécuté. Aucune exécution de code possible par ce biais. |
| Le script `hooks/guard.sh` | **Exécution de code arbitraire** avant chacune de vos commandes. C'est le risque réel, et il est propre à tout plugin — pas seulement à celui-ci. |

La distinction compte : la seconde ligne est la seule qui justifie de la paranoïa.

**Le mode d'emploi méfiant**, dans l'ordre :

1. **Lisez `hooks/guard.sh`** (458 lignes). Ce que vous devriez y vérifier vous-même :
   aucun `eval` ni exécution dynamique ; trois destinations réseau en tout
   (`raw.githubusercontent.com` pour la base, `registry.npmjs.org` pour les dates de
   publication, l'API GitHub via `gh` si vous l'avez) ; aucune télémétrie, aucun serveur
   m'appartenant.
2. **Forkez, et pointez `NPM_GUARD_DB_URL` sur votre fork.** Activez-y l'Action : vous ne
   dépendez plus de ma disponibilité ni de mon compte pour vos données.
3. **Ou copiez simplement `hooks/guard.sh` dans vos propres hooks**, sans installer ce
   plugin du tout. C'est l'usage prévu — le dépôt est un point de départ, pas un
   abonnement.

Les commits sont signés et vérifiés par GitHub à partir de `c706a39` (2026-08-08). Ceux
d'avant ne le sont pas et le resteront : les resigner imposerait de réécrire l'historique,
ce qui invaliderait tout commit déjà épinglé par quelqu'un. Deux commits de cette même
journée portent une signature que GitHub n'attribue pas — clé remplacée en cours de route,
mentionné ici plutôt que masqué.

Note d'honnêteté sur ce que la signature ne prouve pas : elle atteste que le commit vient
de ma clé, pas que son contenu est sûr. Et un checksum publié dans ce même dépôt ne
prouverait rien contre un compte compromis, l'attaquant mettant les deux à jour d'un même
geste. L'épinglage d'un commit que vous avez lu reste la garantie qui ne dépend pas de moi.

## Limites connues

- Un paquet compromis dont l'advisory n'existe pas encore n'est pas détecté par le
  contrôle malware — c'est le rôle de la quarantaine de 3 jours, qui ne couvre pas une
  version piégée publiée il y a plus longtemps sans avoir été détectée.
- **La quarantaine ne regarde que les paquets que vous nommez**, pas l'arbre résolu — à la
  différence du contrôle malware. Une dépendance transitive fraîchement piégée et pas encore
  déclarée échappe donc aux deux contrôles. C'est le trou que la mise à jour quotidienne de la
  base réduit sans le fermer.
- `pnpm` et `yarn` : pas de résolution d'arbre.
- Si le téléchargement de `data/npm-malware.tsv` échoue et que seul `gh` est disponible,
  l'amorçage ne couvre que les **7 derniers jours** (de l'ordre de 4 000 entrées contre
  11 000), et les jours suivants avancent par incréments sans jamais remonter cet
  historique. Le repli protège donc moins que le chemin nominal.
- Réseau indisponible, `jq` ou `python3` absents : le hook laisse passer. Un garde-fou qui
  casse le travail finit désactivé. En pratique le cas n'est pas « hors ligne » — Claude Code
  ne fonctionne pas sans réseau — mais **réseau filtré** : un proxy d'entreprise qui bloque
  `raw.githubusercontent.com` tout en laissant passer le reste.

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

Le neuvième est venu d'une relecture adversariale du dépôt, en se demandant ce qu'un
évaluateur extérieur refuserait d'installer : le découpage de la commande laissait le shell
étendre les jokers, si bien que `npm i key*` lancé dans un dépôt contenant un fichier `keyv`
accusait un paquet que personne n'avait demandé. Le correctif tient en un `set -f` ; le cas
de test, lui, échoue bien sans lui (vérifié avant de l'écrire).

## Licence

MIT.
