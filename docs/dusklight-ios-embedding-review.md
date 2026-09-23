# Dusklight dans Ports — analyse de l'intégration iOS

Ce document conserve l’audit initial des builds 309–310. L’intégration native
de la candidate suivante est décrite dans [dusklight-build311.md](dusklight-build311.md).

Sources examinées le 23 septembre 2026 :

- [Dusklight](https://github.com/TwilitRealm/dusklight/tree/ad979d3dae092d0f5cbdaf49eabca7b4f1db4838), commit `ad979d3dae092d0f5cbdaf49eabca7b4f1db4838`.
- Sous-module [Aurora](https://github.com/encounter/aurora/tree/d0933b745abe0eb9815bedcea8047575da18698d), commit `d0933b745abe0eb9815bedcea8047575da18698d`.
- [Instructions officielles iOS](https://twilitrealm.dev/install/ios/).

## État de l'intégration

Le moteur est disponible en sources et accepte un chemin de disque via `--dvd`.
La distribution iOS officielle est cependant une application autonome. Ajouter
son IPA aux fichiers de NeoStation ne crée pas un moteur que NeoStation puisse
appeler.

La première tranche d'intégration est maintenant présente :

- catégorie `Ports` visible sur iOS, même à bibliothèque vide ;
- racine privée `Documents/Ports/Dusklight` avec `Games`, `Saves`, `Config`,
  `Mods` et `Metadata` ;
- import atomique des formats officiels ISO/GCM/RVZ/WIA/WBFS/CISO/GCZ ;
- validation immédiate des Game IDs pour les images ISO/GCM non compressées ;
- route de lancement exclusive, sans repli silencieux vers RetroArch ;
- plugin iOS chargé à la demande et ABI hôte/Core v1 (`initialize`, `start`,
  `stop`, `is_running`).

Le framework `DusklightCore.framework` n'est pas encore construit ni embarqué.
Cette tranche rend donc l'import et la bibliothèque réels, mais signale
explicitement `DUSKLIGHT_CORE_NOT_READY` lors du lancement. Elle n'intègre pas
l'IPA autonome et ne prétend pas qu'un jeu est déjà exécutable.

## Obstacles établis dans les sources

1. `CMakeLists.txt` produit `add_executable(dusklight ...)` pour iOS et lie
   `aurora::main`. Le point d'entrée et les ressources sont ceux d'une application,
   pas d'un framework exposant démarrage, arrêt, pause et résultat d'erreur.
2. `src/m_Do/m_Do_main.cpp::game_main` positionne `mainCalled` et refuse toute
   nouvelle entrée. Ce garde reste positionné après la sortie du jeu. Supprimer
   seulement ce garde ne prouve pas que les états globaux sont réinitialisables.
3. Le même fichier contient des chemins d'erreur utilisant `exit(1)` et un chemin
   d'aide utilisant `exit(0)`. Dans un moteur intégré, ces sorties termineraient
   aussi NeoStation.
4. `AuroraConfig` ne reçoit pas de vue UIKit fournie par l'hôte. Aurora crée sa
   fenêtre SDL plein écran et termine SDL avec `SDL_Quit()` à la fermeture. Il
   faut définir la propriété de la fenêtre, du rendu, des entrées et des callbacks
   avant de faire cohabiter ce moteur avec Flutter et les autres moteurs iOS.
5. La fermeture du jeu détruit le système machine, demande `OS_RESET_SHUTDOWN`,
   ferme l'audio, les interfaces et Aurora. Un deuxième démarrage dans le même
   processus doit être vérifié sur ces ressources, pas seulement sur `mainCalled`.

## Étape native suivante

- Construire un framework iOS à révision figée, avec ressources séparées et une
  interface de session explicite. Ne pas embarquer de données du jeu.
- Adapter Aurora pour rendre dans la vue appartenant à la session NeoStation,
  sans remplacer son cycle de vie UIKit. Auditer les symboles SDL/Objective-C
  partagés avec ARMSX2 avant l'édition des liens et au chargement.
- Remplacer les sorties de processus par des erreurs retournées et réinitialiser
  les états de session après la libération/jonction des ressources natives.
- Brancher le validateur amont et le moteur sur l'ABI déjà exposée. La validation
  amont du disque doit rester autoritaire pour les formats compressés ; ne pas
  reconnaître un jeu au seul nom du fichier.
- Vérifier premier lancement, fermeture, relancement, disque invalide, changement
  de premier plan, manette et alternance avec Dolphin/ARMSX2/RPCS3 sur iPhone.

Aucun raccourci externe, lancement d'IPA ou moteur factice n'a été ajouté. Le
pont actuel est une frontière native testable et paresseuse ; la validation du
jeu en fonctionnement ne pourra commencer qu'après adaptation et compilation
du framework Core.
