# Build 425 : lancer un jeu RetroArch fermé par ses commandes réseau

Branche `Claude`, à partir de la Build 423 (`0bf904a`). Le mainteneur confirme
que la bibliothèque s'affiche ; le problème est qu'un jeu lancé depuis
NeoStation ouvre RetroArch sans démarrer le jeu quand RetroArch était fermé.
Les changements bibliothèque de la 424 (jamais livrée) sont retirés.

## Pourquoi le lien ne peut pas suffire

- `RetroArchSceneDelegate` (RetroArch `630b36bd` → `master` `60eca9f`) ignore
  l'URL qui démarre l'application ; seule une scène déjà ouverte la reçoit.
- Run `37927541605` : envoyer `retroarch://start` puis le lien du jeu dans le
  même tour, à l'état actif, voit le second lien refusé par iOS, à chaud comme
  à froid. NeoStation ne peut donc transmettre qu'une ouverture.

## Voie retenue par le mainteneur

RetroArch compile `HAVE_NETWORK_CMD` sur iOS (`pkg/apple/BaseConfig.xcconfig`).
Son interface UDP (Réglages › Réseau › Commandes réseau, port 55355,
désactivée par défaut) est lue par sa boucle d'images après tout démarrage.
Commandes utilisées : `GET_STATUS`, `GET_PLAYLIST`, `LIST_CORES` et
`LOAD_CONTENT <cœur>|<contenu>` (branche principale de RetroArch, base du
TestFlight 1.22.2 ; absentes de la version publiée 1.22.0).

1. Tant que le port n'a jamais répondu, NeoStation envoie le lien du jeu
   exactement comme avant, puis interroge `GET_STATUS` (lecture seule) pendant
   que RetroArch est au premier plan. Une réponse est mémorisée.
2. Ensuite, un jeu ouvre RetroArch avec `retroarch://start` (sans effet), puis
   NeoStation attend la réponse du port (démarrage à froid compris), relit
   l'entrée exportée (`gameId` = playlist:index, nom vérifié, recherche si la
   playlist a changé), choisit le cœur comme le lien `game/` de RetroArch
   (cœur de l'entrée, sinon cœur par défaut de la playlist ; chemin actuel
   donné par `LIST_CORES` si le bundle a changé), envoie un seul
   `LOAD_CONTENT`, puis attend `GET_STATUS PLAYING` pour ce contenu.
3. Sans réponse du port, l'échec est signalé et le lien redevient la voie
   suivante. Aucun réglage RetroArch n'est modifié par NeoStation.

La synchronisation de bibliothèque garde son lien (`retroarch://library`).

## Vérifications

- `test/retroarch_command_launch_test.swift` : démarrage à froid avec port
  muet puis réponse, cœur déplacé par une mise à jour, playlist modifiée
  (pages `MORE`), `#` hors archive, cœur introuvable sans chargement, jeu déjà
  en cours non pris pour une réussite, règles libretro d'archive, et vrai
  échange UDP en boucle locale.
- `test/retroarch_command_launch_entry_test.dart` : entrée transmise au natif.
- Les tests existants du lien (`retroarch_url_handoff_test.swift`,
  `retroarch_launch_diagnostics_test.dart`) restent inchangés.

## Sur l'iPhone

1. RetroArch : Réglages › Réseau › Commandes réseau = Activé (port 55355).
2. Lancer un jeu depuis NeoStation une première fois (lien actuel) : le port
   est détecté pendant que RetroArch est affiché.
3. Fermer RetroArch, relancer un jeu depuis NeoStation : RetroArch s'ouvre,
   puis le jeu démarre après son initialisation.
4. `Diagnostics/launch_debug.txt` contient `native=route=…` avec la réponse
   du port, l'entrée, le cœur et la confirmation `GET_STATUS`.
