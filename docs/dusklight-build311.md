# Build 311 — premier moteur Dusklight embarqué

La candidate conserve la bibliothèque Ports du build 310 et ajoute un vrai
`DusklightCore.framework` arm64 compilé depuis Dusklight
`ad979d3dae092d0f5cbdaf49eabca7b4f1db4838`, Aurora
`d0933b745abe0eb9815bedcea8047575da18698d` et SDL 3.4.10. L’application
Dusklight autonome n’est pas imbriquée dans NeoStation.

Le moteur est chargé à la demande. Ses classes Objective-C SDL ont des noms
privés pour éviter les collisions avec les autres moteurs. Il valide le disque
et sa révision avec le validateur officiel, utilise Metal et les contrôles
tactiles/manettes de Dusklight, sans demander de JIT. Les ressources UI du port
sont distribuées avec le framework ; les données du jeu restent fournies par
l’utilisateur.

Le premier appel lance le moteur sur le run loop UIKit. Le résultat de lancement
n’est renvoyé qu’après la première image du jeu. Une expiration avant cette
image demande l’arrêt et conserve la propriété de la session jusqu’à son
nettoyage. Un bouton de fermeture revient à la fenêtre NeoStation capturée au
départ. L’événement natif de fin ferme le suivi de session Flutter, y compris
si le moteur s’est fermé avant la fin des écritures de statistiques.

Le cycle d’arrêt amont a été adapté : drapeau partagé atomique, maintien des
mutex/conditions en vie pendant le réveil des workers, jointure des threads
avant destruction du rendu. Les logs de Dusklight et de son hôte se trouvent
sous `Documents/Ports/Dusklight/Logs`.

## Limite explicite du premier essai

Le port conserve des singletons de durée de vie du processus. Cette candidate
autorise une seule entrée dans le moteur par ouverture de NeoStation. Après
fermeture du jeu, il faut redémarrer NeoStation pour relancer Dusklight. Une
tentative de seconde entrée est refusée avec un message ; le code ne force pas
une remise à zéro incomplète. Un disque rejeté avant l’entrée native ne consomme
pas cette session.

Cette intégration permet un essai réel sur iPhone mais ne constitue pas une
validation du gameplay, des sauvegardes, de la reprise après arrière-plan ou de
l’alternance avec les autres moteurs sur appareil. Les défauts internes du port
restent possibles. Les vérifications automatiques portent sur les transitions,
les files de messages concurrentes, les notifications de fin et le contenu réel
de l’IPA, son ABI, ses ressources et l’absence de chargement anticipé.

## Construction

Le moteur requiert Xcode 26 pour `std::jthread`/`std::stop_token` ; Xcode 26.3 est
utilisé pour ce framework. L’hôte et les autres frameworks conservent leur
chaîne et leurs révisions validées. Les sources modifiées sont intégrales et
canoniques sous `native/dusklight`, avec hashes des fichiers amont avant copie.
La CI ne rejoue pas de série de patches.
