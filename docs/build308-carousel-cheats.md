# Build 308 — carrousel et cheats

## Référence et causes établies

La Build 307 (`879ac44c4e251105bda84ed54e14d3d8e06b4640`) a été validée par
l'utilisateur. Son cœur RPCS3, ses réglages JIT et son chemin de lancement sont
conservés.

- Carrousel : les jaquettes avaient une marge à gauche, mais l'alphabet et le
  pied de page passaient sous la colonne d'actions. Le centrage de la lettre
  sélectionnée utilisait aussi la largeur de l'écran au lieu de celle du défilement.
- ARMSX2 : le menu n'énumérait que les groupes nommés du catalogue de patches.
  Il ignorait le catalogue des cheats et les commandes PNACH sans nom. De plus,
  `setPatchEnableList` enregistrait l'INI sans actualiser sa couche en mémoire ;
  `Patch::ReloadPatches` reprenait donc l'ancienne sélection.
- Dolphin : le menu ne lisait que `GameID.ini`, alors que le moteur charge aussi
  les INI communs et ceux de la révision. L'addition brute des listes Enabled et
  Disabled empêchait une sélection plus précise de remplacer l'état hérité.

La capture ARMSX2 indique un fichier détecté pour `SLES-54182`, CRC `301A1B6E`,
avec trois patches. Elle ne contient ni le PNACH lui-même ni la preuve de leur
activation. Les correctifs traitent les défauts vérifiés dans le code ; ils ne
valident pas le contenu de ce fichier ni l'effet de ses codes dans Scarface.

## Corrections

Le carrousel réserve une marge commune à tous ses éléments. La colonne est
bornée en largeur et conserve sa place pendant le masquage. La lettre active
est centrée sur le défilement réellement disponible.

ARMSX2 affiche les patches et cheats importés, les commandes sans nom et les
comptages actifs fournis par le moteur. Les commandes sans nom gardent leur
traitement automatique natif. Un identifiant typé distingue deux codes de même
nom dans `patches/` et `cheats/`. Les options en mémoire sont rechargées avant
l'application ; sélectionner un cheat active également l'option principale.
Les codes limités au démarrage nécessitent toujours de relancer le jeu.

Dolphin lit le même catalogue dans le menu et au démarrage. La résolution des
états suit la priorité des fichiers du moteur. Les sélections sont enregistrées
dans un INI propre à l'identifiant et à la révision : les définitions héritées
ne sont pas recopiées et les fichiers importés restent intacts. Un catalogue vide
est expliqué dans les douze langues, avec l'identifiant du jeu et les possibilités
de téléchargement/import. Aucun code d'une autre région n'est deviné.

## Sources et validations

Commit des deux nouveaux cœurs : `82351b75114df5fb33387f2157745bccaf1c872d`.

- Test ARMSX2 Foundation : exécute le gestionnaire ObjC++ de production avec un
  moteur contrôlé séparant explicitement les options sur disque et en mémoire.
  Vérifie activation, désactivation, états automatiques, identifiants homonymes,
  commandes sans nom et rejets des états non valides.
- Test Dolphin C++ : utilise les fonctions amont de lecture/sérialisation des
  codes, l'ordre natif des fichiers et les fonctions corrigées de NeoStation avec
  un système de fichiers INI contrôlé. Vérifie héritage, priorité, persistance,
  absence de duplications et conservation des autres révisions et fichiers.
- Tests Flutter : huit configurations taille/échelle, marges iOS, colonne visible,
  masquée et en animation, accès tactile à l'alphabet. Les cinq tests existants de
  routes de lancement passent également. Run `35805854927`.
- Dolphin Core : compilation arm64 et validations réussies, run `35805854922`.
  SHA-256 `50fcea664d458766f56da1154598d32a115c33da8318c039a76a446fee3aa2ca`.
- ARMSX2 Core : compilation et validations réussies, run `35805854967`.
  SHA-256 `cadb6cd56c4b5d01b623bf9696800d48ba504eef8129a8de468c11381de8d162`.
- RPCS3 Core conservé : run `35799603880`, source
  `4e0ae3ccb6f58425fa5f2a0e9780f1f180e77a50`, SHA-256
  `3a1b16e8f8bd4e6751c56ba090081c10a325423d1a5a09c86d9d16736161fe0a`.

La compilation et les tests contrôlés ne remplacent pas une validation sur
iPhone. Le téléchargement depuis le miroir Gecko doit aussi être vérifié sur
le réseau de l'appareil ; les tests ci-dessus utilisent des catalogues contrôlés.

## Test demandé sur iPhone

1. En carrousel, parcourir les lettres et masquer/réafficher la colonne d'actions.
2. Sur Scarface, ouvrir les patches : comparer le CRC, les entrées détectées et les
   nombres actifs. Activer un groupe nommé puis relancer le jeu si son code est
   appliqué seulement au démarrage.
3. Dans Dolphin, télécharger/importer les codes d'un jeu, en activer un, quitter
   et relancer. Confirmer que la sélection et son effet sont conservés.
4. Vérifier un lancement rapide RPCS3 puis l'alternance des émulateurs.

Dusklight n'est pas intégré à cette IPA. L'analyse séparée
`docs/dusklight-ios-embedding-review.md` décrit les changements de cycle de vie
nécessaires pour en faire un moteur Ports intégré.
