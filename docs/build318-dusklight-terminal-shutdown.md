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

## Compilation et livraison vérifiées

| Élément | Identité |
| --- | --- |
| Sources natives | `2f49b2b1c56979a5ce067886cbb8f44d938cdc9a` |
| Run natif / job | `35919913797` / `107380940062` — succès |
| Archive native | artifact `10777210769`, SHA-256 `a011ca7affdf84c113a8e6c99dd793e8dee86a3c0f40231a9ccc1ff499893468` |
| DusklightCore | SHA-256 `6a04608950711d31af05583e0d06faa77c0ad044f31fc4ee3704d9c53ae127cc` |
| Hôte IPA | `43451713b35a6a7aea7dbbdb9821f31b67a0fb57` |
| Run IPA / job | `35920703210` / `107383617206` — succès |
| Archive IPA | artifact `10777102814`, SHA-256 `3ca73db82ee8460ee77c8cd9ed7604beee40880abe27b31fc161c0362dbbe652` |
| IPA | `NeoStation-iOS-Build-318-Dusklight-Terminal-Shutdown.ipa`, 102 352 051 octets |
| SHA-256 IPA | `652ca44397dda184cac9a5d3f5cc6cceb05c1f9c87cca23c21954c32d1c227dc` |

La compilation arm64 du Core, l'analyse Flutter, les tests natifs, audio,
menus, douze langues, route et JIT, la compilation de l'hôte et les validations
de distribution passent. L'identité embarquée confirme l'ABI 4 et la politique
`host_frame_loop_terminal_shutdown`.

Validation sur iPhone de Build 318 : **en attente**. Tester depuis un démarrage
neuf de NeoStation : Dusklight → retour → RPCS3 sans fermer l'application entre
les deux. Le journal doit contenir `before_runtime_shutdown`, puis
`after_runtime_shutdown`, avant `sessionEnded(runtimeReleased: true)` et avant
l'attachement StikJIT de RPCS3.
