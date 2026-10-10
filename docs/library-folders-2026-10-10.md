# Bibliothèques : import, dossiers des consoles et mises à jour (10 octobre 2026)

Demandes du mainteneur après l’installation de la Build 432, sur la branche
`Claude`.

## Ce qui était signalé

1. Un jeu 3DS importé deux fois apparaissait deux fois : l’import copiait
   toujours dans `NeoStation › roms › 3ds` et créait `… (2).3ds` quand le nom
   existait déjà (`Mario Kart 7 (…) (Rev 2) (2).3ds`, journal 3DS du 10
   octobre). Ce dossier `roms` devenait une seconde bibliothèque à côté de
   celle de l’utilisateur.
2. Après chaque mise à jour installée par SideStore, la bibliothèque et ses
   consoles n’apparaissaient plus tant que le dossier n’était pas rechoisi
   dans les réglages.

## Causes établies dans les sources

1. `LibretroInternalService.importGames` copiait dans `roms/<console>` sans
   regarder les bibliothèques enregistrées ni les fichiers déjà présents.
2. Les dossiers de bibliothèque sont enregistrés en chemins absolus
   (`…/Containers/Data/Application/<UUID>/…`). Quand iOS donne un nouvel UUID
   au conteneur d’une app réinstallée, les fichiers restent, mais le chemin
   enregistré n’ouvre plus rien : aucune console n’est détectée. Rechoisir le
   dossier ajoutait le nouveau chemin sans retirer l’ancien (sept dossiers
   dans la base analysée pour la Build 423, plusieurs dans des conteneurs
   introuvables). Le signet du dossier lié suit, lui, le dossier.

## Corrections

- **Import** (`LibretroInternalService.importLibraries`,
  `chooseLibretroImportDestination`) : les jeux vont dans une bibliothèque
  enregistrée et accessible, dans son dossier de console (alias conservé,
  par exemple `Nintendo 3DS`). Plusieurs bibliothèques : page de choix,
  utilisable à la manette. Une seule : utilisée directement. Aucune :
  dossier `roms` de NeoStation, alors enregistré. Bibliothèques enregistrées
  mais aucune accessible : message, rien n’est créé. Un jeu déjà présent
  (même nom, même taille) n’est pas recopié ; un autre fichier du même nom
  reste copié en `(2)`.
- **Dossiers des consoles** (`NeoStationRomLibrary.createConsoleFolders`) :
  un dossier par console du moteur intégré dans `NeoStation › roms`, avec les
  noms que reconnaît le scanner (`3ds`, `psp`, `gba`, `ps1`, `ds`…).
- **Déplacement d’une bibliothèque** (`NeoStationRomLibrary.moveLibrary`) :
  les dossiers de console du dossier choisi sont déplacés dans
  `NeoStation › roms` à la même place (renommage, sinon copie vérifiée puis
  suppression de l’original). Un jeu déjà présent reste à sa place ; un
  fichier iCloud non téléchargé est compté « non déplacé ». Quand tout est
  dans NeoStation, les dossiers enregistrés à l’intérieur du dossier choisi
  sont retirés de la bibliothèque.
- **Première ouverture iOS** (`setup_wizard.dart`) : trois choix, le premier
  recommandé et présélectionné ; haut/bas et A à la manette. L’ouverture
  automatique du sélecteur de dossier est remplacée par ce choix. Les mêmes
  actions sont dans Réglages › Dossiers › Consoles intégrées.
- **Après une mise à jour** (`IosLibraryRootRelocation`, blocs
  `LIBRARY_RELOCATION_*` de `main.dart`, autorisés par le mainteneur) : avant
  la lecture de la configuration, chaque dossier enregistré introuvable situé
  dans un conteneur iOS est cherché au même endroit dans le conteneur actuel
  de NeoStation, puis dans celui du dossier lié. Trouvé, il remplace l’ancien
  chemin ; introuvable, il est conservé. Les doublons laissés par les
  liaisons répétées sont fusionnés. Un scan est lancé si le scan au démarrage
  est désactivé.
- Textes ajoutés dans les douze langues (`LibretroLocale`).

## Vérifications

- Tests Dart : déplacement de conteneur (dossier NeoStation, dossier lié,
  ordre, doublons fusionnés, dossiers conservés), dossiers des consoles,
  déplacement (place conservée, jeu déjà présent, autre fichier du même nom,
  placeholder iCloud, refus de déplacer NeoStation en lui-même), choix de la
  bibliothèque (plusieurs, une, retour, aucune accessible), import sans
  doublon, douze langues.
- Contrats : les deux contrats « l’import arrive dans `roms` » sont remplacés
  par ceux du nouveau comportement ; le garde de la Build 419 retire
  exactement les trois blocs marqués de `main.dart`.
- Non vérifié : le changement réel d’UUID du conteneur de NeoStation sur
  l’iPhone (à confirmer par un journal de la Build 433 comparé à
  `247E7CB5…` de la Build 431) et le déplacement d’un dossier d’une autre app
  sur iOS.

## Livraison

**Build 433**, IPA de test : source `57548e6b214a6ca4b79a7d6f45edb6c9e9e1b552`,
run [38059314049](https://github.com/TarbleFR/neostation-ios/actions/runs/38059314049)
(contrôles Dart exécutés de nouveau, natif, compilation Release à froid
réussis ; contrôles libretro : run 38059137851). IPA scellée : SHA-256
`fe6547b90b484c33c9c8c9af60a943e2577a15f6368909b93a0b001370facd5b`,
205 910 988 octets, 57 signatures de préparation vérifiées. Installation par
SideStore. Aucun test sur iPhone à ce stade.
