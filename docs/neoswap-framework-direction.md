# NeoSwap : direction retenue après le build 396

Décision du 3 octobre 2026. Ce document distingue l'étude mémoire du correctif
de menu RPCS3 et du test de navigation qui a bloqué le build 397.

## Décision

Faire évoluer le framework NeoSwap existant vers le déchargement explicite de
données froides : conserver leur backing vérifiable sur stockage, libérer leur
copie CPU puis les relire ou les reconstruire à leur prochaine acquisition.
L'intégration doit appartenir à chaque cache de l'émulateur, avec une durée de
vie et des points d'acquisition/libération connus. Augmenter le quota seul ne
constitue pas cette intégration.

La piste iPadOS désigne l'imitation de son cycle RAM → stockage → RAM dans
NeoSwap. Le mainteneur a confirmé que l'objectif n'est pas d'activer une API
du système sur iPhone. Les primitives de stockage et restauration sont déjà
présentes ; le chantier ajoute maintenant des blocs CPU modifiables, segmentés
et protégés par des leases. Voir [l'étape réalisée](neoswap-managed-swap-stage1.md).

Conserver les mécanismes donor, GuestPageRelay et les imports Vulkan existants.
Leur capacité, leurs prêts vivants et leurs mesures de résidence restent des
indicateurs distincts. Le nouveau moteur géré est matérialisé dans le framework
sans activer de nouveau consommateur RPCS3 dans ce correctif. Aucun cache froid
massif et sûr n'a encore été identifié dans les
sources examinées. La première étape du chantier suivant est son inventaire,
puis une preuve d'éviction/relecture sur la première cible effectivement trouvée.

## Comparaison des pistes

| Piste | Éléments établis | Direction |
|---|---|---|
| Swap système iPadOS | Apple annonce Virtual Memory Swap sur des iPad compatibles. XNU implémente son activité dans le noyau. Aucune API publique d'activation du swap iPad dans une application iPhone n'a été identifiée. | Référence d'architecture ; ne pas supposer qu'un framework peut activer ce service système. |
| MeloNX public | `master` reste `c1d414def32cdc69862aeb4b1222be4ffb401cf0`. `MachJitWorkaround` traite des objets Mach dans un chemin JIT ; `MemoryLimitManager` est un test d'allocation. Aucun pager iOS sur disque identifié. | Mesure séparée des ledgers possible ; aucun code vivant à remapper sans preuve. |
| NeoSwap donor/relay | Les journaux montrent environ 505 Mio de prêts et 974 Mio de backing invité vivant. Les alias ne sont pas de la mémoire supplémentaire indépendante. | Conserver les chemins fonctionnels ; mesurer leur effet hôte et système. |
| Cache shaders du build 396 | Environ 1,6 Mio alloués au fichier, zéro lecture, zéro hit disque et zéro éviction. | Ne pas augmenter les quotas dans l'espoir d'un gain de plusieurs Gio. |
| Framework de données froides | Les caches dont le contenu est possédé, immuable ou reconstructible permettent un transfert contrôlé vers le stockage. | Axe de développement retenu, après identification d'une cible significative. |

Apple précise que des pages dirty compressées ou swappées restent facturées à
leur taille non compressée dans le footprint. Le swap système peut réduire
leur résidence physique sans supprimer le plafond de l'application. Apple
distingue les fichiers mappés en lecture seule : leurs pages propres peuvent
être retirées et rechargées par le système. Cette propriété ne rend pas leur
résidence ni leur coût d'accès illimités.

`increased-memory-limit` demande une limite supérieure sur les appareils
supportés ; `extended-virtual-addressing` étend l'espace d'adressage. Vérifier
les capacités du binaire installé et le budget obtenu, sans déduire de ces
entitlements une quantité garantie de RAM.

## Ce que le code actuel ne permet pas d'évincer

Les buffers `NEOSWAP_CPU_CACHE` de RPCS3 sont des allocations RSX alignées à
pointeurs bruts. Ce nom ne leur donne pas un contrat de cache froid : ils n'ont
pas de protocole d'éviction/reconstruction. La mémoire invitée mutable, les
labels RSX, les pointeurs utilisés par le JIT, les DMA et les ressources GPU en
vol ne doivent pas être remis sur disque par une interposition générale de
`malloc`, un remplacement `MAP_FIXED` ou un handler global de fautes.

Le code MeloNX `ReallocateBlock` demande un changement d'ownership avec
`TASK_NULL` et `VM_LEDGER_FLAG_NO_FOOTPRINT`. L'appel legacy est conditionné par
`IsIOS && forJit`. Les vues de mémoire partagée ordinaires sont intraprocessus.
L'existence de ce drapeau ne démontre ni son succès sur l'iPhone testé, ni une
économie de RAM physique. Le chemin `DualMappedJitAllocator` examiné ne prouve
pas son application à tout le JIT actuel.

## Prochain travail mesurable

1. Capturer, de façon bornée, l'inventaire des principales allocations CPU/RSX,
   leur propriétaire, leur taille, leurs références et leur durée de vie.
   Distinguer données actives, copies redondantes et caches rechargeables.
2. Choisir une cible réellement volumineuse et possédée. Prouver son contenu
   et son absence d'utilisateur avant éviction : backing vérifié, libération de
   la copie CPU, diminution mesurée du footprint, relecture et contrôle identique.
3. Mesurer bytes vivants, bytes sauvegardés puis libérés, bytes relus, blocs
   épinglés, hits/misses, latences p95/p99 et footprint hôte. Ne pas présenter un
   compteur de libérations cumulées comme une économie nette.
4. Comparer le même parcours de jeu et les mêmes réglages : temps jusqu'à la
   première frame, stabilité, FPS et queues de latence. Refuser une activation
   générale tant que le premier consommateur réel n'est pas validé.

Une expérience Mach d'ownership, si poursuivie, doit porter sur de nouveaux
blocs bornés et isolés, avec mesure avant/après des pages effectivement touchées.
Le RAMBench qui alloue jusqu'à épuisement n'est pas une politique de jeu.

## Incident RSX indépendant

Les nouveaux journaux montrent deux attentes à `0x60300510`, avec une valeur
observée égale à la valeur attendue moins un, puis une attente du consommateur
vidéo. Le FIFO reprend selon le message du cœur, mais les frames restent à zéro
dans la capture. Les compteurs de pression restent à zéro et aucun échec de
mapping n'est observé. Le blocage est établi ; sa cause initiale et une relation
avec NeoSwap restent à démontrer. Aucun réglage de synchronisation ni source
de cœur n'est changé sur cette seule hypothèse.

Voir [le relevé des journaux](neoswap-build396-findings.md) pour les lignes,
sessions, quantités et limites de preuve.

## Correctif préparé pour le candidat 398

- Retrait du bouton PS tactile dans le wrapper RPCS3 intégré. Home/PS et
  Select + Start sont consommés et routés vers le menu NeoStation existant,
  une fois par pression. Start et Select séparés conservent leur fonction.
- Correction du contrat de navigation des outils : quatre entrées sur iOS,
  trois ailleurs. Les contrôles pairing, fallback JIT et NeoSwap restent requis.
- Test réel de la politique d'entrée C++ rendu obligatoire dans la CI. Identité
  du candidat et préservation des sources non concernées restent contrôlées.
- Moteur de blocs CPU possédés et modifiables, checkpoint vérifié avant
  éviction, restauration, budgets bornés et ABI C utilisable depuis Swift.
  Preuves natives, Swift et SDK intégrées aux gates ; consommateur Core à suivre.
- Cœurs, JIT, réglages d'émulation, bibliothèques et données utilisateur conservés.

Ces corrections ne sont pas une revendication de nouveau swap de plusieurs
Gio ni une validation sur iPhone. L'IPA 398 n'est pas lancée par cette étude.

## Sources primaires

- [Apple : Virtual Memory Swap iPadOS 16](https://www.apple.com/newsroom/2022/06/ipados-16-takes-the-versatility-of-ipad-even-further/)
- [Apple WWDC22 : Profile and optimize your game's memory](https://developer.apple.com/videos/play/wwdc2022/10106/)
- [Apple : Bring your high-end game to iPhone 15 Pro](https://developer.apple.com/videos/play/tech-talks/111372/)
- [Apple : Increased Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
- [Apple : os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)
- [Apple XNU : swap backing store](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_compressor_backing_store.c)
- [Apple XNU : VM ledger flags](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h)
- [MeloNX : MachJitWorkaround au commit examiné](https://starforgejo.dev/projects/MeloNX/src/commit/c1d414def32cdc69862aeb4b1222be4ffb401cf0/src/Ryujinx.Memory/MachJitWorkaround.cs)
- [MeloNX : MemoryManagementUnix au commit examiné](https://starforgejo.dev/projects/MeloNX/src/commit/c1d414def32cdc69862aeb4b1222be4ffb401cf0/src/Ryujinx.Memory/MemoryManagementUnix.cs)
- [MeloNX : MemoryLimitManager au commit examiné](https://starforgejo.dev/projects/MeloNX/src/commit/c1d414def32cdc69862aeb4b1222be4ffb401cf0/src/MeloNX/MeloNX/Common/MemoryLimits/MemoryLimitManager.swift)
