# Build 319 — libération de l’espace d’adressage Dusklight

## Cause confirmée sur iPhone

Build 318 arrêtait bien les workers, l’audio, le lecteur de disque, les timers,
SDL, Aurora et Metal. Le journal transmis montre toutefois que cette fermeture
laissait encore environ 504 Mio de nouveaux mappings bas dans le processus
NeoStation. Deux plages correspondent exactement à la configuration Dusklight :

- MEM1 : 256 Mio ;
- MEM2/ARAM : 24 Mio.

Aurora allouait ces mémoires avec `calloc`, sans aucune fonction de destruction,
car son cycle de vie amont suppose normalement que le processus se termine.
NeoStation charge au contraire Dusklight et RPCS3 successivement dans le même
processus iOS. Ils ne partagent ni moteur ni chemin JIT, mais ils partagent donc
le même espace virtuel.

Après Dusklight, RPCS3 réussit encore l’attachement StikJIT et la sonde JIT. Il
échoue ensuite dans `arena_prepare` : son minimum est constitué de deux plages
distinctes de 256 Mio (code et données). Le plus grand trou visible après la
fermeture Build 318 ne faisait qu’environ 330 Mio. Un démarrage neuf de RPCS3
dans un autre PID réussit, ce qui isole le problème au résidu de Dusklight.

## Correction ABI v5

La fermeture terminale effectue désormais, dans cet ordre :

1. arrêt des callbacks, audio et système de jeu ;
2. réveil et `join` de tous les workers, puis fermeture du lecteur de disque ;
3. destruction de l’interface, des textures, de la configuration et d’Aurora ;
4. destruction des tables natives de messages, mutex, conditions et threads ;
5. libération explicite de MEM2/ARAM puis MEM1 ;
6. relâchement des caches de l’allocateur Darwin ;
7. émission de `runtimeReleased: true` seulement après le retour complet.

Le framework reste volontairement chargé : il contient des classes Objective-C
enregistrées par le runtime iOS, et un `dlclose` rendrait leurs pointeurs de
méthodes invalides. Conserver l’image du framework n’autorise cependant plus ses
workers ou ses grosses mémoires de jeu à rester actifs.

Le diagnostic VM expose maintenant `second_largest_visible_hole` et
`jit_min_holes`. Ce dernier doit être au moins égal à 2 après la fermeture pour
correspondre aux deux réservations minimales de RPCS3.

## Validation automatisée

| Élément | Identité |
| --- | --- |
| Sources natives | `5e5a410e258d3b367a76e9d028d118477d001aaf` |
| Run natif / job | `35925383908` / `107399109623` — succès |
| Archive native | artifact `10778309379`, SHA-256 `582421b09cbe915b6f5fdea62648431dadecd75e11e332336a44c234162969e4` |
| DusklightCore | SHA-256 `4719c7ebcca73becaf2ba95b24cbd5bd640957cf6a65b6714c3a69e31caf6536` |
| ABI / politique | `5` / `host_frame_loop_terminal_address_space_release` |

La compilation iPhone arm64, les tests de session, files d’attente, audio,
graphismes, menus, langues, arrêt terminal et topologie des deux arènes passent.

Validation physique requise : démarrer NeoStation à neuf, lancer Dusklight,
revenir à NeoStation puis lancer RPCS3 sans fermer l’application. Le journal
`after_runtime_shutdown` doit montrer la disparition des plages de 256 Mio et
24 Mio et `jit_min_holes` au moins égal à 2 ; RPCS3 doit ensuite atteindre
`arena_prepare_success` puis `jit_initialize_success` dans le même PID.
