# NeoSwap — Build 434 : enveloppe jetsam mesurée, étagères de prêts, préchargement froid

Date : 10 octobre 2026. Sources de départ : branche `Claude`, commit
`fda42ee0` (Build 433, dossiers de bibliothèque du mainteneur ; le numéro
433 est donc consommé). Candidate : Build 434, assemblée par
`retroarch-delivery.yml` (lane SideStore de la branche `Claude`), avec le Core
RPCS3 épinglé inchangé (`afb33454`, run `37620034517`). Appareil visé :
iPhone 16 Pro Max, 8 Go de RAM physique, iOS 18. Charge : RPCS3, God of War
III. Ce document répond aux six missions du mainteneur du 10 octobre 2026 ;
il distingue partout les défauts établis dans les sources, les mesures
disponibles, les hypothèses, les tests exécutés et ce qui reste à valider
sur l'iPhone.

## 0. Résultat et limites

Livré dans les sources de cette candidate :

1. **Enveloppe jetsam mesurée** (`NeoSwapBudget.h`) : le contrôleur de budget
   estime à chaque échantillon la limite réelle du processus hôte
   (`phys_footprint` + `os_proc_available_memory()`, marque haute de la
   session, bornée par la RAM physique), en déduit une réserve de sécurité,
   la part allouable et la marge restante ; il ralentit la croissance
   partagée (100 % / 50 % / 25 % de la dotation bornée) à l'approche de
   l'enveloppe, demande l'archivage des données froides avant que
   `os_proc_available_memory()` ne tombe sous la réserve opérationnelle, et
   traite le passage en arrière-plan comme une pression (croissance fermée,
   prêts vivants conservés).
2. **Étagères de prêts par classe de taille** (`NeoSwap.cpp`) : les prêts
   relais hôte libérés ou préparés attendent sur dix étagères (64 Kio …
   16 Mio, plus une étagère de tailles exactes). Une demande FAST prend un
   intervalle prêt de sa classe sous un simple `try_lock`, sans appel au
   backend ; un échec est mesuré par classe et le tick de maintenance
   suivant réapprovisionne chaque classe du nombre d'échecs constatés (au
   plus huit préparations et 4 ms par tick, hors du mutex du courtier). Les
   journaux Build 411 refusaient 7 084 demandes FAST sur 7 462 faute de
   mémoire prête : c'est ce défaut établi que les étagères traitent.
3. **Planificateur de préchargement froid** (`NeoSwapColdPrefetch.h`) :
   détection des parcours séquentiels, fenêtre de récence, priorité aux
   demandes effectives, annulation de toute spéculation sous pression,
   assistants `F_RDADVISE` / `F_RDAHEAD` (Darwin) et `posix_fadvise` (Linux),
   pré-faute d'une fenêtre mappée sur le worker. Module portable testé ; son
   raccordement au worker du `Store` est décrit en § 6 et reste à faire.
4. **Diagnostics** : objets `budget.hostEnvelope` et
   `relayHostLoans.shelves` dans `NeoSwap-v1.jsonl`, événements
   `application_background` / `application_foreground`.

Non livré et non validé : **7 Go de RAM résidente dans RPCS3 sans jetsam et
60 FPS dans God of War III ne sont pas démontrés.** Aucun test sur iPhone
n'a eu lieu pour cette candidate. Les changements du Core RPCS3 proposés en
§ 7 (seuils de pression dérivés de l'enveloppe, compilation SPU asynchrone,
remise à plat des attentes de verrous) ne sont pas dans cette IPA : ils
exigent une nouvelle construction du Core, son épinglage et leur propre
cycle de mesure. Les limites physiques sont rappelées en § 1.

## 1. Ce que les mesures existantes établissent

| Mesure | Source | Valeur | Conséquence |
|---|---|---|---|
| Empreinte hôte en jeu | `rpcs3-gow3-memory-build352.md` | 1,62 → 5,14 Gio en 7 min 42 s ; nettoyage RSX à environ 1,5 Gio de marge iOS | Limite active du processus ≈ 5,14 + 1,5 ≈ **6,6 Gio ≈ 7,1 Go** décimaux. Le « plafond à 5 Gio » est la politique de pression du Core (seuils fixes de marge) plus la réserve que laisse la limite, pas une limite noyau de 5 Gio. |
| Fixture du contrôleur | `test/neoswap_budget_test.cpp` | footprint 3 Gio, marge 3 900 Mio | Même ordre de grandeur (≈ 6,8 Gio), cohérent avec la lecture ci-dessus. |
| Régime lourd GoW3 | `docs/neoplay/BUILD412.md` (journaux Build 411) | 8,9 fps ; SPU 388 ms CPU/image sur 3,1 cœurs ; PPU 79 ms/image ; attente verrou PPU 120 ms/image ; 635 compilations SPU en 9 s ; 3 Gio de VRAM alloués en 15 s ; réclamations mémoire iOS toutes les 2 s pendant 90 s | La chute de fps précède d'environ 15 s la tempête de verrous ; la rafale de compilations et les allocations VRAM qui déclenchent les réclamations sont les causes premières mesurées. |
| NeoSwap en régime lourd | idem | 7 084 refus FAST sur 7 462 (`NEOSWAP_BUSY`, mémoire non prête) ; 110 Mio mobilisés au maximum | Le chemin FAST ne servait presque rien : défaut d'approvisionnement, pas de capacité. |
| Thermique | idem | état 1 pendant tout le régime lourd, jamais 2 ; pas de jetsam | Le régime lourd n'est ni thermique ni un jetsam. |

Conversion demandée : 7 Go décimaux = 7 000 000 000 octets = 6,52 Gio.
L'enveloppe mesurée (≈ 6,6 Gio) laisse donc, avec la réserve de sécurité de
cette candidate (limite/16 bornée à [384 Mio, 1 Gio], soit ≈ 420 Mio pour
6,6 Gio), environ **6,2 Gio allouables au processus hôte**, auxquels
s'ajoutent les pages relais et donneurs qui ne sont pas facturées au
processus. Le total mobilisable par le jeu (hôte + relais + donneurs) est
borné par la RAM physique libre de l'appareil (8 Go moins le système,
soit 6 à 6,5 Go), pas par l'addition des capacités virtuelles. Ces chiffres
sont des estimations à confirmer par les journaux `hostEnvelope` de la
Build 434 ; ils ne sont pas des valeurs publiées par le noyau.

Faisabilité des 60 FPS : en régime lourd, 388 ms de temps CPU SPU par image
(spins compris) sur environ trois cœurs représentent plus de 120 ms de
temps mural par image. Une image à 60 FPS dispose de 16,67 ms. Aucun
changement de synchronisation ne divise ce travail par sept ; seuls la
qualité du code SPU généré (LLVM AArch64) et le nombre de cœurs
performance de l'A18 Pro (deux) bornent ce régime. Les scènes légères
(54,7 fps mesurés avant la limite à 30 du profil) peuvent atteindre 60 FPS ;
l'objectif réaliste du régime lourd est de supprimer l'effondrement à
8,9 fps (compilations, réclamations, convoi de verrous), pas 60 FPS.

## 2. Architecture remaniée

```
   iPhone 16 Pro Max (8 Go)                      limite active mesurée ≈ 6,6 Gio
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ NeoStation / RPCS3 (processus hôte, bande FOREGROUND)                       │
 │  PPU · SPU · RSX · JIT · heaps ordinaires ─ comptés dans phys_footprint      │
 │  ┌───────────────────────┐  ┌──────────────────────┐  ┌───────────────────┐ │
 │  │ Courtier NeoSwap.cpp  │  │ Contrôleur de budget │  │ Stockage froid    │ │
 │  │ allocate(FAST) :      │  │ NeoSwapBudget.h      │  │ Store/ManagedSwap │ │
 │  │ try_lock → étagère de │◄─┤ 250 ms, QOS utility  ├─►│ + ColdPrefetch    │ │
 │  │ la classe → prêt      │  │ enveloppe + système  │  │ (worker utility)  │ │
 │  │ miss → compteur       │  │ rampe 100/50/25 %    │  │ F_RDADVISE,       │ │
 │  │ maintenance : refill  │  │ arrière-plan = press.│  │ pré-faute         │ │
 │  └──────────┬────────────┘  └──────────────────────┘  └───────────────────┘ │
 │             │ vm_map (alias 64 Kio) — plan de données, zéro IPC par accès    │
 └─────────────┼───────────────────────────────────────────────────────────────┘
               ▼
 ┌─────────────────────────────┐   ┌──────────────────────────────────────────┐
 │ Objets nommés du relais     │   │ Donneurs (≤ 8 extensions NeoSwapDonor)   │
 │ 16 × 512 Mio, LEDGER_TAGGED │   │ objets purgeables NONVOLATILE, vérifiés  │
 │ créateur sorti → pages non  │   │ page par page, facturés aux donneurs,   │
 │ facturées à aucun processus │   │ chaque donneur mesure sa propre marge    │
 └─────────────────────────────┘   └──────────────────────────────────────────┘
   plan de contrôle : NSXPC (droits Mach transportés), hors image, jamais par accès
```

| Composant | Rôle | Chemin des données | Changement Build 434 |
|---|---|---|---|
| Processus hôte | PPU, SPU, RSX, JIT, buffers chauds | pointeurs locaux vers des vues stables | lit l'enveloppe, prend ses prêts sur les étagères |
| Créateur GuestPageRelay (`NeoSwapPageRelay.appex`) | crée 16 objets nommés de 512 Mio avec `MAP_MEM_NAMED_CREATE \| MAP_MEM_LEDGER_TAGGED`, transmet les droits, quitte | aucune donnée ; la sortie observée (`DISPATCH_PROC_EXIT`) désaffecte les pages de tout registre | inchangé |
| Donneurs (`NeoSwapDonor.appex`) | pages purgeables vérifiées, facturées au donneur, prêtées par vues | vues empruntées, zéro IPC par accès | inchangé ; plafond 7 Gio conservé |
| Courtier (`NeoSwap.cpp`) | allocation, jetons, quotas, étagères | `try_lock`, tableaux de slots fixes, refus borné | étagères par classe, réapprovisionnement mesuré hors mutex |
| Contrôleur de budget (`NeoSwapBudget.h`, `NeoSwapPlugin.mm`) | échantillons, admission, pression, enveloppe | file série `QOS_CLASS_UTILITY`, timer 250 ms | enveloppe mesurée, rampe, arrière-plan |
| Stockage (`native/neoswap-storage`) | copie vérifiée des objets CPU froids possédés | `pread`/`pwrite` sur worker, quotas, générations, CRC | planificateur de préchargement (module livré, raccordement décrit) |

Invariants conservés : aucun prêt vivant n'est révoqué par une décision ;
une capacité virtuelle n'est jamais annoncée comme RAM résidente ; le
repli vers l'allocateur ordinaire de RPCS3 reste disponible à chaque refus ;
les pages JIT, la mémoire invitée mutable et les ressources GPU en vol ne
passent jamais par le stockage.

## 3. Mission 1 — allocation progressive jusqu'à l'enveloppe

### 3.1 Stratégie

La croissance n'est jamais une allocation au démarrage. Trois autorités
se superposent, de la plus large à la plus fine :

1. **Marge système mesurée** (`donation::system_headroom`, pages libres et
   purgeables du noyau) : elle seule admet de nouveaux prêts, par dotation
   bornée à 256 Mio par décision de 250 ms (inchangé).
2. **Enveloppe du processus hôte** (nouveau) : limite estimée, réserve de
   sécurité, part allouable et marge restante. La marge module la dotation
   (rampe) et déclenche l'archivage froid ; elle n'ouvre jamais seule une
   admission.
3. **Marges propres à chaque extension** (inchangé) : chaque donneur vérifie
   sa marge jetsam et la marge système par pas de 8 Mio pendant la
   préparation.

```cpp
// NeoSwapBudget.h — enveloppe mesurée, extrait de la politique effective.
constexpr std::uint64_t host_limit_sample(const Inputs& in) noexcept {
    if (!in.host_footprint_valid || !in.host_available_valid) return 0;
    const auto sum = saturating_add(in.host_footprint_bytes, in.host_available_bytes);
    return in.physical_bytes && sum > in.physical_bytes ? in.physical_bytes : sum;
}
// Dans decide() : marque haute de la session, réserve, part allouable, marge.
const auto limit = sample > previous_limit ? sample : previous_limit;
out.host_safety_reserve_bytes = host_safety_reserve(limit);            // clamp(limit/16, 384 Mio, 1 Gio)
out.host_allocatable_bytes = limit - out.host_safety_reserve_bytes;
out.host_room_bytes = out.host_allocatable_bytes - in.host_footprint_bytes;
out.growth_ramp_percent = growth_ramp(out.host_room_bytes, out.host_safety_reserve_bytes, in.foreground);
const auto bounded_grant = ramped(min(growth_room, maximum_growth_grant_bytes), out.growth_ramp_percent);
```

| Marge hôte restante | Rampe | Dotation maximale par décision |
|---|---|---|
| ≥ 2 réserves (≈ 840 Mio pour une limite de 6,6 Gio) | 100 % | 256 Mio |
| entre 1 et 2 réserves | 50 % | 128 Mio |
| < 1 réserve | 25 % | 64 Mio (la rampe freine, elle ne ferme pas) |
| marge nulle | 25 % + `storage_shrink_requested` | 64 Mio, archivage demandé |
| arrière-plan, WARN/CRITICAL | 0 %, état `pressure` | 0, prêts vivants conservés |

### 3.2 Éviter le jetsam pendant une allocation massive

- La somme footprint + marge est relevée par le même tick ; la marque haute
  absorbe la gigue de deux lectures non simultanées et la borne physique
  empêche une somme aberrante d'ouvrir du crédit.
- La dotation reste bornée (256 Mio) et rampée : entre deux échantillons,
  les allocations ordinaires du Core (LLVM, textures) ne peuvent pas
  franchir la réserve de sécurité, dimensionnée sur la rafale mesurée
  (3 Gio de VRAM en 15 s, soit ≈ 50 Mio par tick de 250 ms, bien sous une
  réserve de 384 Mio minimum).
- Les demandes en vol sont déduites (`nextDonationBudget`), une seule
  préparation de donneur est en vol, et chaque donneur refuse de son côté.
- L'arrière-plan ferme tout : iOS place le processus dans la bande
  `BACKGROUND`, éliminée en premier, et peut lui appliquer une limite
  inactive distincte dont la valeur n'est pas publiée. Attendre le signal
  noyau serait trop tard ; la décision ferme l'admission dès
  `UIApplicationDidEnterBackgroundNotification`.

### 3.3 Libération rapide sous pression

Dans l'ordre, sur le tick qui observe WARN/CRITICAL, l'avertissement UIKit
ou l'arrière-plan : admission fermée ; étagères vidées
(`NeoSwap_RelayLoanMaintain(0, 1)`, les intervalles parqués retournent au
relais) ; archivage froid demandé au stockage ; donneurs entièrement
inutilisés retirés (`reclaimIdleDonors`, Build 419) ; prêts vivants
conservés, car un pointeur publié ne se migre pas. Ce qui ne peut pas être
libéré vite : les objets Metal/MoltenVK du Core, qui obéissent à la
politique de pression du Core (§ 7.3).

## 4. Mission 2 — jetsam : mécanisme et contournements réels

### 4.1 Mécanisme (XNU `kern_memorystatus`)

- **Registre par processus.** Chaque tâche porte un ledger `phys_footprint`
  = pages anonymes sales (internes) + pages compressées **à leur taille
  non compressée** + mappings IOKit/IOSurface (textures et buffers Metal
  compris) + purgeable non volatile + tables de pages. Les pages de
  fichiers (propres ou sales, « externes ») et le purgeable volatile n'y
  sont pas comptés.
- **Limites actives et inactives.** `launchd`/RunningBoard fixent par
  processus une limite active et une limite inactive en Mio
  (`MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES`), marquées fatales ou non.
  Pour une application iOS au premier plan la limite est fatale : le
  dépassement du ledger (`memorystatus_on_ledger_footprint_exceeded`)
  termine le processus avec la cause `per-process-limit` dans le rapport
  `JetsamEvent` (`.ips`), sans avertissement préalable garanti. Le noyau ne
  publie pas la valeur ; `os_proc_available_memory()` en donne le reste
  instantané, et `task_info(TASK_VM_INFO)` le `phys_footprint`. C'est la
  base de l'enveloppe de § 3.
- **Bandes de priorité.** `JETSAM_PRIORITY_IDLE` (0) … `BACKGROUND` (3) …
  `FOREGROUND` (10) … `AUDIO_AND_ACCESSORY` (12) … `CRITICAL` (19). En
  pénurie système (`memorystatus_available_pages` sous les seuils
  `pressure` puis `critical`, calculés par appareil), le thread jetsam
  tue de la bande la plus basse vers le haut ; une application au premier
  plan n'est atteinte qu'après les autres. Les notifications de pression
  (`DISPATCH_MEMORYPRESSURE_WARN`/`CRITICAL`) précèdent ces éliminations.
- **Autres causes.** Thrashing du compresseur ou du cache de fichiers,
  pénurie d'espace compresseur, famine du pageout, épuisement de la zone
  map (tue le plus gros processus), `MEMORY_SUSTAINED_PRESSURE`. L'iPhone
  n'a pas de swap pour les pages anonymes : le compresseur est la seule
  détente, et il compte toujours à la taille non compressée dans le
  footprint.

### 4.2 Ce qui fonctionne pour une application sideloadée

| Technique | Effet réel | Conditions |
|---|---|---|
| `com.apple.developer.kernel.increased-memory-limit` | limite active augmentée sur les appareils compatibles | profil de provisionnement d'un compte développeur payant ; déjà demandé par `Runner.entitlements` et par les deux extensions ; sans ce profil, SideStore le retire et la limite par défaut s'applique |
| `com.apple.developer.kernel.extended-virtual-addressing` | espace d'adressage étendu (réservations de RPCS3 : base, sudo, exec, stat) | idem ; aucune RAM physique |
| `com.apple.developer.kernel.increased-debugging-memory-limit` | limite de débogage ; conservé à titre de capacité, aucune valeur de production déduite | idem |
| Objets nommés `MAP_MEM_LEDGER_TAGGED` dont le créateur quitte (relais) | pages facturées à aucun processus ; seule la pénurie globale les limite | mécanisme en place ; capacité 8 Gio ; résidence non mesurée |
| Objets purgeables non volatils des donneurs | facturés au donneur, pas à l'hôte | chaque extension garde sa propre limite et sa mesure |
| Mappings `MAP_SHARED` de fichiers du conteneur (repli fichier NeoSwap) | pages externes, hors footprint ; écriture différée par le pager | coût d'E/S et usure ; jamais pour des données chaudes |
| Purgeable **volatile** | hors footprint, mais le noyau peut vider l'objet à tout moment | réservé aux caches reconstructibles ; jamais la seule copie d'une donnée invitée |
| Mesure continue de l'enveloppe | croissance rampée, archivage anticipé | livré (§ 3) |

### 4.3 Ce qui ne fonctionne pas, et pourquoi

| Demande | Verdict |
|---|---|
| Manipuler `jetsam_priority` du processus | `memorystatus_control` exige le droit privé `com.apple.private.memorystatus` ; AMFI refuse à une application tierce tout droit `com.apple.private.*` absent de son profil, et Apple n'en délivre aucun aux tiers. Une IPA qui l'ajoute ne se lance pas (signature invalide) ou voit l'appel refusé (`EPERM`). |
| `com.apple.private.memory.peak` | aucun contrat vérifié dans XNU public pour cette clé ; non ajouté. |
| `mach_memory_entry_ownership(…, TASK_NULL, …, VM_LEDGER_FLAG_NO_FOOTPRINT)` | demande `com.apple.private.memory.ownership_transfer` ; le relais obtient le même effet par la sortie du créateur, sans droit. |
| `VM_FLAGS_NO_CACHE` | drapeau de gestion de cache des pages d'un objet ; aucune incidence sur le ledger ni sur jetsam. |
| Limite inactive, tailles de bandes, seuils `critical` | non réglables depuis l'application. |
| Certificat d'entreprise, TrollStore, jailbreak | l'entreprise n'accorde pas plus de droits privés ; TrollStore (CoreTrust) ne couvre pas un iPhone 16 Pro Max ; aucun jailbreak public pour l'A18 Pro. |

### 4.4 Processus auxiliaires sous les seuils

Le créateur du relais ne détient rien après sa sortie : la capacité est
publiée seulement après `DISPATCH_PROC_EXIT` observé pour le PID authentifié.
Les donneurs mesurent chacun `os_proc_available_memory()` et refusent toute
croissance à l'approche de leur propre limite ; le contrôleur retire les
donneurs entièrement inutilisés sous pression. Répartir des pages entre
extensions ne crée pas de RAM : la pénurie globale reste la vraie borne.

## 5. Mission 3 — communication interprocessus

| Mécanisme | Partage | Comptabilité | Verdict |
|---|---|---|---|
| `mach_make_memory_entry_64` + `vm_map` (actuel) | zéro copie, droits Mach transportés par NSXPC (`xpc_dictionary_set_mach_send`) | ledger tagué, désaffecté à la sortie du créateur | conservé : seul chemin hors footprint |
| `shm_open` + `mmap(MAP_SHARED)` | zéro copie | pages anonymes partagées facturées à chaque processus qui les mappe | aucun gain ; non retenu |
| `mach_vm_allocate` / `vm_allocate` | intra-tâche | internes | pas un partage ; utilisé seulement pour des réservations |
| `mmap(MAP_SHARED)` de fichiers | zéro copie | externes, pager | repli fichier existant |

Le plan de données n'a **aucune IPC par accès** : la latence d'un prêt
FAST est celle d'un `try_lock` non contendu et d'un parcours d'étagère
(quelques dizaines de nanosecondes), ou celle de l'allocateur ordinaire
en cas d'échec. Le plan de contrôle (NSXPC) reste hors image. Les
préparations de la maintenance (`create` + `map`, quelques dizaines de
microsecondes chacune) s'exécutent désormais **hors du mutex du courtier**,
pour qu'une demande FAST concurrente ne retombe pas en `broker_busy`.

```cpp
// NeoSwap.cpp — chemin FAST (RSX) : jamais d'attente, jamais de backend.
std::unique_lock guard(b.mutex, std::defer_lock);
if (fast && !guard.try_lock()) { b.fast.broker_busy++; return NEOSWAP_BUSY; }
// … étagère exacte, puis étagère de la classe ; sinon la classe mémorise l'échec :
if (fast) { if (klass < shelf_exact_class) b.shelves[klass].misses++; return false; }

// Maintenance (QOS utility, 250 ms) : cible = échecs du dernier tick, bornée à 32.
shelf.target = min(misses - last_misses, shelf_capacity);
// Plan sous le mutex (plus petites classes d'abord, quota et budget projetés),
// préparation hors mutex (≤ 8 intervalles, ≤ 4 ms), rangement sous le mutex.
```

Synchronisation sans blocage : une seule section critique par tick pour le
plan et une pour le rangement ; aucun producteur multiple sur une file
partagée ; les compteurs lus sans verrou sont des atomiques relâchés
destinés au seul affichage. `futex` n'est pas une API iOS ; l'attente
`atomic_wait` de RPCS3 sur Darwin repose déjà sur `__ulock_wait`, et iOS 18
expose publiquement `os_sync_wait_on_address` (§ 7.2).

## 6. Mission 4 — stockage comme mémoire froide

Règles inchangées : le stockage n'ajoute pas de RAM ; une faute sur un
`mmap` fichier bloque le thread qui touche la page, incompatible avec un
budget de 16,67 ms ; les données invitées, les verrous, les pages JIT et
les commandes GPU en vol ne vont jamais sur disque. Le chemin possédé
(`Store`, `ManagedSwap`, `SourceArchive`) archive et restaure sur worker
avec `pread`/`pwrite`, quotas, générations et CRC32 (`F_NOCACHE` sur les
écritures).

Apport de cette candidate : un planificateur portable et deux assistants
d'E/S, à raccorder au worker du `Store`.

```cpp
// NeoSwapColdPrefetch.h — sur le worker utility, jamais sur un thread de frame.
neostation::prefetch::Planner planner;
planner.observe(object, chunk, chunk_count, now_ms, /*demanded=*/true);   // le consommateur attend ce chunk
const auto plan = planner.plan(now_ms, pressure);                         // demandés, puis séquentiels, puis récents
for (size_t i = 0; i < plan.count; ++i) {
    const auto& e = plan.entries[i];
    (void)neostation::prefetch::advise_read(fd, offset_of(e.object, e.chunk), chunk_bytes); // F_RDADVISE
}
// Au rangement d'une fenêtre restaurée, avant publication au consommateur :
neostation::prefetch::prefault(window, bytes, page_bytes);
```

Point de raccordement : `Store::request(handle, speculative)` reçoit déjà
les demandes spéculatives et compte `prefetch_used/wasted/cancelled`. Le
worker appelle `observe()` à chaque `request`/`try_acquire`, puis `plan()`
en tête de sa boucle ; les entrées `demanded` deviennent des lectures
prioritaires, les entrées `sequential`/`recent` des `request(…, true)`
précédées de `advise_read`. Sous `Pressure::warning`, `plan(now, true)`
n'émet que les demandes effectives. Ce raccordement modifie `Store.cpp`
(verrouillé par le manifeste de référence natif) et sera proposé comme
delta natif distinct, avec la preuve `run_validation.py` et la mesure
p95/p99 avant/après ; il n'est pas dans la Build 434.

Exemple Swift équivalent pour un worker propre à Swift (même technique,
sans passer par l'en-tête C++) :

```swift
import Foundation

final class ColdReadAdvisor {
    private let queue = DispatchQueue(label: "neostation.neoswap.cold-read", qos: .utility)
    /// Conseille au noyau de lire `length` octets à `offset` ; indication seulement.
    func advise(fd: Int32, offset: off_t, length: Int32) {
        queue.async {
            var advice = radvisory(ra_offset: offset, ra_count: length)
            if fcntl(fd, F_RDADVISE, &advice) < 0 {
                // errno conservé par l'appelant ; aucune résidence n'est garantie.
            }
        }
    }
    /// Pré-faute une fenêtre restaurée sur le worker, avant sa publication.
    func prefault(_ base: UnsafeRawPointer, bytes: Int, page: Int) {
        var offset = 0
        while offset < bytes { _ = base.load(fromByteOffset: offset, as: UInt8.self); offset += page }
    }
}
```

## 7. Mission 5 — stalls CPU/GPU : causes mesurées et plan

Aucun verrou, barrière ou réglage d'émulation n'est modifié dans cette
candidate (Core épinglé). Les changements ci-dessous sont des deltas de
Core à construire, épingler et mesurer un par un.

### 7.1 Rafale de compilations SPU (cause première mesurée)

635 compilations en 9 s sur les threads SPU eux-mêmes, une image de 6,2 s.
Plan : état unique par programme `absent / compiling / ready / failed`
(publication release/acquire), compilation sur worker, exécution par
l'interpréteur AArch64 existant (`SPUInterpreterGateway.h`) tant que le
module n'est pas prêt, puis bascule sans attendre les dépendances non
nécessaires. Le warmup des modules connus (`SPUWarmupPolicy.h`, Build 411)
reste la première ligne. Invariant : aucun pointeur exécutable publié avant
finalisation du code et cohérence de l'instruction cache ; aucun objet
ARM64 avec adresses de processus persisté.

```cpp
// Proposition (Core) : dispatch hybride, pseudo-code sur la structure existante.
enum class spu_module_state : u8 { absent, compiling, ready, failed };
struct spu_module_slot { std::atomic<spu_module_state> state{spu_module_state::absent}; spu_function_t code{}; };
spu_function_t spu_runtime::dispatch_hybrid(spu_module_slot& slot, const spu_program& program) {
    switch (slot.state.load(std::memory_order_acquire)) {
    case spu_module_state::ready:  return slot.code;                 // JIT
    case spu_module_state::absent: if (slot.state.compare_exchange_strong(expected_absent, compiling))
                                        m_workers.submit([&] { build(slot, program); });   // hors thread SPU
                                   [[fallthrough]];
    default:                       return g_interpreter_gateway;      // interpréteur en attendant
    }
}
```

### 7.2 `vm::writer_lock` / range-lock (amplificateur mesuré)

Les PPU sont immobilisés jusqu'à 1,5 s par seconde derrière le verrou
exclusif pris par PUTLLC (chemin lourd), STORE128, `stwcx` et
`reservation_op`. Le Core épinglé attribue déjà chaque acquisition
(`wl_putllc`, `wl_store128`, `wl_ppu_stcx`, `wl_resop`) avec ses temps
d'acquisition et de maintien : **lire ces compteurs sur l'iPhone avant
toute modification**. Leviers, dans l'ordre : réservations SPU relâchées
pour le profil GoW3 (hypothèse Build 412, déjà dans le profil) ; réduire
le nombre d'acquisitions exclusives (ne prendre le verrou que pour un
PUTLLC qui change réellement des données, en comparant d'abord, ce que
le chemin relâché fait) ; raccourcir le maintien (aucune E/S ni
compilation sous le verrou). Remplacer le verrou par des « verrous
asynchrones » n'est pas possible : il protège la cohérence des réservations
128 octets entre PPU, SPU et RSX ; une attente reste une attente si le
thread a besoin du résultat. Les attentes utilisent déjà `atomic_wait`
(`__ulock_wait` sur Darwin) ; `os_sync_wait_on_address` (iOS 18) est
l'équivalent public, à évaluer pour `atomic_wait_engine` sans changer le
protocole.

### 7.3 Boucle de réclamation mémoire (cause mesurée du régime lourd)

Les réclamations toutes les 2 s pendant 90 s viennent de
`IOSMemoryPressurePolicy.h` : seuils **fixes** de marge
(`high_footprint_headroom_moderate_enter` = 2 560 Mio pour GoW3, sévère
1 280/1 536 Mio, fatal 512/768 Mio) sur `os_proc_available_memory()`.
Avec une limite de 6,6 Gio, le mode modéré commence à 4,1 Gio d'empreinte
et purge textures et chaînes RTT, qui sont rechargées, d'où le cycle.
Delta de Core proposé, dérivé de l'enveloppe plutôt que de constantes :

```cpp
// IOSMemoryPressurePolicy.h (proposition) : seuils relatifs à la limite mesurée.
constexpr std::uint64_t moderate_enter(std::uint64_t limit) { return std::max<std::uint64_t>(512 * MiB, limit / 8); }  // ≈ 845 Mio pour 6,6 Gio
constexpr std::uint64_t moderate_exit (std::uint64_t limit) { return moderate_enter(limit) + moderate_enter(limit) / 2; }
constexpr std::uint64_t severe_enter  (std::uint64_t limit) { return std::max<std::uint64_t>(384 * MiB, limit / 12); }
// fatal inchangé (512/768 Mio). Limiteur : au plus une purge modérée par 8 s,
// et jamais pendant les 3 s qui suivent un changement de scène (chargement).
```

Effet attendu : le processus utilise ≈ 1,7 Gio de plus avant la première
purge (4,1 → 5,8 Gio pour 6,6 Gio de limite) tout en gardant une réserve
d'une demi-rafale mesurée. La limite est lue par le Core de la même façon
que l'enveloppe (footprint + marge, marque haute). À mesurer : `.ips`
JetsamEvent absent, `fps_hold`, nombre de purges.

### 7.4 RSX / GPU

- Soumissions par lots : grouper les `vkQueueSubmit` d'une image, éviter
  `vkQueueWaitIdle` hors readback ; MoltenVK : `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS`
  et synchronisation par `MTLSharedEvent` (déjà utilisé via
  `metal_event.mm`) plutôt que par attente CPU.
- Budget VRAM dérivé de l'enveloppe : la purge du cache de textures devient
  proportionnelle (`texture_cache_quota_*` en fraction de la limite) au
  lieu de paliers fixes de 384/256/128 Mio.
- Les buffers hôte-visibles (type 3) et les images VDEC (type 4) prennent
  désormais leurs prêts sur les étagères : moins d'allocations Vulkan
  système, moins d'interruptions du thread RSX par le courtier.

### 7.5 JIT ARM64 et barrières

Ne pas réduire aveuglément les barrières : `sync`/`lwsync`/`eieio` PPU et
l'ordre des DMA SPU sont des contrats du jeu. Deux pistes mesurables :
abaisser `lwsync` vers des paires `stlr`/`ldar` là où la sémantique
PowerPC le permet, et supprimer les barrières redondantes consécutives
dans les séquences générées (les plis ARM64 de la Build 345 n'ont pas
touché aux barrières). Chaque changement exige les tests de réservation
existants et une session longue sans corruption.

## 8. Mission 6 — entitlements et API

Entitlements effectivement embarqués par la CI (signature ad hoc) et
attendus du profil SideStore : `get-task-allow`,
`com.apple.developer.kernel.extended-virtual-addressing`,
`com.apple.developer.kernel.increased-memory-limit`,
`com.apple.developer.kernel.increased-debugging-memory-limit` (Runner) ;
`increased-memory-limit` et `increased-debugging-memory-limit` pour les
extensions donneur et relais. Aucune clé `com.apple.private.*` n'est
ajoutée (§ 4.3). Vérification après installation :

```bash
codesign -d --entitlements :- Payload/Runner.app          # ce que SideStore a réellement accordé
```

et, dans `NeoSwap-v1.jsonl`, `hostEffectiveMemoryEntitlements`,
`processAvailableBytes` au `process_start` et `budget.hostEnvelope`.
API publiques utilisées : `task_info(TASK_VM_INFO)` (`phys_footprint`,
`compressed`), `os_proc_available_memory()`, `host_statistics64`,
`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`, `vm_map`/`vm_deallocate`/`vm_region_64`,
`mach_make_memory_entry_64`, `vm_purgable_control`, `fcntl(F_RDADVISE,
F_RDAHEAD, F_NOCACHE, F_PREALLOCATE)`, `madvise`. API privées : aucune
nouvelle ; le lancement d'extension par `NSExtension` et le transport
`xpc_dictionary_set_mach_send` existants sont résolus à l'exécution.

## 9. Compilation et livraison

La candidate est assemblée par le workflow `retroarch-delivery.yml`
(`workflow_dispatch`, `--ref Claude`, `build_number=434`), qui exécute les
contrôles Dart/Python, les contrôles natifs macOS, puis la compilation
Release à froid, le scellement ad hoc et le chiffrement de l'artefact pour
le destinataire `build-utils/delivery-424-recipient.pem` (clé privée chez
le mainteneur). Le Core RPCS3, les Cores ARMSX2/Dusklight/KartPad et les
cœurs libretro sont réutilisés par identité exacte.

```bash
# Sur un Mac préparé comme le workflow (Flutter 3.47.2, Xcode 26.3, pods, Cores téléchargés) :
flutter build ios --release --no-codesign --config-only --no-pub --build-number=434 \
  --dart-define-from-file=.dart-defines.json
python3 build-utils/configure_rpcs3_ios_v2.py && python3 build-utils/configure_neoswap_donor.py
python3 build-utils/configure_neoswap_storage.py && pod install --project-directory=ios
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios/DolphinDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  PROVISIONING_PROFILE_SPECIFIER='' COMPILER_INDEX_STORE_ENABLE=NO build
python3 build-utils/embed_rpcs3_core_lazy.py && python3 build-utils/embed_rpcs3_host_entitlements.py
python3 build-utils/embed_neoswap_donor_entitlements.py
python3 packages/dolphin_internal_bridge/ci/build_support.py package      # dist/NeoStation.ipa
python3 build-utils/delivery_benchmark.py seal                             # signatures ad hoc vérifiées
```

Signature avec un compte développeur (remplace la signature ad hoc ; les
extensions et frameworks se signent avant l'application, chacun avec son
profil ; `codesign --deep` ne résout pas le provisioning) :

```bash
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/NeoStation434.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/NeoStation434.xcarchive \
  -exportPath build/NeoStation434-export -exportOptionsPlist ExportOptions.plist   # method: development
```

Aucun certificat Apple n'est disponible dans cette session : l'IPA produite
par la CI est scellée ad hoc et s'installe par SideStore, qui applique la
signature et le profil du compte configuré (payant pour que
`increased-memory-limit` soit accordé).

Identité de la livraison (renseignée après la compilation, § 11).

## 10. Validation

Exécuté localement (Linux, GCC 13.3, AddressSanitizer + UndefinedBehaviorSanitizer ;
Clang 18 sans sanitizer) sur cette révision :

| Suite | Résultat |
|---|---|
| `test/neoswap_budget_test.cpp` (enveloppe, rampe, arrière-plan, marque haute, bornes) | PASS |
| `test/neoswap_relay_loans_test.cpp` (courtier + backend de production : étagères, échecs mesurés, réapprovisionnement borné, stock conservé, sauts de quota, prises concurrentes, cycle de vie) | PASS |
| `test/neoswap_cold_prefetch_test.cpp` (planificateur, conseils de lecture et pré-faute sur fichier réel) | PASS |
| `neoswap_test`, `client_stats`, `usage_policy`, `capacity_probe`, `demand`, `cpu_buffers`, `pool_fragmentation`, `preparation`, `retirement_proof`, `relay_backend`, `memory_samples` | PASS (inchangés, rejoués car `NeoSwap.cpp` a changé) |

Portes de périmètre de la lane de livraison (toutes vertes localement) :
`verify_delivery_reuse.py` reçoit le delta `NEOSWAP_434_DELTA` (sources
NeoSwap, tests, manifeste de hachage) ; `test/delivery_pipeline_test.py`
continue d'exiger des moteurs natifs byte-identiques et n'admet sous
`native/` que le manifeste de hachage ; `test/retroarch_baseline_scope_test.py`
reste intact (aucun fichier de bibliothèque ni moteur natif modifié).

Porte de périmètre NeoSwap (`check_neo_swap_scope.py`, exécutée par
`neoswap-check.yml`, `neoplay-check.yml` et `neoswap-ipa.yml`, aucune
n'étant dans la lane de livraison) : `native/import-memory-candidate.json`
est rafraîchi (hachages des fichiers modifiés, trois ajouts, une puce de
périmètre) et quatre entrées dont les fichiers ont été supprimés par le
retour à la bibliothèque 419 (`afc0a96d`, 8 octobre) sont retirées du
manifeste et des listes blanches (`retroarch_folder_recovery.dart`,
`retroarch_library_importer.dart`, leurs deux tests Dart) : sans cela la
porte s'arrêtait sur un fichier absent. **Cette porte reste rouge sur
`Claude` pour une cause antérieure à cette candidate** : quatre de ses
comparaisons byte pour byte visent des révisions que les commits du
mainteneur ont dépassées depuis (`neoplay-check.yml` et `ios-ci.yml` par la
livraison 422 `7416150d`, `neoswap-ipa.yml` par la restauration 419
`afc0a96d`, `Armsx2InternalBridgePlugin.mm` par le nettoyage `a5650b9b`).
Ré-épingler ces quatre comparaisons sur ces commits est la correction
proposée ; elle n'a pas été appliquée ici, car elle change des assertions de
porte et relève du mainteneur. Le workflow `neoswap-check.yml` s'arrête donc
à cette étape, après les contrôles du gestionnaire mémoire, des échantillons
et des douze langues, et avant les suites du courtier, que cette candidate
a exécutées localement (tableau ci-dessus) ; la compilation iPhone arm64 du
courtier et du plugin est faite par la lane de livraison, et les sondes
Simulator par `neoswap-relay-check.yml` et `neoswap-donation-check.yml`,
qui n'exécutent pas cette porte.

Obligatoires en CI Apple avant toute conclusion : `neoswap-check.yml`
(compilation iPhone arm64 de `NeoSwap.cpp`/`NeoSwapPlugin.mm`, sonde
Simulator du plugin de production, douze langues), puis la lane
`retroarch-delivery.yml`. Un simulateur ne valide ni jetsam physique ni
le framerate.

Protocole iPhone 16 Pro Max, même sauvegarde et mêmes réglages que le
7 octobre : lancement à froid, zone légère, zone lourde, dix minutes,
retour arrière-plan/avant-plan, relancement ; export de `NeoSwap-v1.jsonl`
et du diagnostic RPCS3 ; relever `budget.hostEnvelope.limitEstimateBytes`
(la limite réelle de l'appareil), `roomBytes` minimal, `growthRampPercent`,
`relayHostLoans.shelves` (hits/misses par classe : les refus FAST doivent
chuter par rapport aux 7 084/7 462 de la Build 411), `fastAllocation.ready_misses`,
`performance_summary.fps_hold`, `RANGELOCKPROF wl_*`, et tout `.ips`
JetsamEvent. Accepter uniquement des gains mesurés sans perte de données.

## 11. Identité de la livraison

**Build 434**, IPA de test (NeoSwap : enveloppe mesurée, étagères,
préchargement froid), sur la Build 433 du mainteneur :

- source : `c27a16dc9f8baa2f9a16f1fa3d093e54a817540d` (`Claude`, au-dessus de
  `fda42ee0`, Build 433 ; aucun fichier de la 433 modifié) ;
- run de livraison : [38061542006](https://github.com/TarbleFR/neostation-ios/actions/runs/38061542006)
  (`retroarch-delivery.yml`, `workflow_dispatch`, `build_number=434`) :
  jobs `checks` (validation Dart réutilisée à l'identité des entrées,
  `verify_delivery_reuse` en ligne, gardes de pipeline), `native` (Swift
  réutilisé, hôte libretro, modules frontend, shaders Metal, compilation
  iPhone des sources libretro) et « Release device build • cold »
  (compilation Xcode 26.3 Release arm64 en 198,7 s, 13 validations d'IPA,
  scellement et export en 47,0 s) réussis ; Core RPCS3 `afb33454` run
  `37620034517`, Cores ARMSX2/Dusklight/KartPad et cœurs libretro réutilisés
  par identité exacte ;
- artefact chiffré (destinataire `delivery-424-recipient.pem`) :
  `NeoStation-Build-434-c27a16dc9f8baa2f9a16f1fa3d093e54a817540d-cold`,
  id [11672918827](https://github.com/TarbleFR/neostation-ios/actions/runs/38061542006/artifacts/11672918827),
  206 116 765 octets, empreinte SHA-256 du zip
  `25dc91ec306ce688f139831bf29cdc083819bc63784a765df080be7f3e79d412`,
  rétention 14 jours (jusqu'au 24 octobre 2026) ; diagnostics chiffrés :
  id 11672993537 ;
- IPA avant scellement (`shasum` de l'étape de validation) : SHA-256
  `4da0b9c2812dc8b003c5c32465c7d48cadb036de861d9db50081e5a42cd3659f`,
  environ 192 Mio. Le scellement re-signe chaque binaire en ad hoc, vérifie
  que les sections de code et de données et les métadonnées ABI sont
  inchangées (`allCompiledCodeAndDataSectionsUnchangedBySigning`), puis
  réarchive l'IPA ; l'empreinte scellée n'est pas écrite dans le journal CI ;
- IPA scellée, relevée le 10 octobre 2026 après déchiffrement de l'artefact
  sur le PC du mainteneur (clé privée delivery-424, `gh run download`,
  `openssl pkeyutl` RSA-OAEP SHA-256 puis `openssl enc` AES-256-CBC PBKDF2,
  dossier `nsw\b434\content`) :
  `NeoStation-Build434-c27a16dc9f8baa2f9a16f1fa3d093e54a817540d-cold.ipa`,
  SHA-256 `bc0e766bd7162f855d288cbed1199b8fb2290f2f9083a50eac1d54f6c00eded3`,
  205 913 778 octets, valeur identique dans `SHA256SUMS` et dans
  `signed-payload-identity.json` (`ipaSha256`, `ipaBytes`) ; 57 signatures
  ad hoc de préparation vérifiées sur 57 (`signature.json`), 54 images
  Mach-O aux sections de code et de données inchangées ;
- installation : par SideStore, qui applique la signature et le profil du
  compte configuré. Aucun test sur iPhone à ce stade.

Validations Apple du même commit :

- [38061545630](https://github.com/TarbleFR/neostation-ios/actions/runs/38061545630)
  `neoswap-donation-check.yml` : réussi (noyau macOS, NSXPC, stress ; harnais
  Simulator iOS 18 compilant `NeoSwap.cpp` et `NeoSwapPlugin.mm` avec de vrais
  donneurs) ;
- [38061543678](https://github.com/TarbleFR/neostation-ios/actions/runs/38061543678)
  `neoswap-relay-check.yml` : réussi (backend injecté, 1 Gio écrit après
  sortie réelle du créateur, capacité 8 Gio, extension Simulator iOS 18 avec
  le courtier de production et ses étagères, compilation et édition de liens
  iPhone arm64) ;
- [38061547151](https://github.com/TarbleFR/neostation-ios/actions/runs/38061547151)
  `neoswap-check.yml` : échoué à la porte de périmètre, exactement sur la
  dérive antérieure décrite en § 10 (`neoplay-check.yml` comparé à
  `12fb62f9`), après les six contrôles précédents réussis ; les suites du
  courtier qui suivent cette porte sont celles exécutées localement.

Ce paragraphe a été ajouté après la compilation, sans changer aucune entrée
de la Build 434 ; le commit qui le porte n'est pas celui de l'IPA.

## Sources primaires

1. Apple, [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports).
2. Apple XNU, [kern_memorystatus.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/kern_memorystatus.h), [kern_memorystatus.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus.c), [vm_statistics.h](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h), [vm_user.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_user.c) (`mach_memory_entry_ownership`).
3. Apple, [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory), [Increased Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit), [Extended Virtual Addressing](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing), [Increased Debugging Memory Limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-debugging-memory-limit).
4. Apple, [fcntl(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html) (`F_RDADVISE`, `F_RDAHEAD`, `F_NOCACHE`), [os_sync_wait_on_address](https://developer.apple.com/documentation/os/os_sync_wait_on_address).
5. Ce dépôt : `docs/neoswap-build419-memory.md`, `docs/neoswap-build409-global-budget.md`, `docs/neoplay/BUILD412.md`, `docs/rpcs3-gow3-memory-build352.md`, `docs/neoswap-guest-relay-build373.md`.
