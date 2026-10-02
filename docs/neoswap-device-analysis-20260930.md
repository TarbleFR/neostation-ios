# NeoSwap — analyse des journaux appareil du 30 septembre 2026

Référence examinée : sources `618fb92a90285ea76547803828f8a0d66e257708`,
livrées dans la Build 369. Les sessions récentes du journal appareil portent
explicitement la **Build 368**, dont le Core RPCS3 et le chemin NeoSwap sont
identiques à ceux de la Build 369. Ces fichiers ne constituent donc pas un
test appareil de l'ensemble de la Build 369.

## Preuves reçues

- `RPCS3-diagnostic(20260930-143148).log` : 3 379 enregistrements JSON valides,
  avec un historique des Builds 363, 367 et 368. Les deux sessions Build 368
  contiennent 677 échantillons de performance, pour BLES00113 et BCES00510.
- `NeoSwap-v1.jsonl.previous` : 86 enregistrements JSON valides, tous du même
  PID hôte que la dernière session RPCS3 Build 368, du 30 septembre à
  15:56:43–15:56:54, heure de Paris. Il s'agit d'un fragment de journal après
  rotation, et non de toute la session.

Dans les deux sessions Build 368, `swap_attempts`, `swap_successes` et
`swap_rpc_shared_live` restent à zéro. Le compteur d'appels ignorés sous
1 Mio atteint 20 448 dans la première session, puis 469 638 dans la seconde.
Le journal NeoSwap confirme zéro demande RPCS3 et zéro allocation vivante.
Les huit donneurs finissent par préparer huit blocs vérifiés de 1 Mio,
mais aucun de ces blocs n'est prêté aux allocations du jeu.

## Deux défauts distincts examinés

Les sessions RPCS3 montrent des pertes et redémarrages de donneurs. Le fragment
NeoSwap contient l'erreur `donor_process_ledger_delta_exceeds_chunks` (3116),
y compris pour des slots dont le nouveau PID et la nouvelle génération sont
actifs et vérifiés. Le dictionnaire d'erreurs du plugin conserve l'erreur de
l'ancienne session après récupération : ce défaut de diagnostic est établi.
L'effacement doit attendre l'adoption, la vérification et les acquittements
du donneur actuel, sans laisser un callback d'une ancienne session changer
le diagnostic du nouveau donneur.

La mesure du helper soustrait séparément les catégories résidente et comprimée
de leur baseline, puis ramène chaque différence négative à zéro. Cette formule
peut rejeter un transfert entre catégories : avec une baseline de 32 Kio
résidents, un bloc vérifié de 1 Mio devenu comprimé peut être compté comme
1 Mio + 32 Kio, alors que l'augmentation totale reste exactement 1 Mio.
Le calcul doit compenser les diminutions entre catégories et conserver le
refus d'une augmentation totale réellement supérieure aux blocs vérifiés.
Les journaux ne contiennent pas les valeurs exactes au moment des anciens
échecs : ce défaut arithmétique est reproductible, mais son rôle dans chaque
échec 3116 observé reste à confirmer sur appareil.

## Objectif de 1 Gio réellement utilisé par RPCS3

Le raccordement actuel porte uniquement sur `rsx::aligned_allocator`, pour
les données CPU de 1 Mio ou plus. Les grosses allocations des heaps Vulkan
et du DMA utilisent un autre allocateur. Augmenter la préparation des donneurs
ou abaisser simplement le seuil ne raccorde pas ces allocations.

La piste suivante est l'import des blocs réellement donnés dans les buffers
Vulkan visibles par le CPU, en utilisant le chemin de pointeur hôte déjà
présent dans RPCS3. Elle nécessite une capacité explicite, distincte de l'ABI
CPU actuelle, la vérification de l'extension et de l'alignement sur l'appareil,
une acquisition RAM distinguée du repli par fichier, et une durée de vie liée
à la fin réelle des commandes GPU. Les prêts sont actuellement contigus et
bornés à 256 Mio par bloc ; atteindre 1 Gio doit correspondre au cumul de
buffers réellement utilisés, pas à un bloc de remplissage.

Le palier de 1 Gio en jeu n'est pas implémenté ni validé dans la Build 369.
Les corrections de mesure et de diagnostic sont préparées séparément de
ce raccordement et ne doivent pas être présentées comme une donation de 1 Gio.

La prochaine candidate est identifiée comme Build 370, pour conserver
l'identité de l'IPA Build 369 déjà livrée. Elle corrige le calcul des deltas
et l'effacement des erreurs après récupération vérifiée. Le test portable
couvre les transferts entre catégories, les dépassements réels, les débordements
et la preuve d'un nouveau bloc ; le simulateur exerce la méthode de production
du plugin avec de vrais donneurs et vérifie aussi les callbacks tardifs et les
erreurs encore actuelles. La validation native nécessite macOS/Xcode. Aucun
résultat appareil à 1 Gio n'est déduit de ces vérifications.

## Autres demandes de la mise à jour

- Dusklight 2.0.3 est intégré et son Core a été reconstruit dans la Build 369.
- Mario Kart Pad 0.7.2 n'est pas intégré : le Core 0.5.1 est conservé. La
  migration du runtime peut être préparée, mais sa validation complète exige
  un pack personnel `libkartpad_game.dylib` ABI 3 avec une empreinte compatible.
- Les corrections générales d'import de cheats Dolphin TXT/INI et ARMSX2
  PNACH sont présentes. Le dernier signalement GMXP70/r0 n'est pas confirmé
  comme résolu : le GCT binaire et son TXT source exacts ne sont pas disponibles.
- L'accès aux menus avec la manette a été annulé par le mainteneur.

## Preuve préalable à 1 Gio et compatibilité Metal

Une expérience CI séparée demande exactement 1 Gio de pages NONVOLATILE par le
même chemin NSXPC et les mêmes contrôles de headroom que les essais précédents.
Elle conserve les refus et valeurs réellement mesurées dans son rapport. Un
second essai à 128 Mio importe chaque chunk vérifié dans un `MTLBuffer` sans copie,
écrit sur les buffers avec une commande GPU, vérifie l'alias CPU et effectue
une relecture GPU. Les mappings restent vivants jusqu'à la fin des commandes
et à la libération des objets Metal ; une expiration termine le processus
de test sans libérer prématurément ses pages.

Le contrôle refuse de conclure à une donation GPU utile si les imports
augmentent fortement la charge mémoire du processus hôte. Un runner sans GPU
Metal est un échec de faisabilité documenté, pas une réussite simulée.
Cette expérience n'est compilée ni dans NeoStation ni dans le donneur livré.
Elle ne raccorde pas encore les heaps Vulkan de RPCS3 et ne démontre pas 1 Gio
en jeu sur iPhone. Le résultat matériel de cette preuve doit précéder le
raccordement des grosses allocations ; aucune réserve artificielle n'est
ajoutée au lancement du jeu.

Le premier essai (`1ad7c78`, run `36737143272`) a effectivement préparé
1 073 741 824 octets dans cinq chunks vérifiés. Le donneur mesurait
904 314 880 octets résidents et 169 426 944 octets comprimés. Le total est
exactement 1 Gio, mais l'assertion exigeant 1 Gio résident a échoué avant
l'import Metal. Ce résultat n'est pas une preuve de 1 Gio résident ni de RAM
utilisée par RPCS3. L'exigence résidente est conservée. L'essai Metal est ramené
à 128 Mio pour examiner séparément la compatibilité graphique. Le script
optionnel est aussi corrigé pour ne pas développer un tableau vide sous le
`nounset` du Bash 3.2 de macOS ; le chemin NSXPC habituel est revérifié.


## 2026-10-02 — Build392 logs / Build393 corrective candidate

The exported RPCS3 journal mixes Builds 380, 384, 386 and 392. This correction is based on Build392 PID 94933 and the matching NeoSwap journal; older relay failures are not attributed to this session.

Confirmed: a 480 MiB growth request was accepted by the manager/IPC but refused by the 256 MiB broker. Two 16 MiB startup seeds were below the 64 MiB boot threshold; both recorded waits expired after 1.5 seconds with 48 MiB prepared. The candidate uses 64 MiB seeds, a shared native 256 MiB block bound, 128 MiB fallback, and reserves outstanding requests against the real system budget. The aggregate ceiling remains 5 GiB, not a preallocation or residency claim.

A GoW3 sample contains 51,380,224 bytes of live donor loans, 303,038,464 bytes of file fallback, 939,524,096 bytes of prepared pool and 1,020,788,736 bytes of unique live relay backing. The relay reports physical residency as unknown. The two-series graph therefore reports 1.072168960 decimal GB allocated through microprocess backends and 2.264317952 GB in the host resident counter for that sample. It does not add alias mappings, unused capacity, pool preparation or compressed-page equivalents. The curves are separate measures, not additive physical-RAM totals across processes.

The 113-sample GoW3 summary mixes loading/menus/gameplay and is not a benchmark. Its recorded manual exit warning is not proof of an out-of-memory crash. All actual emulator cores and relay/JIT lifecycle sources stay unchanged. On-device improvement, full 5 GiB residency and FPS gains remain unvalidated.


## 2026-10-02 — Build393 GoW3 follow-up / Build394

**Source separation.** `RPCS3-diagnostic(20261002-131705).log` has 1,631 valid JSON records, including 1,164 for Build393/PID97610 and older Build392 sessions. The last GoW3 session records 231 performance samples and ends with an unresponsive exit request, session closure and restored frontend audio. This is not a jetsam/crash backtrace. `NeoSwap-v1(5).jsonl` contains 40 records from the last approximately 16 seconds only; its rotated predecessor was not supplied. No crash cause or absence of an earlier crash is inferred from that truncated history.

**Observed allocation coverage.** Active donor loans are 135,266,304 bytes and unique live relay backing is 1,020,788,736 bytes, producing the displayed 1.156055040 decimal GB. There are no queued/inflight donation demands in this tail. Prepared donor backing is 939,524,096 bytes, so 804,257,792 bytes are not active loans. Of the ordinary NeoSwap-routed buffers, 219,152,384 bytes use file fallback. Filling an unused pool to 5 GiB cannot migrate these already published buffers or host JIT/private GPU allocations. The host process peaks at 3,519,027,264 footprint bytes in the last GoW3 summary; its process headroom is not device-wide free RAM.

**Confirmed source regression and test reproduction.** Build393 Backend::map re-applies both pressure and full-object headroom admission to every alias. After the first successful relay map, the canonical RPCS3 shared-memory client cannot choose file fallback without splitting coherent aliases. A new executable regression fails on the old backend exactly at the second map under pressure. Build394 records whether an object has ever published an alias, retains this ownership through temporary removal of all views, and admits later coherent aliases without charging backing a second time. First-map/new-object admission, live-token ownership, fixed-address checks, alias-count limits, retirement and actual kernel-map errors remain enforced. Unit tests cover failure atomicity, data preservation, a new slot-generation first-map refusal and sticky diagnostics. The mandatory macOS real-kernel probe also checks additional coherent aliases under pressure while refusing new backing. This reproduces/fixes a source bug, not proof that it caused the reported iPhone crash.

**Focused startup and memory policy.** Two helpers request 256 MiB initial verified chunks instead of 64 MiB. RPCS3's degradable boot seed is 384 MiB, still bounded by the existing 1.5-second maximum; it does not wait for 5 GiB. Steady-state growth is based on active donor loans plus a 128 MiB reserve, never on file-backed allocations, with the retained 512 MiB warm floor and 5 GiB aggregate ceiling. The supplied 135,266,304-byte donor use therefore targets 512 MiB, not 896 MiB. These figures describe policy and tests, not an observed new iPhone result.

**UI and evidence.** Live FPS are restored above the two decimal-GB memory series, including valid zero-FPS stalls and unavailable/NaN handling. Structural donor events are logged immediately; unchanged ledger heartbeats no longer write duplicate full JSON records, while the two-second detailed samples remain. Build numbers, idle-prepared bytes and persistent relay pressure/map-failure counters are included. No Core ABI, JIT helper, saved data, game assets, public release or baseline reference is modified.


## 2026-10-02 — Build395, first allocation-coverage experiment

This is the first implementation step after Build394, not an iPad kernel-swap port and not a five-gigabyte game-memory result. Apple describes Virtual Memory Swap as using device storage. This candidate keeps the distinction between physical residency, compressed accounting, shared data and file fallback. Official references: https://www.apple.com/newsroom/2022/06/ipados-16-takes-the-versatility-of-ipad-even-further/ and https://developer.apple.com/documentation/xcode/responding-to-low-memory-warnings .

The prior GoW3 evidence shows 1.156055040 decimal GB active in donor/relay paths and 219152384 bytes in file fallback. No new Build394/395 device logs have been supplied. The current implementation cannot claim that filling a five-GiB donor pool would move all LLVM/JIT/private GPU allocations out of RPCS3.

The first added allocation family is the RSX aligned CPU buffer path from 64 KiB inclusive to 1 MiB exclusive. Its Core helper uses the existing ABI-1 CPU_CACHE kind. Only the six existing God of War III title IDs enable the host experiment. All other titles, tiny buffers, disabled mode, unavailable donor pool or pressure take the original heap path. These requests never allocate per-buffer files, wait for a helper, force compression or migrate a published pointer. Larger CPU buffers and the Vulkan threshold/import/lifetime contracts remain unchanged.

The metadata budgets are separated: 256 original large-allocation slots remain reserved, with 768 extra small-buffer slots and a 512 MiB maximum of live small loans. This is a cap, not a preallocation. The donor manager still grows on genuine routed use plus its bounded spare, within the unchanged five-GiB aggregate ceiling and measured system headroom. Both dispatch memory-pressure warnings and current background headroom close new small-buffer admission. Existing mappings/releases remain valid under pressure and after the experiment is disabled.

The cpuBufferExperiment diagnostic object reports requested sizes, successful donor loans, live/peak bytes, ordinary-heap fallback count, pressure/policy refusal counts, pool misses and four size bins. These counters describe cumulative independent samples; they must not be added to owner_donated_live_bytes again. The on-screen FPS and two memory curves are preserved.

Tests use three separate layers: the production broker with injected donor operations (including 768/256 slot isolation, 512 MiB cap, cleanup failure, pressure and data-copy behavior); the exact materialized Core allocator using that injected pool; and the existing real macOS donor/kernel campaign expanded with a real 64 KiB shared-page alias check. No injected test is physical-memory proof. Existing Vulkan, relay, JIT, game-memory/savestate and packaging tests remain mandatory. Compiling the new Core is required; the previous binary must not be used with a new-source identity.

Next measurements: compare the same cold-cache and warm-cache GoW3 sequence with Build394 and this candidate. Record time to menu/gameplay, frame-time tail, CPU-buffer active peak and fallback bytes, donor/host resident and compressed categories, plus .ips/JetsamEvent on termination. Stop growing optional caches under pressure. Game-file prefetch, cold-cache compression/storage eviction and a dedicated live five-GB device probe are not implemented by this first lot; they require measured allocation/access coverage before expansion.


### Build395 packaging and hot-path regression

The source Core candidate is `f73ac8f26953fcdd244003981936b74482482626`, workflow `37022595373`. The IPA gate requires that exact Core run to succeed and its source/recipe/ABI/binary hashes to match before installation. No old Core can exercise the new CPU allocator call. The final host changes do not alter any Core-pinned input.

Increasing the bounded loan table exposed a quadratic free-gap scan in the host pool. Replaced it with fixed-slot per-entry offset-ordered links: each occupied interval is visited once, no heap allocation or IPC is added to acquisition. A new ASan/UBSan test links production Pool.cpp with explicitly injected map ownership and exercises all 1,024 slots, mixed alignment, 3,000 fragmented churn operations, head/middle/tail reuse, retained live data after donor loss, cleanup failures and a new campaign. A synthetic Linux/O2 burst of 768 retained 64-KiB loans measured 298.172 ms before and 2.765 ms after in one paired run. This is metadata/allocation microbenchmark evidence only, not iPhone loading or FPS evidence. Actual donor/kernel tests remain mandatory.


### Build395 CI recovery — cancelled prerequisite, not a compiler diagnosis

IPA run 37024031181 stopped at the exact-Core gate because required run 37022595373 was cancelled after the host-integration push. The former workflow-wide shared concurrency group used cancel-in-progress=true before the build-job skip condition. Move concurrency into the actual Core job, isolate source SHAs and disable running-build cancellation. The source contract rejects the old scheduler and checks both protections. Runtime, capacity policy and game data are unchanged. A new exact-input Core must be built and its successful run pinned before packaging; never substitute the Build394 Core.
