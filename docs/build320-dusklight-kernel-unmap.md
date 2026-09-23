# Build 320 — barrière de désallocation noyau Dusklight

## Diagnostic établi par les journaux du Build 319

Après `after_runtime_shutdown`, le processus NeoStation conservait encore les
deux régions exactes de Dusklight :

- MEM1 : `0x158800000`, `268435456` octets (256 Mio) ;
- ARAM/MEM2 : `0x168800000`, `25165824` octets (24 Mio).

Il ne restait alors qu'un seul trou virtuel d'au moins 256 Mio
(`jit_min_holes=1`). RPCS3 pouvait réserver son arène JIT de code, mais pas sa
seconde arène minimale de données, puis échouait avec
`NEOSTATION_EXACT_ATOMIC_JIT_RESERVATION_V1`.

Le Build 319 appelait bien `free()`. Le problème n'était donc plus un thread
oublié ni un mauvais chemin de framework : l'allocateur Darwin gardait les deux
grandes régions virtuelles dans le processus.

## Correction du Build 320

- MEM1 et ARAM sont allouées sur Apple par `mmap(MAP_PRIVATE | MAP_ANON)` ;
- leur taille et leur adresse exactes restent sous le contrôle de Dusklight ;
- la fermeture appelle `munmap()` après l'arrêt des callbacks et la jonction de
  tous les workers ;
- chaque résultat est enregistré sous la forme
  `Kernel unmap barrier: ARAM=<résultat> MEM1=<résultat>` ;
- la fermeture est bloquante et échoue fermement si une désallocation ne renvoie
  pas `1` ; dans ce cas, NeoStation n'émet pas `runtimeReleased` et ne permet pas
  le passage silencieux à RPCS3 ;
- ABI Dusklight : `6` ; politique :
  `host_frame_loop_terminal_kernel_unmap`.

L'image Objective-C du framework demeure passivement chargée dans le processus,
car `dlclose` rendrait invalides des classes déjà enregistrées par le runtime.
Elle ne possède toutefois plus de boucle, callback, worker, audio, disque,
fenêtre ou grandes arènes MEM1/MEM2 après la barrière terminale.

## Validation automatisée

- Core commit : `de7062685d7739511d22cc889965940d9db0207f` ;
- Core run : `35931454781` (succès) ;
- SHA-256 du binaire `DusklightCore` :
  `eb5418ccfda29f83100e3be5f9aa89c5300a02a9608a2a44918bc2a7a15fdfd8` ;
- Host commit : `12b1d2cb9849811cefd82a3df0fbbbf7477da92d` ;
- Build run : `35932190035` (succès) ;
- IPA : `NeoStation-iOS-Build-320-Dusklight-Kernel-Unmap.ipa` ;
- taille : `102354037` octets ;
- SHA-256 de l'IPA :
  `48a5fd8cb56f846335c3dcb13c83fd3afe7816158fa2fe1810aba25b3070460f`.

## Validation iPhone attendue

Reproduire sans fermer NeoStation : démarrage neuf, lancement d'un jeu
Dusklight, retour au menu, puis lancement immédiat d'un jeu RPCS3.

Le journal Dusklight doit contenir :

```text
Kernel unmap barrier: ARAM=1 MEM1=1 (1 means released).
```

Dans l'instantané `after_runtime_shutdown`, les régions exactes de 256 Mio et
24 Mio ne doivent plus apparaître. RPCS3 doit ensuite franchir sa réservation
des deux arènes JIT sans l'erreur atomique observée sur le Build 319.
