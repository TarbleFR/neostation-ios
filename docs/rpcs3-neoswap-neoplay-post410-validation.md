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
   Les profils découverts avant le chargement du Core sont publiés de nouveau,
   hors réseau, à la fin de l’initialisation existante après le helper JIT.
   Cette publication manquait lorsque le premier envoi avait trouvé le Core
   indisponible ; elle conserve la priorité des réglages utilisateur explicites.
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
   Sur Windows, une restriction SPS manquante est complétée seulement pour
   les nouveaux émetteurs garantissant explicitement l’absence de
   réordonnancement. L’encodeur refuse cette garantie si VideoToolbox rejette
   le réglage requis ; les anciens émetteurs conservent leurs SPS.
   La conversion et l’horloge PCM ont maintenant la durée de vie du streaming,
   indépendamment des encodeurs vidéo successifs. La configuration initiale
   doit effectivement être transmise avant d’ouvrir l’audio. Les files et la
   cible audio de 80 ms sont conservées ; les pertes avant cette première
   configuration sont comptées séparément. Les nouveaux tests natifs doivent
   encore valider cette dernière correction.

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
  38 tests Node réussis (30 avant les changements), également exécutés sur
  le PC Windows physique. `npm start` reste actif sur ce PC. La fenêtre Edge
  de capture a ensuite été fermée : le récepteur annonce `available=false`
  jusqu’à sa réouverture et un clic sur Ready. Aucun paquet provenant du
  téléphone n’a été reçu pendant les captures.
- Les nouvelles régressions couvrent le warmup SPU, les refus et cycles de vie
  NeoSwap, la télémétrie et les identités des comparaisons. Les gates obligatoires
  sont intégrés aux workflows existants.
- Sources publiées sur `experimental` :
  `bb347665ed777bdc8126159a3d180b3ab00b69a6`. La compilation native du
  cœur a détecté une conversion implicite interdite de deux réglages
  `cfg::_bool` dans le warmup. La conversion explicite et un test compilant
  l’expression réelle passent localement après correction ; un nouveau build
  est requis. Aucun cœur
  issu de ce passage échoué ni aucune IPA postérieure à 410 n’est livré.
- La preuve Vulkan isolée vérifiait les prêts avant la maintenance différée
  présente dans l’application. Son adaptation conserve les assertions finales
  de zéro prêt et teste le retrait borné : 40 prêts, refus temporaire puis
  reprise, refus permanent avec conservation de la mémoire. Ces tests locaux
  passent. Au passage `d9589fa209de26cce8c53ec2bc40f93b4d154836`, les
  preuves natives macOS passent à 128 Mio et 1 Gio : respectivement deux et
  cinq prêts soldés en un passage, zéro prêt restant côté broker et pool,
  zéro backing disque. Les 10 µs de la sonde mesurent le drain des prêts,
  pas la restitution de la mémoire physique au noyau. Runs `37595624348`
  et `37595624322` ; aucune preuve iPhone n’en est déduite.
- Au premier passage CI, l’analyse Dart et les 17 tests d’interface NeoPlay
  passent, ainsi que les encodeurs natifs, la lecture de leurs fixtures dans
  Windows Edge hébergé, les deux suites de stockage Linux/macOS et les preuves
  relay et donation NSXPC. Le gate historique de périmètre NeoPlay requiert
  les nouvelles postimages autorisées ; ses assertions de préservation
  sont conservées et la version adaptée passe localement. Le gate Flutter
  a aussi révélé une ancienne assertion imposant une mutation au lancement
  désormais interdite ; le contrat de démarrage unique la remplace. Les
  nouveaux tests Flutter de publication après initialisation passent dans
  le run `37595624359` du commit `d9589fa`. Les tests natifs du contrat
  sans réordonnancement passent aussi (`37595624347`). Ces résultats ne
  couvrent pas encore la correction PCM ajoutée après ce commit.
- Donation réelle sur iOS 18.5 Simulator au commit `d9589fa` : deux processus
  auxiliaires, quatre blocs de 16 Mio, soit 64 Mio effectivement prêtés et
  vérifiés ; onze contrôles de cycle de vie, refus, callbacks tardifs et
  nettoyage réussis. Les 26 empreintes source de l’artefact correspondent
  au commit. Le harness pilote son propre calendrier ; cela ne valide pas
  le warmup pendant God of War III sur téléphone.
- Le run stockage `37595624315` du même commit échoue au lancement de
  l’application de test Simulator : `simctl launch` dépasse 120 s après
  compilation, boot et installation réussis. Les 46 fichiers concernés
  sont identiques au passage précédent réussi. Aucun rapport applicatif
  final n’est récupéré ; la cause du timeout reste indéterminée. Le prochain
  passage conserve ce délai et toutes les assertions.
- Sur le PC Windows physique, la même fixture `bb347665` passe de 28 à
  1 image tardive au même point du test, avec 134 → 191 images présentées.
  Le décodage matériel et la cible audio de 80 ms sont conservés. Le déficit
  PCM persiste : 10 586 → 12 050 trames à 48 kHz, soit 220,5 → 251,0 ms ;
  zéro skip dans les deux cas. Après redimensionnement, le dernier diagnostic
  compte six images tardives : c’est un autre point de mesure. Détails,
  cushion, débit, empreintes et limites dans `neoplay/RECEIVER-VALIDATION.md`.
  Ce résultat est un rejeu de laboratoire et ne valide pas le grésillement
  sur iPhone. Les anciens flux, sans garantie explicite, ne sont pas modifiés.
- Le diagnostic PCM isole ensuite neuf paquets manquants entre 5,0 et 5,3 s
  au changement de qualité, dans les fixtures `bb347665` et `d9589fa`.
  Le harness fournit ces échantillons, mais l’ancien encodeur les abandonne
  en attendant sa nouvelle configuration vidéo. Un rejeu de l’anneau audio
  de production reproduit 11 163 trames d’underrun (232,6 ms) ; fournir les
  neuf paquets manquants dans un contrefactuel donne zéro underrun avec la
  même cible de 80 ms. Ce contrefactuel établit la cause dans la fixture ;
  ce n’est pas une mesure de la correction native ni du téléphone.
- Stress mémoire macOS du premier passage : arrêt réel sur pression mémoire
  après 8 388 608 000 octets préparés et vérifiés (7,8125 Gio), avec
  3 866 279 936 octets résidents et 4 522 328 064 octets compressés.
  La demande restante de 201 326 592 octets est refusée. Le seuil de 8 Gio
  n’est pas atteint ; les protections et les critères de réussite sont
  conservés. Ce résultat ne mesure pas la capacité d’un iPhone.
- Aucun flux iPhone → Windows ni session God of War III sur iPhone n’a été
  observé. La validation sur appareil reste ouverte.

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
- Profils : `lib/services/rpcs3_game_profile_service.dart` et
  `lib/services/rpcs3_internal_service.dart`.
- Broker : `packages/neo_swap/ios/Classes/NeoSwap.cpp`, `.h`, `NeoSwapHost.h`,
  `native/neoswap/NeoSwapClient.h`, `native/neoswap-donation/Pool.cpp`, `.h`,
  `Broker.cpp`, `.h`.
- Préparation : `NeoSwapPlugin.mm`, `NeoSwapPreparation.h`,
  `packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm`.
- NeoPlay : `NPCapture.swift`, `NPFrameEncoder.swift`, `NPWindowsTransport.swift`, tests Swift
  et collecte des fixtures ; `tools/neoplay-receiver/diagnostics.mjs`,
  `h264-sps.mjs`, `player.mjs`, `server.mjs`, `playback-smoke.mjs` et leurs tests.
- Retrait GPU : `VulkanDonationProbe.h`, `RetirementProof.h`, validateur de
  preuve et tests de retrait ; les chemins GPU de production sont conservés.
- Comparaisons : `tools/compare_rpcs3_neoswap_builds.py` et son test.
- Tests, workflows et manifestes : changements explicites de portée,
  empreintes et exécution obligatoire des nouvelles régressions.
