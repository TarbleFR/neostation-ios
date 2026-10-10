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

**Établi sur l’iPhone** (journal de la Build 431, 10 octobre 2026,
10 h 11 UTC) : l’échec vient de l’espace d’adressage. Avant le démarrage,
la mesure donne « no usable base among 256 probed (1790 regions mapped in
0x100000000-0x18bff0000 …); largest hole 0x3ee8000 bytes ». PPSSPP
confirme ensuite : `vm_remap failed (3)` vers `0x183800000`,
`MemoryMap_Setup: Failed finding a memory base.`, puis
`Memory init failed`. La session renvoie `LIBRETRO_CORE_STOPPED` avec ces
lignes, comme prévu par la correction précédente.

Compilé pour iOS (`MASKED_PSP_MEMORY`), PPSSPP place la mémoire PSP à des
adresses fixes. Il essaie une base alignée sur 8 Mio entre 4 Gio et
`0x17FFF0000` (`MemoryMap_Setup`, `vm_remap` sans écrasement). Il lui faut
16 Kio libres à +0x10000, 8 Mio à +0x4000000 et 64 Mio à +0x8000000 ; avant
cela, son arène de 72 Mio est allouée n’importe où. Au moment d’un jeu PSP,
cette fenêtre de NeoStation est morcelée en 1 790 régions et son plus grand
trou fait 63 Mio : aucune base ne convient. Les autres pistes (cœur ou
fichiers absents, JIT, contexte OpenGL ES, lecture du fichier) sont
écartées par ce même journal : PPSSPP s’arrête avant de lire le jeu.

**Correction** (`LibretroAddressSpace.m`) : la fenêtre est réservée tant
qu’elle est encore libre.

- Juste après le lancement de l’app, une fois tous les plugins
  enregistrés, le plugin libretro réserve 192 Mio d’adresses (de la base
  jusqu’à la fin de la dernière vue) à la plus haute base libre de la
  fenêtre, sans accès (`VM_PROT_NONE`) : aucune mémoire n’est consommée.
  La réservation JIT anticipée de RPCS3 est déjà en place à ce moment-là ;
  RPCS3 n’est pas modifié.
- Juste avant `retro_load_game` de PPSSPP, seules les trois plages des vues
  sont libérées. Chacune est plus petite que l’arène de 72 Mio, qui va donc
  ailleurs, et le reste de la plage réservée empêche toute autre allocation
  de s’y installer. PPSSPP trouve ses vues libres à cette base.
- Après le déchargement de PPSSPP, les plages des vues sont de nouveau
  réservées. Si l’une d’elles a été prise entre-temps, elle n’est pas
  touchée : seules les parties appartenant à la réservation sont libérées
  et une nouvelle plage libre est cherchée.
- Si la réservation au lancement a échoué, elle est retentée au lancement
  du jeu PSP. Le journal de session indique chaque état :
  `[HOST] PPSSPP window held at 0x…`, `view ranges released for this
  boot`, `reserved again`.

Les autres émulateurs (Dolphin, ARMSX2, Dusklight) allouent leur mémoire
sans adresse imposée : ils ne perdent que ces 192 Mio d’adresses dans la
zone de 4 à 6 Gio, sans mémoire consommée.

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
- Un lancement en échec est aussi copié dans `failed-launch.log`, conservé
  jusqu’au prochain échec : les sessions suivantes (nouvel essai, autre
  jeu) ne le font plus disparaître par rotation, comme c’est arrivé au
  premier journal PSP.

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
  réel) ; réservation sur le processus réel (plage entière réservée sans
  accès à une base sondée par PPSSPP, vues libérables seules pour le
  démarrage, reprise à la même base après déchargement, vue prise
  entre-temps laissée intacte et nouvelle plage réservée) ; journal
  (écriture immédiate, rotation, session inachevée conservée, écritures
  concurrentes, lancement en échec conservé).
- **Simulateur iOS 26.2** (`.github/workflows/libretro-simulator.yml`,
  runs 38009696405 sur `de2bd95c` et 38010857254 sur `19631f95`) : la vraie
  `LibretroSession`, dans la vraie pile UIKit, Metal, OpenGL ES et MoltenVK.
  Les 8 scénarios réussissent :
  - le cœur de test logiciel : lancement, quitter, relancer ; arrêt pendant
    le démarrage reçu comme `LIBRETRO_CORE_STOPPED` avec l’erreur du cœur ;
  - PPSSPP : programme de test PSP, puis image ISO deux fois, chacun quitté
    et relancé ;
  - PPSSPP dans une fenêtre encombrée comme celle de l’iPhone : la case
    scratchpad de chaque base sondée est occupée avant le lancement, si
    bien qu’aucune base n’est libre sans la réservation (scénario
    `ppsspp-crowded`) ; le job `before-reservation` rejoue ce scénario avec
    les sources de la Build 431 ;
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
   - s’il démarre, jouer quelques secondes, quitter puis relancer ;
   - s’il échoue, transmettre `Libretro/Logs/failed-launch.log` (lignes
     `PPSSPP window` et erreur de PPSSPP).
3. Lancer et quitter un jeu d’une autre console (GBA, SNES, DS, N64) pour
   vérifier l’absence de régression de l’ordre de fermeture.
