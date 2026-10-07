# NeoStation — Build 412 (cycle God of War III)

Candidat privé distinct de l'IPA 411 (identité de référence : commit
`8c63c682`, run `37605768644`, SHA-256 `da40c7a7…`, artefact conservé jusqu'au
10 octobre ; le réempaquetage du mainteneur sur `d317c956`, run `37618048149`,
a échoué à l'attente des preuves). Aucune validation sur iPhone
physique n'est revendiquée dans cette build : les preuves sont celles de la CI
et de l'analyse des journaux iPhone de Build 411 du 7 octobre 2026.

## Identité de l'IPA privée emballée

- Renseignée après l'empaquetage (commit, run `neoswap-ipa.yml`, artefact,
  SHA-256 de `NeoStation.ipa`). Cœur RPCS3 emballé : run `37620034517` sur
  `afb33454` (attribution des writer locks, comptage du thread `rsx::thread`).

## Ce que les journaux Build 411 établissent (BCES00510, 287 s, 8 Go)

| Régime | Durée | fps | temps CPU SPU/image | PPU/image | attente verrou PPU/image | réveils/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| léger | 146 s | 54,7 | 37 ms (2,0 cœurs) | 5,9 ms | 0,7 ms | 1 053 |
| intermédiaire | 61 s | 33,3 | 72 ms | 12,3 ms | 7,4 ms | 3 657 |
| lourd | 66 s | 8,9 | 388 ms (3,1 cœurs) | 79 ms | 120 ms | 10 152 |

- Le régime lourd commence par 635 compilations SPU en 9 s, exécutées sur les
  threads SPU eux-mêmes (une image de 6,2 s), puis 3 Gio de VRAM allouée en
  15 s, puis des réclamations mémoire iOS toutes les 2 s pendant 90 s.
- `spu_ms` est du temps CPU (spins compris) ; `range_stalls` ne compte que les
  attentes des threads PPU (réveils notifiés de 70 à 110 µs, pas des expirations).
  Les PPU ont été bloqués jusqu'à 1,5 s par seconde.
- Le thread `rsx::thread` n'était pas compté (`rsx_ms = 0`) ; le temps GPU n'est
  pas mesuré.
- NeoSwap : 7 084 refus sur 7 462 (NEOSWAP_BUSY, chemin FAST sans mémoire
  prête), 110 Mio mobilisés au maximum ; la RAM NeoSwap n'est pas le levier.
- Thermique 1 pendant tout le régime lourd, jamais 2 ; pas de jetsam.

## Mécanisme retenu (hypothèse, à prouver sur l'appareil)

Avec « Accurate SPU Reservations » (défaut du cœur, non surchargé jusqu'ici),
chaque PUTLLC qui change des données et chaque PUTLLUC prend `vm::writer_lock`,
qui pose `cpu_flag::memory` sur les deux threads PPU et attend qu'ils soient
garés ; les sept threads SPU spinnent pendant ce temps. Le cache de textures,
Write Color Buffers et NeoSwap ne touchent jamais ces bits.

## Changements de cette build

- Cœur (`afb33454`, run `37620034517`) : `RANGELOCKPROF` ajoute
  `wl_<source>=compte:acquisition_ms:maintien_ms` pour PUTLLC, STORE128, stwcx
  PPU, reservation_op et autres ; `rsx::thread` entre dans le groupe RSX de
  COREPROF. Aucun protocole de verrou modifié.
- Hôte : `SPUPROF` et `RANGELOCKPROF` exportés ; jalons durables
  `renderer_detected` (version MoltenVK), `boot_policy`, `gow3_mlaa_bypass`,
  `host_cpu_topology` ; `performance_summary` mesure le maintien de 30 fps
  (`fps_hold`, `below_target_samples`, `longest_below_target_run_s`,
  `below_target_mean_fps`, `constant`).
- Profil GoW3 (six identifiants) : `Accurate SPU Reservations: false` et
  `Frame limit: 30`. Ce sont des hypothèses mesurées, pas des correctifs
  démontrés.
- Overlay : deux séries seulement, RAM utilisée par l'appareil et NeoSwap.

## Protocole de mesure sur iPhone

Même scène que le 7 octobre (lancement, zone légère, zone lourde). Comparer
avec Build 411 : `fps_hold` et `longest_below_target_run_s` de
`performance_summary` ; dans COREPROF `range_wait_ms`, `range_stalls`,
`ppu_ms`, `spu_ms`, `rsx_ms` ; dans RANGELOCKPROF `wl_putllc` et `wl_store128`
(attendus proches de zéro avec les réservations relâchées) ; dans SPUPROF les
compilations de chargement et de jeu. Toute instabilité de jeu avec les
réservations relâchées invalide l'hypothèse : rétablir la clé dans le profil.

## Ce qui reste à valider sur iPhone

30 fps constants en zone lourde, stabilité du jeu avec réservations relâchées,
rafale de compilations SPU à la transition de scène (non traitée ici),
réclamations mémoire pendant le streaming de textures (non traitées ici).
