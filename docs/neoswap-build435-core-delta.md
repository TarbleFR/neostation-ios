# Build 435 — delta du Core RPCS3 : enveloppe mesurée, compilation SPU différée, pré-comparaison du `writer_lock`

Demande du mainteneur du 10 octobre 2026 : appliquer au Core RPCS3 les trois
leviers proposés au § 7 de `docs/neoswap-build434-7go-envelope.md`, qui
exigeaient une reconstruction du Core. Les sources NeoStation (hôte,
bibliothèque de baseline 419, NeoSwap 434) sont inchangées ; seul le delta
canonique `build-utils/rpcs3/embedded-core.patch` et son manifeste changent.

## 0. Ce qui est démontré et ce qui ne l'est pas

- Démontré ici : les trois politiques s'exécutent sur l'hôte avec les en-têtes
  réels du Core (`test/rpcs3_build435_core_delta_test.py`), leur câblage dans
  les sites d'appel de production est vérifié par jetons, le delta se matérialise
  à partir de la source épinglée `XITRIX/rpcs3@22f1152` avec tous les
  hachages de postimage, et toutes les portes de périmètre passent localement.
- Non démontré : le comportement sur iPhone. Ni la résidence mémoire, ni
  l'absence de jetsam, ni le framerate de God of War III ne sont mesurés. Les
  chiffres ci-dessous sont des effets attendus à partir des mesures des Builds
  352, 411 et 412, à confirmer par les journaux du téléphone.
- Les licences des cœurs et le protocole de réservation ne changent pas.

## 1. Delta A — seuils de pression relatifs à l'allocation mesurée

Fichiers : `rpcs3/ios/IOSMemoryPressurePolicy.h`,
`rpcs3/ios/RPCS3IOSPerformance.{h,cpp}`, `rpcs3/Emu/RSX/VK/VKResourceManager.cpp`.

- Le Core estime l'allocation réelle du processus comme la marque haute de
  `phys_footprint + os_proc_available_memory()`, bornée par la RAM
  (`process_memory_limit_estimate()`, même définition que l'enveloppe hôte de
  la Build 434). Elle apparaît dans `COREPROF … limit_mib=`.
- Profil God of War III : l'étape modérée (purge récupérable des caches RSX)
  commence lorsque la marge passe sous **un quart de l'allocation**, plancher
  1 280 Mio (sortie sévère, échelle monotone), plafond 2 560 Mio (constante
  Build 352, conservée). Pour l'allocation mesurée de 6 676 Mio : 1 669 Mio de
  marge, soit une empreinte de 5 007 Mio au lieu de 4 116 Mio. Sévère
  (1 024 Mio) et fatal (512 Mio) restent absolus : ils couvrent la rafale
  d'allocation mesurée (≈ 200 Mio/s en transition de scène).
- Allocation inconnue (premier échantillon absent) : comportement Build 352.
  Profil par défaut : inchangé.
- Limiteur adaptatif : une passe modérée est jugée efficace si la marge a
  gagné ≥ 128 Mio depuis la passe précédente ; sinon le délai double
  (1,5 s/3 s → 6 → 12 → 24 s, plafond 24 s). Le cycle Build 412 (purge toutes
  les 2 s pendant 90 s, textures rechargées aussitôt) devient sept passes en
  90 s. La passe forte (sévère) toutes les 8 s suit le même recul. Fatal reste
  immédiat ; sévère reste à 125 ms.
- Journal : `iOS memory pressure is … (allowance estimate N MiB, moderate
  below M MiB)` et `iOS moderate reclaim freed nothing lasting … next pass in
  D ms`.

## 2. Delta B — compilation SPU différée avec repli interpréteur

Fichiers : `rpcs3/Emu/Cell/SPUDeferredCompilePolicy.h` (nouveau),
`SPUCommonRecompiler.cpp`, `SPURecompiler.h`, `SPUThread.h`,
`rpcs3/ios/RPCS3IOSPerformance.{h,cpp}`.

- Fait mesuré (Build 411) : 635 compilations LLVM en 9 s, chacune exécutée sur
  le thread SPU qui a manqué le dispatcher, d'où le blocage du SPU, des PPU qui
  l'attendent, et une image de 6,2 s.
- Nouveau chemin (`spu_recompiler_base::dispatch`, iOS) : après l'analyse sur
  le thread SPU, l'item est cherché dans le runtime (`add_empty`). Décision
  pure `classify_dispatch` :
  - module publié → saut direct ;
  - premier manquement → mise en file dans le pool « SPU Deferred » puis
    exécution par l'interpréteur existant sur la plage du programme ;
  - en file ou en cours ailleurs → interpréteur ;
  - échec définitif → interpréteur sur la plage (comportement d'échec existant) ;
  - pool absent, item relocalisé, analyse du pool divergente ou file saturée
    (256) → compilation inline Build 434.
- Pool : 2 workers sur 6 cœurs (3 à partir de 8), chacun avec son instance
  LLVM et un local store de travail, comme les workers de warmup ; le plus
  sollicité (hits du dispatcher) est compilé en premier. La publication passe
  par `spu_llvm_recompiler::compile()` (revendication, construction,
  installation, trampoline) : aucune seconde voie de publication.
- Sortie de l'interpréteur uniquement sur un branchement pris : à l'entrée du
  programme quand le module est publié, ou après 4 096 branchements (une boucle
  interne ne reste pas interprétée ; le dispatcher compile alors un programme
  depuis ce pc). Invariants : aucun pointeur exécutable publié avant
  finalisation, cohérence du cache d'instructions assurée par `compile()`.
- Télémétrie `SPUPROF` : `deferred_hits`, `deferred_queued`,
  `deferred_pending`, `deferred_failed_hits`, `deferred_inline`,
  `deferred_published`, `deferred_failures`, `deferred_wait_ms`,
  `deferred_wait_max_ms`, `deferred_build_ms`, `interp_entries`,
  `interp_instructions`, `interp_branches`, `interp_handoffs` ; journal
  `SPUDEFERRED pool started workers=…`.
- Interrupteur de compilation : `rpcs3::spu::deferred_compile_enabled`
  (aucun réglage, aucune interface, aucune chaîne traduite).

## 3. Delta C — pré-comparaison avant `vm::writer_lock`

Fichiers : `rpcs3/Emu/Cell/SPUThread.cpp` (PUTLLC, chemin complet),
`rpcs3/Emu/Cell/PPUThread.cpp` (stcx 128 octets), `RPCS3IOSPerformance.{h,cpp}`.

- Une réservation dont la ligne diffère déjà de l'instantané GETLLAR ne peut
  pas réussir : elle échoue avant de parquer tous les threads PPU. Seule la
  comparaison sous verrou peut réussir ; le protocole, `vm.cpp`,
  `vm_locking.h` et `vm_reservation.h` sont byte-identiques.
- `RANGELOCKPROF` gagne `wl_putllc_avoided` et `wl_ppu_stcx_avoided`. Lire
  ces compteurs avec `wl_putllc`/`wl_store128`/`wl_ppu_stcx`/`wl_resop` avant
  tout autre levier sur le verrou.

## 4. Non-régression et portes

| Vérification | Résultat local |
|---|---|
| `rpcs3/ios/tests/IOSMemoryPressurePolicyTests.cpp` étendu (static_assert) | PASS g++ 13 / clang++ 18 |
| `test/native/rpcs3_build435_core_delta_test.cpp` via `test/rpcs3_build435_core_delta_test.py` (ASan/UBSan) | PASS g++ et clang++ |
| `materialize_rpcs3_core.py` sur un clone frais de `22f1152` | PASS (143 postimages) |
| `rpcs3_build352_gow3_memory_test.py` (contrat du délai remplacé par le délai adaptatif, bases 1 500/3 000 ms conservées) | PASS |
| `preprocessor_balance`, `build301_passive_dlopen`, `atomic_startup`, `failed_startup`, `build264/351/353`, `armsx3_performance_patch` | PASS |
| `rpcs3_core_syntax_gate_test.py` (`SPUThread.cpp` et `VKResourceManager.cpp` ajoutés aux unités) | PASS |
| `check_neo_swap_scope.py` : étape Build 412 figée sur `afb33454`, étape Build 435 épinglée par empreintes de hunks | voir § 6 |
| `import_memory_candidate_scope_test.py` : ré-épinglage approuvé des quatre comparaisons dérivées | voir § 6 |

Le test `rpcs3_build435_core_delta_test.py` est ajouté à
`build_rpcs3_embedded_core.sh`, au pré-vol de `rpcs3-core.yml` et aux entrées
épinglées du Core (`neo_swap_core_pin_test.py`).

## 5. Ré-épinglage approuvé de la porte de périmètre

Sur demande du mainteneur (10 octobre 2026), les quatre comparaisons byte pour
byte dépassées par ses commits sont ré-épinglées sur le dernier commit ayant
touché chaque fichier, sans retirer d'assertion :

| Fichier | Ancien pin | Nouveau pin |
|---|---|---|
| `.github/workflows/neoplay-check.yml` | `12fb62f9` | `7416150d` (livraison 422) |
| `.github/workflows/ios-ci.yml` | `424a360` | `7416150d` |
| `.github/workflows/neoswap-ipa.yml` | `424a360` + lignes Build 410–421 | `afc0a96d` (restauration 419) |
| `packages/armsx2_internal_bridge/ios/Classes/Armsx2InternalBridgePlugin.mm` | `424a360` | `a5650b9b` (nettoyage) |

## 6. Identité de la livraison

Renseigné après les compilations (Core puis IPA 435).
