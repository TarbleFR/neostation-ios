# Fermeture 3DS et démarrage PSP — moteur libretro intégré

Signalement du mainteneur du 10 octobre 2026, vidéo
`ScreenRecording_10-10-2026 01-04-54_1.mov` (31 s), sur la Build 430
(`940f114975c9ae4761b227e5efa9381ef9fa976e`).

## Ce que montre la vidéo

- **PSP** (« Assassin’s Creed : Bloodlines ») : « Launching Game… » pendant
  le délai habituel de 2 s. La vue de jeu native apparaît à 1,89 s (skin PSP
  et indicateur de chargement), disparaît avant 2,09 s, puis Flutter affiche
  « Game executing… » jusqu’à 5,5 s et revient à la liste PSP, sans message.
  La session native a donc signalé un lancement réussi puis s’est terminée
  en moins de 0,2 s.
- **3DS** (« Mario Kart 7 ») : lancement, écran titre, menu en jeu,
  « Quit game » puis confirmation à 24,5 s. À 25,0 s, iOS affiche l’écran
  d’accueil. La carte NeoStation reste dans le sélecteur avec l’image du
  menu, mais la réouverture passe par l’écran de démarrage (29 s) puis le
  menu principal : le processus s’était terminé. C’est un arrêt du
  processus pendant la fermeture du jeu, pas une navigation Flutter.

## 3DS : cause établie dans les sources

Ordre de fermeture de la Build 430 (`LibretroSession -unloadCore`, Vulkan) :
attente du GPU, `context_destroy`, **destruction du `VkDevice` et du
`VkInstance`** (`LibretroVulkanRenderer -teardown`), puis
`retro_unload_game`, `retro_deinit` et `dlclose`.

Azahar 2126.2 (version du cœur livré, `src/citra_libretro`) :

- `context_destroy` ne libère rien pour Vulkan (seulement
  `emu_window->DestroyContext()`) ;
- `retro_unload_game` appelle `Core::System::Shutdown()`, qui détruit le
  moteur de rendu Vulkan. Celui-ci appelle `device.waitIdle()` et les
  `vkDestroy*` par `vulkan_intf->device`, c’est-à-dire le périphérique du
  frontal (`PresentWindow::~PresentWindow`, `MasterSemaphoreLibRetro`) ;
- l’interface de négociation passe `destroy_device = nullptr` avec le
  commentaire « frontend owns the device ».

Le cœur utilisait donc un `VkDevice` déjà détruit au moment de
« Quit game » : arrêt immédiat du processus. RetroArch suit l’ordre
inverse : `video_driver_free_hw_context` (`context_destroy`), puis
`retro_unload_game` et `retro_deinit`, et seulement ensuite la destruction
du pilote vidéo et de son périphérique.

**Correction** (`LibretroCoreHost -unloadWithContextDestroy:contextRelease:`) :

1. écriture de la sauvegarde ;
2. arrêt de la présentation, attente du GPU, `context_destroy` (contexte GL
   courant ou périphérique Vulkan vivant) ;
3. `retro_unload_game` puis `retro_deinit`, le contexte et l’interface
   fournis au cœur existant encore ;
4. libération du contexte GL ou du périphérique Vulkan ;
5. `dlclose`.

Le même ordre s’applique à OpenGL ES (PPSSPP, Mupen64Plus, Beetle PSX HW) :
leurs objets GL sont maintenant supprimés avec leur contexte courant.

## PSP : ce qui est établi et ce qui ne l’est pas

**Établi** : PPSSPP démarre la PSP de façon asynchrone ; quand
`PSP_InitUpdate` échoue, `retro_run` journalise l’erreur et demande
`RETRO_ENVIRONMENT_SHUTDOWN` (`libretro/libretro.cpp`). La session avait
déjà répondu « réussi » à Dart et traitait cette demande comme une fin
normale : retour silencieux à la liste, erreur perdue.

**Correction** : le lancement n’est déclaré réussi qu’après une période de
démarrage (60 images et 5 s d’émulation hors pause, ou plus tôt si
l’utilisateur quitte le jeu). Un cœur qui s’arrête de lui-même avant la fin
de cette période produit l’échec `LIBRETRO_CORE_STOPPED` : message traduit
dans les 12 langues (« Le cœur d’émulation s’est arrêté pendant le
démarrage du jeu. ») et détails techniques contenant les lignes d’erreur
du cœur et son journal.

**Établi dans le simulateur iOS** : le vrai cœur PPSSPP, dans la vraie
session NeoStation, démarre un programme de test PSP, directement puis
depuis une image ISO construite comme un disque PSP. Il se ferme et se
relance sans erreur. Le chargement de PPSSPP par NeoStation n’est donc pas
défaillant en soi. Le simulateur a aussi révélé deux défauts, corrigés :

- **Contexte OpenGL ES** : quand sa surface échouait après
  `retro_load_game`, la session déchargeait PPSSPP pendant que son fil de
  démarrage tournait, et PPSSPP s’arrêtait dans `retro_unload_game`
  (`PSP_Shutdown` n’attend pas ce fil). Le contexte et une surface
  provisoire sont désormais créés dès `SET_HW_RENDER`. Un échec y refuse le
  contexte matériel et PPSSPP passe en rendu logiciel, ce que fait le
  simulateur, qui ne sait pas créer de texture OpenGL ES sur IOSurface.
- **Mesure de la fenêtre mémoire** : avant de chercher sa base, PPSSPP
  alloue 72 Mio n’importe où ; dans le simulateur, cette arène est tombée
  dans la fenêtre même qu’il lui faut ensuite. La mesure en tient compte.

**Non établi** : la raison exacte de l’échec du démarrage PSP sur l’iPhone.
L’échec intervient en moins de 0,2 s, donc tôt : identification ou montage
du fichier, ou installation de la mémoire PSP. Pistes examinées :

- **Écartées** :
  - cœur ou fichiers PPSSPP absents : `ppsspp_libretro.framework` et
    `LibretroSystem/PPSSPP` sont dans l’IPA 430 ;
  - JIT : le cœur reçoit `GET_JIT_CAPABLE = false` et l’interpréteur IR est
    imposé ;
  - contexte OpenGL ES 2 : `GPU_Init` construit `GPU_GLES` sans pouvoir
    échouer ;
  - chargement de PPSSPP par la session : il démarre dans le simulateur.
- **Plausible, propre à NeoStation : l’espace d’adressage.** Compilé pour
  iOS (`MASKED_PSP_MEMORY`), PPSSPP place la mémoire PSP à des adresses
  fixes. Il essaie une base alignée sur 8 Mio entre 4 et 6 Gio
  (`MemoryMap_Setup`, `vm_remap` sans écrasement). Il lui faut 16 Kio à
  +0x10000, 8 Mio à +0x4000000 et 64 Mio à +0x8000000, plus son arène de
  72 Mio. Or NeoStation réserve dès son lancement environ 704 Mio de JIT
  pour RPCS3 dans la première zone libre au-dessus de 4 Gio, et les mesures
  de la Build 319 montraient un espace d’adressage déjà serré sur cet
  iPhone. Sans base libre, PPSSPP échoue avec « Memory init failed ».
- **Possible** : lecture du fichier (fichier iCloud ou fournisseur non
  téléchargé, format inattendu) : PPSSPP le signalerait par « Failed to
  mount ISO file » ou « Error identifying file ».

Pour trancher sans nouvelle hypothèse livrée à l’aveugle, chaque démarrage
PSP inscrit avant le chargement une ligne
`[HOST] PPSSPP memory window, estimated before boot: …` : première base
utilisable estimée ou absence de base, emplacement attendu de l’arène, plus
grand trou. Dans le simulateur, PPSSPP a pris sa base un pas de 8 Mio après
l’estimation. La ligne apparaît dans les détails techniques de l’erreur et
dans le journal de session. Aucune réservation d’adresses n’est ajoutée tant
que cette mesure n’a pas confirmé la piste. Une telle réservation pèserait
sur RPCS3, Dusklight, Dolphin et ARMSX2, qui se partagent le même espace.

## Diagnostics ajoutés

Journal de session : `Fichiers › NeoStation › Libretro › Logs`.

- `session.log` : lancement, cœur et contenu chargés, contexte graphique
  (ou raison de son refus), mesure PPSSPP, confirmation du démarrage,
  demande d’arrêt (utilisateur ou cœur), chaque étape de fermeture
  (`context_destroy`, `retro_unload_game`, `retro_deinit`, libération du
  moteur de rendu, `dlclose`, fermeture de la vue), puis le journal du cœur
  et une ligne `END`.
- Chaque ligne est écrite immédiatement : si le processus s’arrête, le
  fichier se termine sur l’étape qui n’est jamais revenue.
- La session suivante conserve ce fichier sous le nom
  `unfinished-session.log` et le précédent sous `previous-session.log`.

## Vérifications

- **Hôte libretro (macOS)**, avec un cœur de test qui demande son interface
  de rendu matériel comme Azahar :
  - l’ordre exact est `context_destroy`, `retro_unload_game`,
    `retro_deinit`, libération du contexte, `dlclose` ;
  - l’interface reste disponible dans `retro_unload_game` et `retro_deinit` ;
  - un cœur qui demande l’arrêt à l’image 3 est vu à cette image avec son
    erreur.
- **Modules portables (macOS)** : fenêtre mémoire de PPSSPP (fenêtre vide,
  réservation de type RPCS3, arène occupant le seul trou utilisable, base
  unique, trous entre les vues, entrées désordonnées, mesure du processus
  réel) ; journal (écriture immédiate, rotation, session inachevée
  conservée, écritures concurrentes).
- **Simulateur iOS 26.2** (`.github/workflows/libretro-simulator.yml`,
  runs 38009696405 sur `de2bd95c` et 38010857254 sur `19631f95`) : la vraie
  `LibretroSession`, dans la vraie pile UIKit, Metal, OpenGL ES et MoltenVK.
  Les 8 scénarios réussissent :
  - le cœur de test logiciel : lancement, quitter, relancer ; arrêt pendant
    le démarrage reçu comme `LIBRETRO_CORE_STOPPED` avec l’erreur du cœur ;
  - PPSSPP : programme de test PSP, puis image ISO deux fois, chacun quitté
    et relancé ;
  - un cœur Vulkan de test qui crée le périphérique et détruit ses objets
    dans `retro_unload_game` comme Azahar : lancement, quitter, relancer,
    ses objets détruits par le périphérique encore vivant.

  **Défaut reproduit avec les sources d’avant le correctif** (`940f114`,
  même run, job `before-fix`). Le même cœur Vulkan démarre, puis
  « Quit game » ferme tout le processus. MoltenVK journalise d’abord
  « Destroyed VkDevice » et « Destroying VkInstance » (ancien ordre), puis
  le `retro_unload_game` du cœur attend ce périphérique détruit. L’arrêt
  vient de `libc++abi: terminating due to uncaught exception of type
  std::__1::system_error: mutex lock failed: Invalid argument`. C’est le
  mécanisme de la fermeture 3DS de la vidéo.

  Azahar lui-même ne démarre pas dans le simulateur : le GPU simulé n’a pas
  de tableaux de textures ni d’échantillonneurs
  (`vk::FeatureNotPresentError`, avec ou sans correctif). Les cœurs de
  l’iPhone y tournent après le seul changement de plateforme Mach-O (iOS →
  simulateur). Un simulateur n’est pas un iPhone.

## Livraison

**Build 431**, IPA de test :

- source : `19631f95d75f39ddf407878ed32e3120f1e929ce` ;
- run : [38010863934](https://github.com/TarbleFR/neostation-ios/actions/runs/38010863934)
  (contrôles, natif, compilation Release à froid réussis) ;
- IPA scellée : SHA-256
  `633c3cc580c54b6b37d457ad9fea5495cb90c914eb0d65bccd916db4a7961230`,
  205 871 564 octets ;
- signatures : 57 signatures de préparation vérifiées, aucune section de
  code modifiée par la signature ;
- installation : par SideStore.

Ce document a été complété après la compilation, sans changer aucune entrée
de la Build 431.

## Reste à vérifier sur iPhone

1. Lancer un jeu 3DS, le quitter par « Quit game », puis le relancer. Le
   retour doit se faire sur la liste 3DS sans passer par l’écran d’accueil
   d’iOS.
2. Lancer un jeu PSP :
   - s’il démarre, quitter puis relancer ;
   - s’il échoue, le message traduit et les détails techniques donnent la
     ligne `PPSSPP memory window` et l’erreur de PPSSPP. Les transmettre,
     avec `Libretro/Logs/session.log`.
3. Lancer et quitter un jeu d’une autre console (GBA, SNES, DS, N64) pour
   vérifier l’absence de régression de l’ordre de fermeture.
