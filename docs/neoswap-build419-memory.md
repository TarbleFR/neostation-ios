# NeoSwap — Build 419 : mémoire, jetsam et stalls RPCS3

Date : 8 octobre 2026. Sources de départ : `experimental`, commit
`255228445154a6a38b72463c50624426106cf258`, Build 418.

## Résultat et limites

Cette candidate corrige des comportements établis dans les sources : les réserves
de donneurs complètement inutilisés restaient détenues pendant une pression
mémoire ; un avertissement UIKit était seulement journalisé ; zéro octet renvoyé
par `os_proc_available_memory()` était traité comme une mesure absente ; un seul
échantillon pouvait ouvrir plusieurs Gio de nouveaux prêts relais.

Le plafond de capacité des donneurs passe de 5 à 7 **Gio** : 7 516 192 768 octets,
soit environ 7,52 **Go** décimaux. Ce plafond n'est ni une allocation au démarrage,
ni une limite jetsam relevée, ni une mesure de RAM résidente. L'application garde
ses contrôles système et les contrôles propres à chaque extension. Si l'objectif
est exactement 7 Go décimaux, il représente 7 000 000 000 octets, soit 6,52 Gio.
La RAM effectivement exploitable dépend de l'appareil, d'iOS, de la signature,
des autres processus, du GPU et du workload. Une réserve virtuelle et un fichier
mappé de 7 Gio ne prouvent pas que 7 Gio de RAM peuvent être utilisés.

**7 Go de RAM résidente sans jetsam et 60 FPS dans God of War III ne sont pas
validés.** Il n'existe ici aucune mesure physique de cette candidate sur iPhone.

## 1. Allocation progressive et réaction à la pression

Le donneur commence avec 16 Mio vérifiés. Une seule préparation est en vol.
Le besoin vient des prêts réellement vivants et des demandes du courtier, avec
une réserve bornée. Une cible élevée ne justifie jamais de toucher 7 Gio.

Le contrôleur prend la marge système mesurée, lui soustrait sa réserve
opérationnelle, puis distribue **au maximum 256 Mio par décision** entre relais
hôte et donneurs. La cadence normale est 250 ms ; ce plafond par décision n'est
pas une garantie de débit constant. Les demandes en vol sont également déduites
dans `nextDonationBudget`. Chaque donneur vérifie encore sa marge jetsam et la
marge système pendant la préparation des pages, par étapes de 8 Mio.

```cpp
// Extrait de la politique effective, sans appel noyau ni allocation.
const auto grant = out.growth_room_bytes < maximum_growth_grant_bytes
    ? out.growth_room_bytes : maximum_growth_grant_bytes;
const auto desired = saturating_add(in.relay_host_live_bytes, grant);
// Le quota réel est aussi borné par la capacité restante après la part invitée.
out.donor_room_bytes = grant > relay_growth ? grant - relay_growth : 0;
```

Sur WARN/CRITICAL, l'admission ferme et le stockage reçoit une demande de
réduction. L'avertissement UIKit déclenche immédiatement une décision et une
retenue de deux secondes, ensuite soumise à l'état du système. La file de
maintenance utilise explicitement `QOS_CLASS_UTILITY`.

Une nouvelle opération, `pool_retire_idle_donor(epoch, index, generation)`, vérifie
et retire l'admission sous le même mutex que l'acquisition : elle refuse si une
entrée est empruntée. Le gestionnaire ferme ensuite le helper et collecte les
vues inutilisées sur sa file de maintenance. Aucun buffer vivant n'est détruit.
Les callbacks de la génération retirée sont ignorés ; une nouvelle génération
peut reprendre après récupération et nettoyage. Les échecs de nettoyage gardent
la propriété des ressources et restent réessayables.

Cette réduction porte sur **un donneur entier sans prêt vivant**. Un donneur qui
possède encore un prêt ne rend pas ses autres chunks inutilisés dans cette
candidate : cela demanderait un protocole de libération par chunk avec preuve
de propriété et nouvelles validations. La fermeture d'une extension et la
restitution physique sont asynchrones, sans délai garanti par iOS.

Les diagnostics ajoutent `maximumGrowthGrantBytes`, `donorPressureRetirements`
et `donorCapacityCeilingBytes`. Les chiffres résidents, virtuels, retenus,
compressés et archivés gardent leurs définitions distinctes.

## 2. Jetsam : ce qu'une IPA peut réellement modifier

Jetsam utilise notamment des limites de `phys_footprint` par processus, avec
des valeurs actives/inactives, et des priorités de terminaison lors d'une pénurie
système. Une limite fatale peut déclencher la terminaison même sans avertissement
UIKit préalable. Le noyau traite aussi la pression et le thrashing à l'échelle
du système ; répartir les pages entre des extensions ne crée pas de RAM. Les
coalitions et les pages partagées rendent l'addition naïve des RSS incorrecte.
[1][2]

Il n'y a pas de seuil universel documenté « iPhone 8 Go = app 7 Go ». Mesurer
`TASK_VM_INFO.phys_footprint`, `os_proc_available_memory()` dans chaque processus,
la pression et les événements JetsamEvent de l'appareil. La fonction de marge
processus donne une information instantanée, pas une réservation exclusive ni
une garantie qu'une grosse allocation réussira. [3]

| Capacité / API | Effet et conditions |
|---|---|
| `com.apple.developer.kernel.increased-memory-limit` | Demande une limite augmentée sur les appareils compatibles ; maintien obligatoire d'un repli si elle n'est pas disponible. [4] |
| `com.apple.developer.kernel.extended-virtual-addressing` | Étend l'espace d'adressage ; ce n'est pas une augmentation de RAM physique. [5] |
| `get-task-allow` | Autorise le débogage dans une signature/provisioning compatible ; ne supprime pas jetsam. |
| `com.apple.developer.kernel.increased-debugging-memory-limit` | Déjà demandé dans les métadonnées du projet ; conserver comme capacité de débogage, sans en déduire une limite de production. |
| `com.apple.private.memorystatus` | Privilège restreint vérifié par XNU pour certaines opérations de `memorystatus_control`. Une chaîne ajoutée dans une IPA ne garantit pas son octroi. [2] |
| `com.apple.private.memory.peak` | Aucun contrat officiel vérifié pour donner 7 Go à cette app ; cette candidate ne l'ajoute pas. |
| `VM_FLAGS_NO_CACHE` | Paramètre de gestion de cache VM ; n'exempte pas les pages des ledgers ou de jetsam. [6] |
| `vm_allocate`, `mach_vm_map`, `mach_make_memory_entry_64` | Allocation virtuelle et partage d'objets Mach ; respect des droits, de la signature et du sandbox. |

Modifier une priorité jetsam n'annule ni une limite fatale, ni une pénurie
globale. Les contrôles privilégiés renvoient une erreur si le droit noyau manque.
Le code ne tente pas de s'auto-attribuer ces droits. Le sideloading enlève la
contrainte de distribution App Store, mais n'enlève pas la validation des droits
par iOS. Un certificat d'entreprise ne confère pas automatiquement les droits
réservés à Apple.

Les techniques concrètes retenues sont donc : croissance demandée et mesurée,
une préparation en vol, marges dans chaque helper, refus sous pression,
restitution des donneurs entièrement libres, nettoyage du cache de prêts relais,
éviction des données froides propres, et conservation des données sales ou
épinglées jusqu'à copie vérifiée. La mémoire purgeable ne convient qu'aux données
reconstructibles ; ne jamais déclarer volatile la seule copie d'une donnée invitée.

## 3. Architecture et communication

| Composant | Rôle | Chemin des données |
|---|---|---|
| Processus NeoStation / RPCS3 | PPU, SPU, RSX, JIT et buffers chauds | Pointeurs locaux vers des vues stables ; aucune requête XPC par accès |
| Créateur GuestPageRelay | Création et transfert authentifié de memory entries | L'hôte retient les droits Mach et crée ses alias ; le créateur termine selon le protocole existant |
| Extensions donneuses | Préparation des pages, preuve de partage et mesure des ledgers | Droits Mach transportés par NSXPC ; vues empruntées servies par le pool |
| Courtier hôte | Allocation, jetons, quotas et conservation des prêts | Acquisition en `try_lock`, tableaux de slots fixes, refus borné en cas de contention |
| Contrôleur de budget | Échantillons, admission, pression et réduction | File série utility, timer 250 ms et événements de pression |
| Worker stockage | Copie vérifiée des objets CPU possédés et froids | Fichier privé, quotas, générations, checksum et lectures/préchargement asynchrones |

GuestPageRelay est déjà adossé aux primitives Mach. `mach_vm_allocate` et
`vm_allocate` allouent dans une tâche ; ils ne donnent pas à eux seuls un partage
interprocessus. Le protocole actuel utilise les memory entries et des mappings
sans copie : le remplacer simplement par une allocation anonyme perdrait ce
contrat de transport et de propriété.

`shm_open`/`mmap(MAP_SHARED)` sont une autre option de backing, à vérifier dans les
sandboxes et conteneurs communs réels ; ce n'est pas une preuve d'avantage de
latence. Les mappings partagés restent soumis à la pression globale. Garder la
mémoire commune dans le plan de données et NSXPC dans le plan de contrôle.
Transporter identifiant d'objet, offset, longueur et génération, jamais un
pointeur brut d'un autre processus. Toutes les plages sont alignées à la taille
de page mesurée ; ne pas coder en dur 4 Kio sur iPhone.

Une file de commandes SPSC peut publier les descripteurs avec store-release /
load-acquire, mais doit avoir un seul producteur et consommateur, une capacité
bornée et un protocole d'arrêt. Des atomiques partagés ne suffisent pas à rendre
correct un protocole multiproducteur. Les lecteurs gardent leurs leases jusqu'à
la fin CPU/GPU ; aucun worker ne recycle une plage encore en vol.

## 4. Stockage froid et exemples C++/Swift

Le stockage n'ajoute pas de RAM physique. Une faute sur un `mmap` fichier peut
bloquer le thread qui touche la page ; elle n'est pas automatiquement compatible
avec un budget de frame de 16,67 ms. Le chemin possédé actuel archive et restaure
sur un worker, avec I/O explicite `pread`/`pwrite`, quotas et leases. Les données
invitées générales, locks, pointeurs actifs, pages JIT et commandes GPU en vol
ne sont pas placés arbitrairement sur disque. [7]

`F_RDAHEAD` active/désactive la lecture anticipée automatique ; `F_RDADVISE` donne
un conseil de lecture d'une plage. Ce sont des indications, pas des commandes
de résidence ni des garanties de fin d'I/O. La candidate conserve le chemin
vérifié : préchargement prioritaire des données prévues, annulation de la
spéculation sous pression, lectures demandées devant la spéculation, contrôle
de génération/checksum avant publication, et aucune suppression de la seule
copie sale. Un futur conseil de lecture par plage doit être comparé au worker
actuel avec p95/p99 et pression, en tenant compte de `F_NOCACHE` déjà utilisé. [8]

Exemple d'allocation : réserver une plage de 7 Gio sans la toucher n'est qu'une
opération d'adresse. Exemple de réservation et restitution, sans écriture des pages :

```cpp
#include <mach/mach.h>

bool reserveThenReleaseSevenGiB() {
    vm_address_t address = 0;
    const vm_size_t bytes = 7ULL * 1024 * 1024 * 1024;
    if (vm_allocate(mach_task_self(), &address, bytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return false;
    // Aucune preuve de résidence : ne pas memset cette plage pour tester le jeu.
    return vm_deallocate(mach_task_self(), address, bytes) == KERN_SUCCESS;
}
```

Ce code est illustratif et n'est pas ajouté au démarrage. En production,
les fonctions `Block::create_owned`,
`Block::map_borrowed` et `nextDonationBudget` assurent respectivement allocation
possédée, alias partagé et admission mesurée ; elles gèrent les erreurs et la
restitution. L'API suivante retire un donneur inutilisé sans attendre son IPC :

```cpp
const auto retired = neostation::donation::pool_retire_idle_donor(
    epoch, donorIndex, generation);
if (retired) {
    // Sur la file de contrôle : fermer la session puis collecter ses vues.
    // Une entrée empruntée provoque un refus ; ses octets restent valides.
    (void)neostation::donation::pool_collect_lost();
}
```

Exemple Swift utilisant l'ABI possédée du stockage, avec tous les résultats
vérifiés et sans lecture synchrone sur le thread de rendu :

```swift
import Foundation
import NeoSwapManaged // module C créé par le harness de validation

func archiveColdChunk(_ context: OpaquePointer, object: NeoSwapManagedObject,
                      chunk: UInt32, generation: UInt64) {
    // Le détenteur doit garder context vivant jusqu'à la fin du travail.
    var error = NeoSwapManagedError()
    error.struct_size = UInt32(MemoryLayout<NeoSwapManagedError>.size)
    error.abi_version = UInt32(NEOSWAP_MANAGED_ABI_VERSION)
    let checkpoint = NeoSwapManagedCheckpoint(context, object, chunk, generation, &error)
    guard checkpoint == 0 else { return } // conserver la copie sale
    let evicted = NeoSwapManagedEvict(context, object, chunk, &error)
    guard evicted == 0 else { return } // une lease peut encore épingler le chunk
}
// Appeler sur une file utility dédiée ; le thread PPU/SPU/RSX continue avec
// les objets chauds disponibles. Ne pas transférer librement context entre
// tâches Swift strictes sans wrapper de propriété et d'isolation approprié.
```

L'exemple Swift complet, avec écriture, checkpoint, éviction, restauration exacte,
destruction du contexte et lease conservée, est
`native/neoswap-storage/tests/managed_swap_swift_test.swift` ; la CI le compile
et l'exécute sur macOS, puis vérifie l'interface iOS. Les fonctions sont
synchrones : les placer sur un worker ne rend pas synchrone leur appel depuis
le thread du jeu, il faut acheminer les résultats par le protocole possédé.

## 5. CPU/GPU : ordre de travail pour God of War III

Cette candidate ne modifie pas les barrières ARM64 ni les verrous invités de
RPCS3. Elle réutilise le Core instrumenté déjà épinglé, avec ses identités exactes.
Il faut mesurer la scène fautive avant de modifier un verrou ou le JIT.

Le profil automatique God of War III actuel définit aussi `gpu.frame_limit`
à `30` dans `lib/services/rpcs3_game_profile_service.dart`. Cette candidate
conserve ce profil : une cible de 60 FPS exigerait d'abord de relever cette
limite, puis de vérifier le comportement du jeu et le temps de frame physique.
Les correctifs mémoire ne lèvent donc pas ce plafond de configuration.

| Cause mesurée | Intervention à évaluer | Invariant |
|---|---|---|
| Première recompilation SPU | Warmup au chargement des modules connus ; cache de métadonnées signé par version/configuration | Ne pas persister des pointeurs ARM64 ou du code machine avec adresses de processus |
| Plusieurs compilations du même module | État unique `absent/compiling/ready/failed`, publication release/acquire ; attente bornée uniquement des dépendances nécessaires | Pas de pointeur exécutable publié avant finalisation du code et cohérence instruction-cache |
| `vm::writer_lock` / range-lock | Attribuer séparément attente et durée détenue ; déplacer I/O et compilation hors de la section si les invariants le permettent | Réservations SPU, DMA, exceptions et ordre mémoire invités préservés |
| Attentes PPU/SPU | Événement/condition avec prédicat recontrôlé, ou primitive Darwin d'attente adaptée | Pas de réveil perdu ; priorité du propriétaire prise en compte ; ne pas déplacer arbitrairement la charge sur GPU |
| Soumissions RSX | Batchs bornés, réduire seulement les flushs redondants mesurés | Readbacks, barrières Vulkan, synchronisation CPU/GPU et fences restent corrects |
| Restaurations froides | Précharger au changement de scène sur worker, bornage des queues et admission à la frame | Pas de page fault disque imposé au rendu ; résultat manquant traité explicitement |

Linux `futex` n'est pas une API iOS. Une attente atomique/condition reste une
attente si le thread a besoin du résultat. Remplacer un lock correct par un
« verrou asynchrone » sans protocole de continuation peut introduire corruption
ou deadlock. Réduire aveuglément les barrières ARM64 peut rendre incorrecte
l'émulation. Le budget de 60 FPS est 16,67 ms par image ; mesurer p50/p95/p99,
temps de compilation, attente/durée détenue des locks, latences de stockage,
soumissions et GPU, pression et thermique. Aucune hausse mémoire ne garantit
une réduction des attentes SPU ou RSX.

## 6. Compilation, signature et validation

Le workflow `.github/workflows/neoswap-ipa.yml` porte le numéro 419 et ne démarre
le packaging qu'avec `[neoswap-ipa]` ou un déclenchement manuel. Il attend les
tests requis au **même SHA**, vérifie les Core épinglés, matérialise le projet
Flutter/iOS et ses extensions, puis compile l'ensemble. Les anciens tests ne
sont pas supprimés. Le manifeste de périmètre est mis à jour pour les fichiers
effectivement modifiés et les nouvelles notes, en conservant les contrôles des
autres émulateurs et des identités natives.

Sur un Mac préparé selon ce workflow, la compilation réelle est :

```bash
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios/DolphinDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER='' \
  COMPILER_INDEX_STORE_ENABLE=NO build
python3 build-utils/embed_rpcs3_core_lazy.py
python3 build-utils/embed_rpcs3_host_entitlements.py
python3 build-utils/embed_neoswap_donor_entitlements.py
```

Ces commandes seules ne téléchargent pas les Core et ne régénèrent pas le
projet ; exécuter les étapes antérieures du workflow exact. Le packaging y
inclut aussi les autres frameworks, ressources, licences et validations IPA.
La CI utilise une signature **ad hoc** pour les métadonnées d'entitlements,
sans identité Apple ni profil d'installation fourni dans cette session.

Pour une signature installable avec son compte développeur, utiliser une
identité et des profils réellement disponibles pour Runner et chaque extension,
et des bundle IDs associés. Exemple après configuration Xcode de ces profils :

```bash
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/NeoStation419.xcarchive \
  DEVELOPMENT_TEAM="$NEOSTATION_TEAM_ID" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/NeoStation419.xcarchive \
  -exportPath build/NeoStation419-export -exportOptionsPlist ExportOptions.plist
codesign -d --entitlements :- build/NeoStation419.xcarchive/Products/Applications/Runner.app
```

`ExportOptions.plist` doit correspondre au mode de distribution et aux profils
de tous les bundles. Lors d'une resignature manuelle, signer les dépendances et
extensions avant l'app, avec les entitlements appropriés et leurs profils ;
`codesign --deep` ne résout pas ce provisioning. La resignature SideStore habituelle
doit préserver les capacités effectivement accordées. Aucun certificat Apple
personnel de l'assistant n'est disponible.

Validation locale : politique et pool sous ASan/UBSan, fragmentation, protection
des prêts, refus des générations périmées, échec de cleanup puis récupération,
bornage des admissions ; contrats donneur et contrôle des douze langues. Dans
l'environnement Linux actuel, LeakSanitizer est désactivé parce que `/proc`
n'est pas utilisable par cet outil ; les tests stockage locaux nécessitent
liblz4-dev absent. Les vérifications Apple, stockage, Swift, simulateur et
packaging sont obligatoires dans la CI et leur résultat doit être rapporté
séparément. Un simulateur ne valide ni jetsam physique, ni le framerate du jeu.

Tests sur iPhone à effectuer après installation : même version/sauvegarde/scène
de God of War III, premier lancement et relancement, dix minutes de jeu incluant
les ralentissements, retour arrière/relancement, pression et thermique, puis
export des diagnostics NeoSwap/RPCS3 et de tout JetsamEvent. Ne pas provoquer une
allocation synthétique de 7 Gio dans une session de jeu. Comparer les mêmes
scènes à la Build 418 ; accepter uniquement des gains mesurés sans perte de
données ni régression. La RAM maximale stable reste un résultat de ces essais.

## Sources primaires

1. Apple, [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports).
2. Apple XNU, [kern_memorystatus.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/kern_memorystatus.h) et [kern_memorystatus.c](https://github.com/apple/darwin-xnu/blob/main/bsd/kern/kern_memorystatus.c). Les détails changent selon la version du noyau ; les constantes de `main` ne sont pas des seuils iPhone garantis.
3. Apple, [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory).
4. Apple, [Increased Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit).
5. Apple, [Extended Virtual Addressing](https://developer.apple.com/help/glossary/extended-virtual-addressing/).
6. Apple XNU, [vm_statistics.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h).
7. Apple, [Reducing your app's memory use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-memory-use).
8. Apple, [fcntl(2), F_RDAHEAD et F_RDADVISE](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html).
