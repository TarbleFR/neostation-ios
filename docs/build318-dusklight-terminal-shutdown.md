# Build 318 — fermeture terminale de Dusklight

## Cause confirmée sur Build 317

Le journal iPhone du PID 54892 confirme que la restitution graphique partielle
ne suffit pas. Avant Dusklight, l'empreinte physique est de 487 229 664 octets
et le plus grand trou visible de 910 327 808 octets. Après le retour au menu,
malgré la destruction des buffers temporaires, l'empreinte reste à
1 136 396 896 octets et le plus grand trou visible à 239 779 840 octets.
RPCS3 demande une arène contiguë de 256 Mio : la session Dusklight conservée
reste donc incompatible avec le démarrage RPCS3 dans le même processus.

Ce n'est pas un défaut d'état du JIT de Dusklight : ce port n'utilise pas le
JIT. Le blocage vient des heaps, du lecteur de disque, des workers, du moteur
audio et du runtime graphique qui restaient volontairement vivants pour la
reprise à chaud.

## Nouveau contrat ABI 4

Le retour vers NeoStation n'est plus une suspension. À la frontière d'image :

1. le timer de démarrage et le `CADisplayLink` sont invalidés ;
2. les entrées tactiles et l'audio sont suspendus ;
3. seule la fenêtre Dusklight est masquée et la fenêtre NeoStation est reprise ;
4. le chemin natif ordonné ferme Borealis, les callbacks audio, les threads du
   jeu, le lecteur de disque, RmlUi, les textures, la configuration, Aurora,
   Dawn/Metal et SDL ;
5. les observateurs UIKit, boutons et références de fenêtre sont détachés ;
6. une mesure VM après arrêt est écrite ;
7. l'événement `sessionEnded(runtimeReleased: true)` est envoyé seulement après
   la fin de cette barrière.

`GameLaunchManager` refuse de considérer le retour comme terminé sans ce
marqueur. La restauration audio et la fermeture de la route suivent ensuite ;
un lancement RPCS3 ultérieur ne peut donc commencer son attachement StikJIT
avant la libération du runtime Dusklight.

## Conséquence volontaire

Les singletons natifs de Dusklight ne sont pas réinitialisables proprement.
Après avoir quitté Dusklight, un nouveau lancement Dusklight exige donc de
redémarrer NeoStation. Ce choix remplace explicitement la reprise à chaud afin
de rendre possibles l'alternance Dusklight → RPCS3 et l'absence d'activité
Dusklight en arrière-plan. Les sauvegardes, réglages, jeux et mods ne sont pas
supprimés.

Les textes de confirmation et de relance ont été mis à jour dans les douze
langues. RPCS3, StikJIT, Dolphin et ARMSX2 ne sont pas modifiés par ce correctif.

## Vérifications obligatoires

- état natif : annulation précoce réessayable, première image, arrêt terminal,
  absence de deuxième `game_main` ;
- ordre complet : frame, audio, workers, lecteur, UI, graphique, SDL, puis
  événement hôte ;
- aucune chaîne ni branche de reprise du runtime dans l'hôte ABI 4 ;
- événement Flutter accepté seulement avec `runtimeReleased: true` ;
- traductions identiques en clés et paramètres dans les douze catalogues ;
- compilation arm64 du Core et IPA, identités natives et artefact consignés
  après succès CI ;
- validation iPhone requise : Dusklight → retour → RPCS3, sans fermer
  NeoStation, puis contrôle du journal `after_runtime_shutdown`.
