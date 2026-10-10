# RPCS3 / XITRIX v0.11 — import sélectif dans le Core Build 436

Demande du mainteneur du 10 octobre 2026 : reprendre de la mise à jour
XITRIX v0.11 ce qui peut améliorer notre RPCS3. Ce document sépare les
correctifs importés, ceux qui ne s'appliquent pas à notre Core et ceux qui
restent à examiner. Aucun test sur iPhone ni gain de FPS n'est revendiqué.

## Sources examinées

| Référence | Identité |
| --- | --- |
| Publication iOS v0.11 (2026-10-08 10:49 UTC) | [Tag v0.11](https://github.com/XITRIX/RPCS3-iOS-Releases/releases/tag/v0.11) ; `RPCS3.ipa` 32 020 392 octets, SHA-256 `387f2a2e5065dfabd9b51deec9588670b536a87899f6cbc6e98cde1dec3e66e4` (identique au fichier transmis par le mainteneur) |
| Branche source `ios-port` (2026-10-09 21:29 UTC) | [395636f5a64ec33fc3b9b44c8f01f1c5d69b9217](https://github.com/XITRIX/rpcs3/commit/395636f5a64ec33fc3b9b44c8f01f1c5d69b9217) |
| Base canonique NeoStation | `22f1152783cef1f7e04af7b1c895173e28fd5b03` |
| Précédent audit | [v0.10.1](rpcs3-xitrix-v0101-audit.md), tête `6747b75a` |

La branche `ios-port` a de nouveau été rebasée sur un RPCS3 amont plus récent
(463 commits d'avance, 107 de retard sur notre base). En comparant les sujets
de commits, 53 commits iOS de XITRIX sont postérieurs à notre base ; la
présence de leurs lignes dans notre patch montre que ceux jusqu'au
27 septembre étaient déjà importés (Build 353 et v0.10.1). L'IPA publiée n'est
liée à aucun SHA source par le dépôt de publications : l'import part des
sources, pas du binaire.

## Cinq commits importés tels quels

Chaque commit est appliqué sur le Core canonique avec un diff identique à
celui de XITRIX (identifiant de patch Git comparé), fixtures comprises. Seul
l'agrégateur `rpcs3/ios/tests/run-contract-tests.sh` reste celui de notre
Core : `test/rpcs3_xitrix_v011_native_test.py` exécute directement les
runners importés sur la source matérialisée, avant la compilation du Core.

| Commit XITRIX | Défaut corrigé | Fixture exécutée |
| --- | --- | --- |
| [3dc49630](https://github.com/XITRIX/rpcs3/commit/3dc496307b86f81a409f03816af07261a49748d3) | Échantillonnage d'un tampon de profondeur chevauchant au lieu de l'image couleur écrite par le même draw. | `run-framebuffer-source-tests.py`, avec contrôle négatif. |
| [7137b41a](https://github.com/XITRIX/rpcs3/commit/7137b41aed01d94345e35719a98fdc4190d08e50) | Course sur le pool d'images du cache de textures Vulkan entre le nettoyage et le thread pilote (plantages de Devil May Cry 4). | `run-vk-image-pool-tests.py` ; le contrôle négatif exécute le fichier de base, qui perd l'image rendue. |
| [3ebf5c99](https://github.com/XITRIX/rpcs3/commit/3ebf5c99fada6cd15da346ab216c96ba09a81f63) | Surcoût de rendu : l'attente `fence::wait_flush` tournait sans fin sur un cœur CPU (attente active courte puis sommeil sous iOS) ; fonctions chaudes en ligne, parcours des attributs par bits, indices de petits quads calculés sur place. | Runners Minecraft : optimisation, sommets, fence (moteur d'attente réel sous macOS), descripteurs, indices, comparés aux références figées avant le lot. |
| [57ce3bf6](https://github.com/XITRIX/rpcs3/commit/57ce3bf6a9f6a522fcb7b8f2ae140b59b19f0cd3) | Plage des attributs à fréquence divisée arrondie au supérieur : lecture d'une instance de trop, pouvant franchir la mémoire locale (WRC4). Le commit ajoute aussi la capture RSX de plusieurs images (outil de débogage). | `run-wrc4-vertex-range-tests.py`. |
| [395636f5](https://github.com/XITRIX/rpcs3/commit/395636f5a64ec33fc3b9b44c8f01f1c5d69b9217) | Alpha-to-one ignoré après l'alpha-to-coverage émulé : de faibles alphas amplifiaient le bloom de Gran Turismo 6. | `run-rsx-alpha-coverage-tests.py`, avec contrôle négatif. |

Effets à connaître :

- 7 sections du patch canonique changent et 67 sont ajoutées (23 fichiers
  RSX/Vulkan, `IOSDMACopy.h` et 50 fichiers de fixtures). Aucun fichier SPU,
  PPU, JIT, VM, mémoire ou cycle de vie n'est touché ; la porte
  `test/check_neo_swap_scope.py` l'impose.
- Le bit `RSX_SHADER_CONTROL_ALPHA_TO_ONE` (`0x80000000`) crée des variantes
  de fragment program seulement pour les titres qui combinent
  alpha-to-coverage émulé et alpha-to-one. Les autres entrées du cache de
  shaders restent valides.
- Le correctif de God of War III de la même Build 436 (compilation SPU
  différée désactivée, voir [rpcs3-build436-gow3-black-screen.md](rpcs3-build436-gow3-black-screen.md))
  est indépendant de ces fichiers.

## Non applicable à notre Core

[a5c5ed56](https://github.com/XITRIX/rpcs3/commit/a5c5ed563b400eb08751e3a3314e96c0092dcb02),
« PPU: Fix deadlock on startup » (blocages au démarrage annoncés dans v0.11),
corrige la porte de démarrage `start_gate_caller` introduite par le commit
amont [d42fc3dc](https://github.com/XITRIX/rpcs3/commit/d42fc3dc41b6619c9de70c9444bda834fc8d427a)
du 30 septembre. Notre base ne contient pas cette porte : le blocage n'existe
pas dans notre Core.

## Non importés

| Commit | Raison |
| --- | --- |
| `8a02594e` audio après arrière-plan | Modifie la session audio de la plateforme iOS de XITRIX ; en conflit avec le cycle de vie hôte de NeoStation. |
| `94fcb18b` régression audio | Corrige la chaîne audio shared-memory, absente de notre delta. |
| `e552f981` région JIT en une fois (« JIT plus rapide ») | Remplace la réservation JIT ; nos arènes et helpers JIT sont conservés. |
| `c2d07c1b` draws d'occlusion | Pas de fixture amont ; test graphique à construire. |
| `00c4b29e` cubemaps à bordure | Change la politique de fusion du cache de textures ; revue dédiée. |
| `18c68c92`, `7beb0de3` horloge invitée | Revue System/sys_time/audio/savestates toujours requise (déjà relevé dans l'audit v0.10.1). |
| `fd130035` retrait du compilateur de shaders Legacy | Migration des configurations par titre. |

Le gel de Gran Turismo 6 pendant le chargement du cache de shaders annoncé
par la publication n'est rattaché à aucun commit iOS identifiable ; il n'est
pas revendiqué ici.

## Vérifications

Exécuté localement (Windows, sans compilateur C++) :

- application du patch sur une base propre et arbre identique à l'arbre
  d'import (`19cee3ec`) ;
- `materialize_rpcs3_core.py` : 210 postimages vérifiées, exports complets ;
- tests sans compilateur du script de construction (préprocesseur, dlopen
  passif, GoW III 264/351/352, v0.10, ARMSX3) : réussis.

Les fixtures natives s'exécutent sur l'hôte macOS arm64 de `rpcs3-core.yml`
avant la compilation du Core ; leur résultat est consigné avec le run. Elles
établissent un comportement d'hôte, pas le rendu sur iPhone.

Licence : XITRIX/rpcs3 et ses fixtures sont sous GPL-2.0-only.
