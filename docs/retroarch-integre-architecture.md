# RetroArch intégré à NeoStation — évaluation d'architecture

*9 octobre 2026 — branche `Claude` (`8a1f4c4`). Évaluation seulement : aucun code produit modifié, aucune compilation, rien publié à l'extérieur.*

## En bref

- **Recommandation : intégrer le moteur de RetroArch — ses cœurs libretro — et non l'application RetroArch.** NeoStation devient son propre frontend libretro grâce à un pont embarqué `libretro_internal_bridge`, construit comme ceux d'ARMSX2, Dolphin et RPCS3 : même bouton Importer, mêmes playlists natives, même session plein écran avec son menu.
- Les cœurs sont les binaires officiels du buildbot libretro, à l'adresse qu'utilise le script iOS de RetroArch (`pkg/apple/update-cores.sh`). La compatibilité des jeux reste celle des cœurs de vos playlists actuelles.
- Un jeu lancé par le moteur intégré ne passe plus par aucun lien `retroarch://` : le défaut de lancement à froid de `RetroArchSceneDelegate` ne le concerne plus. Les systèmes non migrés gardent la route actuelle, inchangée.
- Les 13 cœurs de vos playlists existent en iOS ARM64 sur le buildbot (relevé du 9 octobre 2026), pour environ 37 Mo compressés au total. Neuf tournent en rendu logiciel et forment la phase 1 ; N64, PSP, PS1 (version matérielle) et 3DS demandent le rendu GPU (phases 2 et 3).
- Avant tout développement, trois décisions vous reviennent : les licences de cinq cœurs (non commerciales ou MAME), une exception relue dans les fichiers de bibliothèque verrouillés sur la Build 419, et le périmètre de la phase 1.

## 1. Deux façons d'« intégrer RetroArch »

### A. Embarquer l'application RetroArch entière — déconseillé

La couche iOS de RetroArch suppose qu'elle possède le processus. Sur `master` (`df16ef1`), `ui/drivers/ui_cocoatouch.m` contient son propre point d'entrée `UIApplicationMain`, son délégué d'application employé comme singleton (`[RetroArch_iOS get]`, 8 lignes) et son délégué de scène. L'objet global `apple_platform` (protocole `ApplePlatform` de `ui/drivers/cocoa/apple_platform.h` : vue de rendu, focus, mode vidéo, curseur, veille de l'écran) sert aussi dans `cocoa_common.m`.

L'embarquer imposerait :

- un fork permanent de cette couche (point d'entrée, délégués, état global), à resynchroniser à chaque version de RetroArch ;
- deux interfaces dans une même application (menus XMB ou Ozone dans NeoStation), deux configurations (`retroarch.cfg` et la base NeoStation) et des textes hors des catalogues de traduction de NeoStation ;
- la remise à zéro de tout l'état global de RetroArch après « Quitter », qu'il n'est pas prévu pour faire sans terminer le processus ;
- la cohabitation de deux boucles de rendu et de deux politiques audio avec le moteur Flutter.

Ce n'est pas l'architecture des autres moteurs embarqués.

### B. Un hôte libretro dans NeoStation — recommandé

RetroArch est un frontend ; l'émulation est faite par des cœurs libretro, des bibliothèques qui exposent une API C stable (`libretro.h`, licence MIT, `RETRO_API_VERSION 1`) : `retro_init`, `retro_load_game`, `retro_run`, `retro_serialize`, `retro_get_memory_data`… NeoStation peut charger ces mêmes cœurs et fournir lui-même ce que fournit RetroArch : image, son, manettes, répertoires, menu.

Cette API remplit exactement le rôle des ABI C versionnées que NeoStation a dû écrire pour ses autres moteurs (`NeoARMSX2_GetAPI`, `NeoDusklight_GetAPI`, `NeoKartPad_GetAPI`). Ici, elle existe déjà et elle est commune à tous les cœurs : un seul pont sert tous les systèmes libretro.

## 2. Architecture cible, calquée sur les moteurs embarqués

| Couche | Moteurs embarqués actuels | Équivalent libretro |
|---|---|---|
| Pont Flutter | `packages/armsx2_internal_bridge`, `dolphin_internal_bridge`, `rpcs3_internal_bridge`… ; canal `neostation/<moteur>_internal` | `packages/libretro_internal_bridge` ; canal `neostation/libretro_internal` (lancer, arrêter, diagnostics, fin de session) |
| Moteur | artefact CI `<Nom>Core-<sha>` avec `identity.json`, copié dans `Runner.app/Frameworks` après `xcodebuild`, chargé par `dlopen` à la demande | artefact `LibretroCores-<sha>` : cœurs officiels épinglés par SHA-256 et emballés en `<cœur>.framework` ; seul le cœur du jeu lancé est chargé |
| Session | contrôleur plein écran et menu de session (`Armsx2SessionMenu`…) | `LibretroSessionViewController` et `LibretroSessionMenu` : reprendre, sauvegarder ou charger un état, réinitialiser, disposition des écrans, réglages, quitter |
| Entrées | overlays tactiles, GCController/SDL | même pile, traduite en RetroPad libretro ; un overlay par système ; pointeur tactile pour l'écran inférieur DS/3DS |
| Audio | session audio du jeu, puis `AudioPolicyService.restoreAfterGameSession` | même transfert ; tampon au débit du cœur |
| JIT | chaîne StikJIT existante, état réellement mesuré | réponse à `RETRO_ENVIRONMENT_GET_JIT_CAPABLE` (74) depuis ce même état mesuré |
| Bibliothèque | racine visible dans Fichiers et playlists natives toujours visibles (`scanning.dart`, `system_repository.dart`) | `Documents/Libretro/Games/<système>/` et une playlist native par système migré |
| Import | `lib/widgets/*_internal_playlist_actions.dart`, câblés dans `my_games_list.dart` | `LibretroInternalPlaylistActions` : même bouton flottant, même action d'onglet |
| Lancement | bloc dédié dans `game_launch_service.dart` avant la route RetroArch, `registerGameLaunch(…, 'ios_<moteur>_internal')`, `_embeddedIOSSessionExecutables` (`game_launch_manager.dart:67`) | bloc `ios_libretro_internal` avant la ligne 418, seulement si le système est migré et son cœur présent et validé |
| Systèmes | `assets/systems/{gc,ports,ps2,ps3,wii}.json` : `"ios": {"embedded": true}` | même drapeau pour chaque système migré, avec son cœur par défaut |
| Traductions | `embedded_emulator_locale.dart`, `armsx2_ui_locale.dart`… en 12 langues | `libretro_locale.dart` en 12 langues, contrôlé automatiquement |
| Contrôles | `validate_<moteur>_ipa.py`, `validate_single_ipa_distribution.py`, bundle légal | `validate_libretro_ipa.py` ; licence de chaque cœur dans le bundle légal |

### 2.1 L'hôte libretro (code NeoStation, GPLv3)

L'hôte est compilé avec l'application, dans le pont ; seuls les cœurs viennent d'un artefact.

- **Chargement** : `dlopen` du framework du cœur, résolution des fonctions `retro_*`, refus si `retro_api_version()` diffère de 1. En fin de session : `retro_unload_game`, `retro_deinit`, puis fermeture de la bibliothèque, pour que chaque partie reparte d'un cœur neuf. RetroArch fait de même (`uninit_libretro_symbols` → `dylib_close`, `runloop.c`).
- **Environnement** : répertoires système et de sauvegarde (`GET_SYSTEM_DIRECTORY` 9, `GET_SAVE_DIRECTORY` 31), format de pixel (`SET_PIXEL_FORMAT` 10), rotation des bornes verticales (`SET_ROTATION` 1), langue de NeoStation (`GET_LANGUAGE` 39), options de cœur (`SET_CORE_OPTIONS_V2_INTL` 68), JIT (`GET_JIT_CAPABLE` 74), rendu matériel (`SET_HW_RENDER`, `GET_PREFERRED_HW_RENDER` 56). Un appel non pris en charge répond `false`, cas prévu par l'API.
- **Image** : les images logicielles (RGB565, XRGB8888, 0RGB1555) vont dans une texture Metal affichée au rapport d'aspect du cœur, en échelle entière ou lissée. Phase 2 : contextes `RETRO_HW_CONTEXT_OPENGLES3` (4) et `RETRO_HW_CONTEXT_VULKAN` (6), ce dernier via MoltenVK, que NeoStation emploie déjà pour RPCS3 et NeoSwap (version à aligner plutôt que dupliquer).
- **Son** : tampon circulaire alimenté par le cœur, AVAudioEngine, rééchantillonnage vers le débit de l'appareil et contrôle dynamique du débit, comme RetroArch, contre les craquements et la dérive.
- **Cadence** : un fil d'émulation au rythme du cœur (50 ou 60 Hz), synchronisé sur l'écran ; pause et écriture de la sauvegarde au passage en arrière-plan.
- **Contenu** : chemin ou données selon `need_fullpath` du cœur. FBNeo lit directement les `.zip`/`.7z` ; pour les autres cœurs, l'hôte extrait l'archive dans un cache temporaire avant `retro_load_game`, comme RetroArch.

Ordre de grandeur : les ponts natifs actuels comptent 5 693 lignes (ARMSX2), 6 503 (RPCS3) et 7 375 (Dolphin) sous `ios/`. L'hôte libretro sera du même ordre, l'émulation elle-même étant fournie par les cœurs.

### 2.2 Bibliothèque, playlists et bouton Importer

Deux entrées complémentaires, sans aucune migration automatique :

1. **Vos playlists actuelles restent les mêmes.** Les systèmes concernés sont déjà remplis par le scan de vos dossiers liés. Une fois un système migré, Jouer lance le cœur intégré, qui lit la ROM sur place avec l'accès déjà accordé par le dossier lié : ni copie ni manipulation. C'est le principe de la racine ARMSX2 liée.
2. **Le même bouton Importer que les autres moteurs** copie de nouveaux jeux dans `Documents/Libretro/Games/<système>/`, visible dans Fichiers. Une playlist native par système migré reste visible même vide. L'import partant de la playlist d'un système, une extension ambiguë (`.bin`, `.cue`, `.chd`, `.iso`) n'a pas à être devinée ; les ensembles `.cue`/`.bin` et `.m3u` sont copiés en entier.

Comme pour ARMSX2, une ROM du moteur intégré n'est jamais réinterprétée comme un jeu RetroArch : un échec affiche l'erreur réelle du cœur, sans repli silencieux. Les jeux connus seulement par la synchronisation RetroArch, sans fichier accessible à NeoStation, gardent la route RetroArch ou s'importent.

### 2.3 Sauvegardes et BIOS

- NeoStation garde ses propres sauvegardes : `Documents/Libretro/Saves/<cœur>/<jeu>.srm` et `Documents/Libretro/States/<cœur>/`. C'est la disposition par défaut de RetroArch (`DEFAULT_SORT_SAVEFILES_ENABLE` et `DEFAULT_SORT_SAVESTATES_ENABLE` valent `true`), si bien que les fichiers restent échangeables à la main.
- **Reprendre une partie RetroArch** est une action explicite qui copie, sans jamais déplacer ni modifier les fichiers de RetroArch. Les `.srm` sont l'image brute de la mémoire de sauvegarde (`DEFAULT_SAVE_FILE_COMPRESSION false`) et se reprennent tels quels. Les états RetroArch sont un conteneur `RASTATE` version 1 (blocs `MEM `, `ACHV`, `RPLY`, `END `), compressé en rzip par défaut sur iOS (`DEFAULT_SAVESTATE_FILE_COMPRESSION true`) : l'import décompresse, puis extrait le bloc `MEM ` ; il accepte aussi les états bruts plus anciens. Un état ne fonctionne qu'avec une version compatible du même cœur ; le `.srm` reste la voie fiable.
- **BIOS** : `Documents/Libretro/System/`, avec un contrôle par système fondé sur les listes de firmware des `.info`, comme le contrôle BIOS d'ARMSX2. Obligatoires selon les `.info` : `scph5500.bin`, `scph5501.bin` et `scph5502.bin` (mednafen_psx_hw), `PPSSPP/ppge_atlas.zim` (ppsspp, fichier système à embarquer). Facultatifs mais nécessaires à certains jeux : `bios_CD_*.bin` (Mega-CD), `disksys.rom` (Famicom Disk System), `fbneo/neogeo.zip` (Neo Geo)…

### 2.4 Cœurs : provenance, emballage, identité

- **Source** : `https://buildbot.libretro.com/nightly/apple/ios-arm64/latest/`, l'adresse de `pkg/apple/update-cores.sh` dans RetroArch ; 178 archives le 9 octobre 2026.
- **L'outillage existe déjà dans le dépôt** : `tools/build_retroarch_receiver.py`, écrit pour le récepteur 781, accepte les deux formes de nom (`<cœur>_libretro_ios.dylib.zip` et `<cœur>_libretro.dylib.zip`), extrait le membre exact, enregistre le SHA-256 de l'archive et de la bibliothèque, refuse un cache dont le hash diffère, contrôle la plateforme Mach-O (`verify_ipa.macho`, qui a écarté `hatarib`, déclaré macOS) et emballe chaque cœur en `.framework`. Il reste à l'extraire dans un workflow `libretro-cores.yml`, sur le modèle des `*-core.yml`.
- **Épinglage** : `latest` change chaque nuit. L'artefact `LibretroCores-<sha>` fige les hashes et se réutilise par identité, selon la règle de réutilisation. Le manifeste enregistre aussi `library_version` (`retro_get_system_info`, qui contient souvent le commit) pour désigner la source correspondante que la GPL exige ; à défaut, les cœurs seront compilés depuis un commit épinglé.

### 2.5 Les 13 cœurs de vos playlists

Relevé du 9 octobre 2026 : fichiers `.info` de `libretro/libretro-core-info` et listing du buildbot iOS ARM64. Lors de la construction du récepteur 781, ces 13 binaires ont été contrôlés ARM64 iOS avec un minimum inférieur à iOS 18 (`docs/retroarch-receiver-sidestore.md`).

| Cœur | Systèmes | Licence (`.info`) | Rendu | Archive iOS | Phase |
|---|---|---|---|---|---|
| gambatte | Game Boy, Game Boy Color | GPLv2 | logiciel | 355 Ko | 1 |
| mgba | Game Boy Advance | MPL 2.0 | logiciel | 429 Ko | 1 |
| nestopia | NES, Famicom Disk System | GPLv2 | logiciel | 740 Ko | 1 |
| snes9x | Super Nintendo | Non commerciale | logiciel | 769 Ko | 1 |
| genesis_plus_gx | Mega Drive, Master System, Game Gear, Mega-CD | Non commerciale | logiciel | 793 Ko | 1 |
| genesis_plus_gx_wide | idem, écran large | Non commerciale | logiciel | 683 Ko | 1 |
| picodrive | Mega Drive, 32X, Mega-CD | MAME | logiciel | 687 Ko | 1 |
| fbneo | Arcade, Neo Geo | Non commerciale | logiciel | 14 242 Ko | 1 |
| desmume | Nintendo DS | GPLv2 | logiciel par défaut | 851 Ko | 1 |
| mednafen_psx_hw | PlayStation | GPLv2 | OpenGL Core 3.3 ou Vulkan | 2 108 Ko | 2 |
| mupen64plus_next | Nintendo 64 | GPLv2 | OpenGL ES ≥ 2.0 (OpenGL Core 3.3 ailleurs) | 2 238 Ko | 2 |
| ppsspp | PSP | GPLv2 | OpenGL ES ≥ 2.0 ou Vulkan | 6 114 Ko (archive du 1er octobre) | 2 |
| azahar | Nintendo 3DS | GPLv2+ | `.info` : OpenGL Core 3.3 seulement | 7 497 Ko | 3 |

Total des 13 archives : 37 506 Ko compressés, soit de l'ordre de 37 Mo de plus dans l'IPA.

- Le `.info` d'azahar n'annonce qu'OpenGL Core 3.3, absent d'iOS : l'API graphique réellement demandée par le binaire iOS doit être mesurée avant de planifier ce cœur.
- `mednafen_psx` (même moteur Beetle PSX, rendu logiciel seul, GPLv2, 1 074 Ko) existe aussi en iOS : il ouvrirait la PS1 dès la phase 1. La compatibilité des cartes mémoire entre les deux versions reste à vérifier.
- Les cœurs de la phase 1 n'ont pas besoin du JIT. N64, PSP et 3DS en profitent ; l'hôte répond à `GET_JIT_CAPABLE` avec l'état réel, jamais déduit d'une route disponible ou d'un succès antérieur.

## 3. Décisions à prendre

1. **Option B** plutôt que l'application RetroArch embarquée.
2. **Licences.** NeoStation est sous GPLv3. Pour la FSF, un module chargé dans le même processus et partageant ses structures de données forme avec le programme une seule œuvre combinée. Cinq cœurs portent des restrictions incompatibles avec la GPL : snes9x, genesis_plus_gx, genesis_plus_gx_wide et fbneo (non commerciaux), picodrive (licence MAME). Les cœurs marqués « GPLv2 » doivent aussi être vérifiés « ou toute version ultérieure ». RetroArch distribue ces cœurs selon sa propre analyse, qui n'engage pas NeoStation. Deux voies : les livrer après une décision juridique explicite, ou les remplacer par des cœurs compatibles, présents en iOS sur le buildbot :

   | Cœur actuel | Remplaçant possible (licence `.info`, archive iOS) |
   |---|---|
   | snes9x | bsnes (GPLv3, 937 Ko) ou mesen-s (GPLv3, 1 039 Ko) |
   | genesis_plus_gx, genesis_plus_gx_wide, picodrive | blastem (GPLv3, 2 207 Ko) pour la Mega Drive ; gearsystem (GPLv3, 227 Ko) pour Master System et Game Gear ; Mega-CD et 32X restent à couvrir |
   | fbneo | mame (GPLv2+, 92 137 Ko, jeux de ROM différents) |
   | gambatte, si GPLv2 seule | sameboy (MIT, 104 Ko) ou gearboy (GPLv3, 242 Ko) |

   Changer de cœur peut rendre certaines sauvegardes incompatibles, et tous les états.
3. **Fichiers verrouillés.** `test/retroarch_baseline_scope_test.py` fige dix fichiers de bibliothèque sur la Build 419, dont `scanning.dart`, `system_repository.dart` et `main.dart`. Chaque moteur embarqué y est inscrit en dur (pour ARMSX2 : `scanning.dart:93` et `641–729`, liste `['ps2', 'ps3', 'ports']` en `system_repository.dart:74`). L'intégration demande votre accord et une exception relue sur le modèle de la Build 423 : seules les lignes libretro s'ajoutent, la logique de scan existante reste identique octet pour octet.
4. **Périmètre de la phase 1** : les neuf cœurs logiciels (Game Boy et Color, GBA, NES, Super Nintendo, Mega Drive, Master System, Game Gear, Mega-CD, 32X, arcade, DS), plus la PS1 via `mednafen_psx` si vous l'acceptez.
5. **Réglages des cœurs.** Leurs libellés viennent des cœurs, souvent en anglais seulement, ce que la règle des 12 langues exclut. Recommandé : n'exposer qu'une sélection de réglages traduits dans les catalogues NeoStation (résolution interne, disposition des écrans DS, région…).

## 4. Phases

Une seule build de validation par phase, sans empilement de correctifs.

- **Phase 0 (sans IPA)** : workflow `libretro-cores.yml` et artefact `LibretroCores-<sha>` (hashes, plateformes Mach-O, `library_version`, licences) ; décisions 1 à 5.
- **Phase 1** : hôte (image logicielle Metal, son, manettes, overlays par système, SRAM, états, menu de session), bouton Importer, playlists natives, lancement depuis les playlists existantes, reprise explicite des `.srm` RetroArch, pour les systèmes de la phase 1. Les autres systèmes gardent la route RetroArch actuelle.
- **Phase 2** : rendu GPU (OpenGL ES pour mupen64plus_next ; Vulkan via MoltenVK pour ppsspp et mednafen_psx_hw), JIT, changement de disque (`.m3u`), fichiers système de PPSSPP.
- **Phase 3** : azahar après mesure de son API graphique sur iOS ; succès RetroAchievements (rcheevos et cartes mémoire du cœur) ; codes de triche (`retro_cheat_set`, avec le parseur NeoCheat utilisé sans modification) ; choix du cœur par jeu.
- Hors périmètre au départ : shaders, netplay, retour arrière, run-ahead.

## 5. Vérifications obligatoires

- **Tests automatiques** : routage (système migré → moteur intégré ; système non migré → route RetroArch inchangée ; ROM du moteur intégré jamais renvoyée vers RetroArch) ; contrat d'import (`test/integrated_import_tab_contract_test.py` étendu) ; playlists natives toujours visibles ; catalogues complets dans les 12 langues, paramètres de substitution et chinois traditionnel compris ; identité des cœurs (hash, plateforme Mach-O, présence dans l'IPA) ; bundle légal ; liste `DELTA` de `build-utils/verify_delivery_reuse.py`.
- **Tests natifs sur macOS en CI** : un petit cœur de test écrit pour la fixture, donc sans ROM commerciale, pour charger, exécuter N images, sérialiser et restaurer, écrire puis relire la SRAM, quitter, relancer et changer de cœur.
- **Sur iPhone, par vous** (aucun succès annoncé sans eux) : premier lancement et relancement ; changement de cœur ; alternance avec ARMSX2, Dolphin et RPCS3 ; arrière-plan puis retour ; SRAM conservée après « Quitter » et après fermeture forcée ; son rendu au menu ; manette et tactile ; états du JIT.

## 6. Ce qui ne change pas

- Les moteurs existants, leurs cœurs, leurs helpers JIT et les 130 fichiers natifs verrouillés (`native_sha256`) restent intacts : le nouveau code vit dans un nouveau paquet.
- La route `retroarch://` reste pour les systèmes non migrés, avec sa limite connue au lancement à froid (`AGENTS.md`).
- Rien n'est publié vers libretro ou RetroArch : les cœurs sont seulement téléchargés depuis le buildbot public.
- Le moteur n'étant pas l'application RetroArch, l'interface nomme le cœur (par exemple « Snes9x — intégré ») et les crédits citent libretro.

## Sources consultées

- RetroArch `master` `df16ef193cbe385b87e8a1cf27b66da35bf3c0e0` : `libretro-common/include/libretro.h`, `config.def.h`, `tasks/task_save.c`, `runloop.c`, `ui/drivers/ui_cocoatouch.m`, `ui/drivers/cocoa/apple_platform.h`, `pkg/apple/update-cores.sh`.
- `libretro/libretro-core-info` : fichiers `.info` des 13 cœurs et des remplaçants cités.
- Listing `https://buildbot.libretro.com/nightly/apple/ios-arm64/latest/` du 9 octobre 2026 (tailles affichées par le buildbot).
- Dépôt NeoStation, branche `Claude` : ponts `packages/*_internal_bridge`, `lib/services/game/game_launch_service.dart`, `lib/services/game_launch_manager.dart`, `lib/screens/game_screen/my_games_list.dart`, `test/retroarch_baseline_scope_test.py`, `docs/retroarch-baseline-manifest.json`, `tools/build_retroarch_receiver.py`, `docs/retroarch-receiver-sidestore.md`.
