# Build 321 — réservation précoce de l'espace JIT RPCS3

## Pourquoi la fermeture Dusklight ne suffisait pas

La Build 320 arrête les workers, callbacks, audio et graphiques, puis rend bien
MEM1 et ARAM/MEM2 au noyau avec `munmap()`. Cela ne remet toutefois pas
l'espace d'adressage du processus dans son état de démarrage. Le chargement de
Dusklight, de ses dépendances, de Metal et des allocateurs peut laisser de
petites régions passives réparties dans la fenêtre basse de 4 à 64 Gio.

RPCS3 est le seul moteur qui exige ensuite deux très grandes régions JIT dans
cette fenêtre, à moins de 4 Gio l'une de l'autre. Une image Dusklight peut donc
être entièrement inactive tout en ayant déjà fragmenté la seule disposition
virtuelle acceptée par RPCS3. Cela explique pourquoi RPCS3 démarre depuis un
lancement neuf de NeoStation, mais échoue après une session Dusklight.

## Correction de la Build 321

Le pont RPCS3 protège désormais son futur espace JIT dès l'enregistrement du
plugin, avant qu'un jeu Dusklight puisse charger son Core :

- une zone virtuelle inaccessible (`VM_PROT_NONE`) est réservée sans toucher
  de pages physiques ;
- la disposition préférée protège 448 Mio de code et 256 Mio de données ;
- les replis 384, 320 puis 256 Mio de code reprennent exactement la politique
  adaptative déjà utilisée par le Core RPCS3 ;
- une disposition scindée reste possible uniquement si les deux régions sont
  à moins de 4 Gio ;
- Dusklight et son arrêt s'exécutent pendant que cette zone demeure protégée ;
- le framework RPCS3 est chargé passivement alors que la protection est encore
  active ;
- la propriété et la protection de chaque page sont vérifiées, puis la zone est
  rendue au noyau immédiatement avant l'unique appel à
  `rpcs3_ios_initialize()` ;
- aucune journalisation, allocation hôte ou seconde voie de démarrage ne se
  place entre la restitution et l'initialisation du Core ;
- si la réservation ou son transfert n'est pas démontrable, le lancement
  échoue fermement avec `RPCS3_EARLY_VA_HANDOFF_FAILED` au lieu d'entrer dans
  RPCS3 avec un espace déjà fragmenté.

Cette correction ne réintroduit pas la réservation fixe de la Build 302 et ne
modifie pas l'ABI du Core. RPCS3 continue de posséder et d'allouer lui-même ses
arènes ; NeoStation ne fait que conserver à l'avance un trou compatible, puis
le lui restituer.

## Validation automatisée

Les tests couvrent :

- la réservation préférée de 704 Mio dans le trou mesuré sur appareil ;
- l'impossibilité pour un autre runtime d'occuper cette zone ;
- la restitution exacte au Core ;
- les trois capacités de repli ;
- la disposition scindée et la contrainte de portée ;
- l'annulation complète après un échec de la seconde réservation ;
- l'arrêt ferme après un échec de restitution ;
- l'ordre obligatoire : réservation au démarrage, `dlopen` passif, transfert,
  puis unique initialisation RPCS3.

## Validation iPhone attendue

Sans fermer NeoStation : démarrer l'application, lancer un jeu Dusklight,
quitter vers le menu, puis lancer immédiatement un jeu PS3. Cette séquence doit
désormais utiliser le trou protégé avant Dusklight, indépendamment des mappings
passifs que sa fermeture peut laisser dans le processus.
