# NeoSwap Build 409 — contrôleur de budget global et prêts hôte du relais

Candidat privé préparé le 6 octobre 2026 sur `experimental`. Il ne modifie ni
`main`, ni `backup`, ni la baseline Build 350. Les Builds 402 à 408 ont été
consommés sur `feature/fast-candidate` ; le prochain numéro libre est 409.

Ce document sépare strictement : les défauts et limites établis dans les
sources, les mécanismes implémentés, les tests exécutés sur cette machine
Linux, les tests qui ne peuvent s'exécuter qu'en CI Apple, et la validation
iPhone, qui reste à faire. Aucun gain de RAM, de FPS ou de stabilité sur
iPhone n'est démontré par ce candidat.

## 1. État de départ établi dans les sources

| Chemin | Mécanisme réel | Capacité | Consommateur RPCS3 | Limite établie |
|---|---|---|---|---|
| Relais de pages invitées (`NeoSwapPageRelay.appex`) | 16 objets nommés de 512 Mio créés avec `MAP_MEM_NAMED_CREATE \| MAP_MEM_LEDGER_TAGGED`, droits transmis par NSXPC, sortie du créateur observée par `DISPATCH_PROC_EXIT`, vues `vm_map` | 8 Gio retenus | mémoire invitée `utils::shm` (`guest_data`) uniquement | 973,5 Mio vivants mesurés (Build 392–396) ; résidence physique non mesurée |
| Donneurs (`NeoSwapDonor.appex`, jusqu'à 8 processus) | objets purgeables NONVOLATILE possédés par des processus vivants, vérification page par page et par ledgers | plafond 5 Gio, blocs ≤ 256 Mio contigus | buffers CPU RSX ≥ 64 Kio (GoW3 seulement pour < 1 Mio), buffers Vulkan hôte-visibles 1–256 Mio | 135–505 Mio prêtés mesurés ; plancher chaud de 512 Mio préparé même sans usage |
| Fichiers (NeoSwap v1) | fichiers privés préalloués, `MAP_SHARED \| MAP_FIXED` | 8 Gio | repli des allocations ≥ 1 Mio | 219–303 Mio en repli mesurés |
| Stockage (shaders, GLSL, images VDEC) | `Store` fichier anonyme, CRC32, LZ4 optionnel, leases | 128 Mio par domaine | SPIR-V, GLSL, pixels YUV420 des images anciennes | 634 Mo archivés / 406 Mo restaurés cumulés en une session ; attentes FIFO jusqu'à 169 ms reproduites |

Constats de code exploités par ce candidat :

- Le relais est le seul mécanisme du dépôt dont les pages ne sont pas facturées
  à l'empreinte du processus hôte (le contrôle de capacité mesure moins de
  4 Mio de variation d'empreinte pour 16 Mio écrits). Il n'était utilisé que
  pour la mémoire invitée : environ 7 Gio de capacité retenue restaient inertes.
- Les budgets étaient fixes : plancher donneur 512 Mio, réserve 128 Mio,
  quota CPU 512 Mio, seuils vidéo 1 Gio / 1,5 Gio, sans vue d'ensemble.
- `release()` du courtier parcourait linéairement 1 024 emplacements sous mutex
  à chaque libération RSX.
- Les allocations Vulkan et RSX CPU partageaient le type `CPU_DATA` : le hôte
  ne pouvait pas attribuer un segment à un consommateur identifiable.

## 2. Architecture livrée

```
                 ┌────────────────────────────────────────────────────┐
                 │ NeoSwapPlugin (timer 250 ms, file série diagnostics) │
   mesures ───▶  │  applyBudget : neostation::budget::decide(Inputs)    │
                 └───────┬──────────────┬──────────────┬───────────────┘
                         │              │              │
          quota + admission      plancher/réserve   shrink
                         ▼              ▼              ▼
   ┌─────────────────────────┐  ┌──────────────┐  ┌────────────────────┐
   │ Courtier NeoSwap.cpp    │  │ Gestion des  │  │ NeoSwapStorage     │
   │ allocate(owner,kind,…)  │  │ donneurs     │  │ VideoMemoryNeed    │
   │ 1. prêt hôte relais     │  │ (adaptive    │  │ budget_shrink      │
   │ 2. prêt donneur         │  │  target)     │  └────────────────────┘
   │ 3. fichier (≥ 1 Mio)    │  └──────────────┘
   └───────────┬─────────────┘
               ▼
   ┌─────────────────────────┐
   │ Backend relais (owner 1)│  quota par propriétaire, part réservée invité
   │ objets nommés retenus   │
   └─────────────────────────┘
```

### 2.1 Contrôleur de budget (`packages/neo_swap/ios/Classes/NeoSwapBudget.h`)

Politique pure (aucun appel noyau, aucune allocation), exécutée par
`test/neoswap_budget_test.cpp` sous ASan/UBSan. Entrées mesurées toutes les
250 ms : session RPCS3 active, mémoire physique, `phys_footprint` et
`os_proc_available_memory()` du hôte, échantillon système du noyau
(`donation::system_headroom`, pages libres + purgeables ou estimation
`memorystatus`), niveau de pression noyau et dispatch, état thermique,
capacité et occupation du relais (invité / hôte), état du pool donneur,
octets en repli fichier et vidéo archivée vivante. Rôle du ledger du
processus : `phys_footprint` n'est qu'exporté et affiché (les pages relais et
donneurs n'y sont pas imputées) ; `os_proc_available_memory()` sous la
réserve opérationnelle demande l'archivage anticipé au stockage, seule
action qui réduit l'empreinte du processus. Une mesure processus absente ne
ferme rien : l'échantillon système reste l'autorité.

Sorties appliquées :

| Sortie | Définition |
|---|---|
| `operational_reserve_bytes` | `clamp(physique/16, 256 Mio, 768 Mio)`, doublée sous pression ou thermique sérieuse |
| `growth_room_bytes` | marge système mesurée moins la réserve ; 0 si la mesure est absente |
| `guest_reserve_bytes` | part du relais réservée à la mémoire invitée : `max(1 536 Mio, invité vivant)` |
| `host_loan_quota_bytes` | plafond des prêts hôte : `min(prêts vivants + marge, capacité − réserve invité)`, jamais sous les prêts vivants |
| `host_loans_admitted` | nouveaux prêts admis seulement avec ≥ 64 Mio de marge mesurée |
| `small_cpu_admitted` | buffers RSX 64 Kio–1 Mio admis si relais ou donneurs disponibles et ≥ 128 Mio de marge |
| `donor_floor_bytes` / `donor_reserve_bytes` | 0 / 64 Mio quand le relais sert ; 512 / 128 Mio sinon (comportement précédent) |
| `donor_room_bytes` | marge restant aux donneurs dans l'échantillon après la part accordée au plafond relais : `marge − (plafond − prêts hôte vivants)` ; une même marge n'est jamais accordée deux fois |
| `donor_growth_admitted` | croissance donneur admise seulement si `donor_room_bytes` atteint le quantum (64 Mio, 32 Mio en `growing`) ; `nextDonationBudget` plafonne la demande par `donor_room_bytes` |
| `storage_shrink_requested` | archivage vidéo anticipé sous la réserve système, sous pression, ou quand `os_proc_available_memory()` passe sous la réserve opérationnelle |
| `mobilized_bytes` | relais invité + relais hôte + prêts donneurs : intervalles vivants hors empreinte hôte |

États : `idle`, `warming` (relais absent, donneurs), `growing`, `holding`,
`shrinking` (hystérésis jusqu'à 1,5 × réserve), `growing`/`holding` (admission à un quantum de 64 Mio de marge mesurée, sortie seulement sous 32 Mio, pour qu'une gigue d'échantillon ou les octets rendus par une maintenance ne fassent pas basculer l'état à chaque tick), `pressure` (fermeture, prêts
vivants conservés). Aucune sortie ne révoque un prêt vivant.

### 2.2 Prêts hôte adossés au relais (`NeoSwap.cpp`, `Backend.cpp`)

- Nouveau propriétaire relais 1 (`host_loan_owner`) à côté de l'invité (0),
  avec quota par propriétaire dans le backend (`set_owner_quota`) : la part
  invitée ne peut pas être consommée par les données hôte.
- Ordre de service du courtier pour RPCS3 : prêt hôte relais (vue
  `vm_map` ANYWHERE 64 Kio) → prêt donneur → fichier (≥ 1 Mio uniquement).
- Limite connue : un plancher donneur abaissé par le contrôleur arrête la
  croissance du pool mais ne rend aucune page déjà préparée ; le pool n'est
  vidé qu'à la fin de la session (`retireDonorsIfIdle`). Le retrait de
  pages préparées en cours de session demanderait une API de réduction
  du pool côté donneur, non livrée ici.
  Les refus relais retombent sur les chemins existants ; les images vidéo et
  les petits buffers n'utilisent jamais de fichier.
- Cache de réemploi borné : 32 entrées, 128 Mio, 2 s. Les âges sont mesurés sur l'horloge monotone du courtier, celle qui horodate les libérations (`NeoSwap_RelayLoanMaintain(0, …)`) ; le cache n'est vidé qu'en l'absence de session, en `shrinking` ou en `pressure`, jamais en `holding`. Une libération conserve
  la vue mappée et la requête identique suivante la reprend sans parcours du
  backend ni effacement. Vidé à la fin de session et quand l'admission se ferme.
- Index d'adresses à adressage ouvert (effacement par décalage arrière) :
  `release()` ne parcourt plus les emplacements.
- Table d'emplacements : 256 + 768 historiques, plus 1 024 dédiés aux prêts
  relais.
- Compteurs par consommateur (`NeoSwapRelayLoanStats`) : octets vivants, blocs,
  allocations, refus par type, réemplois, cache, padding (arrondi 64 Kio),
  échecs de libération, dernier résultat backend.

### 2.3 Consommateurs RPCS3 raccordés (patch Core, trois en-têtes)

Types additifs sur l'ABI allocateur 1 inchangée (`NeoSwapClient.h`) :
`NEOSWAP_GPU_HOST_VISIBLE = 3`, `NEOSWAP_VIDEO_FRAME = 4`, avec
`try_allocate_kind()`. Un hôte plus ancien répond `NEOSWAP_INVALID` et le Core
garde son allocateur d'origine.

| Consommateur | Fichier Core | Type | Repli |
|---|---|---|---|
| Buffers CPU RSX alignés ≥ 1 Mio | `aligned_malloc.hpp` (inchangé) | 1 | heap aligné |
| Buffers CPU RSX 64 Kio–1 Mio, tous titres | `aligned_malloc.hpp` (inchangé), porte hôte | 2 | heap aligné |
| Buffers Vulkan SYSTEM hôte-visibles cohérents 1–256 Mio | `NeoSwapVulkanBuffer.h` | 3 | VMA |
| Images VDEC logicielles possédées (YUV420, 4 Kio–4 Mio) | `NeoSwapStorage/VideoBuffer.h` | 4 | mapping anonyme |

Les images Vulkan, le JIT, la mémoire invitée mutable et les ressources GPU
en vol ne sont pas redirigés. Le modèle mémoire invité n'est pas modifié.

### 2.4 Stockage

`VideoMemoryNeed` reçoit l'entrée `budget_shrink` : l'archivage des pixels
froids commence quand le contrôleur mesure une marge système sous la réserve,
avant que la marge du processus seule ne l'exige. Les refus sous pression,
en arrière-plan ou avec mesure périmée sont conservés. Les images vivantes
empruntent désormais en priorité des pages relais (type 4), ce qui réduit le
besoin d'archiver sur disque quand le budget est disponible.

### 2.5 Mesures et affichage

- JSONL `Documents/Diagnostics/NeoSwap-v1.jsonl` : objets `budget` (décision,
  raison, entrées, quotas, prêts relais par type) et `neoswapContribution`
  (empreinte hôte, marge hôte, relais invité, relais hôte, donneurs, fichiers,
  vidéo archivée, total). Événement `budget_decision` à chaque changement
  d'état ou de raison, au plus quatre fois par seconde.
- `guestRelay` : `guestLiveBackingBytes`, `hostLoanLiveBackingBytes`, pics,
  `hostLoanQuotaBytes`, `hostLoanQuotaRefusals`.
- Overlay RPCS3 : nouvelle ligne « fourni par NeoSwap » (prêts hôte relais +
  prêts donneurs, hors pages invitées), clé `memoryNeoSwap` dans les douze
  catalogues natifs.
- Panneau Flutter NeoSwap : six clés (`budgetSummary`, `budgetBreakdown`,
  `budgetState`, `budgetQuota`, `budgetNote`, `relayLoanKinds`) dans
  `native/neoswap/localizations.json` et `lib/l10n/neoswap_locale.dart`,
  douze langues, substitutions vérifiées par `test/neo_swap_locale_test.dart`.

Définition des unités : tous les compteurs `*Bytes` sont des octets
d'intervalles de mémoire alloués ou vivants. Aucun n'est une mesure de pages
résidentes ; `residencyMeasured` vaut `false`. Les compteurs cumulés
(`allocationCount`, `cacheFlushes`, refus) ne doivent pas être additionnés aux
octets vivants.

## 3. Tests exécutés sur cette machine (Linux, g++ 13 / clang 18, ASan/UBSan)

| Test | Résultat |
|---|---|
| `test/neoswap_budget_test.cpp` | PASS : six états, bornes de quota, réserve invité, hystérésis, sommes saturantes |
| `test/neoswap_relay_loans_test.cpp` (courtier + backend de production, fixture fichiers partagés réels) | PASS : types 1–4, portes d'admission/quota/vidéo, cache de réemploi, maintenance, propriété après échec de `unmap`, repli fichier, porte petits buffers, 371 allocations relais et 649 fichiers en churn aléatoire, index d'adresses, fin de session |
| `test/relay_backend_test.cpp` | PASS : quotas par propriétaire ajoutés, contrat précédent remplacé (le propriétaire 1 était « non supporté ») |
| `test/neoswap_test.cpp`, `neoswap_cpu_buffers_test.cpp`, `neoswap_capacity_probe_test.cpp`, `neoswap_client_stats_test.cpp`, `neoswap_usage_policy_test.cpp` | PASS |
| `test/rpcs3_neoswap_vulkan_buffer_test.py` et `test/rpcs3_neoswap_relay_test.py` sur la source Core matérialisée | PASS |
| `test/rpcs3_video_frame_archive_test.py` (FFmpeg 6.1 Ubuntu, 60 images H.264 réelles) | PASS : 52 images archivées, 73 908 224 octets réellement démappés, sans API NeoSwap installée (repli anonyme) |
| `test/neoswap_source_work_test.py` | PASS, y compris l'entrée `budget_shrink` |
| `build-utils/materialize_rpcs3_core.py` sur un arbre amont propre, `test/neo_swap_core_pin_test.py --source-only --source-root` | PASS : patch régénéré pour trois sections seulement, 138 empreintes vérifiées |
| `test/check_neo_swap_scope.py` (étapes Core, manifeste candidat remplacé par un stub local) | PASS : nouvelle étape Build 409 bornant le delta Core aux trois en-têtes |
| `test/rpcs3_neoswap_localizations_test.py` (couverture source) | PASS 12 × 18 clés ; l'exécution Foundation exige macOS |

Non exécutables ici : Objective-C++ (`NeoSwapPlugin.mm`, `NeoSwapRelayService.mm`,
overlay), Flutter (`neo_swap_dialog_test.dart`, `neo_swap_locale_test.dart`),
sonde Simulator, campagnes macOS NSXPC/noyau. Ils restent obligatoires dans
`neoswap-check`, `neoswap-relay-check`, `neoswap-storage-prototype` et le
workflow IPA.

## 4. Gates CI et épinglage

- `neoswap-check.yml` compile et exécute `neoswap_budget_test.cpp` et
  `neoswap_relay_loans_test.cpp` (courtier + `Backend.cpp` + `Broker.cpp`).
- `rpcs3-core.yml` doit reconstruire le Core : `embedded-core.patch`,
  `canonical-source.json` (`patch_sha256`
  `7db1bb716f2d9c3de48e1dd091b5f4f920a999707070632a207835a4663026d5`, bloc
  `neoswap_host_loans`), `native/neoswap/NeoSwapClient.h`,
  `native/neoswap-storage/VideoBuffer.h` et `test/neo_swap_core_pin_test.py`
  ont changé. Le run réussi devra être épinglé (`RPCS3_CORE_HOST_SHA`,
  `RPCS3_CORE_RUN_ID`) dans `neoswap-ipa.yml` avant tout packaging.
- `neoswap-ipa.yml` passe à Build 409 et exige le Build 401 packagé
  (run `37135708903`, commit `905461854998c65e1b884cabfedd7b46060c701b`).

### 4.1 Résultats du premier passage CI (commit `1a307a0`)

Verts : `neoswap-vulkan-proof`, `neoswap-donation-check` (ipc, kernel,
stress), relay-check étapes backend/1 GiB/8 GiB/link arm64, Core étape
« Validate startup contracts ». Le run Core `37491042733` a démarré la
compilation.

Rouges, tous dus à des contrats de texte source ou à des listes de fichiers
figées, corrigés à la source dans le commit suivant :

| Workflow | Cause | Correction (test du nouveau comportement) |
|---|---|---|
| `neoswap-check` étape donneurs | `neoswap_donor_contract_test.py` attendait `donationWarmFloorBytes` fixe et `SetCPUBufferExperiment(donors() && titre)` | assertions sur `donorFloorBytes`/`donorReserveBytes` (repli fixe avant décision, valeur du contrôleur ensuite), refus `global_budget_refused_growth`, admission `relay() \|\| donors()` |
| `neoswap-storage-prototype` | `neoswap_shader_storage_host_test.py` comptait 4 gardes `NEOSWAP_SHADER_STORAGE` | 6 gardes, les deux nouvelles (lecture vidéo archivée, `SetBudgetShrink`) vérifiées sous garde |
| `neoswap-research-check` | le harnais C++ extrait `adaptiveDonationTarget`, qui appelle désormais `[self donorFloorBytes]` | le harnais extrait aussi les deux accesseurs, exécute leurs corps de production et ajoute les cas budget (plancher 0 / réserve 64 Mio → 128 Mio ; pression → 0 ; profil research → 16/32 Mio) |
| `neoswap-donation-check` simulateur | copie figée des en-têtes sans `NeoSwapBudget.h` | en-tête ajouté aux deux listes |
| `neoswap-relay-check` simulateur | contrat « propriétaires 1–5 désactivés » | propriétaire 1 activé et exercé (prêt hôte réel écrit, split `guest`/`hostLoan`, refus de quota compté, libération à zéro), propriétaires 2–5 désactivés ; fixtures `relay_extension`/`evidence_lifecycle` complétées |
| `neoplay-check`, `cheats-media-check`, `neoswap-check` scope | gates verrouillées par hachage (autorisées par le mainteneur le 6 octobre 2026) | voir 4.2 |

### 4.2 Gates verrouillées mises à jour (autorisation explicite du mainteneur)

- `test/import_memory_candidate_scope_test.py` : cible Build 409 ;
  `NeoSwapBudget.h` en production, document et deux tests en support ; le
  contrat de genre `(kind != CPU_DATA && kind != CPU_CACHE)` remplacé par
  `!host_kind_supported(kind)` et les quatre genres ; `neoswap-ipa.yml`
  comparé à la révision ARMSX2 `424a360` après seize remplacements de ligne
  explicites (numéro de build, Build 401 requis, nom d'artefact), chacun
  appliqué exactement une fois ; masque de propriétaires 3 ; bloc
  `global_budget` du manifeste (genres, entrées mesurées, budgets fixes
  remplacés, aucune validation appareil ni maximum mesuré).
- `native/import-memory-candidate.json` : empreintes et modes régénérés pour
  211 fichiers de production et 164 de support, trois postimages Core alignées
  sur `canonical-source.json`, run Build 401 comme build précédent.
- `test/neoplay_build397_integration_test.py` : empreinte du bridge après la
  fusion `swap` et Build 409 ; ensembles approuvés séparés pour la fusion
  `swap`, l'intégration ARMSX2 (octet pour octet sur `424a360`) et Build 409 ;
  chaînes Build 409 / Build 401 / run `37135708903`.

### 4.3 NeoPlay dans la 409 (décision du mainteneur du 6 octobre 2026)

La 409 ne contenait NeoPlay qu'au niveau du Build 401. Les Builds 402 à 408
(branche `feature/fast-candidate`, supprimée, dernier commit `6674c2a`) ne
sont pas dans `experimental`. Sur décision du mainteneur, la branche
`neoplay-v2-frames` (trois commits : encodeur VideoToolbox par image,
PCM brut, négociation récepteur par l'indicateur `frames`, taille d'encodage
indépendante de la fenêtre du récepteur, 12 bit/px/s, profil High sur la
voie Windows ; dix fichiers, aucune entrée Core) est fusionnée dans
`experimental`. Aucune chaîne visible n'est ajoutée (journaux techniques
`NPLog` seulement), donc aucune traduction nouvelle. Les gates NeoPlay et
le manifeste candidat prennent cette révision comme référence du bridge.

Reste avant l'IPA : succès du run Core, épinglage (`RPCS3_CORE_HOST_SHA`,
`RPCS3_CORE_RUN_ID`, paire de remplacement supplémentaire dans le test
candidat), puis commit `[neoswap-ipa] [rpcs3-host-integration]`.

## 5. Protocole de validation sur iPhone 16 Pro Max (God of War III)

À chaque palier, même appareil, même version du jeu, mêmes réglages, mêmes
caches, lancement à froid :

1. Lancement, menu, première cinématique, premier combat, deux cycles
   fermeture/relancement.
2. Exporter `NeoSwap-v1.jsonl` et le diagnostic RPCS3 ; relever
   `neoswapContribution` (empreinte hôte, relais hôte, relais invité,
   donneurs, fichiers, vidéo archivée) et `budget` (état, raisons, refus).
3. Comparer FPS, p95/p99 des temps de trame et pauses longues avec Build 401.
4. Vérifier `relayHostLoans.releaseFailures = 0`, `quarantinedFixedAliasCount = 0`,
   `cacheFlushes` et `reuseHits` cohérents, et l'absence de `.ips` jetsam.
5. Palier suivant seulement si l'intégrité et la stabilité sont établies.

Paliers attendus : prêts hôte 256 Mio, 1 Gio, puis plafond mesuré par la
marge système. L'objectif de 8 Go reste une capacité de travail du relais ;
la RAM physique réellement mobilisée est bornée par la marge système mesurée
et doit être lue dans les journaux, jamais déduite des quotas.
