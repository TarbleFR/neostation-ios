# Dusklight dans Ports — analyse de l'intégration iOS

Sources examinées le 23 septembre 2026 :

- [Dusklight](https://github.com/TwilitRealm/dusklight/tree/ad979d3dae092d0f5cbdaf49eabca7b4f1db4838), commit `ad979d3dae092d0f5cbdaf49eabca7b4f1db4838`.
- Sous-module [Aurora](https://github.com/encounter/aurora/tree/d0933b745abe0eb9815bedcea8047575da18698d), commit `d0933b745abe0eb9815bedcea8047575da18698d`.
- [Instructions officielles iOS](https://twilitrealm.dev/install/ios/).

## Résultat

Le moteur est disponible en sources et accepte un chemin de disque via `--dvd`.
La distribution iOS officielle est cependant une application autonome. Ajouter
son IPA aux fichiers de NeoStation ne crée pas un moteur que NeoStation puisse
appeler. La catégorie de bibliothèque et l'import de disque ne suffisent pas.
L'intégration exécutable n'est pas réalisée dans la Build 308.

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

## Travail nécessaire pour obtenir le comportement demandé

- Construire un framework iOS à révision figée, avec ressources séparées et une
  interface de session explicite. Ne pas embarquer de données du jeu.
- Adapter Aurora pour rendre dans la vue appartenant à la session NeoStation,
  sans remplacer son cycle de vie UIKit. Auditer les symboles SDL/Objective-C
  partagés avec ARMSX2 avant l'édition des liens et au chargement.
- Remplacer les sorties de processus par des erreurs retournées et réinitialiser
  les états de session après la libération/jonction des ressources natives.
- Brancher l'import de disque validé par Dusklight sur une entrée Ports, avec
  sauvegardes et configuration propres au moteur. La validation amont du disque
  doit rester autoritaire ; ne pas reconnaître un jeu au seul nom du fichier.
- Vérifier premier lancement, fermeture, relancement, disque invalide, changement
  de premier plan, manette et alternance avec Dolphin/ARMSX2/RPCS3 sur iPhone.

Aucun raccourci externe, lancement d'IPA ou moteur factice n'a été ajouté aux
sources livrées. Cette analyse constate la nécessité d'un portage ; elle ne
constitue pas une validation de Dusklight intégré à NeoStation.
