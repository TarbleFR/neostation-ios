# RPCS3 / XITRIX Preview 0.10 — candidat Build 353

Build 353 part du Core Build 352 et conserve la baseline stable Build 350, la
politique mémoire God of War III de Build 352 et l'ABI iOS RPCS3 30. La source
de départ reste `XITRIX/rpcs3@22f1152783cef1f7e04af7b1c895173e28fd5b03` :
les nouveautés de la Preview 0.10 sont backportées dans le patch canonique au
lieu de remplacer brutalement le Core par `ios-port@559987e`.

## Référence étudiée

La Preview 0.10 XITRIX a été publiée le 27 septembre 2026. La branche source
`ios-port` correspondante termine sur
`559987e966db0f8ac983502a160b419968e2474d`.

## Apports retenus

| Domaine | Apport Build 353 | Provenance principale |
| --- | --- | --- |
| ARM64 / SPU | Lowering NEON supplémentaire, comparaisons, rotations/shifts, hash/scan de réservations et chemins DMA/interrupts améliorés. | `40eee1350`, `5ecb8ad7a`, `6691e6b7e`, `739f2cc37`, `34023568f`, `4dfc49afe`, `f5d389fbf` |
| SPU / CPU | Attentes mailbox réduites, barrières acquire autour des réservations et timer du decrementer au lieu d'un polling permanent. | `d7bc312e5`, `559987e96` |
| PPU | Correctifs overflow/OE/CR0 et conversions NaN ARM64, avec nouvelle génération de cache. Le budget LLVM basé sur le headroom iOS de NeoStation est conservé. | `559987e96` |
| Mémoire | Amélioration de `VMReservationRange`; les stacks restaurées par savestate conservent leurs pages 4K. | `a755f48ea`, `8b952cf92` |
| RSX / Metal | Lock IO-map moins coûteux, sélection FIFO par bit-scan, cache/query batching, attente GPU Metal native et synchronisation FSR compute. | `a5715cde0`, `77783854f`, `5879207e7`, `559987e96` |
| Textures | Hashing iOS et validation de cache, invalidation sampler, correction deswizzle GTA V et feedback draws. | `d355dbef9`, `31d521acc`, `4077c32af`, `8525c9915`, `f8eb8b587` |
| Audio iOS | Récupération de buffer, tempo borné et fade 3 ms lors des discontinuités. | `dca80663a` |
| Stabilité | Teardown RSX offload, changement de résolution, exitspawn, socket events, SELF decoding, interpréteurs ARM64. | `8b952cf92`, `1fa6baa41`, `c05e9f3de`, `d55d8badd`, `b4d9a763d` |

## Éléments volontairement non importés

- La migration complète du Core vers `ios-port@559987e` : elle entre en
  conflit avec le JIT, la mémoire GoW3, le cycle de vie et le bridge NeoStation.
- `046d7a42f` JIT allocation : Build 352 contient déjà une version plus
  avancée (réservation basse, séparation code/données, repli de capacité,
  proposition d'arène jusqu'à 1 Gio).
- La chaîne audio shared-memory issue de RPCS3 #19467 : elle modifie une
  quinzaine de fichiers VM/LV2/savestate pour une optimisation secondaire et
  augmenterait fortement le risque du candidat.
- Les changements de backgrounding/experimental-paths : ils touchent la
  politique de cycle de vie iOS et doivent être évalués séparément.

## Validation

Le build Core doit réussir les contrats Build 301/351/352 ainsi que
`rpcs3_build353_xitrix_v010_test.py`. Une compilation réussie ne constitue pas
une mesure de FPS sur appareil.

Pour God of War III, comparer Build 352 et Build 353 sur la même sauvegarde et
la même résolution : FPS moyen/1% low, temps SPU/PPU, attentes range-lock,
attentes RSX, mémoire maximale et stabilité des cinématiques.
