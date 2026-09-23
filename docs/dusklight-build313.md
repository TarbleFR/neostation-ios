# Build 313 — contrôles natifs et reprise Dusklight

## Causes établies

- Le réglage upstream `game.enableTouchControls` est désactivé par défaut.
- Le menu RmlUi existe, mais seule la fermeture avait un bouton UIKit visible.
- ABI 2 interdisait toute session après le premier retour de `game_main` : les
  singletons du jeu ne sont pas réinitialisables par un nouvel appel à ce point
  d’entrée. Retirer seulement le verrou aurait réutilisé des objets détruits.

## Changement de cycle de vie (ABI 3)

Le moteur est initialisé une seule fois. `main01` initialise le jeu, puis rend
la main. `NeoDusklight_TickGame` est exécuté par un CADisplayLink du thread UIKit.
SDL ne lance plus de boucle UIKit imbriquée ; Aurora ne bloque plus dans
`SDL_WaitEvent` lorsque sa fenêtre perd le focus. La cadence suit les réglages
natifs (30 images/s sans interpolation, plafond choisi sinon).

Retour à la playlist : attendre la fin de l’image, arrêter le CADisplayLink,
relâcher les commandes tactiles, suspendre l’horloge et fermer le périphérique
audio, masquer uniquement la fenêtre SDL capturée et restaurer la fenêtre hôte.
Les heaps, le lecteur du disque et l’état du jeu restent en mémoire. Les
sauvegardes ne sont ni effacées ni réécrites pour contourner le problème.

Relancement du même fichier : réouvrir l’audio sans réinitialiser le DSP/JAS,
réafficher la fenêtre possédée et attendre une **nouvelle** image avant de
signaler la réussite. Le jeu reprend sa session ; le menu natif permet Reset.
Ce n’est pas un redémarrage à froid du moteur. Un autre disque ou un fichier
remplacé est refusé explicitement, car le moteur ne gère pas ce changement à chaud.
Une panne native irréversible reste terminale ; elle est distincte d’un retour
normal. Le moteur conservé occupe toujours de la mémoire : l’alternance avec
les autres émulateurs doit être vérifiée sur appareil.

Une migration active les commandes tactiles une fois. Les modifications
ultérieures faites dans les réglages Dusklight restent conservées. Le bouton
engrenage ouvre le menu d’origine, sans réimplémenter ses réglages.
Les nouveaux libellés, aides et erreurs viennent des catalogues NeoStation
dans les 12 langues, dont le chinois traditionnel. Les réglages internes
préexistants de l’amont ne sont pas réécrits par cette intervention.

## Vérification

- Transitions natives : 100 cycles, annulation avant initialisation/reprise,
  double lancement, image tardive et erreur terminale.
- Fonction audio de production : 100 suspensions/reprises, fermeture effective
  du périphérique, absence de double création ou double fermeture.
- Horloge Aurora réelle : gel pendant une longue pause, raisons host/background
  indépendantes, vitesse préservée et absence de rattrapage du temps masqué.
- Chargeur natif et ordre de réveil/jonction des workers : tests conservés.
- Flutter : transactions, reprise répétée, fin ancienne ignorée, 12 catalogues
  et transmission des libellés vers le natif.
- CI : compilation arm64 du Core avant de produire l’IPA hôte ; identités et
  ressources vérifiées. Aucun nouveau binaire Dolphin, RPCS3 ou ARMSX2.

## Validation iPhone à effectuer

1. Overlay tactile sans manette ; déplacement et boutons simultanés.
2. Engrenage, réglages natifs, désactivation/réactivation des commandes.
3. Retour à NeoStation, relancement du même disque au moins cinq fois.
4. Aucune musique de Dusklight dans la playlist ; reprise audio correcte.
5. Arrière-plan puis retour ; absence de touches bloquées ou de saut temporel.
6. Alternance Dolphin/RPCS3/Dusklight et contrôle de la pression mémoire.
7. Sauvegarde dans le jeu, fermeture complète de l’application et relecture.

La compilation et les tests simulés ne prouvent pas la stabilité sur iPhone.
