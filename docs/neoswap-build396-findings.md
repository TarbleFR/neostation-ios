# NeoSwap — diagnostic du build 396

Date d'analyse : 2 octobre 2026. Analyse en lecture seule ; aucune compilation déclenchée.

Sources :

- `upload/NeoSwap-v1(7).jsonl` — 171 lignes JSON.
- `upload/RPCS3-diagnostic(20261002-215824).log` — 89 lignes JSON.

Les références de lignes ci-dessous correspondent aux fichiers originaux, une entrée JSON par ligne. Les heures sont exprimées en UTC ; ajouter deux heures pour l'heure locale de Paris le 2 octobre 2026. Les valeurs en Mio et Gio utilisent respectivement 1 048 576 et 1 073 741 824 octets.

## Conclusion

Le build 396 active effectivement la donation et GuestRelay. Le stockage ajouté est également actif dans la dernière session de God of War III (`BCES00510`), mais il ne concerne qu'un petit cache de bytecode CPU de shaders Vulkan. Il n'a ni évincé ni restauré de données dans cet essai. Son activité porte sur quelques Mio, contre environ 3,3 Gio d'empreinte du processus ; elle ne constitue pas une extension de plusieurs Gio pour le jeu.

L'incident visible à la fin est un arrêt des frames accompagné de deux attentes RSX d'environ deux secondes et d'un décodeur vidéo privé de consommateur. Les compteurs ne montrent pas d'épuisement mémoire. Il faut investiguer cette chaîne de synchronisation indépendamment de l'extension du stockage.

Les fichiers ne démontrent ni une donation physique de 8 Gio, ni un swap disque de la mémoire invitée, ni un crash ou un jetsam. Ils ne permettent pas non plus une comparaison de performances contrôlée entre deux builds.

## Sessions et activation du stockage

Le JSONL conserve plusieurs sessions : les lignes 1–44 appartiennent au build **395**, PID **760**, et les lignes 45–171 au build **396**, PID **933**. Les métriques du premier groupe ne doivent pas être attribuées au build 396.

| Source et lignes | Heure UTC | Session / événement | État du stockage shader |
|---|---|---|---|
| NeoSwap 45 | 21:49:21.323 | `process_start`, build 396, PID 933 | Préférence désactivée ; cache pas encore en session |
| NeoSwap 46 | 21:49:23.349 | GuestRelay prêt après sortie du créateur | Aucun backing invité utilisé à cet instant |
| NeoSwap 47–67 | À partir de 21:49:42.275 | Premier lancement `BCES00510` — God of War III | `requestedEnabled:false`, `active:false`, `reason:"disabled"` |
| NeoSwap 68 | 21:50:17.579 | `donation_session_end` | `reason:"session_ended"` ; prêts et backing invité reviennent à zéro |
| NeoSwap 70 | 21:50:26.659 | `shader_storage_preference`, résultat 0 | Préférence activée ; session encore inactive |
| NeoSwap 74–79 | 21:50:35.636–21:50:35.780 | Test de capacité de 64 Mio | Test diagnostique séparé du jeu |
| NeoSwap 81–85 | À partir de 21:50:57.309 | Lancement `BLES00113` | `requestedEnabled:true`, `active:false`, `reason:"unsupported_title"` |
| NeoSwap 86 | 21:51:04.345 | Fin de cette session | `reason:"session_ended"` |
| NeoSwap 88–171 | À partir de 21:51:09.205 | Nouveau lancement `BCES00510` — God of War III | `requestedEnabled:true`, `active:true`, `reason:"ready"` |

La préférence s'applique au lancement suivant (`appliesOnNextLaunch:true`). Le premier essai de God of War III a donc été exécuté sans stockage shader. L'autre titre `BLES00113` est explicitement exclu par la politique de ce build. En revanche, le dernier essai de God of War III a bien activé le cache : l'absence d'évolution ne peut pas être expliquée uniquement par une option restée désactivée.

## Donation et allocations effectivement utilisées

Les données de cette table correspondent au dernier échantillon NeoSwap, ligne 171, sauf mention contraire.

| Métrique | Valeur observée | Signification et limite |
|---|---:|---|
| Mémoire physique du téléphone | 7 989 460 992 octets, soit 7 619,344 Mio | Mémoire physique déclarée ; aucune RAM supplémentaire n'est créée |
| Objectif maximal de donation | 5 368 709 120 octets, soit 5 Gio | `donationGoalBytes` et `donationHardLimitBytes` ; plafond, pas utilisation effective |
| Cible effective / capacité préparée | 671 088 640 octets, soit 640 Mio | Politique `active_donor_loans_plus_bounded_reserve` |
| Prêts actuellement utilisés par RPCS3 | 529 383 424 octets, soit 504,859 Mio | `donatedClientBytes`, identique aux `liveBytes` du propriétaire `rpcs3` |
| Réserve préparée inutilisée | 141 705 216 octets, soit 135,141 Mio | `donationUnusedPreparedBytes` |
| Donneurs | 2, aucune perte | `donorCount:2`, `donorLostCount:0` |
| Mémoire résidente comptabilisée chez les donneurs | 523 943 936 octets, soit 499,672 Mio | Mesure des processus donneurs, pas une seconde quantité à additionner aveuglément aux alias hôte |
| Mémoire compressée comptabilisée chez les donneurs | 147 144 704 octets, soit 140,328 Mio | Les deux catégories totalisent les 640 Mio préparés dans cet échantillon |
| Empreinte des donneurs | 680 447 536 octets, soit 648,925 Mio | Inclut un coût de processus/comptabilité supplémentaire |
| Blocs vivants du système de prêt | 557 | `liveBlocks` |
| Allocations propriétaire RPCS3 | 953 | Aucun rejet signalé pour ce propriétaire |
| CPU buffers expérimentaux vivants | 174 964 736 octets, soit 166,859 Mio | Sous-ensemble des prêts ; ne pas additionner aux 504,859 Mio |
| CPU buffers, allocations réussies / demandes | 912 / 915 | 3 refus de politique et 3 fallback ; `poolMisses:0`, `pressureRefusals:0` |
| CPU buffers, backing disque | Désactivé | `diskFallback:false` |
| Nettoyage donation | OK | `pendingBlocks:0`, `pendingMappings:0`, `pendingRights:0`, `kernelResult:0` |

Les diagnostics RPCS3, notamment la ligne 1, confirment `swap_rpc_total_live=529383424`, `swap_rpc_shared_live=529383424`, 953 succès sur 956 tentatives et trois échecs. Les trois refus de politique du sous-système CPU sont cohérents avec ces compteurs globaux, mais leur correspondance exacte doit être vérifiée dans le code avant de présenter chaque échec comme un même événement.

Le champ agrégé `donorHeadroomBytes` vaut environ 13,3 milliards d'octets en fin de fichier, supérieur à la mémoire physique. Il reflète des marges rapportées par plusieurs processus ; il ne représente pas une quantité de RAM physique disponible que l'on pourrait additionner ou donner au jeu.

## GuestRelay : capacité, backing, alias et preuve CPU

| Métrique, NeoSwap 171 | Valeur | Limite de preuve |
|---|---:|---|
| Capacité annoncée / retenue | 8 589 934 592 octets, soit 8 Gio | Capacités de mappage déclarées ; pas une mesure de RAM physique résidente |
| Segments | 16 | `segmentCount` |
| Backing vivant | 1 020 788 736 octets, soit 973,5 Mio | `liveBackingBytes` ; quantité utilisée, pas capacité de 8 Gio touchée |
| Objets | 208 | `objectCount` |
| Alias | 581 | `aliasCount` |
| Octets mappés par les alias | 2 215 182 336 octets, soit 2 112,563 Mio | Plusieurs vues peuvent référencer le même backing ; ce total n'est pas autant de RAM indépendante |
| Résident / compressé | `null` | `residentBytesMeasured:false` |
| Octets touchés déclarés | 0 | Ce compteur ne démontre aucune mise en résidence de toute la capacité |
| Sortie du créateur | Observée | `creatorExitObserved:true`, `exitEvidence:"kernel_dispatch_proc_exit"` ; connexion et requête d'extension terminées |
| Échec de mapping / erreur OS / rejet | 0 / 0 / 0 | Aucun échec observé dans cet essai |
| Nettoyage en attente | 0 | `pendingCleanupEntries:0` |

Le test CPU associé, également conservé dans le champ `guestRelay.capabilityCheck`, a demandé **16 Mio**, obtenu `result:0` et `aliasDataVerified:true` après la sortie du créateur. Variation d'empreinte hôte mesurée : **16 408 octets**. Le champ `gameplayValidated:false` indique que cette vérification CPU ne valide pas, à elle seule, le comportement complet d'un jeu sous pression.

## Le test de capacité est limité à 64 Mio

NeoSwap lignes 74–79 :

1. `before`, `testedBytes:0`.
2. `written`, `testedBytes:67108864`.
3. `synced`, `testedBytes:67108864`.
4. `verified`, `testedBytes:67108864`.
5. `released`, `testedBytes:67108864`.
6. Événement `capacityProbe`, `result:0`.

La séquence dure environ **144 ms**. Le compteur racine `allocatedDiskBytes` monte au maximum à **64 Mio** pendant ce test et revient ensuite à zéro. Ce test prouve cette séquence d'écriture, synchronisation, vérification et libération à 64 Mio. Le champ global `capacityBytes:8589934592` n'étend pas cette preuve à 8 Gio.

Le compteur racine `allocatedDiskBytes:0` en fin de session ne signifie pas que le cache shader n'a pas écrit de fichier : son allocation est publiée séparément sous `shaderStorage.cache.allocatedFileBytes`.

## Stockage shader : activité réelle et absence d'éviction

NeoSwap ligne 171 décrit explicitement sa portée :

> `regenerable Vulkan shader CPU bytecode; GPU modules, guest memory and JIT unchanged`

`kernelSwapEnabled:false`. Les marqueurs déclaratifs `physicalIPhoneValidated:false` et `gameplayGainValidated:false` ne doivent pas être présentés comme des validations positives.

| Métrique, NeoSwap 171 | Valeur |
|---|---:|
| Budget RAM / disque | 8 Mio / 128 Mio |
| Entrées publiées | 58 |
| Taille logique | 1 873 288 octets, soit 1,787 Mio |
| Allocation du fichier | 1 654 784 octets, soit 1,578 Mio |
| Octets écrits | 1 183 821 |
| Appels d'écriture / erreurs d'écriture | 116 / 0 |
| Latence p95 écriture | 13 762 µs |
| RAM brute / capacité RAM compressée | 0,6875 Mio / 1 Mio |
| Pic RAM gérée | 1,875 Mio |
| Copies CPU libérées cumulativement | 2 654 208 octets, soit 2,531 Mio |
| Recherches / misses / hits | 349 / 349 / 0 |
| Compilations source | 355 |
| Lectures disque / disk hits | 0 / 0 |
| Restaurations / octets restaurés | 0 / 0 |
| Évictions / données uniquement sur disque | 0 / 0 |
| Refus de publication / backpressure | 214 / 206 |
| Refus de petites entrées | 74 |
| Pic de file / latence p95 de file | 16 / 121 654 µs |
| Pression / événements de pression | 0 / 0 |
| Erreurs I/O / corruptions | 0 / 0 |

Les compteurs sont pratiquement figés à partir de NeoSwap ligne 108, 21:51:42 UTC, jusqu'à la fin. Les entrées ne dépassent jamais le budget RAM ; aucune éviction ni restauration ne se produit. Le cache prépare donc un chemin de stockage, mais cet essai n'exerce pas un cycle de libération RAM puis rechargement utile au jeu.

Les 2,531 Mio représentent des copies CPU libérées **cumulativement** ; ils ne démontrent pas une baisse nette actuelle de l'empreinte de même montant. Une partie des données reste stockée en RAM compressée ou brute. Il faut mesurer le coût complet avant/après pour établir un bénéfice net.

## Performance et gel RSX

Le log RPCS3 couvre seulement **21:52:46.480–21:53:48.460 UTC**, soit environ 62 secondes. Il commence au milieu de la session et ne contient pas la demande de lancement ni la première frame.

Avant le gel, 51 échantillons actifs : **51,17–56,84 FPS**, moyenne arithmétique **54,23 FPS**. Les dix profils normaux indiquent environ 54,1–55,4 FPS moyens, 18,05–18,49 ms par frame, des SPU à 36,8–38,0 ms, et des PPU à 5,7–6,2 ms. Les métriques de sous-systèmes peuvent être cumulatives/concurrentes ; elles ne doivent pas être additionnées ou assimilées directement au temps d'une frame sans vérifier leur instrumentation.

| RPCS3, lignes | Heure UTC | Fait observé |
|---|---|---|
| 71 | 21:53:36.470 | Dernier échantillon actif, 56,59 FPS |
| 72 | 21:53:37.411 | Premier échantillon à 0 FPS ; RSX à 0 |
| 74 | 21:53:38.612 | `RSX acquire recovery exhausted; resuming FIFO`, adresse `0x60300510`, attendu `0x1548`, observé `0x1547`, attente **2 001 337 µs** |
| 76 | 21:53:40.362 | `rsx_semaphore_timeouts=1`, aucune récupération mémoire |
| 77 | 21:53:40.362 | `p99_ms=2003.131`, profil à 21,508 FPS moyens |
| 79 | 21:53:40.614 | Même attente RSX, adresse `0x60300510`, attendu `0x1549`, observé `0x1548`, attente **2 000 005 µs** |
| 83 | 21:53:43.994 | Décodeur vidéo attend un consommateur depuis cinq secondes ; `queue_size=60` |
| 86 | 21:53:45.401 | Nouveau timeout de sémaphore enregistré |
| 72–89 | Jusqu'à 21:53:48.460 | FPS restent à zéro |

Les messages exacts de récupération signalent qu'une reprise du FIFO a été tentée. Elle n'a pas rétabli les frames dans cet extrait. Le décalage attendu/observé d'une unité et le manque de consommateur vidéo justifient une enquête sur la progression du moteur/RSX et la consommation vidéo ; ils ne suffisent pas à attribuer la cause au menu PlayStation ou à GuestRelay.

Pendant l'incident :

- `memory_pressure_peak=0`, `memory_reclaims=0`, `memory_reclaim_effective=0` dans tous les profils de résilience.
- Headroom publié d'environ 3,2–3,4 Gio, empreinte autour de 3,3 Gio.
- Prêts et backing GuestRelay stables ; aucune perte de donneur ni erreur de mapping.
- Aucun manque de cache shader, nouvelle compilation de pipeline ou lecture du cache disque dans cette fenêtre.
- PID 933 continue de publier les échantillons jusqu'à la fin.

Ces indices ne soutiennent pas un épuisement mémoire comme explication immédiate du gel. Aucun crash ni jetsam n'est démontré. Le champ `jetsamCause:null` n'est pas un remplacement de rapport jetsam système et ne prouve pas l'absence de jetsam dans d'autres sessions.

## Limites de preuve

- Aucun essai A/B contrôlé sur la même scène avec le cache activé/désactivé n'est fourni. Les séquences mélangent builds, titres et sessions.
- La fenêtre RPCS3 ne contient pas les premières frames ; un temps de lancement fiable ne peut pas être calculé.
- L'heure de préparation des donneurs ne donne pas l'heure d'une demande de lancement utilisateur. Les délais d'interaction et d'émulation sont confondus sans événements dédiés.
- Les mappings/alias ne sont pas des mesures de mémoire physique résidente ; les mêmes pages peuvent être vues plusieurs fois.
- Le test CPU GuestRelay et le test de fichier de 64 Mio ne valident pas une capacité physique ou un swap invité de 8 Gio.
- Le log ne rapporte aucun événement d'ouverture du menu PlayStation, pause volontaire ou changement d'affichage. Leur lien éventuel avec le gel n'est donc pas établi.
- Les timings GPU sont `gpu_time_ms=-1`, avec plusieurs champs RSX/JIT à zéro : la capture ne permet pas une attribution détaillée du temps GPU.

## Pistes de correction ciblées

1. **Corriger le gel indépendamment du stockage.** Inspecter le traitement des sémaphores RSX à l'adresse observée, les transitions pause/reprise/arrêt et la chaîne vidéo. Vérifier qu'une récupération ne reprend pas le FIFO sans rétablir le producteur ou le consommateur attendu. Ajouter seulement les événements nécessaires pour distinguer ouverture de menu, pause demandée, attente RSX et arrêt de consommation vidéo.

2. **Conserver un seul menu en jeu.** Masquer le bouton PlayStation natif dans l'intégration RPCS3 et conserver l'accès aux commandes requises via le menu NeoStation. Ne pas confondre ce correctif d'interface avec une preuve de résolution du gel ; contrôler les transitions pause/reprise utilisées par le menu NeoStation.

3. **Aligner l'interface NeoSwap sur la preuve.** Présenter séparément plafond de capacité, prêts vivants, backing invité, empreinte et stockage réellement libéré. Ne pas afficher 8 Gio comme RAM ajoutée à partir du seul champ de capacité ou du test de 64 Mio. Rendre visible le motif `unsupported_title` et l'application au prochain lancement.

4. **Mesurer le bénéfice net du cache actuel avant de l'étendre.** Les quelques Mio stockés ne répondent pas à l'objectif de plusieurs Gio. Publier RAM réellement retenue, copies CPU libérées et restaurations utiles séparément. Le total libéré cumulatif ne suffit pas. Les nombreux refus de publication et la latence de file justifient une revue d'admission/backpressure, avec maintien d'une compilation source non bloquante.

5. **Chercher les grandes allocations avec un cycle de restitution exploitable.** Identifier dans RPCS3 les données CPU volumineuses, régénérables ou persistables, puis leur coût de libération et de restauration. Le bytecode shader de cet essai est trop petit. Toute extension doit respecter l'identité/adressage des données et les chemins qui les consultent ; remplacer arbitrairement des pages invitées ou du code JIT par un fichier peut violer les invariants de l'émulateur.

6. **Pour la piste MeloNX, comparer les primitives effectivement utilisées.** Distinguer tests de mapping/pression, extension donneuse, objet survivant au créateur et vrai mécanisme de backing disque/restauration. Un test de mapping qui réussit ne démontre pas un swap fonctionnel de plusieurs Gio en gameplay. Relier chaque idée retenue à un changement concret des grosses allocations RPCS3 plutôt qu'à une hausse de la capacité annoncée.

Ce rapport ne prescrit aucun test artificiel supplémentaire et n'a déclenché aucun build.
