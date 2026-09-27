# RPCS3 / God of War III — candidat expérimental Build 351

Build 351 conserve intégralement la baseline stable Build 350 et remplace
uniquement le cœur RPCS3 ainsi que le profil God of War III. Ce candidat ne
constitue pas une release.

## Diagnostic retenu

La capture `BCES00510` ne montrait ni pression mémoire critique, ni compilation
de shaders, ni compilation JIT soutenue pendant les passages lents. En revanche,
les fenêtres à environ 20–24 FPS cumulaient 95–112 ms de travail SPU par image,
et le thread RSX attendait des labels produits par le CELL pendant environ
4,85–4,95 secondes sur chaque fenêtre de cinq secondes.

Le réglage de planification des compilations SPU n'est donc pas activé : il
n'aurait aucun effet sur ces fenêtres où le compteur de compilation est nul.

## Changements moteur

- Les deux correctifs MLAA officiels de God of War III sont intégrés au moteur.
  Le correctif PPU empêche la planification du post-traitement et le correctif
  SPU sert de garde complémentaire. Leur activation exige simultanément un
  identifiant de jeu God of War III reconnu et l'empreinte exacte du module :
  `PPU-19724fde…` pour la version 1.03, `SPU-530c2559…` pour la version 1.00 ou
  `SPU-2239af48…` pour la version 1.03. Aucun autre binaire n'est modifié.
- Le recompiler LLVM supprime désormais les helpers d'état et de dispatch SPU
  devenus inatteignables après optimisation, selon l'amélioration RPCS3 amont
  `e826098`.
- Le chemin PUTLLC amont `083859b` évite le verrou d'écriture lourd lorsqu'une
  réservation non précise modifie une seule voie de 16 octets. Les réservations
  précises restent activées dans le profil God of War III pour préserver la
  stabilité ; ce chemin n'est donc utilisé qu'après un choix manuel explicite.
- La récupération bornée des attentes de sémaphore RSX du commit précédent est
  conservée : elle ne fabrique jamais de label invité et empêche une attente
  perdue de bloquer le FIFO indéfiniment.

Le contournement MLAA réduit légèrement l'anticrénelage natif du jeu, mais évite
un post-traitement CELL coûteux et permet d'utiliser proprement la mise à
l'échelle de résolution. La différence réelle de FPS doit être mesurée sur
l'iPhone cible ; elle ne peut pas être déduite du build seul.

## Test appareil demandé

Comparer Build 350 et Build 351 sur la même sauvegarde, avec la même résolution :

1. une cinématique complète ;
2. le premier combat pendant au moins deux minutes ;
3. cinq cycles quitter puis relancer RPCS3 ;
4. FPS moyen, 1 % bas, temps PPU/SPU, attente de sémaphore RSX, mémoire et état
   thermique dans les logs.

