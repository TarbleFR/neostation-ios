# RPCS3 / God of War III — mémoire bornée Build 352

Build 352 prolonge le candidat expérimental Build 351 sans modifier la baseline
stable Build 350, ni les cœurs Mario Kart Pad, Dusklight, Dolphin ou ARMSX2.

## Diagnostic mesuré

La session `BCES00510` de 7 min 42 s monte d'environ 1,62 Gio à 5,14 Gio.
La même fenêtre totalise 10 241 allocations Vulkan contre 6 739 libérations et
17,6 Gio d'allocations cumulées. Le nettoyage ne démarre qu'avec environ
1,5 Gio de marge iOS, quand le processus a déjà dépassé 5 Gio. La chute finale
à 2–7 FPS coïncide avec les réallocations et les attentes SPU/range-lock, et
non avec une compilation continue de shaders ou de PPU.

## Apports retenus de PS3Native

La base RPCS3 épinglée contient déjà les changements PS3Native pertinents :

- limitation de la hauteur des blits vers la mémoire CELL pour éviter des
  plages surdimensionnées ;
- fusion et vidage partiel de la file `mprotect`, au lieu de vider toute la
  file à chaque conflit ;
- stationnement des boucles RSX et budget mémoire de compilation PPU.

La génération d'images DIS n'est pas importée. Elle consomme des surfaces GPU
supplémentaires et ne corrige ni les 5 Gio résidents ni les 5–10 FPS réels.

## Politique Build 352

- Le profil n'est actif que pour les six identifiants connus de God of War III.
- La pression modérée commence à 2 560 Mio de marge iOS et se relâche à
  2 816 Mio ; les seuils sévère et fatal restent inchangés.
- À l'entrée en pression, le moteur exécute une seule purge forte des textures
  déverrouillées et des chaînes RTT périmées, puis au maximum une fois toutes
  les huit secondes si la pression persiste.
- Le chemin fatal, son drain GPU complet et le spill de mémoire unifiée ne sont
  jamais utilisés par ce nettoyage anticipé.
- Les nettoyages modérés sont espacés de 1,5 à 3 secondes pour éviter la boucle
  purge/réallocation visible dans les logs Build 350.
- Les diagnostics de pression indiquent désormais séparément les pools
  textures et surfaces.

## Validation attendue sur appareil

Comparer Build 351 et Build 352 sur la même sauvegarde et la même résolution.
Relever le maximum de `memory_mib`, les nouvelles lignes de pression RSX et la
fluidité du premier combat. La cible est de rester nettement sous 5 Gio sans
introduire de purge permanente ni de régression de lancement/retour NeoStation.
