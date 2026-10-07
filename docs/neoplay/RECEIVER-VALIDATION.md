# NeoPlay — validation du récepteur après la Build 410

Ces changements de diagnostic sont postérieurs à l'IPA 410 documentée dans
`BUILD410.md`. Ils ne modifient pas son identité et ne constituent pas une
validation de streaming sur un iPhone ou un PC Windows physique.

## Installation et protocole réellement actif

Dans `tools/neoplay-receiver`, lancer `npm ci --ignore-scripts && npm start`,
puis ouvrir l'adresse locale indiquée dans Edge ou Chrome et cliquer sur Ready.
`npm ci` installe les versions exactes du lockfile ; il ne met pas arbitrairement
les dépendances à leur dernière version.

Pendant un flux réel, `Receiving · frames` désigne le protocole v2
(WebCodecs + PCM AudioWorklet). Vérifier que les compteurs `video` (présentées /
reçues) et `PCM` augmentent et que `rx` est positif. Le mot `segments` désigne
le repli v1 MediaSource : ce n'est pas un deuxième indicateur de réussite v2.
En v2, le compteur de segments doit rester à zéro.

## Capturer les mesures sans augmenter le buffer

Le récepteur conserve au maximum 1 200 échantillons à 500 ms, soit dix minutes.
Après l'arrêt, il conserve le dernier flux terminé. Avant de relancer, exporter
depuis la console de développement Edge/Chrome :

```javascript
copy(JSON.stringify(window.neoplayDebug.diagnostics(), null, 2))
```

Enregistrer le résultat comme `receiver-diagnostics.json`, avec le journal iOS
`NeoPlay.jsonl`, le SHA source exact et les heures de début/fin du test. Aucun
contenu audio/vidéo, PIN, jeton ou adresse réseau n'est inclus dans cet export.

| Mesure | Signification |
| --- | --- |
| `rx` / `megabitsPerSecond`, `packetsPerSecond` | Débit reçu par la page sur la dernière fenêtre ; distinct du ratio audio. |
| `cushion` | Remplissage / cible audio en millisecondes. |
| `resample` / `ratio` | Ratio de consommation audio ; ce n'est pas le débit réseau. |
| `late-video` / `droppedLate` | Images vidéo trop tardives ; ce n'est pas un compteur de paquets audio perdus. |
| `underruns` | Trames PCM de sortie manquantes ; durée = compteur / `audioOutputSampleRate`. |
| `skips`, `skipped` | Événements de saut et trames PCM sautées dans l'anneau audio. |
| `gaps`, `silence`, `trimmed`, `dropped` | Discontinuités de PTS audio, silence inséré, chevauchements rognés et trames périmées. |
| `pcmArrivalGapMaxMs` | Intervalle maximal entre deux réceptions PCM par la page, pour cette fenêtre. Inclut d'éventuelles pauses de l'émetteur ou du navigateur ; ne prouve pas à lui seul une perte réseau. |
| `queueWaitMaxMs` | Attente maximale dans la file de traitement de la page, pour cette fenêtre. |
| `lastMediaPtsUs` | PTS audio/vidéo reçus, dans la chronologie de l'émetteur ; pas des heures UTC. |

`time` utilise l'UTC comme `NPLog.time` côté iOS ; synchroniser les horloges des
deux appareils. Les débits et délais locaux utilisent une horloge monotone.
Comparer les **différences** des compteurs entre fenêtres aux événements iOS
`audio.dropped`, `audio.nonmonotonic`, aux changements de palier et aux délais
du transport. L'absence de PTS dans certains événements iOS limite la précision
de la corrélation ; cet export ne mesure pas la latence réseau aller simple.

Tester une séquence reproductible : démarrage, cinq minutes de jeu, passage
plein écran/redimensionnement, pause, reprise, arrêt puis relance. Conserver
séparément les captures v1 et v2. Un test Node ou une fixture encodée ne valide
ni ReplayKit sur le téléphone, ni le réseau Wi-Fi, ni le son physique Windows.
Si le grésillement est entendu sur le téléphone uniquement, instrumenter aussi
la sortie audio iOS avant de l'attribuer au récepteur Windows.

## Vérifications automatisées

`npm test` couvre le protocole, le relais, l'anneau audio, la présentation et les
mesures (débit, unités, limites d'historique et relance). `playback-smoke.mjs`
vérifie les compteurs face aux paquets des fixtures iOS et écrit aussi
`test-output/receiver-frames-diagnostics.json` ou
`test-output/receiver-segments-diagnostics.json` pour les preuves CI.

La validation physique reste ouverte jusqu'à l'observation des compteurs qui
progressent pendant le flux iPhone → Windows et à l'examen des deux journaux.
