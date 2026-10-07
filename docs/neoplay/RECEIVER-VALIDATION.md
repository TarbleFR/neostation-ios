# NeoPlay — validation du récepteur après la Build 410

Ces changements sont postérieurs à l'IPA 410 documentée dans `BUILD410.md`.
Ils ne modifient pas son identité. Les fixtures ont été lues sur le PC Windows
physique le 7 octobre 2026 ; le flux provenant d'un iPhone reste à valider.

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

## Résultats Windows du 7 octobre 2026

Installation isolée `NeoPlay-post410-20261007-a276`, sans modification des
anciens récepteurs : `npm ci --ignore-scripts` puis `npm start` exécutés sur le
PC. Node 24.19.0, npm 11.17.0, Edge 154.0.4258.62 ; 38 tests Node réussis avec
les dernières sources. Le serveur de capture écoute sur
`http://127.0.0.1:17642/`, sans paquet iPhone observé pendant ces mesures.
À la dernière vérification, sa fenêtre Edge avait été fermée et l'état était
`available=false` : la page doit être rouverte et Ready activé avant le flux réel.
Les fixtures utilisent un autre port et une fenêtre Edge de test distincte.

La comparaison ci-dessous utilise les mêmes octets `frames.json`, issus de la
CI native `37592258513`, commit `bb347665ed777bdc8126159a3d180b3ab00b69a6`,
SHA-256 `0eb1c37004d91611d8b15497e2827c5c75728d397e5e27fb3b5dcabeb05e40e5`.
Durée sept secondes, 210 images, 192 paquets PCM, deux configurations avec
changement de palier à cinq secondes. Avant = récepteur `bb347665` ; après =
sources de réparation SPS décrites ci-dessous. Les nombres vidéo et audio sont
pris au même point du smoke, **avant** son test de redimensionnement.

| Mesure | Avant | Après |
| --- | ---: | ---: |
| Images présentées / décodées | 134 / 168 | 191 / 201 |
| Images tardives `late-video` | 28 | 1 |
| Cible audio | 80 ms | 80 ms |
| Cushion observé, fenêtres 500 ms | 58,7–111,7 ms | 49,5–90,7 ms |
| Réception, fenêtres 500 ms | 0,86–2,58 Mbit/s | 0,87–2,59 Mbit/s |
| Réception paquets | 27,4–75,5/s | 27,9–75,9/s |
| `underruns`, trames PCM à 48 kHz | 10 586 (220,5 ms) | 12 050 (251,0 ms) |
| `skips` | 0 | 0 |
| Discontinuités audio / sauts de chronologie | 1 / 1 | 1 / 1 |
| Attente maximale de traitement de page | 1,1 ms | 0,8 ms |
| Intervalle maximal entre réceptions PCM | 324,5 ms | 345,7 ms |
| Reconfigurations / récupérations décodeur | 1 / 0 | 1 / 0 |
| Gate vidéo existant, sans modification du seuil | Échec | Réussite |

Les fenêtres de débit/cushion couvrent la capture ; le dernier échantillon
après redimensionnement et arrêt indique 192 images présentées et **6** images
tardives. Il est conservé dans le JSON et n'est pas substitué à la mesure du
tableau. Le déficit PCM persiste autour de la discontinuité de la fixture lors
du changement d'encodeur : ce test ne démontre aucune résolution du grésillement.
Le son est analysé puis rendu silencieusement par le banc ; aucune écoute
physique n'est revendiquée. Le repli v1 a également passé son smoke avec 142
images, progression `segments` et RMS audio 0,176, dans une session séparée.

### Cause vidéo et portée du changement

Les configurations H.264 observées omettent la restriction VUI du tampon de
réordonnancement. Sur ce PC, le décodeur matériel garde des images jusqu'aux
images clés, provoquant des groupes d'environ treize images tardives aux
secondes deux et quatre, alors que les PTS sont monotones à 30 Hz. Le même
défaut apparaît avec les sources antérieures aux nouveaux diagnostics : ceux-ci
ne sont pas la cause de la régression. Un essai logiciel isolé et un essai avec
restriction SPS explicite lèvent ce retard ; la correction conserve
`prefer-hardware`, les règles de présentation et le buffer audio existants.

`h264-sps.mjs` complète seulement une restriction absente, avec zéro image à
réordonner et un DPB compatible avec les références déclarées. Les restrictions
explicites, les profils non pris en charge et les données malformées restent
inchangés. L'opération exige la promesse booléenne `noFrameReordering: true`
transmise par l'émetteur authentifié ; le relais l'associe à sa session et la
réinitialise à la déconnexion. Le nouvel encodeur iOS refuse son initialisation
si VideoToolbox refuse `AllowFrameReordering=false` et ferme sa session créée.
Un ancien émetteur, dont l'IPA 410, n'annonce pas cette garantie : ses SPS ne
sont pas réécrits automatiquement.

Les deux fixtures historiques utilisées pour les essais A/B ont été examinées
intégralement avec ffprobe : 206 images P et quatre I, aucune B. Un manifeste
**de laboratoire**, lié au SHA de ces octets, autorise leur rejeu de test avec
la promesse ; il ne garantit pas les autres flux d'une ancienne IPA. Les
nouvelles fixtures natives produisent leur propre `frames-manifest.json`, lié
au SHA-256 et seulement après construction des encodeurs soumis au nouveau
contrat. Leur génération et les tests de rejet de propriété doivent passer la
CI Apple avant validation de cette modification native.

Sources exactes de l'essai final :

| Fichier | SHA-256 |
| --- | --- |
| `h264-sps.mjs` | `d7b84ab244a1ba2142082d25ed01ec0acb36e819a6067cd4d40dae5666ecb873` |
| `player.mjs` | `85776048594a0dfd43f11eb69e2ee05da4b18cc240467535f046847f4753f4b3` |
| `server.mjs` | `64c7c54e85f660978f10721d9df94b2c4ea737b2d6654e92b9a53f0619bfc365` |
| `playback-smoke.mjs` | `f164319acd7e1c7e406c34ec5a567d49c0f138f94ec15dcb5b9188326fcf24d3` |

Preuves conservées sur le PC : `windows-before-bb347665-observation.json`,
`probe-negotiated-sps/windows-final-unit.log`,
`probe-negotiated-sps/windows-final-bb347665.log` et
`probe-negotiated-sps/output-final/{playback-frames,receiver-frames-diagnostics}.json`.
Les JSON et journaux sont aussi recopiés dans le dossier de preuves de la
session de travail. Aucun journal iPhone correspondant n'a encore été reçu.
