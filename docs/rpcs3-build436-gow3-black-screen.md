# Build 436 — écran noir de God of War III (Build 435) : cause et correction

Journaux de l'iPhone du mainteneur (10 octobre 2026, iPhone 16 Pro Max,
8 Go, iOS 27.0 bêta 24A5380h) : `RPCS3-diagnostic.log`,
`RPCS3-milestones.log`, `NeoSwap-v1.jsonl`, `NeoSwap-operations.jsonl`.
Ce document sépare les faits mesurés, les hypothèses et ce qui reste à
valider sur l'iPhone.

## 1. Ce que montrent les journaux

| Build | Cœur RPCS3 | God of War III (BCES00510) |
|---|---|---|
| 434 | `afb33454` (run 37620034517) | Le jeu tourne : 20 à 58 FPS, SPU 36 à 100 ms par image, RSX 17 à 43 ms, mémoire 2,7 → 3,4 Gio, 866 allocations VRAM. |
| 435 | `6fede58a` (run 38068094552) | 3 sessions sur 3 (pid 17899, 17908, 17963) : le jeu se fige environ 5 s après le démarrage. |

Dans les trois sessions 435, après la première fenêtre de 5 s :

- les images continuent d'être présentées à 60 FPS, mais PPU 0,8 ms, SPU
  1,2 ms et RSX 0,08 ms par image : l'émulateur ne calcule plus rien ;
- plus aucune compilation SPU ni allocation VRAM, mémoire figée entre 1,73
  et 1,88 Gio : le jeu attend indéfiniment (écran noir) ;
- la première fenêtre montre la compilation SPU différée de la Build 435 à
  l'œuvre : 218 programmes mis en file puis publiés par le pool, 788 entrées
  dans l'interpréteur de secours, 42,5 s d'attente cumulée
  (`deferred_wait_ms=42522`).

Dans la même build, un autre titre (BLES00113, session 17899) s'arrête sur
`SPU[0x1000100] Thread (CellSpursKernel1) [0x037e4]: Thread terminated due
to fatal error: Unknown STOP code: 0x0 (op=0x0)` : un SPU exécute un mot nul
de son local store.

Les deux autres changements de la Build 435 ne sont pas en cause d'après ces
mêmes journaux : la pré-comparaison avant `vm::writer_lock` (C) ne s'est
jamais déclenchée (`wl_putllc_avoided=0`, `wl_ppu_stcx_avoided=0`) et
l'enveloppe mémoire mesurée (A) n'a provoqué aucune réclamation
(`memory_reclaims=0`). La compilation SPU différée avec repli sur
l'interpréteur (B) est le seul changement placé sur le chemin d'exécution des
SPU.

## 2. Correction (Build 436)

- `rpcs3/Emu/Cell/SPUDeferredCompilePolicy.h` :
  `deferred_compile_enabled = false`, l'interrupteur prévu par la Build 435.
  Un SPU qui manque le répartiteur compile de nouveau en ligne, comme en
  Build 434 ; le pool n'est plus démarré. Les changements A et C sont
  conservés.
- Patch canonique, manifeste `canonical-source.json`, manifeste candidat et
  test natif (`deferred_compile_enabled` attendu à `false`) mis à jour ; la
  porte `test/check_neo_swap_scope.py` fige l'étape 435 sur `6fede58a` et
  n'autorise pour la 436 que l'interrupteur et son commentaire.
- Nouveau cœur construit par `rpcs3-core.yml`, puis épinglé dans la voie de
  livraison une fois la construction réussie.

Non démontré : la ligne exacte du défaut dans le chemin différé. Hypothèses
non vérifiées : résultats flottants différents entre l'interpréteur et le
recompilateur (le profil God of War III impose `SPU XFloat accuracy:
Approximate`, appliqué par le recompilateur LLVM), ou reprise du code publié
à une adresse incohérente. Réactiver ce chemin exige d'abord une preuve sur
l'iPhone.

## 3. NeoSwap pendant la partie (Build 434)

- Mémoire utilisable par tout le système : environ 0,58 Go pendant le jeu ;
  2,9 Go câblés par le système (iOS 27 bêta), 1,0 Go compressé.
- Les donneurs étaient prêts (marge par processus de 6,9 Go, droits mémoire
  effectifs) ; leur croissance est refusée parce que la mémoire libre du
  système est sous la réserve opérationnelle (0,5 Go) :
  `system_room_below_operational_reserve`. Donné : 48 Mio.
- Le relais a porté jusqu'à 1,1 Go de mémoire invitée ; 2 250 des
  2 774 demandes rapides sont retombées sur la mémoire ordinaire.

NeoSwap déplace de la mémoire entre des processus qui partagent les mêmes
8 Go ; il ne peut pas fournir de la RAM que le système n'a pas. Pendant God
of War III, la limite observée est la mémoire libre de tout l'iPhone, pas un
refus erroné de NeoSwap. Dans la session 435, les donneurs n'ont pas démarré
parce que le jeu s'est figé avant tout besoin de mémoire.

## 4. À vérifier sur l'iPhone

1. Lancer God of War III (Build 436) : le jeu doit dépasser l'écran noir.
2. Transmettre `RPCS3-diagnostic.log` et `NeoSwap-v1.jsonl` après quelques
   minutes de jeu (fenêtres `COREPROF`, `SPUPROF`, `limit_mib`, enveloppe).
