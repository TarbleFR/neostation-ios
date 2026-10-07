# RPCS3, NeoSwap et NeoPlay — chantier après l’IPA 410

Ces changements ne sont pas présents dans l’IPA 410 existante
(`f5478b036878e5727a035086faff97d0581931cf`). La base de travail est
`301ff56a63291c1229fba4c5d4f345e124fc0caa`, branche `experimental`.
`main` et `backup` restent inchangées. Aucun résultat sur appareil réel ni
gain de FPS n’est déduit des tests de code.

## Changements

1. **SPU** : effacement complet du tampon de reconstruction des programmes,
   warmup des modules découverts même si des métadonnées existent déjà pour
   God of War III, respect du réglage de précompilation, budget des workers
   existants plafonné à deux. Les six identifiants régionaux du profil natif
   sont couverts. Les objets ARM64 contenant des adresses propres au processus
   ne sont pas persistés, y compris dans les chemins debug et interpréteur.
   Les mesures distinguent chargement, compilation en partie et réutilisation.
2. **NeoSwap** : demande rapide additive dans l’ABI existante, prêts déjà prêts,
   refus immédiat lorsque la ressource ou son verrou est indisponible. Le
   mapping ordinaire de RPCS3 demeure le repli. Les alias invités déjà publiés
   conservent leur backing et leurs protections de cohérence. Les attentes de
   réservation RPCS3 sont mesurées séparément des acquisitions NeoSwap.
3. **Donors** : réveil de la file existante au début de session, préparation
   progressive de 16 Mio, une préparation simultanée, demandes contiguës plus
   grandes traitées séparément en arrière-plan. Le boot ne patiente plus
   1,5 seconde pour un seuil de 384 Mio. Les états partiel, prêt, refusé,
   timeout, `relay-only` et mapping ordinaire sont explicités sans assimiler
   capacité préparée, mémoire résidente et mémoire effectivement prêtée.
4. **NeoPlay** : mesures reçues horodatées et bornées, débit réseau distinct du
   ratio audio, unités explicites pour les retards vidéo et les underruns PCM.
   Le protocole v2 affiche `Receiving · frames` avec les compteurs vidéo/PCM.
   `segments` désigne le repli MediaSource v1 ; il doit rester nul en v2.

## Avant / après : mesures disponibles

Les approximations de la colonne « signalé » viennent de la demande ; aucun
journal source lié à ces valeurs n’a été fourni pour ce cycle. Elles ne sont
pas utilisées comme résultats de référence vérifiés.

| Mesure | Signalé avant | Après sur appareil réel |
| --- | --- | --- |
| Compilation SPU en partie, cumul | environ 50 s | Non mesuré |
| Plus longue compilation SPU | environ 8,8 s | Non mesuré |
| Attente range-lock | environ 118 ms par fenêtre, unité à confirmer dans le journal | Non mesuré |
| Blocages / itérations d’attente | plus d’un million, nature exacte à confirmer | Non mesuré |
| Frametime et FPS | Pas de capture comparable fournie | Non mesuré |
| RAM physique et prêts NeoSwap utilisables | `donor_count=0`, `prepared=0`, `result=-7` signalés | Non mesuré |
| Latence des défauts mémoire et du repli complet | Non fournie | Non mesurée ; distincte du temps d’acquisition NeoSwap |
| NeoPlay : cushion, débit, late, underruns, skips | Pas de flux réel accessible dans ce cycle | Non mesuré |

Le `range-lock` existant protège les réservations mémoire de RPCS3. La présence
d’une attente ne prouve pas qu’elle est causée par NeoSwap. Les compteurs
historiques d’itérations et le nouveau nombre d’épisodes ne sont pas
interchangeables. Les chemins rapides évitent la préparation lente explicite ;
ils ne constituent pas une garantie d’absence de défaut mémoire du système.

## Validation et reproduction

- Référence locale : 12 suites C++ portables réussies avec GCC 13.3,
  AddressSanitizer et UndefinedBehaviorSanitizer. LeakSanitizer indisponible
  dans cet environnement ; aucun résultat de recherche de fuite n’est annoncé.
- Révision modifiée : les mêmes 12 suites C++ compilent et passent. Les
  régressions SPU, préparation donor et comparaison des captures passent aussi.
  Les 28 commandes Python/Node retenues se terminent sans échec ; cinq cas
  Apple sont ignorés, dont le test natif JIT entièrement indisponible ici.
  Le test Node du handshake et le contrat LocalDevVPN passent.
- Récepteur : `npm ci --ignore-scripts` réussi sans changement du lockfile,
  34 tests Node réussis (30 avant l’instrumentation). `npm start` atteint le
  serveur puis échoue lors de l’énumération multicast des interfaces dans le
  conteneur. Les tests du serveur utilisent une annonce désactivée explicitement.
- Les nouvelles régressions couvrent le warmup SPU, les refus et cycles de vie
  NeoSwap, la télémétrie et les identités des comparaisons. Les gates obligatoires
  sont intégrés aux workflows existants.
- Compilation iOS de cette révision : en attente. Les tests Objective-C++,
  Flutter et les preuves natives Apple doivent être exécutés par la CI macOS.
- Le PC Desktop Commander était hors ligne lors de la vérification. Aucun
  flux iPhone → Windows ni session God of War III sur iPhone n’a été observé.

Pour les captures comparables, suivre
[`rpcs3-neoswap-measurement-captures.md`](rpcs3-neoswap-measurement-captures.md).
Le collecteur produit un tableau JSON/Markdown avec SHA source, session,
empreintes des journaux et valeurs manquantes explicites. Il ne reconstruit
pas un percentile global de frametime depuis des FPS échantillonnés.

Pour les compteurs du récepteur et leur corrélation avec `NeoPlay.jsonl`, suivre
[`neoplay/RECEIVER-VALIDATION.md`](neoplay/RECEIVER-VALIDATION.md). Tester
démarrage, jeu, redimensionnement/plein écran, pause/reprise, arrêt et relance.

## Fichiers principaux

- Sources RPCS3 : `build-utils/rpcs3/embedded-core.patch` et
  `canonical-source.json` ; postimages SPU, profiler, VM et client NeoSwap.
- Profils : `lib/services/rpcs3_game_profile_service.dart`.
- Broker : `packages/neo_swap/ios/Classes/NeoSwap.cpp`, `.h`, `NeoSwapHost.h`,
  `native/neoswap/NeoSwapClient.h`, `native/neoswap-donation/Pool.cpp`, `.h`,
  `Broker.cpp`, `.h`.
- Préparation : `NeoSwapPlugin.mm`, `NeoSwapPreparation.h`,
  `packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm`.
- Récepteur : `tools/neoplay-receiver/diagnostics.mjs`, `player.mjs`,
  `server.mjs`, `playback-smoke.mjs` et leurs tests.
- Comparaisons : `tools/compare_rpcs3_neoswap_builds.py` et son test.
- Tests, workflows et manifestes : changements explicites de portée,
  empreintes et exécution obligatoire des nouvelles régressions.
