# Build 424 : bibliothèque RetroArch retrouvée sans action et rapport lisible

Branche `Claude`, à partir de la Build 423 (`0bf904a`). Après installation de
la 423, le mainteneur signale le même problème : aucune bibliothèque
RetroArch. Aucun journal récent de l'iPhone n'est disponible ; ce document
distingue ce qui est démontré par le code de ce qui reste à mesurer.

## Ce qui ne dépend pas de l'appareil

- Le scanner, la base et l'affichage sont identiques de la Build 412 à 423.
- Les dossiers ROM sont des chemins absolus. Quand le conteneur de RetroArch
  change (mise à jour, réinstallation), son signet suit le dossier mais la
  racine enregistrée ne le suit pas ; le scan supprime alors les jeux de cette
  racine.
- La 423 retire la limite de cinq dossiers, mais il faut encore relier le
  dossier à la main. Un scan déjà en cours (démarrage ou synchronisation) fait
  ignorer le scan demandé par la liaison : le nouveau dossier n'est scanné
  qu'au lancement suivant.
- `ConfigService.loadAvailableSystems()` lit `assets/system-data/systems.json`,
  absent du dépôt. Le scanner et la liaison utilisent la base ; les nouveaux
  appels utilisent donc `SqliteConfigService.loadAvailableSystems()`.

## Changements

- Démarrage (`main.dart`, blocs `RETROARCH_RELINK_*`) : après résolution du
  signet RetroArch et avant la lecture de la configuration, la racine résolue
  est enregistrée si elle est lisible et absente. Seule une copie inaccessible
  du même dossier relatif à un conteneur iOS est remplacée.
- Liaison : attente de la fin d'un scan en cours, puis même règle
  d'enregistrement, puis scan.
- Rapport `Fichiers › NeoStation iOS › Diagnostics › retroarch_library_report.txt`,
  réécrit au démarrage et après chaque scan : signet, racine résolue, dossiers
  ROM avec leurs sous-dossiers de systèmes, nombre de jeux par système et
  systèmes masqués. Il ne modifie rien.
- Aucune ligne de jeu n'est réécrite ou migrée. MeloNX, ARMSX2, Dolphin,
  RPCS3, NeoSwap, le JIT et le scanner restent inchangés ; le garde de
  référence 419 retire uniquement les trois blocs marqués de `main.dart`.

## Lancement à froid : mesure du double envoi

Run `37927541605` (commit `f2ddcbc`), deux applications de test sur iOS
Simulator 18.5 (Xcode 16.4), récepteur reproduisant `RetroArchSceneDelegate`.
L'émetteur demande `retroarch://start` puis le lien du jeu dans le même tour
de boucle, à l'état actif (`state=0` pour les deux envois) :

| Récepteur | `start` | lien du jeu | URL reçues par la scène |
| --- | --- | --- | --- |
| Scène existante (RetroArch en arrière-plan) | accepté | **refusé** | `start` seul |
| Processus arrêté (froid) | accepté, perdu à la connexion | **refusé** | aucune |

La même acceptation/refus est observée à chaud avec Xcode 26.3 ; la séquence
froide de ce second simulateur ne s'est pas terminée. iOS ne transmet donc
qu'une ouverture par passage au premier plan : un double envoi casserait le
lancement à chaud actuel sans réparer le froid. NeoStation conserve l'envoi
unique ; seul le récepteur RetroArch peut traiter l'URL initiale
(`docs/upstream/retroarch-initial-scene-url.patch`).

## À vérifier sur l'iPhone

1. Installer la 424 et ouvrir NeoStation sans rien relier.
2. Si les jeux RetroArch ne réapparaissent pas, envoyer
   `retroarch_library_report.txt` et `user-data/app.log`.
3. Le lancement à froid de RetroArch dépend de son récepteur
   (`docs/retroarch-relaunch-2026-10-09.md`,
   `docs/upstream/retroarch-initial-scene-url.patch`).
